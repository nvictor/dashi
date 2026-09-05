import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var filter: String? = "all"
    @State private var search = ""
    @State private var ordering = CardOrder.attention

    private enum CardOrder: String, CaseIterable {
        case attention = "Attention first", recent = "Most recent", name = "Name"
    }
    private var title: String {
        if filter == "attention" { return "Needs attention" }
        if let kind = PackageKind.allCases.first(where: { $0.rawValue == filter }) { return kind.rawValue + "s" }
        if let source = store.sources.first(where: { $0.id.uuidString == filter }) { return URL(fileURLWithPath: source.path).lastPathComponent }
        return "Overview"
    }
    private var visible: [DashboardItem] {
        store.items.filter { item in
            let matches: Bool
            if filter == "attention" { matches = item.attention }
            else if let kind = PackageKind.allCases.first(where: { $0.rawValue == filter }) { matches = item.kind == kind }
            else if let source = store.sources.first(where: { $0.id.uuidString == filter }) { matches = item.id == source.path || item.id.hasPrefix(source.path + "/") }
            else { matches = true }
            return matches && (search.isEmpty || "\(item.name) \(item.packageID)".localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            if ordering == .attention && lhs.attention != rhs.attention { return lhs.attention }
            if ordering != .name {
                let left = lhs.lastEvent ?? lhs.modifiedSort
                let right = rhs.lastEvent ?? rhs.modifiedSort
                if left != right { return left > right }
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Label("Overview", systemImage: "square.grid.2x2").tag("all")
                Label("Needs Attention", systemImage: "exclamationmark.circle").tag("attention")
                Section("Types") {
                    ForEach(PackageKind.allCases, id: \.self) { kind in
                        Label(kind.rawValue + "s", systemImage: kind.symbol).tag(kind.rawValue)
                    }
                }
                Section("Sources") {
                    ForEach(store.sources) { source in
                        Label(URL(fileURLWithPath: source.path).lastPathComponent, systemImage: source.problem == nil ? "folder" : "folder.badge.questionmark")
                            .help(source.path).tag(source.id.uuidString)
                            .contextMenu {
                                Button("Reconnect…") { store.chooseFolder(replacing: source.id) }
                                Button("Remove Source", role: .destructive) { store.remove(source.id) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            Group {
                if store.sources.isEmpty {
                    ContentUnavailableView {
                        Label("Your personal dashboard", systemImage: "rectangle.3.group")
                    } description: { Text("Drop folders here to see where everything stands.") }
                    actions: { Button("Add Folder…") { store.chooseFolder() } }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(title).font(.largeTitle.bold())
                                    Text("\(visible.count) items · \(visible.filter(\.attention).count) need attention")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("Sort", selection: $ordering) {
                                    ForEach(CardOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.fixedSize().labelsHidden().accessibilityLabel("Sort cards")
                            }
                            if visible.isEmpty {
                                ContentUnavailableView("No items found", systemImage: "doc.text.magnifyingglass", description: Text("Try another folder or change your filters."))
                                    .frame(maxWidth: .infinity, minHeight: 250)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 440), spacing: 16)], alignment: .leading, spacing: 16) {
                                    ForEach(visible) { item in StatusCard(item: item) }
                                }
                            }
                        }.padding(28)
                    }
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
            }
            .navigationTitle("Dashi")
            .searchable(text: $search, prompt: "Find an item")
            .toolbar {
                ToolbarItem { if store.scanning { ProgressView().controlSize(.small) } }
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }.keyboardShortcut("r") }
                ToolbarItem { Button("Add Folder", systemImage: "folder.badge.plus") { store.chooseFolder() } }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in store.add(urls); return !urls.isEmpty }
        .frame(minWidth: 780, minHeight: 520)
        .alert("Dashi", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh() }
    }
}

private extension PackageKind {
    var symbol: String {
        switch self { case .workflow: "point.3.connected.trianglepath.dotted"; case .coach: "figure.mind.and.body"; case .task: "checkmark.circle" }
    }
}

struct StatusCard: View {
    let item: DashboardItem
    @State private var showIssue = false
    private var statusColor: Color {
        if item.stale || !item.diagnostics.isEmpty { return .orange }
        switch item.status {
        case "blocked": return .orange
        case "completed": return .green
        case "active", "in_progress": return .teal
        default: return .secondary
        }
    }
    private var statusLabel: String {
        if item.stale { return "Stale" }
        if !item.diagnostics.isEmpty { return "Unable to read" }
        return item.status.replacingOccurrences(of: "_", with: " ").capitalized
    }
    private var dateLabel: String {
        guard item.lastEvent != nil else { return "State updated" }
        return item.kind == .coach ? "Last session" : "Last run"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(item.typeName, systemImage: item.kind?.symbol ?? "exclamationmark.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if item.attention {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention").help("Needs attention")
                }
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                    if !item.diagnostics.isEmpty { Button("Show Read Error…") { showIssue = true } }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(item.name)")
            }
            Text(item.name).font(.headline).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                .help("\(item.name)\n\(item.folder.path)")
            HStack(spacing: 8) {
                Text(statusLabel).font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .foregroundStyle(statusColor)
                    .background(statusColor.opacity(0.10), in: Capsule())
                if item.kind == .task, let outcome = item.outcome {
                    Text("Last run: \(outcome)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider()
            HStack {
                Text(dateLabel).foregroundStyle(.secondary)
                Spacer()
                if let date = item.lastEvent ?? item.modified {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .help("\(dateLabel): \(date.formatted())")
                } else { Text("Not recorded").foregroundStyle(.secondary) }
            }.font(.caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)) }
        .accessibilityElement(children: .contain)
        .popover(isPresented: $showIssue) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Unable to read current status").font(.headline)
                if item.stale { Text("Showing the last readable status.") }
                ForEach(item.diagnostics, id: \.self) { Text($0) }
            }.padding().frame(width: 320).textSelection(.enabled)
        }
    }
}
struct SourceSettings: View {
    @EnvironmentObject var store: DashboardStore
    var body: some View {
        VStack(alignment: .leading) {
            Text("Source folders").font(.headline)
            List(store.sources) { source in
                VStack(alignment: .leading) {
                    Text(source.path).textSelection(.enabled)
                    if let problem = source.problem { Text(problem).foregroundStyle(.orange) }
                    HStack { Button("Reconnect…") { store.chooseFolder(replacing: source.id) }; Button("Remove") { store.remove(source.id) } }
                }
            }
            Button("Add Folder…") { store.chooseFolder() }
            Text("Removing a source only removes it from Dashi. Its files remain unchanged.").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 560, height: 340)
    }
}
