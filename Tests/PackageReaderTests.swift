import XCTest
@testable import Dashi

final class PackageReaderTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult
    func package(_ name: String = "sample", kind: PackageKind = .workflow, state: String = "Status: draft\n\n## Current step\nStep one", parent: URL? = nil, changes: [String: Any] = [:]) throws -> URL {
        let folder = (parent ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["id": name, "schema_version": kind == .workflow || kind == .conversation ? 1 : 2, kind.field: "definition.md", "state_file": "state.md", "runner_file": "runner.md", "status": "active", "memory_file": "memory.md"]
        manifest.merge(changes) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for file in ["definition.md", "runner.md", "memory.md"] { try "# Synthetic fixture".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        try state.write(to: folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
        return folder
    }
    func testWorkflowAndUnknownSections() throws {
        let folder = try package(state: "Status: blocked\n## Current step\nStep two\n## Blockers\nWaiting for input\n## Extra knowledge\nKeep me")
        let item = try XCTUnwrap(PackageReader.read(folder))
        XCTAssertEqual(item.status, "blocked"); XCTAssertTrue(item.attention); XCTAssertEqual(item.summary, "Step two")
        XCTAssertEqual(item.sections.last?.title, "Extra knowledge"); XCTAssertNotNil(item.modified)
    }
    func testCoachDateAndFocus() throws {
        let folder = try package(kind: .coach, state: "## Last completed session\n- 2026-09-01T10:00:00Z: Practiced.\n## Current difficulty\nBaseline\n## Next useful target\nPractice again\n## Open interaction\n- None.")
        let item = try XCTUnwrap(PackageReader.read(folder))
        XCTAssertEqual(item.status, "active"); XCTAssertEqual(item.summary, "Practice again"); XCTAssertNotNil(item.lastEvent); XCTAssertFalse(item.attention)
    }
    func testTaskShowsLifecycleWithoutOutcome() throws {
        let folder = try package(kind: .task, state: "## Last attempted run\n- 2026-09-01T10:00:00-04:00 — partial.\n## Current checkpoint\nTwo remaining\n## Known failures\n- Flaky step")
        let item = try XCTUnwrap(PackageReader.read(folder))
        XCTAssertEqual(item.status, "active"); XCTAssertNotNil(item.lastEvent); XCTAssertEqual(item.summary, "Two remaining"); XCTAssertFalse(item.attention)
    }
    func testConversationHasNoLifecycle() throws {
        let folder = try package(kind: .conversation, state: "# Conversation state\n\n## Current question\nWhat makes a chorus land?\n\n## Unresolved threads\nNone recorded yet.\n\n## Pending exchange\nNo exchange has occurred in this package.\n\n## Resume point\nStart from the current question.")
        let item = try XCTUnwrap(PackageReader.read(folder))
        XCTAssertEqual(item.status, "ongoing"); XCTAssertEqual(item.summary, "What makes a chorus land?")
        XCTAssertFalse(item.attention); XCTAssertNil(item.lastEvent); XCTAssertTrue(item.diagnostics.isEmpty)
    }
    func testAttentionIsOnlyBlockedOrUnreadable() throws {
        let blocked = try XCTUnwrap(PackageReader.read(try package("blocked", state: "Status: blocked\n## Current step\nx")))
        XCTAssertEqual(blocked.attentionReason, "Blocked"); XCTAssertEqual(blocked.attentionDetail, "Blocked")
        let open = try XCTUnwrap(PackageReader.read(try package("open", state: "Status: in_progress\n## Current step\nx\n## Pending decisions\n- Pick a database")))
        XCTAssertNil(open.attentionReason); XCTAssertFalse(open.attention)
        let done = try XCTUnwrap(PackageReader.read(try package("done", state: "Status: completed\n## Current step\nx\n## Blockers\n- Waiting on review")))
        XCTAssertEqual(done.status, "completed"); XCTAssertNil(done.attentionReason); XCTAssertFalse(done.attention)
    }
    func testCadenceDays() {
        XCTAssertNil(DueState.cadenceDays(["frequency": "manual", "interval": 1]))
        XCTAssertEqual(DueState.cadenceDays(["frequency": "daily"]), 1)
        XCTAssertEqual(DueState.cadenceDays(["frequency": "weekly", "interval": 1]), 7)
        XCTAssertEqual(DueState.cadenceDays(["frequency": "weekly", "interval": 2]), 14)
        XCTAssertEqual(DueState.cadenceDays(["frequency": "monthly", "interval": 1]), 30)
        XCTAssertNil(DueState.cadenceDays(["frequency": "weekly", "interval": 0]))
    }
    func testDueStateBoundaries() {
        XCTAssertEqual(DueState.classify(elapsedRatio: 0.74), .onTrack)
        XCTAssertEqual(DueState.classify(elapsedRatio: 0.75), .dueSoon)
        XCTAssertEqual(DueState.classify(elapsedRatio: 1.0), .dueSoon)
        XCTAssertEqual(DueState.classify(elapsedRatio: 1.01), .overdue)
        XCTAssertEqual(DueState.classify(elapsedRatio: .infinity), .overdue)
    }
    func testCoachDueStateFromManifestAndState() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        let schedule: [String: Any] = ["frequency": "weekly", "interval": 1]
        let recent = try XCTUnwrap(PackageReader.read(try package("recent", kind: .coach, state: "## Last completed session\n- 2026-10-21T12:00:00Z: Done.", changes: ["schedule": schedule])))
        XCTAssertEqual(recent.dueState(now: now), .onTrack)
        let late = try XCTUnwrap(PackageReader.read(try package("late", kind: .coach, state: "## Last completed session\n- 2026-10-01T12:00:00Z: Done.", changes: ["schedule": schedule])))
        XCTAssertEqual(late.dueState(now: now), .overdue)
        let never = try XCTUnwrap(PackageReader.read(try package("never", kind: .coach, state: "## Last completed session\n- None recorded.", changes: ["schedule": schedule])))
        XCTAssertEqual(never.dueState(now: now), .overdue)
        let manual = try XCTUnwrap(PackageReader.read(try package("manual", kind: .coach, state: "## Last completed session\n- 2026-10-01T12:00:00Z: Done.", changes: ["schedule": ["frequency": "manual", "interval": 1]])))
        XCTAssertNil(manual.dueState(now: now))
        let paused = try XCTUnwrap(PackageReader.read(try package("paused", kind: .coach, state: "## Last completed session\n- 2026-10-01T12:00:00Z: Done.", changes: ["schedule": schedule, "status": "paused"])))
        XCTAssertNil(paused.dueState(now: now))
        let task = try XCTUnwrap(PackageReader.read(try package("task", kind: .task, state: "## Last attempted run\n- 2026-10-01T12:00:00Z: Done.", changes: ["schedule": schedule])))
        XCTAssertNil(task.dueState(now: now))
    }
    func testRunPromptPerKind() throws {
        let titles: [PackageKind: String] = [.coach: "Run Coach", .task: "Run Task", .workflow: "Resume Workflow", .conversation: "Resume Conversation"]
        for (kind, title) in titles {
            let item = try XCTUnwrap(PackageReader.read(try package("p-\(kind.rawValue.lowercased())", kind: kind, state: kind == .workflow ? "Status: draft\n## Current step\nx" : "## Current question\nx")))
            XCTAssertEqual(item.runPromptTitle, title)
            let prompt = try XCTUnwrap(item.runPrompt)
            XCTAssertTrue(prompt.contains("\"\(item.folder.path)\"")); XCTAssertTrue(prompt.contains("runner.md")); XCTAssertTrue(prompt.localizedCaseInsensitiveContains(kind.rawValue))
            let status = try XCTUnwrap(item.statusPrompt)
            XCTAssertTrue(status.contains("\"\(item.folder.path)\"")); XCTAssertTrue(status.contains("read-only")); XCTAssertTrue(status.localizedCaseInsensitiveContains("status"))
            XCTAssertNotEqual(status, prompt)
        }
    }
    func testStatusRankOrder() throws {
        let ranks = try ["Status: blocked", "Status: in_progress", "Status: paused", "Status: draft", "Status: completed", "Status: abandoned"].enumerated().map {
            try XCTUnwrap(PackageReader.read(try package("rank\($0.offset)", state: "\($0.element)\n## Current step\nx"))).statusRank
        }
        XCTAssertEqual(ranks, ranks.sorted()); XCTAssertEqual(Set(ranks).count, ranks.count)
        let broken = try XCTUnwrap(PackageReader.read(try package("broken", state: "Status: nonsense\n## Current step\nx")))
        XCTAssertEqual(broken.statusRank, 0)
    }
    func testEmptyMarkersAndUnrelatedDates() throws {
        let doc = StateDocument("## Last attempted run\n- None recorded.\n## Extra\n2026-09-01T10:00:00Z")
        XCTAssertNil(StateDocument.explicitDate(doc.section("Last attempted run")))
        for value in ["- None.", "None recorded.", "", "- None for beginning step 1."] { XCTAssertFalse(StateDocument.meaningful(value)) }
        XCTAssertTrue(StateDocument.meaningful("Waiting for feedback"))
    }
    func testMarkdownCommentsFencesAndDuplicateSections() {
        let doc = StateDocument("Status: draft\n<!--\n## False\n-->\n## Current step\n```swift\n## Not a section\n```\nActual text\n## Other\nOne\n## Other\nTwo")
        XCTAssertEqual(doc.sections.count, 3); XCTAssertTrue(doc.section("Current step")!.contains("Not a section")); XCTAssertNil(doc.section("Other"))
    }
    func testInvalidAndAmbiguousLifecycles() throws {
        for (name, state) in [("invalid", "Status: running"), ("ambiguous", "Status: draft\nStatus: completed")] {
            let item = try XCTUnwrap(PackageReader.read(try package(name, state: state)))
            XCTAssertEqual(item.status, "Unavailable"); XCTAssertTrue(item.attention)
        }
    }
    func testVersionsDiscriminatorsAndMissingFiles() throws {
        let unsupported = try package("version", changes: ["schema_version": 99])
        let conflict = try package("conflict", changes: ["prompt_file": "definition.md"])
        let missing = try package("missing", changes: ["runner_file": "absent.md"])
        for folder in [unsupported, conflict, missing] { XCTAssertFalse(try XCTUnwrap(PackageReader.read(folder)).diagnostics.isEmpty) }
    }
    func testPathTraversalAndSymlinkEscape() throws {
        let outside = root.appendingPathComponent("outside.md"); try "secret".write(to: outside, atomically: true, encoding: .utf8)
        let traversal = try package("traversal", changes: ["state_file": "../outside.md"])
        XCTAssertTrue(try XCTUnwrap(PackageReader.read(traversal)).attention)
        let symlink = try package("symlink", changes: ["state_file": "linked.md"])
        try FileManager.default.createSymbolicLink(at: symlink.appendingPathComponent("linked.md"), withDestinationURL: outside)
        XCTAssertTrue(try XCTUnwrap(PackageReader.read(symlink)).attention)
    }
    func testDiscoverySkipsArchiveFolders() throws {
        let archive = root.appendingPathComponent("archive")
        try package("old-chat", kind: .conversation, state: "## Current question\nx", parent: archive)
        try package("live-chat", kind: .conversation, state: "## Current question\nx")
        XCTAssertEqual(Discovery.scan([root]).map(\.packageID), ["live-chat"])
    }
    func testNestedDiscoveryOverlapAndDuplicateIDs() throws {
        let first = try package(parent: root.appendingPathComponent("one"))
        let second = try package(parent: root.appendingPathComponent("two"))
        for excluded in [".hidden", "build", "node_modules", "DerivedData"] { try package(parent: root.appendingPathComponent(excluded)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: first.deletingLastPathComponent())
        let items = Discovery.scan([root, first])
        XCTAssertEqual(Set(items.map(\.id)), Set([first.path, second.path]))
    }
    func testMalformedAndUnrelatedManifests() throws {
        let folder = try package()
        try "{".write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(PackageReader.read(folder)).attention)
        try "{\"name\":\"unrelated\"}".write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(PackageReader.read(folder))
    }
    func testAtomicReplacementCreationDeletionAndReadFailure() throws {
        let folder = try package()
        XCTAssertEqual(Discovery.scan([root]).count, 1)
        try "Status: completed".write(to: folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Discovery.scan([root]).first?.status, "completed")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("state.md"))
        XCTAssertTrue(Discovery.scan([root]).first!.attention)
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(Discovery.scan([root]).isEmpty)
    }
}

extension PackageReaderTests {
    func testStaleSnapshotAndRecovery() throws {
        let folder = try package()
        let previous = Discovery.scan([root])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("state.md"))
        let stale = SnapshotMerge.merge(previous: previous, fresh: Discovery.scan([root]))
        XCTAssertEqual(stale.first?.summary, "Step one"); XCTAssertEqual(stale.first?.stale, true)
        XCTAssertFalse(stale.first!.diagnostics.isEmpty)
        try "Status: completed".write(to: folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
        let recovered = SnapshotMerge.merge(previous: stale, fresh: Discovery.scan([root]))
        XCTAssertEqual(recovered.first?.status, "completed"); XCTAssertEqual(recovered.first?.stale, false)
    }
    func testPartialRefreshKeepsOtherItems() throws {
        let first = try package("first"); try package("second")
        let previous = Discovery.scan([root])
        let merged = SnapshotMerge.merge(previous: previous, fresh: [try XCTUnwrap(PackageReader.read(first))], affected: [first.path])
        XCTAssertEqual(merged.count, 2)
    }
}

extension PackageReaderTests {
    @MainActor
    func testFileWatcherReceivesAtomicReplacement() async throws {
        let folder = try package()
        let event = expectation(description: "State change delivered")
        event.assertForOverFulfill = false
        let watcher = FolderWatcher()
        watcher.changed = { paths, _ in
            if paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path) }) { event.fulfill() }
        }
        watcher.start([root.path])
        defer { watcher.stop() }
        try "Status: completed".write(to: folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
        await fulfillment(of: [event], timeout: 2)
    }
    func testReadsDoNotModifyPackageFiles() throws {
        let folder = try package()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let before = try files.map { try Data(contentsOf: $0) }
        _ = Discovery.scan([root]); _ = PackageReader.read(folder)
        XCTAssertEqual(before, try files.map { try Data(contentsOf: $0) })
    }
    func testTimestampOffsetsAndFractionalSeconds() {
        XCTAssertEqual(StateDocument.explicitDate("2026-09-01T10:00:00-04:00"), StateDocument.explicitDate("2026-09-01T14:00:00Z"))
        XCTAssertNotNil(StateDocument.explicitDate("2026-09-01T10:00:00.123Z"))
        XCTAssertNil(StateDocument.explicitDate("September 1, 2026"))
    }
}
