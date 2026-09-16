import XCTest
import CoreServices
@testable import EverywhereCore

final class ChangeHandlerTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var database: Database!
    private var handler: ChangeHandler!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsearch-changes-\(UUID().uuidString)", isDirectory: true)
        root = tempDir.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try Database(path: tempDir.appendingPathComponent("index.sqlite").path)
        let config = IndexConfig(
            roots: [root.path],
            skipPathPrefixes: [tempDir.appendingPathComponent("skipped").path]
        )
        handler = ChangeHandler(db: database, config: config, debounce: 0.1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNamePatternsAndFolderExclusionsApplyToLiveUpdates() throws {
        let excluded = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data().write(to: excluded.appendingPathComponent("hidden.txt"))
        try Data().write(to: root.appendingPathComponent("scratch.tmp"))
        try Data().write(to: root.appendingPathComponent("kept.txt"))
        let filtered = ChangeHandler(db: database,
                                     config: IndexConfig(roots: [root.path], namePatterns: ["*.tmp"], skipPathPrefixes: [excluded.path]))
        defer { filtered.stop() }
        filtered.ingest(events: [FileSystemEvent(path: root.path, id: 42)])
        filtered.flushPendingNow()
        XCTAssertEqual(try database.search(SearchRequest(text: ".txt")).entries.map(\.name), ["kept.txt"])
        XCTAssertEqual(try database.search(SearchRequest(text: ".tmp")).total, 0)
    }

    func testOrdinaryEventDoesNotWalkUnchangedSubdirectories() throws {
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("existing.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.123456)], ofItemAtPath: nested.path)
        try FilesystemIndexer(db: database, config: IndexConfig(roots: [root.path])).run()
        let committed = expectation(description: "Only changed directory checked")
        let handler = ChangeHandler(db: database, config: IndexConfig(roots: [root.path]), onCommit: { id, _, stats in
            XCTAssertEqual(id, 42)
            XCTAssertEqual(stats.scannedDirectories, 1)
            committed.fulfill()
        })
        handler.ingest(events: [FileSystemEvent(path: root.path, id: 42)])
        handler.flushPendingNow()
        wait(for: [committed], timeout: 3)
        handler.stop()
    }

    func testCoalescedEventScansUnchangedDescendants() throws {
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: nested.path)
        try FilesystemIndexer(db: database, config: IndexConfig(roots: [root.path])).run()
        try Data([1]).write(to: nested.appendingPathComponent("offline.txt"))
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: nested.path)
        handler.ingest(events: [FileSystemEvent(path: root.path, id: 42,
                                                flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))])
        handler.flushPendingNow()
        XCTAssertEqual(try database.search(SearchRequest(text: "offline")).total, 1)
    }

    func testHistorySentinelDoesNotIndexItsPath() throws {
        let committed = expectation(description: "History completed")
        let handler = ChangeHandler(db: database, config: IndexConfig(roots: [root.path]), onCommit: { id, history, stats in
            XCTAssertEqual(id, 77)
            XCTAssertTrue(history)
            XCTAssertEqual(stats.scannedDirectories, 0)
            committed.fulfill()
        })
        handler.ingest(events: [FileSystemEvent(path: "/", id: 77, flags: UInt32(kFSEventStreamEventFlagHistoryDone))])
        handler.flushPendingNow()
        wait(for: [committed], timeout: 3)
        XCTAssertEqual(try database.count(), 0)
        handler.stop()
    }

    func testIgnoredEventsDoNotCommitAndCreateFeedbackLoop() {
        let committed = expectation(description: "No checkpoint for ignored events")
        committed.isInverted = true
        let handler = ChangeHandler(db: database, config: IndexConfig(roots: [root.path], skipPathPrefixes: [root.path]),
                                    onCommit: { _, _, _ in committed.fulfill() })
        handler.ingest(events: [FileSystemEvent(path: root.path, id: 99)])
        handler.flushPendingNow()
        wait(for: [committed], timeout: 0.1)
        handler.stop()
    }

    func testDroppedEventsRescanAllConfiguredRoots() throws {
        try Data([1]).write(to: root.appendingPathComponent("recover.txt"))
        handler.ingest(events: [FileSystemEvent(path: "/unrelated", id: 80,
                                                flags: UInt32(kFSEventStreamEventFlagKernelDropped))])
        handler.flushPendingNow()
        XCTAssertEqual(try database.search(SearchRequest(text: "recover")).total, 1)
    }

    func testIngestIndexesCreatedFile() throws {
        try Data(repeating: 0, count: 4).write(to: root.appendingPathComponent("fresh.txt"))
        handler.ingest([root.path])
        handler.flushPendingNow()

        let result = try database.search(SearchRequest(text: "fresh"))
        XCTAssertEqual(result.entries.map(\.path), [root.path + "/fresh.txt"])
    }

    func testIngestRemovesDeletedFile() throws {
        let file = root.appendingPathComponent("temporary.txt")
        try Data(repeating: 0, count: 4).write(to: file)
        handler.ingest([root.path])
        handler.flushPendingNow()
        XCTAssertEqual(try database.search(SearchRequest(text: "temporary")).total, 1)

        try FileManager.default.removeItem(at: file)
        handler.ingest([root.path])
        handler.flushPendingNow()
        XCTAssertEqual(try database.search(SearchRequest(text: "temporary")).total, 0)
    }

    func testIgnoredPathsAreNotIndexed() throws {
        let skippedDir = tempDir.appendingPathComponent("skipped", isDirectory: true)
        try FileManager.default.createDirectory(at: skippedDir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4).write(to: skippedDir.appendingPathComponent("hidden.txt"))

        handler.ingest([skippedDir.path])
        handler.flushPendingNow()

        XCTAssertEqual(try database.search(SearchRequest(text: "hidden")).total, 0)
    }
}

final class FSEventsMonitorTests: XCTestCase {
    func testMonitorDeliversDirectoryEvents() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsearch-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectation = XCTestExpectation(description: "FSEvents delivered a change event")
        expectation.assertForOverFulfill = false
        let received = ReceivedRecorder {
            expectation.fulfill()
        }
        let monitor = FSEventsMonitor(roots: [tempDir.path], latency: 0.1) { paths in
            received.record(paths)
        }
        monitor.start()
        defer { monitor.stop() }

        try Data(repeating: 0, count: 1).write(to: tempDir.appendingPathComponent("watched.txt"))

        wait(for: [expectation], timeout: 10)

        let normalized = received.paths.map { Self.normalized($0) }
        let expected = Self.normalized(tempDir.path)
        XCTAssertTrue(
            normalized.contains(expected),
            "expected the watched directory itself in events, got: \(received.paths)"
        )
    }

    private static func normalized(_ path: String) -> String {
        var result = (path as NSString).resolvingSymlinksInPath
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private final class ReceivedRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [String] = []
        private let onFirst: @Sendable () -> Void

        init(onFirst: @escaping @Sendable () -> Void) {
            self.onFirst = onFirst
        }

        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return received
        }

        func record(_ paths: [String]) {
            lock.lock()
            let first = received.isEmpty
            received.append(contentsOf: paths)
            lock.unlock()
            if first {
                onFirst()
            }
        }
    }
}
