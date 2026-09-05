import Foundation

enum PackageKind: String, CaseIterable, Codable, Sendable {
    case workflow = "Workflow", coach = "Coach", task = "Task"
    var field: String { switch self { case .workflow: "workflow_file"; case .coach: "prompt_file"; case .task: "task_file" } }
    var pluralName: String { switch self { case .coach: "Coaches"; default: rawValue + "s" } }
}
struct StateSection: Identifiable, Sendable {
    var id: Int
    var title: String
    var body: String
}
struct DashboardItem: Identifiable, Sendable {
    var id: String { folder.path }
    var folder: URL
    var packageID: String
    var name: String
    var kind: PackageKind?
    var status = "Unavailable"
    var summary = "Unavailable"
    var sections: [StateSection] = []
    var diagnostics: [String] = []
    var attentionReason: String?
    var modified: Date?
    var stateURL: URL?
    var definitionURL: URL?
    var schedule: String?
    var lastEvent: Date?
    var outcome: String?
    var stale = false
    var typeName: String { kind?.rawValue ?? "Issue" }
    var modifiedSort: Date { modified ?? .distantPast }
    var attention: Bool { attentionReason != nil || !diagnostics.isEmpty }
    var attentionDetail: String? { attentionReason ?? diagnostics.first }
    /// Sort order for the "Status" card ordering: most urgent first, terminal and unknown last.
    var statusRank: Int {
        if !diagnostics.isEmpty { return 0 }
        switch status {
        case "blocked": return 1
        case "in_progress", "active": return 2
        case "paused": return 3
        case "draft": return 4
        case "completed": return 5
        case "archived", "abandoned": return 6
        default: return 7
        }
    }
}
struct StateDocument {
    var preamble: String
    var sections: [StateSection]
    init(_ text: String) {
        let clean = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        var title: String?; var lines: [String] = []; var result: [StateSection] = []; var intro = ""
        var fence: Character?; var fenceCount = 0
        for line in clean.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let first = trimmed.first
            let count = trimmed.prefix { $0 == first }.count
            if let marker = fence {
                lines.append(line)
                if first == marker && count >= fenceCount && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                continue
            }
            if (first == "`" || first == "~") && count >= 3 { fence = first; fenceCount = count; lines.append(line); continue }
            if trimmed.hasPrefix("## ") {
                let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if let title { result.append(.init(id: result.count, title: title, body: body)) } else { intro = body }
                title = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces); lines = []
            } else { lines.append(line) }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let title { result.append(.init(id: result.count, title: title, body: body)) } else { intro = body }
        preamble = intro; sections = result
    }
    func section(_ title: String) -> String? {
        let matches = sections.filter { $0.title.lowercased() == title.lowercased() }
        return matches.count == 1 ? matches.first?.body : nil
    }
    static func meaningful(_ text: String?) -> Bool {
        guard let text else { return false }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*.")).lowercased() }.filter { !$0.isEmpty }
        return lines.contains { !["none", "none recorded", "no checkpoint required"].contains($0) && !$0.hasPrefix("none for ") }
    }
    static func explicitDate(_ text: String?) -> Date? {
        guard let text, let range = text.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"#, options: .regularExpression) else { return nil }
        let value = String(text[range]); let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
struct PackageReader {
    static func read(_ folder: URL) -> DashboardItem? {
        var item = DashboardItem(folder: folder, packageID: folder.lastPathComponent, name: folder.lastPathComponent)
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError("Manifest must be a JSON object.") }
            let kinds = PackageKind.allCases.filter { manifest[$0.field] != nil }
            guard !kinds.isEmpty else { return nil }
            guard kinds.count == 1, let kind = kinds.first else { throw ReadError("Manifest has conflicting package types.") }
            item.kind = kind
            item.packageID = manifest["id"] as? String ?? folder.lastPathComponent
            item.name = manifest["name"] as? String ?? item.packageID.replacingOccurrences(of: "-", with: " ").capitalized
            guard let version = manifest["schema_version"] as? Int, version == (kind == .workflow ? 1 : 2) else { throw ReadError("Unsupported package schema version.") }
            guard let packageID = manifest["id"] as? String, packageID == folder.lastPathComponent,
                  packageID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else { throw ReadError("Package ID must match its folder and use lowercase hyphenated words.") }
            func file(_ key: String) throws -> URL {
                guard let path = manifest[key] as? String, !path.isEmpty, !path.hasPrefix("/") else { throw ReadError("Missing or unsafe \(key).") }
                let url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                let root = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                guard url.path.hasPrefix(root) else { throw ReadError("\(key) points outside the package.") }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw ReadError("\(key) is not a regular file.") }
                return url
            }
            item.stateURL = try file("state_file"); item.definitionURL = try file(kind.field)
            _ = try file("runner_file")
            if kind == .workflow { _ = try file("memory_file") }
            guard let stateURL = item.stateURL else { throw ReadError("Missing state file.") }
            let doc = StateDocument(try String(contentsOf: stateURL, encoding: .utf8))
            item.sections = doc.sections
            item.modified = try stateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if kind == .workflow {
                let statuses = doc.preamble.components(separatedBy: .newlines).filter { $0.hasPrefix("Status:") }.map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) }
                if statuses.count == 1, let status = statuses.first, ["draft", "in_progress", "paused", "blocked", "completed", "abandoned"].contains(status) { item.status = status }
                else { item.diagnostics.append("Missing, ambiguous, or invalid workflow lifecycle.") }
                item.summary = doc.section("Current step") ?? "Unavailable"
            } else {
                if let status = manifest["status"] as? String, ["draft", "active", "paused", "archived"].contains(status) { item.status = status }
                else { item.diagnostics.append("Missing or invalid package lifecycle.") }
                item.summary = doc.section(kind == .coach ? "Next useful target" : "Current checkpoint") ?? "Unavailable"
                item.lastEvent = StateDocument.explicitDate(doc.section(kind == .coach ? "Last completed session" : "Last attempted run"))
                if kind == .task, let run = doc.section("Last attempted run") {
                    let words = run.lowercased().components(separatedBy: CharacterSet.letters.inverted)
                    let outcomes = ["success", "failed", "blocked", "partial", "no-op"].filter { $0 == "no-op" ? run.lowercased().contains("no-op") : words.contains($0) }
                    if outcomes.count == 1 { item.outcome = outcomes[0] }
                }
                if let schedule = manifest["schedule"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: schedule, options: [.prettyPrinted, .sortedKeys]) { item.schedule = String(data: data, encoding: .utf8) }
            }
            let terminal = ["completed", "abandoned", "archived"].contains(item.status)
            let openSections = terminal ? [] : ["Blockers", "Pending decisions", "Known failures", "Open interaction", "Open operation"].filter { StateDocument.meaningful(doc.section($0)) }
            if item.status == "blocked" { item.attentionReason = "Blocked" }
            else if !terminal, let outcome = item.outcome, ["failed", "blocked", "partial"].contains(outcome) { item.attentionReason = "Last run \(outcome)" }
            else if let section = openSections.first { item.attentionReason = "Unresolved \(section.lowercased())" }
        } catch { item.diagnostics.append(error.localizedDescription) }
        return item
    }
    struct ReadError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
struct Discovery {
    static func scan(_ roots: [URL]) -> [DashboardItem] {
        var items: [String: DashboardItem] = [:]
        var visited: Set<String> = []
        let fm = FileManager.default
        func visit(_ folder: URL) {
            let root = folder.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(root.path).inserted else { return }
            do {
                let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles])
                if children.contains(where: { $0.lastPathComponent == "manifest.json" }), let item = PackageReader.read(root) { items[item.id] = item }
                for child in children {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                    if values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true && !["node_modules", "build", "DerivedData"].contains(child.lastPathComponent) { visit(child) }
                }
            } catch {
                var issue = DashboardItem(folder: root, packageID: root.lastPathComponent, name: root.lastPathComponent)
                issue.diagnostics = ["Cannot read folder: \(error.localizedDescription)"]
                items[issue.id] = issue
            }
        }
        for root in roots { visit(root) }
        return Array(items.values)
    }
}

/// Keeps readable state visible when a later read fails, without hiding the failure.
struct SnapshotMerge {
    static func merge(previous: [DashboardItem], fresh: [DashboardItem], affected: [String]? = nil) -> [DashboardItem] {
        var result = fresh
        if let affected { result += previous.filter { !affected.contains($0.id) } }
        for index in result.indices where !result[index].diagnostics.isEmpty {
            let failure = result[index]
            if var old = previous.first(where: { $0.id == failure.id && !$0.sections.isEmpty }) {
                old.diagnostics = failure.diagnostics; old.stale = true; result[index] = old
            }
            for var old in previous where old.id.hasPrefix(failure.id + "/") && !result.contains(where: { $0.id == old.id }) {
                old.diagnostics = failure.diagnostics; old.stale = true; result.append(old)
            }
        }
        return result
    }
}
