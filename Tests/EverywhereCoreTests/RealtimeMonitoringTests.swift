import CoreServices
import XCTest
@testable import EverywhereCore

final class RealtimeMonitoringTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var db: Database!
    private var config: IndexConfig { IndexConfig(roots: [root.path]) }
    private let fileFlags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try index()
    }

    override func tearDownWithError() throws {
        db = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func index() throws {
        try FilesystemIndexer(db: db, config: config).run()
    }

    private func event(_ path: URL, id: UInt64 = 42) -> FileSystemEvent {
        FileSystemEvent(path: path.path, id: id, flags: fileFlags)
    }

    private func reconcile(_ events: [FileSystemEvent], limit: Int = 16_384) throws -> Commit {
        let recorder = Recorder()
        let handler = ChangeHandler(db: db, config: config, debounce: 30, maxPendingPaths: limit,
                                    onCommit: { recorder.append(Commit(id: $0, history: $1, stats: $2)) },
                                    onError: { XCTFail("Reconciliation failed: \($0)") })
        defer { handler.stop() }
        handler.ingest(events: events)
        handler.flushPendingNow()
        return try XCTUnwrap(recorder.commits.last)
    }

    func testFileEventChecksOneEntryWithoutEnumeratingWideParent() throws {
        for number in 0..<128 {
            try Data([1]).write(to: root.appendingPathComponent("sibling-\(number).txt"))
        }
        try index()
        let file = root.appendingPathComponent("sibling-64.txt")
        let oldID = try XCTUnwrap(db.search(SearchRequest(text: "sibling-64.txt")).entries.first?.id)
        try Data([1, 2, 3]).write(to: file)
        let commit = try reconcile([event(file)])
        XCTAssertEqual(commit.stats.scannedItems, 1)
        XCTAssertEqual(commit.stats.scannedDirectories, 0)
        XCTAssertEqual(commit.stats.rows, 1)
        XCTAssertTrue(commit.stats.didChangeIndex)
        let result = try XCTUnwrap(db.search(SearchRequest(text: "sibling-64.txt")).entries.first)
        XCTAssertEqual(result.id, oldID)
        XCTAssertEqual(result.size, 3)
        let generation = db.entryChangeGeneration
        let unchanged = try reconcile([event(file, id: 43)])
        XCTAssertFalse(unchanged.stats.didChangeIndex)
        XCTAssertEqual(unchanged.stats.rows, 0)
        XCTAssertEqual(unchanged.id, 43)
        XCTAssertEqual(db.entryChangeGeneration, generation)
    }

    func testPointChecksDiscoverNewPathsAndPruneVanishedPaths() throws {
        let old = root.appendingPathComponent("old.txt")
        let renamed = root.appendingPathComponent("renamed.txt")
        try Data([1]).write(to: old)
        XCTAssertTrue(try reconcile([event(old)]).stats.didChangeIndex)
        try FileManager.default.moveItem(at: old, to: renamed)
        let rename = try reconcile([event(old), event(renamed, id: 43)])
        XCTAssertEqual(rename.stats.scannedDirectories, 0)
        XCTAssertEqual(rename.stats.deleted, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "old.txt")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "renamed.txt")).total, 1)
        try FileManager.default.removeItem(at: renamed)
        XCTAssertTrue(try reconcile([event(renamed)]).stats.didChangeIndex)
        XCTAssertEqual(try db.search(SearchRequest(text: "renamed.txt")).total, 0)
        XCTAssertFalse(try reconcile([event(renamed)]).stats.didChangeIndex)
    }

    func testFileEventUnderMissingAncestorsDiscoversTheirSiblings() throws {
        let nested = root.appendingPathComponent("new/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let leaf = nested.appendingPathComponent("leaf.txt")
        try Data([1]).write(to: leaf)
        try Data([1]).write(to: nested.deletingLastPathComponent().appendingPathComponent("sibling.txt"))
        try Data([1]).write(to: root.appendingPathComponent("peer.txt"))
        let commit = try reconcile([event(leaf)])
        XCTAssertEqual(commit.stats.scannedDirectories, 3)
        for name in ["leaf.txt", "sibling.txt", "peer.txt"] {
            XCTAssertEqual(try db.search(SearchRequest(text: name)).total, 1)
        }
    }

    func testDirectoryEventUnderMissingAncestorsDoesNotCreateUnscannedPlaceholders() throws {
        let nested = root.appendingPathComponent("new/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("leaf.txt"))
        try Data([1]).write(to: nested.deletingLastPathComponent().appendingPathComponent("sibling.txt"))
        _ = try reconcile([FileSystemEvent(path: nested.path, id: 42)])
        XCTAssertEqual(try db.search(SearchRequest(text: "leaf.txt")).total, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "sibling.txt")).total, 1)
    }

    func testFileToDirectoryReplacementFallsBackRecursively() throws {
        let item = root.appendingPathComponent("item")
        try Data([1]).write(to: item)
        try index()
        try FileManager.default.removeItem(at: item)
        try FileManager.default.createDirectory(at: item.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try Data([1]).write(to: item.appendingPathComponent("deep/created.txt"))
        let commit = try reconcile([event(item)])
        XCTAssertTrue(commit.stats.didChangeIndex)
        XCTAssertEqual(try db.search(SearchRequest(text: "created.txt")).total, 1)
        XCTAssertTrue(try XCTUnwrap(db.search(SearchRequest(text: "item")).entries.first).isDirectory)
    }

    func testDirectoryToSymlinkReplacementPrunesOldDescendantsWithoutFollowingLink() throws {
        let item = root.appendingPathComponent("item")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data([1]).write(to: item.appendingPathComponent("stale.txt"))
        try index()
        try FileManager.default.removeItem(at: item)
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: root)
        let commit = try reconcile([FileSystemEvent(path: item.path, id: 42,
                                                    flags: UInt32(kFSEventStreamEventFlagItemIsSymlink))])
        XCTAssertEqual(commit.stats.scannedDirectories, 0)
        XCTAssertTrue(commit.stats.didChangeIndex)
        XCTAssertEqual(try db.search(SearchRequest(text: "stale.txt")).total, 0)
        XCTAssertFalse(try XCTUnwrap(db.search(SearchRequest(text: "item")).entries.first).isDirectory)
    }

    func testStaleDirectoryAndNewFileFlagsHandleSamePathReplacementInEitherOrder() throws {
        for directoryFirst in [true, false] {
            let item = root.appendingPathComponent("item-\(directoryFirst)")
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try Data([1]).write(to: item.appendingPathComponent("stale-\(directoryFirst).txt"))
            try index()
            try FileManager.default.removeItem(at: item)
            try Data([1]).write(to: item)
            let directoryEvent = FileSystemEvent(path: item.path, id: 41,
                                                flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRemoved))
            let fileEvent = event(item)
            let commit = try reconcile(directoryFirst ? [directoryEvent, fileEvent] : [fileEvent, directoryEvent])
            XCTAssertEqual(commit.id, 42)
            XCTAssertFalse(try XCTUnwrap(db.search(SearchRequest(text: "item-\(directoryFirst)")).entries.first).isDirectory)
            XCTAssertEqual(try db.search(SearchRequest(text: "stale-\(directoryFirst).txt")).total, 0)
        }
    }

    func testCaseOnlyRenameReconcilesActualFilenameWithoutGhostRows() throws {
        for includeOldPath in [true, false] {
            let old = root.appendingPathComponent("Mixed-\(includeOldPath).txt")
            let renamed = root.appendingPathComponent("mixed-\(includeOldPath).txt")
            try Data([1]).write(to: old)
            guard FileManager.default.fileExists(atPath: renamed.path) else {
                throw XCTSkip("Requires a case-insensitive fixture volume")
            }
            try index()
            try FileManager.default.moveItem(at: old, to: renamed)
            let flags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRenamed)
            var events = [FileSystemEvent(path: renamed.path, id: 42, flags: flags)]
            if includeOldPath { events.append(FileSystemEvent(path: old.path, id: 41, flags: flags)) }
            let commit = try reconcile(events)
            let result = try db.search(SearchRequest(text: "mixed-\(includeOldPath).txt"))
            XCTAssertEqual(commit.stats.scannedDirectories, 1)
            XCTAssertEqual(result.total, 1)
            XCTAssertEqual(result.entries.first?.name, renamed.lastPathComponent)
        }
    }

    func testCaseOnlyRemoveAndCreateReconcilesActualFilenameWithoutRenameFlags() throws {
        let old = root.appendingPathComponent("Mixed.txt")
        let replacement = root.appendingPathComponent("mixed.txt")
        try Data([1]).write(to: old)
        guard FileManager.default.fileExists(atPath: replacement.path) else {
            throw XCTSkip("Requires a case-insensitive fixture volume")
        }
        try index()
        try FileManager.default.removeItem(at: old)
        try Data([1]).write(to: replacement)
        let commit = try reconcile([
            FileSystemEvent(path: old.path, id: 41,
                            flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved)),
            FileSystemEvent(path: replacement.path, id: 42,
                            flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated))
        ])
        let result = try db.search(SearchRequest(text: "mixed.txt"))
        XCTAssertEqual(commit.stats.scannedDirectories, 1)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.entries.first?.name, "mixed.txt")
    }

    func testFileNameChangesCollapseToOneParentCheckAlongsidePointEdits() throws {
        let edited = root.appendingPathComponent("edited.txt")
        try Data([1]).write(to: edited)
        try index()
        try Data([1, 2]).write(to: edited)
        var events = [event(edited)]
        for number in 0..<128 {
            let file = root.appendingPathComponent("created-\(number).txt")
            try Data([1]).write(to: file)
            events.append(FileSystemEvent(path: file.path, id: 42,
                                           flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)))
        }
        let commit = try reconcile(events)
        XCTAssertEqual(commit.stats.scannedDirectories, 1)
        XCTAssertEqual(commit.stats.scannedItems, 129)
        XCTAssertEqual(try db.search(SearchRequest(text: "created-")).total, 128)
        XCTAssertEqual(try db.search(SearchRequest(text: "edited.txt")).entries.first?.size, 2)
    }

    func testStaleDirectoryFlagsDoNotFollowReplacementSymlinkOutsideRoot() throws {
        let item = root.appendingPathComponent("item")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("not-indexed.txt"))
        try index()
        try FileManager.default.removeItem(at: item)
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: outside)
        _ = try reconcile([FileSystemEvent(path: item.path, id: 42,
                                           flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))])
        XCTAssertEqual(try db.search(SearchRequest(text: "not-indexed.txt")).total, 0)
        XCTAssertFalse(try XCTUnwrap(db.search(SearchRequest(text: "item")).entries.first).isDirectory)
    }

    func testDirectoryReplacementWithSameNameScansExistingDescendants() throws {
        let item = root.appendingPathComponent("item/deep")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data([1]).write(to: item.appendingPathComponent("stale.txt"))
        try index()
        try FileManager.default.removeItem(at: item.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data([1]).write(to: item.appendingPathComponent("fresh.txt"))
        _ = try reconcile([FileSystemEvent(path: item.deletingLastPathComponent().path, id: 42,
                                           flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))])
        XCTAssertEqual(try db.search(SearchRequest(text: "stale.txt")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "fresh.txt")).total, 1)
    }

    func testConfiguredRootReplacedByFilePrunesOldContentsAndCanReturn() throws {
        try Data([1]).write(to: root.appendingPathComponent("stale.txt"))
        try index()
        try FileManager.default.removeItem(at: root)
        try Data([1]).write(to: root)
        let changed = FileSystemEvent(path: root.path, id: 42, flags: UInt32(kFSEventStreamEventFlagRootChanged))
        _ = try reconcile([changed])
        XCTAssertEqual(try db.search(SearchRequest(text: "stale.txt")).total, 0)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("returned.txt"))
        _ = try reconcile([changed])
        XCTAssertEqual(try db.search(SearchRequest(text: "returned.txt")).total, 1)
    }

    func testRootSlashIsNotCoalescedIntoItselfOrRemovedFromRecursiveScan() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: "/")
        let config = IndexConfig(roots: ["/"], skipDirNames: names)
        let recorder = Recorder()
        let handler = ChangeHandler(db: db, config: config, debounce: 30,
                                    onCommit: { recorder.append(Commit(id: $0, history: $1, stats: $2)) },
                                    onError: { XCTFail("Root recovery failed: \($0)") })
        defer { handler.stop() }
        handler.ingest(events: [FileSystemEvent(path: "/", id: 42,
                                                flags: UInt32(kFSEventStreamEventFlagKernelDropped))])
        handler.flushPendingNow()
        let commit = try XCTUnwrap(recorder.commits.last)
        XCTAssertEqual(commit.id, 42)
        XCTAssertEqual(commit.stats.scannedDirectories, 1)
        XCTAssertTrue(commit.stats.didChangeIndex)
    }

    func testRecursiveAncestorAbsorbsOverlappingEventsWithoutDuplicateWalks() throws {
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("file.txt"))
        try index()
        let recursive = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        let commit = try reconcile([
            event(nested.appendingPathComponent("file.txt"), id: 10),
            FileSystemEvent(path: nested.path, id: 20, flags: recursive),
            FileSystemEvent(path: root.path, id: 30, flags: recursive)
        ])
        XCTAssertEqual(commit.id, 30)
        XCTAssertEqual(commit.stats.scannedDirectories, 3)
        XCTAssertFalse(commit.stats.didChangeIndex)
    }

    func testPendingOverflowRecoversAllRootsAndPreservesHistoryCompletion() throws {
        var events: [FileSystemEvent] = []
        for number in 0..<5 {
            let file = root.appendingPathComponent("file-\(number).txt")
            try Data([1]).write(to: file)
            events.append(event(file, id: UInt64(10 + number)))
        }
        events.append(FileSystemEvent(path: "", id: 20, flags: UInt32(kFSEventStreamEventFlagHistoryDone)))
        let commit = try reconcile(events, limit: 2)
        XCTAssertEqual(commit.id, 20)
        XCTAssertTrue(commit.history)
        XCTAssertEqual(commit.stats.scannedDirectories, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "file-")).total, 5)
    }

    func testMutationNotificationSurvivesCheckpointFailureAndNoOpRetry() throws {
        let file = root.appendingPathComponent("created.txt")
        try Data([1]).write(to: file)
        let recorder = Recorder()
        let handler = ChangeHandler(db: db, config: config, debounce: 30, pathCooldown: 30,
                                    onCommit: { id, history, stats in
            recorder.append(Commit(id: id, history: history, stats: stats))
            if recorder.commits.count == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        defer { handler.stop() }
        handler.ingest(events: [event(file)])
        handler.flushPendingNow()
        handler.flushPendingNow()
        let commits = recorder.commits
        XCTAssertEqual(commits.count, 2)
        XCTAssertTrue(commits[0].stats.didChangeIndex)
        XCTAssertTrue(commits[1].stats.didChangeIndex)
        XCTAssertEqual(commits[1].stats.rows, 0)
        handler.ingest(events: [event(file, id: 43)])
        handler.flushPendingNow()
        XCTAssertFalse(try XCTUnwrap(recorder.commits.last).stats.didChangeIndex)
    }

    func testContinuousArrivalsCannotPostponeFlushForever() throws {
        let committed = expectation(description: "Flush while events continue arriving")
        committed.assertForOverFulfill = false
        let file = root.appendingPathComponent("busy.txt")
        try Data([1]).write(to: file)
        let handler = ChangeHandler(db: db, config: config, debounce: 0.1, maxDebounce: 0.1,
                                    onCommit: { _, _, _ in committed.fulfill() })
        let events = [event(file)]
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.continuous-events"))
        timer.setEventHandler { handler.ingest(events: events) }
        timer.schedule(deadline: .now(), repeating: 0.01)
        timer.resume()
        defer {
            timer.cancel()
            handler.stop()
        }
        wait(for: [committed], timeout: 2)
    }

    func testFileEventsRespectExcludedParentsAndFilenamePatterns() throws {
        let excluded = root.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let hidden = excluded.appendingPathComponent("hidden.txt")
        let scratch = root.appendingPathComponent("scratch.tmp")
        try Data([1]).write(to: hidden)
        try Data([1]).write(to: scratch)
        let handler = ChangeHandler(db: db, config: IndexConfig(roots: [root.path], namePatterns: ["*.tmp"],
                                                               skipPathPrefixes: [excluded.path]), debounce: 30)
        defer { handler.stop() }
        handler.ingest(events: [event(hidden), event(scratch)])
        handler.flushPendingNow()
        XCTAssertEqual(try db.search(SearchRequest(text: ".txt")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: ".tmp")).total, 0)
    }

    private struct Commit {
        var id: UInt64
        var history: Bool
        var stats: IndexerStats
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Commit] = []

        var commits: [Commit] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        func append(_ commit: Commit) {
            lock.lock()
            defer { lock.unlock() }
            values.append(commit)
        }
    }
}
