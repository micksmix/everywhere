import CoreServices
import XCTest
@testable import EverywhereCore

final class IndexingPerformanceTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var database: Database!
    private var config: IndexConfig { IndexConfig(roots: [root.path]) }
    private var modifyFlags: UInt32 {
        UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("everywhere-indexing-performance-\(UUID().uuidString)", isDirectory: true)
        root = directory.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try Database(path: directory.appendingPathComponent("index.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        guard let directory, directory.lastPathComponent.hasPrefix("everywhere-indexing-performance-"),
              directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func testDuplicateFileStormChecksUniqueFilesOnceAndUnchangedReplayDoesNotInvalidateCache() throws {
        let files = try (0..<128).map { try write("item-\($0).txt", in: root) }
        try index()
        let initial = try cachedItems()
        let changedFiles = stride(from: 0, to: files.count, by: 16).map { files[$0] }
        for file in changedFiles { try Data([1, 2, 3]).write(to: file) }
        let events = (0..<2048).map { number in
            FileSystemEvent(path: changedFiles[number % changedFiles.count].path,
                            id: UInt64(number + 1), flags: modifyFlags)
        }

        let changed = try reconcile(events)
        XCTAssertEqual(changed.id, 2048)
        XCTAssertEqual(changed.stats.scannedItems, 8)
        XCTAssertEqual(changed.stats.scannedDirectories, 0)
        XCTAssertEqual(changed.stats.rows, 8)
        XCTAssertEqual(changed.stats.deleted, 0)
        XCTAssertTrue(changed.stats.didChangeIndex)
        let refreshed = try cachedItems()
        XCTAssertEqual(refreshed.entries.map(\.id), initial.entries.map(\.id))
        XCTAssertEqual(refreshed.total, 128)
        XCTAssertEqual(refreshed.entries.filter { $0.size == 3 }.count, 8)
        XCTAssertEqual(refreshed.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertEqual(refreshed.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes + 1)

        let generation = database.entryChangeGeneration
        let replay = try reconcile(events.map {
            FileSystemEvent(path: $0.path, id: $0.id + 4096, flags: $0.flags)
        })
        XCTAssertEqual(replay.id, 6144)
        XCTAssertEqual(replay.stats.scannedItems, 8)
        XCTAssertEqual(replay.stats.scannedDirectories, 0)
        XCTAssertEqual(replay.stats.rows, 0)
        XCTAssertEqual(replay.stats.deleted, 0)
        XCTAssertFalse(replay.stats.didChangeIndex)
        XCTAssertEqual(database.entryChangeGeneration, generation)
        let unchanged = try cachedItems()
        XCTAssertEqual(unchanged.entries, refreshed.entries)
        XCTAssertEqual(unchanged.snapshotVersion, refreshed.snapshotVersion)
        XCTAssertEqual(unchanged.cacheStatistics.fullLoads, refreshed.cacheStatistics.fullLoads)
        XCTAssertEqual(unchanged.cacheStatistics.incrementalRefreshes, refreshed.cacheStatistics.incrementalRefreshes)
    }

    func testRepeatedUnchangedWideReconciliationHasZeroWriteAndCacheRefreshBudget() throws {
        for number in 0..<96 { try write("item-root-\(number).txt", in: root) }
        for branch in 0..<8 {
            let folder = root.appendingPathComponent("Branch-\(branch)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for number in 0..<12 { try write("item-branch-\(branch)-\(number).txt", in: folder) }
        }
        try index()
        let initial = try cachedItems()
        XCTAssertEqual(initial.total, 192)
        let generation = database.entryChangeGeneration

        for useBulkReader in [true, false] {
            let configuration = IndexConfig(roots: [root.path], useBulkReader: useBulkReader)
            for _ in 0..<3 {
                let reconciler = Reconciler(db: database, config: configuration, roots: [root.path],
                                            skipUnchangedDirs: false)
                try reconciler.run()
                XCTAssertEqual(reconciler.snapshot.scannedDirectories, 9)
                XCTAssertEqual(reconciler.snapshot.scannedItems, 200)
                XCTAssertEqual(reconciler.snapshot.rows, 0)
                XCTAssertEqual(reconciler.snapshot.deleted, 0)
                XCTAssertEqual(reconciler.snapshot.skipped, 0)
                XCTAssertEqual(database.entryChangeGeneration, generation)
                let result = try cachedItems()
                XCTAssertEqual(result.entries, initial.entries)
                XCTAssertEqual(result.snapshotVersion, initial.snapshotVersion)
                XCTAssertEqual(result.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
                XCTAssertEqual(result.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes)
            }
        }
    }

    func testOverlappingRecursiveStormWalksOnlyAffectedBranchOnce() throws {
        for branch in 0..<12 {
            let folder = root.appendingPathComponent("Branch-\(branch)", isDirectory: true)
            let child = folder.appendingPathComponent("Child", isDirectory: true)
            let deep = child.appendingPathComponent("Deep", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            for location in [folder, child, deep] { try write("item.txt", in: location) }
        }
        try index()
        let initial = try cachedItems()
        let branch = root.appendingPathComponent("Branch-5", isDirectory: true)
        let child = branch.appendingPathComponent("Child", isDirectory: true)
        let deep = child.appendingPathComponent("Deep", isDirectory: true)
        let changedFile = deep.appendingPathComponent("item.txt")
        let originalID = try XCTUnwrap(initial.entries.first { $0.path == changedFile.path }?.id)
        try Data([1, 2, 3]).write(to: changedFile)
        let paths = [deep.path, child.path, branch.path]
        let flags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)
        let events = (0..<768).map { number in
            FileSystemEvent(path: paths[number % paths.count], id: UInt64(number + 1), flags: flags)
        }

        let commit = try reconcile(events)
        XCTAssertEqual(commit.id, 768)
        XCTAssertEqual(commit.stats.scannedDirectories, 3)
        XCTAssertEqual(commit.stats.scannedItems, 5)
        XCTAssertEqual(commit.stats.rows, 1)
        XCTAssertEqual(commit.stats.deleted, 0)
        XCTAssertTrue(commit.stats.didChangeIndex)
        let result = try cachedItems()
        XCTAssertEqual(result.total, 36)
        XCTAssertEqual(result.entries.first { $0.path == changedFile.path }?.id, originalID)
        XCTAssertEqual(result.entries.first { $0.id == originalID }?.size, 3)
        XCTAssertEqual(result.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertEqual(result.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes + 1)
    }

    func testOrdinaryDirectoryStormSkipsKnownDescendantsAndDiscoversNewSubtree() throws {
        for branch in 0..<8 {
            let deep = root.appendingPathComponent("Known-\(branch)/Child/Deep", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            for number in 0..<4 { try write("item-\(number).txt", in: deep) }
        }
        try index()
        let initial = try cachedItems()
        let deep = root.appendingPathComponent("New/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let created = try write("item-new.txt", in: deep, size: 3)
        let events = (0..<512).map { number in
            FileSystemEvent(path: root.path, id: UInt64(number + 1), flags: UInt32(kFSEventStreamEventFlagItemIsDir))
        }

        let commit = try reconcile(events)
        XCTAssertEqual(commit.id, 512)
        XCTAssertEqual(commit.stats.scannedDirectories, 3)
        XCTAssertEqual(commit.stats.scannedItems, 11)
        XCTAssertEqual(commit.stats.rows, 3)
        XCTAssertEqual(commit.stats.dirs, 2)
        XCTAssertEqual(commit.stats.files, 1)
        XCTAssertEqual(commit.stats.deleted, 0)
        let result = try cachedItems()
        XCTAssertEqual(result.total, 33)
        XCTAssertEqual(result.entries.filter { $0.name == "item-new.txt" }.map(\.path), [created.path])
        XCTAssertEqual(result.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertEqual(result.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes + 1)
    }

    func testCreateAndModifyStormAcrossTwoParentsDoesNotWalkUnrelatedSubtrees() throws {
        let parents = [root.appendingPathComponent("A", isDirectory: true),
                       root.appendingPathComponent("B", isDirectory: true)]
        for parent in parents {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            for number in 0..<16 { try write("item-old-\(number).txt", in: parent) }
        }
        let unrelated = root.appendingPathComponent("Unrelated/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        for number in 0..<24 { try write("item-unrelated-\(number).txt", in: unrelated) }
        try index()
        let initial = try cachedItems()
        for parent in parents {
            for number in 0..<4 { try write("item-new-\(number).txt", in: parent) }
            try Data([1, 2, 3]).write(to: parent.appendingPathComponent("item-old-0.txt"))
        }
        let createdFlags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
        let events = (0..<2048).map { number -> FileSystemEvent in
            let parent = parents[number % parents.count]
            let isModify = number % 5 == 0
            let name = isModify ? "item-old-0.txt" : "item-new-\((number / 2) % 4).txt"
            return FileSystemEvent(path: parent.appendingPathComponent(name).path, id: UInt64(number + 1),
                                   flags: isModify ? modifyFlags : createdFlags)
        }

        let commit = try reconcile(events)
        XCTAssertEqual(commit.id, 2048)
        XCTAssertEqual(commit.stats.scannedDirectories, 2)
        XCTAssertEqual(commit.stats.scannedItems, 40)
        XCTAssertEqual(commit.stats.rows, 10)
        XCTAssertEqual(commit.stats.deleted, 0)
        let result = try cachedItems()
        XCTAssertEqual(result.total, 64)
        XCTAssertEqual(result.entries.filter { $0.name.hasPrefix("item-new-") }.count, 8)
        XCTAssertEqual(result.entries.filter { $0.size == 3 }.count, 2)
        XCTAssertEqual(result.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertEqual(result.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes + 1)
    }

    func testPendingOverflowRecoversEachIndexedRootOnceInsteadOfPerEvent() throws {
        let other = directory.appendingPathComponent("other-root", isDirectory: true)
        let roots = [root!, other]
        for location in roots {
            let child = location.appendingPathComponent("Child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            for number in 0..<16 { try write("item-\(number).txt", in: location) }
            try write("item-child.txt", in: child)
        }
        let configuration = IndexConfig(roots: roots.map(\.path))
        try index(configuration)
        let initial = try cachedItems()
        var events: [FileSystemEvent] = []
        for number in 0..<32 {
            let file = roots[number % roots.count].appendingPathComponent("item-\(number / 2).txt")
            try Data([1, 2, 3]).write(to: file)
            events.append(FileSystemEvent(path: file.path, id: UInt64(number + 1), flags: modifyFlags))
        }

        let commit = try reconcile(events, configuration: configuration, maxPendingPaths: 4)
        XCTAssertEqual(commit.id, 32)
        XCTAssertEqual(commit.stats.scannedDirectories, 4)
        XCTAssertEqual(commit.stats.scannedItems, 36)
        XCTAssertEqual(commit.stats.rows, 32)
        XCTAssertEqual(commit.stats.deleted, 0)
        XCTAssertTrue(commit.stats.didChangeIndex)
        let result = try cachedItems()
        XCTAssertEqual(result.total, 34)
        XCTAssertEqual(result.entries.filter { $0.size == 3 }.count, 32)
        XCTAssertEqual(result.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertEqual(result.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes + 1)
    }

    @discardableResult
    private func write(_ name: String, in directory: URL, size: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: size).write(to: url)
        return url
    }

    private func index(_ configuration: IndexConfig? = nil) throws {
        try FilesystemIndexer(db: database, config: configuration ?? config).run()
    }

    private func cachedItems() throws -> SearchResult {
        try database.search(SearchRequest(text: "item", limit: 512), useMemory: true)
    }

    private func reconcile(_ events: [FileSystemEvent], configuration: IndexConfig? = nil,
                           maxPendingPaths: Int = 16_384) throws -> Commit {
        let recorder = Recorder()
        let handler = ChangeHandler(db: database, config: configuration ?? config, debounce: 3600,
                                    maxDebounce: 3600, pathCooldown: 3600, maxPendingPaths: maxPendingPaths,
                                    onCommit: { recorder.append(Commit(id: $0, stats: $2)) },
                                    onError: { recorder.record($0) })
        defer { handler.stop() }
        handler.ingest(events: events)
        handler.flushPendingNow()
        XCTAssertTrue(recorder.errors.isEmpty, recorder.errors.joined(separator: "; "))
        XCTAssertEqual(recorder.commits.count, 1)
        return try XCTUnwrap(recorder.commits.last)
    }

    private struct Commit {
        let id: UInt64
        let stats: IndexerStats
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Commit] = []
        private var failures: [String] = []

        var commits: [Commit] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        var errors: [String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }

        func append(_ commit: Commit) {
            lock.lock()
            defer { lock.unlock() }
            values.append(commit)
        }

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            failures.append(String(describing: error))
        }
    }
}
