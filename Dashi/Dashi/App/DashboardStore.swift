import AppKit
import Combine
import CoreServices

struct Source: Identifiable, Codable {
    var id = UUID()
    var path: String
    var bookmark: Data
    var problem: String?
}
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    var changed: (([String], Bool) -> Void)?
    func start(_ paths: [String]) {
        stop(); guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let changedPaths = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            let resetMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let reset = (0..<count).contains { flags[$0] & resetMask != 0 }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed?(changedPaths, reset)
        }, &context, paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
    }
    func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil }
    deinit { stop() }
}
@MainActor
final class DashboardStore: ObservableObject {
    @Published var sources: [Source] = []
    @Published var items: [DashboardItem] = []
    @Published var scanning = false
    @Published var error: String?
    private var access: [UUID: URL] = [:]
    private let watcher = FolderWatcher()
    private var debounce: Task<Void, Never>?
    private var refreshAgain = false
    private var pendingPaths: Set<String> = []
    private var needsFullScan = false
    private var generation = 0
    init() {
        if let data = UserDefaults.standard.data(forKey: "sources") { sources = (try? JSONDecoder().decode([Source].self, from: data)) ?? [] }
        resolve()
        watcher.changed = { [weak self] paths, reset in
            Task { @MainActor in
                self?.pendingPaths.formUnion(paths)
                self?.needsFullScan = (self?.needsFullScan ?? false) || reset
                self?.debounce?.cancel()
                self?.debounce = Task { try? await Task.sleep(for: .milliseconds(300)); guard !Task.isCancelled else { return }; self?.refreshChanged() }
            }
        }
        refresh()
    }
    private func persist() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(sources), forKey: "sources") }
        catch { self.error = error.localizedDescription }
    }
    private func resolve() {
        generation += 1
        for url in access.values { url.stopAccessingSecurityScopedResource() }; access = [:]
        for index in sources.indices {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: sources[index].bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw PackageReader.ReadError("Folder access expired. Reconnect this source.") }
                access[sources[index].id] = url
                sources[index].path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if stale { sources[index].bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
                sources[index].problem = nil
            } catch { sources[index].problem = error.localizedDescription }
        }
        persist(); watcher.start(access.values.map(\.path))
    }
    func chooseFolder(replacing id: UUID? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = id == nil
        guard panel.runModal() == .OK else { return }; add(panel.urls, replacing: id)
    }
    func add(_ urls: [URL], replacing id: UUID? = nil) {
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw PackageReader.ReadError("Choose a folder.") }
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                if sources.contains(where: { $0.id != id && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == canonical }) { continue }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                let source = Source(id: id ?? UUID(), path: canonical.path, bookmark: bookmark)
                if let id, let index = sources.firstIndex(where: { $0.id == id }) { sources[index] = source } else { sources.append(source) }
            } catch { self.error = error.localizedDescription }
        }
        resolve(); refresh()
    }
    func remove(_ id: UUID) { sources.removeAll { $0.id == id }; resolve(); refresh() }
    private func refreshChanged() {
        let paths = pendingPaths; pendingPaths = []
        let full = needsFullScan; needsFullScan = false
        // New manifests, removals, and directory events can change discovery membership.
        let folders = items.filter { item in paths.contains { path in
            [item.stateURL?.path, item.definitionURL?.path].compactMap { $0 }.contains(path)
        }}.map(\.folder)
        let knownFiles = Set(items.flatMap { [$0.stateURL?.path, $0.definitionURL?.path].compactMap { $0 } })
        if full || !paths.isSubset(of: knownFiles) { refresh() }
        else if !folders.isEmpty { refresh(affected: folders) }
    }
    func refresh(affected: [URL]? = nil) {
        if scanning { refreshAgain = true; return }
        scanning = true
        let roots = Array(access.values)
        let scanGeneration = generation
        let prior = items
        Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                if let affected { return affected.compactMap { PackageReader.read($0) } }
                return Discovery.scan(roots)
            }.value
            guard scanGeneration == generation else { scanning = false; refresh(); return }
            var merged = SnapshotMerge.merge(previous: prior, fresh: fresh, affected: affected?.map(\.path))
            for source in sources where source.problem != nil {
                let url = URL(fileURLWithPath: source.path)
                var issue = DashboardItem(folder: url, packageID: source.path, name: url.lastPathComponent)
                issue.diagnostics = [source.problem!]; merged.append(issue)
                for var old in items where old.id.hasPrefix(source.path + "/") { old.stale = true; old.diagnostics = [source.problem!]; merged.append(old) }
            }
            items = merged; scanning = false
            if refreshAgain { refreshAgain = false; refresh() }
        }
    }
}
