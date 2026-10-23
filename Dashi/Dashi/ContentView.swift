import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var filter: String? = "all"
    @State private var search = ""
    @State private var ordering = CardOrder.recent

    private enum CardOrder: String, CaseIterable {
        case recent = "Most recent", status = "Status", due = "Due"
    }
    private var visible: [DashboardItem] {
        store.items.filter { item in
            let matches: Bool
            if let kind = PackageKind.allCases.first(where: { $0.rawValue == filter }) { matches = item.kind == kind }
            else if let source = store.sources.first(where: { $0.id.uuidString == filter }) { matches = item.id == source.path || item.id.hasPrefix(source.path + "/") }
            else { matches = true }
            return matches && (search.isEmpty || "\(item.name) \(item.packageID)".localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            if ordering == .due {
                let left = lhs.elapsedRatio() ?? -1, right = rhs.elapsedRatio() ?? -1
                if left != right { return left > right }
            }
            if ordering == .status {
                if lhs.statusRank != rhs.statusRank { return lhs.statusRank < rhs.statusRank }
                if lhs.attention != rhs.attention { return lhs.attention }
            }
            let left = lhs.lastEvent ?? lhs.modifiedSort
            let right = rhs.lastEvent ?? rhs.modifiedSort
            if left != right { return left > right }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
    private func badgeCount(for kind: PackageKind) -> Int {
        let items = store.items.filter { $0.kind == kind }
        guard kind == .coach else { return items.count }
        let overdue = items.filter { $0.dueState() == .overdue }.count
        return overdue > 0 ? overdue : items.count
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Label("Overview", systemImage: "square.grid.2x2").tag("all")
                Section("Types") {
                    ForEach(PackageKind.allCases, id: \.self) { kind in
                        Label(kind.pluralName, systemImage: kind.symbol)
                            .badge(badgeCount(for: kind))
                            .tag(kind.rawValue)
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
                                Spacer()
                                Picker("Sort", selection: $ordering) {
                                    ForEach(CardOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.segmented).fixedSize().labelsHidden().accessibilityLabel("Sort cards")
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
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }.keyboardShortcut("r").help("Refresh") }
                ToolbarItem { Button("Add Folder", systemImage: "folder.badge.plus") { store.chooseFolder() }.help("Add source folder") }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in store.add(urls); return !urls.isEmpty }
        .onChange(of: filter) { _, new in if new == PackageKind.coach.rawValue { ordering = .due } }
        .frame(minWidth: 780, minHeight: 520)
        .alert("Dashi", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh() }
    }
}

private extension PackageKind {
    var symbol: String {
        switch self { case .workflow: "point.3.connected.trianglepath.dotted"; case .coach: "figure.mind.and.body"; case .task: "checkmark.circle"; case .conversation: "bubble.left.and.bubble.right" }
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
        guard item.lastEvent != nil else { return item.kind == .coach ? "Last session" : "State updated" }
        return item.kind == .coach ? "Last session" : "Last run"
    }
    private func dueChip(_ due: DueState, ratio: Double) -> some View {
        let color: Color = due == .overdue ? .orange : due == .dueSoon ? .yellow : .green
        let detail = due == .overdue && ratio.isFinite ? String(format: "%.1f× cadence", ratio) : nil
        return Text([due.label, detail].compactMap { $0 }.joined(separator: " · "))
            .font(.caption.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .help(ratio.isFinite ? "\(Int(ratio * 100))% of the target cadence has passed since the last session." : "No session recorded yet.")
    }
    private var lastRunAge: String? {
        guard item.kind == .coach, let date = item.lastEvent else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(item.typeName, systemImage: item.kind?.symbol ?? "exclamationmark.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if let title = item.runPromptTitle, let prompt = item.runPrompt {
                        Button(title) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                        }
                    }
                    if let prompt = item.statusPrompt {
                        Button("Status") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                        }
                    }
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
                if let detail = item.attentionReason {
                    Label(detail, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        .accessibilityLabel("Needs attention: \(detail)").help(detail)
                }
                if let due = item.dueState() { dueChip(due, ratio: item.elapsedRatio() ?? 0) }
            }
            Divider()
            HStack {
                Text(dateLabel).foregroundStyle(.secondary)
                Spacer()
                if let date = item.kind == .coach ? item.lastEvent : (item.lastEvent ?? item.modified) {
                    HStack(spacing: 6) {
                        if let age = lastRunAge { Text(age).foregroundStyle(.secondary) }
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                    }.help("\(dateLabel): \(date.formatted())")
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
