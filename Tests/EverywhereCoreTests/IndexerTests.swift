import XCTest
@testable import EverywhereCore

final class IndexerTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var database: Database!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsearch-indexer-\(UUID().uuidString)", isDirectory: true)
        root = tempDir.appendingPathComponent("root", isDirectory: true)
        let folder = root.appendingPathComponent("Docs", isDirectory: true)
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        let skip = root.appendingPathComponent("skipme", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skip, withIntermediateDirectories: true)

        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("Alpha.txt"))
        try Data(repeating: 0, count: 20).write(to: root.appendingPathComponent("beta.log"))
        try Data(repeating: 0, count: 30).write(to: folder.appendingPathComponent("nested-file.md"))
        try Data(repeating: 0, count: 40).write(to: skip.appendingPathComponent("secret.txt"))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        database = try Database(path: tempDir.appendingPathComponent("index.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSubdirectoryEventsReuseIndexedTree() throws {
        let config = config()
        try FilesystemIndexer(db: database, config: config).run()
        let original = try search("nested-file").first!.id
        let docs = root.appendingPathComponent("Docs")
        for _ in 0..<3 {
            try Reconciler(db: database, config: config, roots: [docs.path], skipUnchangedDirs: false).run()
        }
        for memory in [false, true] {
            let result = try database.search(SearchRequest(text: "nested-file"), useMemory: memory)
            XCTAssertEqual(result.entries.map(\.id), [original])
            XCTAssertEqual(result.total, 1)
        }
        let newFolder = docs.appendingPathComponent("New/Deep")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data().write(to: newFolder.appendingPathComponent("created.txt"))
        try Reconciler(db: database, config: config, roots: [newFolder.path], skipUnchangedDirs: false).run()
        try Reconciler(db: database, config: config, roots: [root.path], skipUnchangedDirs: false).run()
        XCTAssertEqual(try search("created.txt").map(\.path), [newFolder.appendingPathComponent("created.txt").path])
        try FileManager.default.removeItem(at: docs.appendingPathComponent("nested-file.md"))
        try Reconciler(db: database, config: config, roots: [docs.path], skipUnchangedDirs: false).run()
        XCTAssertTrue(try search("nested-file").isEmpty)
    }

    func testFolderAndWildcardExclusionsInWalkAndReconciliation() throws {
        let excluded = root.appendingPathComponent("cache")
        let retained = root.appendingPathComponent("cache-other")
        for folder in [excluded, retained] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("inside.txt"))
        }
        try Data().write(to: root.appendingPathComponent("scratch.TMP"))
        let ordinary = IndexConfig(roots: [root.path])
        try FilesystemIndexer(db: database, config: ordinary).run()
        let filtered = IndexConfig(roots: [root.path], namePatterns: ["*.tmp"], skipPathPrefixes: [excluded.path])
        try Reconciler(db: database, config: filtered, roots: [root.path], skipUnchangedDirs: false).run()
        XCTAssertEqual(try search("inside").map(\.path), [retained.appendingPathComponent("inside.txt").path])
        XCTAssertTrue(try search("scratch").isEmpty)
        XCTAssertFalse(try search("cache").contains { $0.path == excluded.path })
        try database.clear()
        try FilesystemIndexer(db: database, config: filtered).run()
        XCTAssertEqual(try search("inside").map(\.path), [retained.appendingPathComponent("inside.txt").path])
        XCTAssertTrue(try search("scratch").isEmpty)
        XCTAssertFalse(try search("cache").contains { $0.path == excluded.path })
    }

    func testWildcardExclusionsAreWholeNameAndLiteralExceptStarAndQuestion() {
        let config = IndexConfig(roots: ["/"], namePatterns: ["*.tmp", "cache-?", "[literal]", "foo"])
        XCTAssertTrue(config.ignores(name: "a.TMP"))
        XCTAssertTrue(config.ignores(name: "cache-é"))
        XCTAssertTrue(config.ignores(name: "[literal]"))
        XCTAssertTrue(config.ignores(path: "/work/cache-a/child.txt"))
        XCTAssertFalse(config.ignores(name: "a.tmp.backup"))
        XCTAssertFalse(config.ignores(name: "cache-ab"))
        XCTAssertFalse(config.ignores(name: "foobar"))
        XCTAssertFalse(config.ignores(name: "literal"))
        XCTAssertFalse(config.ignores(name: "foo\n"))
    }

    func testExcludedRootIsRemovedDuringReconciliation() throws {
        try FilesystemIndexer(db: database, config: config()).run()
        let filtered = IndexConfig(roots: [root.path], skipPathPrefixes: [root.path])
        try Reconciler(db: database, config: filtered, roots: [root.path], skipUnchangedDirs: false).run()
        XCTAssertEqual(try database.count(), 0)
        try FilesystemIndexer(db: database, config: filtered).run()
        XCTAssertEqual(try database.count(), 0)
    }

    private func config() -> IndexConfig {
        IndexConfig(roots: [root.path], exclusions: ["skipme"], batchSize: 2)
    }

    private func search(_ text: String) throws -> [Entry] {
        try database.search(SearchRequest(text: text)).entries
    }

    func testIndexesFilesAndDirectories() throws {
        let indexer = FilesystemIndexer(db: database, config: config())
        try indexer.run()

        let alpha = try search("alpha")
        XCTAssertEqual(alpha.map(\.path), [root.path + "/Alpha.txt"])

        let nested = try search("nested")
        XCTAssertEqual(nested.map(\.path), [root.path + "/Docs/nested-file.md"])

        let docs = try search("Docs")
        XCTAssertTrue(docs.contains { $0.path == root.path + "/Docs" && $0.isDirectory })

        let stats = indexer.snapshot
        XCTAssertEqual(stats.files, 4)
        XCTAssertEqual(stats.dirs, 2)
        XCTAssertEqual(try database.count(), 7)
    }

    func testExclusionsArePruned() throws {
        let indexer = FilesystemIndexer(db: database, config: config())
        try indexer.run()

        XCTAssertTrue(try search("skipme").isEmpty)
        XCTAssertTrue(try search("secret").isEmpty)
    }

    func testSymlinkIndexedButNotTraversed() throws {
        let indexer = FilesystemIndexer(db: database, config: config())
        try indexer.run()

        let loop = try search("loop")
        XCTAssertEqual(loop.count, 1)
        let entry = try XCTUnwrap(loop.first)
        XCTAssertFalse(entry.isDirectory)
        XCTAssertEqual(entry.path, root.path + "/loop")
    }

    func testBulkReaderMatchesPosixReader() throws {
        let bulkDB = try Database(path: tempDir.appendingPathComponent("bulk.sqlite").path)
        let posixDB = try Database(path: tempDir.appendingPathComponent("posix.sqlite").path)

        var bulkConfig = config()
        bulkConfig.useBulkReader = true
        var posixConfig = config()
        posixConfig.useBulkReader = false

        try FilesystemIndexer(db: bulkDB, config: bulkConfig).run()
        try FilesystemIndexer(db: posixDB, config: posixConfig).run()

        let bulkRows = try bulkDB.search(SearchRequest(text: "", limit: 100_000)).entries
        let posixRows = try posixDB.search(SearchRequest(text: "", limit: 100_000)).entries

        XCTAssertEqual(bulkRows.map(\.path), posixRows.map(\.path))
        XCTAssertEqual(bulkRows.map(\.size), posixRows.map(\.size))
        XCTAssertEqual(bulkRows.map(\.isDirectory), posixRows.map(\.isDirectory))
        for (bulkRow, posixRow) in zip(bulkRows, posixRows) {
            XCTAssertEqual(bulkRow.modified.timeIntervalSince1970, posixRow.modified.timeIntervalSince1970, accuracy: 0.001, "mtime mismatch for \(bulkRow.path)")
        }
    }

    func testPauseAndResumeContinuesTheExistingWalk() throws {
        let control = IndexingControl()
        let didPause = CancelFlag()
        let paused = expectation(description: "Paused after the first directory")
        let completed = expectation(description: "Walk completed")
        let indexer = FilesystemIndexer(db: database, config: config())
        DispatchQueue.global().async {
            do {
                try indexer.run(isCancelled: { !control.waitUntilRunning() }) { stats in
                    if stats.scannedDirectories >= 1 && !didPause.isCancelled {
                        didPause.isCancelled = true
                        control.pause()
                        paused.fulfill()
                    }
                }
            } catch {
                XCTFail("Unexpected indexing error: \(error)")
            }
            completed.fulfill()
        }
        wait(for: [paused], timeout: 3)
        XCTAssertTrue(try search("nested").isEmpty)
        control.resume()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(try search("nested").count, 1)
        XCTAssertEqual(try database.count(), 7)
        XCTAssertEqual(indexer.snapshot.scannedDirectories, 3)
        XCTAssertEqual(indexer.snapshot.scannedItems, 7)
    }

    func testCancelledPausedWalkDoesNotCreateRootRows() throws {
        let control = IndexingControl()
        control.pause()
        let completed = expectation(description: "Cancelled walk completed")
        let indexer = FilesystemIndexer(db: database, config: config())
        DispatchQueue.global().async {
            do {
                try indexer.run(isCancelled: { !control.waitUntilRunning() })
            } catch {
                XCTFail("Unexpected indexing error: \(error)")
            }
            completed.fulfill()
        }
        control.cancel()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(try database.count(), 0)
    }

    func testCancelStopsIndexing() throws {
        let flag = CancelFlag()
        flag.isCancelled = true
        let indexer = FilesystemIndexer(db: database, config: config())
        try indexer.run(isCancelled: { flag.isCancelled })
        XCTAssertEqual(try database.count(), 0)
    }
}

final class ReconcilerTests: XCTestCase {
    func testFractionalTimestampsDoNotRewriteUnchangedFiles() throws {
        for bulk in [false, true] {
            for timestamp in [1_700_000_000.75, -1000.75] {
                let file = root.appendingPathComponent("old.txt")
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)],
                                                      ofItemAtPath: file.path)
                let config = IndexConfig(roots: [root.path], useBulkReader: bulk)
                try database.clear()
                try FilesystemIndexer(db: database, config: config).run()
                let reconciler = Reconciler(db: database, config: config, roots: [root.path], skipUnchangedDirs: false)
                try reconciler.run()
                XCTAssertEqual(reconciler.snapshot.rows, 0)
                XCTAssertEqual(reconciler.snapshot.scannedItems, 1)
            }
        }
    }

    func testFailedDirectoryReadPreservesIndexedChildren() throws {
        for failure in [EIO, EACCES] {
            let reconciler = Reconciler(db: database, config: IndexConfig(roots: [root.path]),
                                        roots: [root.path], skipUnchangedDirs: false)
            reconciler.readDirectory = { _, _, _ in errno = failure; return false }
            if failure == EIO { XCTAssertThrowsError(try reconciler.run()) }
            else { try reconciler.run() }
            XCTAssertEqual(try database.search(SearchRequest(text: "old.txt")).entries.count, 1)
            XCTAssertEqual(reconciler.snapshot.deleted, 0)
        }
    }

    func testFailedReadDeletesConfirmedMissingDirectory() throws {
        try FileManager.default.removeItem(at: root)
        let reconciler = Reconciler(db: database, config: IndexConfig(roots: [root.path]),
                                    roots: [root.path], skipUnchangedDirs: false)
        try reconciler.run()
        XCTAssertEqual(try database.count(), 0)
    }

    func testBulkFallbackDiscardsPartialOutputAndPublishesOnlyCompleteReads() {
        let item = DirectoryReader.Item(name: "partial", isDir: false, isSymlink: false, size: 0, modified: 0, created: 0)
        var output: [DirectoryReader.Item] = []
        XCTAssertTrue(DirectoryReader.read("unused", preferBulk: true, out: &output,
            bulkReader: { _, items in items.append(item); return false },
            posixReader: { _, items in
                XCTAssertTrue(items.isEmpty)
                items.append(item)
                return true
            }))
        XCTAssertEqual(output.count, 1)
        XCTAssertFalse(DirectoryReader.read("unused", preferBulk: true, out: &output,
            bulkReader: { _, items in items.append(item); return false },
            posixReader: { _, items in items.append(item); return false }))
        XCTAssertEqual(output.count, 1)
    }

    func testRecursiveScanFindsChangesWithUnchangedDirectoryTimestamp() throws {
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: folder.path)
        let config = IndexConfig(roots: [root.path])
        try Reconciler(db: database, config: config, roots: [root.path], skipUnchangedDirs: false).run()
        try Data().write(to: folder.appendingPathComponent("new.txt"))
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: folder.path)
        try Reconciler(db: database, config: config, roots: [root.path], skipUnchangedDirs: true).run()
        XCTAssertEqual(try database.search(SearchRequest(text: "new.txt")).entries.count, 1)
    }
    private var tempDir: URL!
    private var root: URL!
    private var database: Database!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsearch-reconcile-\(UUID().uuidString)", isDirectory: true)
        root = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("old.txt"))
        database = try Database(path: tempDir.appendingPathComponent("index.sqlite").path)
        let indexer = FilesystemIndexer(db: database, config: IndexConfig(roots: [root.path]))
        try indexer.run()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPausedReconciliationResumesAndReportsUnchangedItems() throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: root.appendingPathComponent("old.txt").path)
        try database.clear()
        try FilesystemIndexer(db: database, config: IndexConfig(roots: [root.path])).run()
        let control = IndexingControl()
        control.pause()
        let completed = expectation(description: "Reconciliation completed")
        let reconciler = Reconciler(db: database, config: IndexConfig(roots: [root.path]),
                                    roots: [root.path], skipUnchangedDirs: false)
        DispatchQueue.global().async {
            do {
                try reconciler.run(isCancelled: { !control.waitUntilRunning() })
            } catch {
                XCTFail("Unexpected reconciliation error: \(error)")
            }
            completed.fulfill()
        }
        XCTAssertEqual(reconciler.snapshot.scannedItems, 0)
        control.resume()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(reconciler.snapshot.scannedItems, 1)
        XCTAssertEqual(reconciler.snapshot.scannedDirectories, 1)
        XCTAssertEqual(reconciler.snapshot.rows, 0)
        XCTAssertEqual(try database.search(SearchRequest(text: "old", kind: .files)).total, 1)
    }

    func testModifiedFileRemainsIndexedAfterReconciliation() throws {
        try Data(repeating: 1, count: 99).write(to: root.appendingPathComponent("old.txt"))
        let reconciler = Reconciler(db: database, config: IndexConfig(roots: [root.path]),
                                    roots: [root.path], skipUnchangedDirs: false)
        try reconciler.run()
        let result = try database.search(SearchRequest(text: "old", kind: .files))
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.entries.first?.size, 99)
    }

    func testDetectsCreationsModificationsAndDeletions() throws {
        try Data(repeating: 0, count: 25).write(to: root.appendingPathComponent("new.txt"))
        try Data(repeating: 0, count: 99).write(to: root.appendingPathComponent("old.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("old.txt"))

        let reconciler = Reconciler(db: database, config: IndexConfig(roots: [root.path]), roots: [root.path], skipUnchangedDirs: false)
        try reconciler.run()

        let added = try database.search(SearchRequest(text: "new"))
        XCTAssertEqual(added.entries.map(\.path), [root.path + "/new.txt"])
        XCTAssertEqual(added.entries.first?.size, 25)

        let removed = try database.search(SearchRequest(text: "old", kind: .files))
        XCTAssertEqual(removed.total, 0)
    }

    func testDetectsNewFilesInSubfolderWithUnchangedDirSkip() throws {
        let sub = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let first = Reconciler(db: database, config: IndexConfig(roots: [root.path]), roots: [root.path], skipUnchangedDirs: false)
        try first.run()
        XCTAssertTrue(try database.search(SearchRequest(text: "Folder")).entries.contains { $0.path == sub.path && $0.isDirectory })

        try Data(repeating: 0, count: 5).write(to: sub.appendingPathComponent("extra.txt"))
        let second = Reconciler(db: database, config: IndexConfig(roots: [root.path]), roots: [root.path], skipUnchangedDirs: true)
        try second.run()

        let extra = try database.search(SearchRequest(text: "extra"))
        XCTAssertEqual(extra.entries.map(\.path), [sub.path + "/extra.txt"])
    }

    func testDetectsRemovedDirectory() throws {
        let sub = root.appendingPathComponent("doomed", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1).write(to: sub.appendingPathComponent("inside.txt"))
        let add = Reconciler(db: database, config: IndexConfig(roots: [root.path]), roots: [root.path], skipUnchangedDirs: false)
        try add.run()
        XCTAssertEqual(try database.search(SearchRequest(text: "inside")).total, 1)

        try FileManager.default.removeItem(at: sub)
        let remove = Reconciler(db: database, config: IndexConfig(roots: [root.path]), roots: [root.path], skipUnchangedDirs: false)
        try remove.run()

        XCTAssertEqual(try database.search(SearchRequest(text: "inside")).total, 0)
        XCTAssertEqual(try database.search(SearchRequest(text: "doomed")).total, 0)
    }
}
