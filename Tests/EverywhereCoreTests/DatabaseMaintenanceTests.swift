import SQLite3
import XCTest
@testable import EverywhereCore

final class DatabaseMaintenanceTests: XCTestCase {
    func testCompactionReclaimsSpaceAndPreservesSearchPathsAndIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path
        let db = try Database(path: path)
        let tree = TestTree(db: db)
        try db.beginBulkLoad()
        for number in 0..<2000 {
            try tree.add(path: "/discard/document-\(number)-\(String(repeating: "x", count: 100)).txt")
        }
        let survivor = try tree.add(path: "/keep/survivor.txt")
        try db.endBulkLoad()
        let identity = IndexCheckpoint.identity(of: path)
        try db.deleteSubtree(id: XCTUnwrap(tree.id(for: "/discard")))
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).int64Value
        XCTAssertFalse(try db.compactIfNeeded())
        XCTAssertTrue(try db.compactIfNeeded(minimumFreeBytes: 1, minimumFreeFraction: 0))
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).int64Value
        XCTAssertLessThan(after, before)
        XCTAssertEqual(IndexCheckpoint.identity(of: path), identity)
        let result = try db.search(SearchRequest(text: "survivor"))
        XCTAssertEqual(result.entries.map(\.id), [survivor])
        XCTAssertEqual(result.entries.map(\.path), ["/keep/survivor.txt"])
        XCTAssertEqual(try db.search(SearchRequest(text: "document")).total, 0)
        try tree.add(path: "/keep/after-compaction.txt")
        XCTAssertEqual(try db.search(SearchRequest(text: "after")).total, 1)
        try db.beginBulkLoad()
        XCTAssertFalse(try db.compactIfNeeded(minimumFreeBytes: 0, minimumFreeFraction: 0))
        try db.endBulkLoad()
    }

    func testEntryGenerationAndDataVersionIgnoreNoOpUpserts() throws {
        try withDatabasePath { path in
            let db = try Database(path: path)
            XCTAssertEqual(db.entryChangeGeneration, 0)
            let tree = TestTree(db: db)
            let id = try tree.add(path: "/folder/report.txt", size: 10, modified: 100.9)
            let parent = try XCTUnwrap(tree.id(for: "/folder"))
            XCTAssertEqual(db.entryChangeGeneration, 3)
            let observer = try SQLiteObserver(path: path)
            let version = try observer.integer("PRAGMA data_version")
            let generation = db.entryChangeGeneration
            var row = IndexRow(id: id, parent: parent, name: "report.txt", isDir: false, size: 10, modified: 100.1)
            _ = try db.search(SearchRequest(text: "report"), useMemory: true)
            for _ in 0..<3 {
                try db.insert(rows: [row])
            }
            _ = db.allocateIDs(3)
            XCTAssertEqual(try db.ensureRootRow(path: "/"), try db.child(ofParent: 0, name: "")?.id)
            XCTAssertEqual(db.entryChangeGeneration, generation)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), version)
            row.size = 11
            try db.insert(rows: [row])
            XCTAssertEqual(db.entryChangeGeneration, generation + 1)
            XCTAssertNotEqual(try observer.integer("PRAGMA data_version"), version)
            row.modified = 101.9
            try db.insert(rows: [row])
            XCTAssertEqual(db.entryChangeGeneration, generation + 2)
            row.isDir = true
            try db.insert(rows: [row])
            XCTAssertEqual(db.entryChangeGeneration, generation + 3)
            try db.deleteIDs([id])
            XCTAssertEqual(db.entryChangeGeneration, generation + 4)
            try db.deleteIDs([id])
            XCTAssertEqual(db.entryChangeGeneration, generation + 4)
            try db.deleteSubtree(id: parent)
            XCTAssertEqual(db.entryChangeGeneration, generation + 5)
            try db.deleteSubtree(id: parent)
            XCTAssertEqual(db.entryChangeGeneration, generation + 5)
        }
    }

    func testIndexedDirectoryAncestorFindsDeepestDirectoryWithoutWrites() throws {
        try withDatabasePath { path in
            let db = try Database(path: path)
            let tree = TestTree(db: db)
            _ = try tree.add(path: "/known/deep/report.txt")
            let deepID = try XCTUnwrap(tree.id(for: "/known/deep"))
            let rootID = try db.ensureRootRow(path: "/")
            let observer = try SQLiteObserver(path: path)
            let count = try db.count()
            let generation = db.entryChangeGeneration
            let version = try observer.integer("PRAGMA data_version")
            for requested in ["/known/deep", "/known/deep/", "/known/deep/report.txt", "/known/deep/report.txt/child", "/known/deep/missing/child"] {
                let ancestor = try XCTUnwrap(db.indexedDirectoryAncestor(path: requested, roots: ["/"]))
                XCTAssertEqual(ancestor.path, "/known/deep")
                XCTAssertEqual(ancestor.id, deepID)
            }
            let ancestor = try XCTUnwrap(db.indexedDirectoryAncestor(path: "/missing/child", roots: ["/"]))
            XCTAssertEqual(ancestor.path, "/")
            XCTAssertEqual(ancestor.id, rootID)
            let root = try XCTUnwrap(db.indexedDirectoryAncestor(path: "/", roots: ["/"]))
            XCTAssertEqual(root.path, "/")
            XCTAssertEqual(root.id, rootID)
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/known/deep", roots: ["/known"]))
            XCTAssertNil(try db.child(ofParent: deepID, name: "missing"))
            XCTAssertEqual(try db.count(), count)
            XCTAssertEqual(db.entryChangeGeneration, generation)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), version)
        }
    }

    func testIndexedDirectoryAncestorDoesNotCreateMissingOrFileRoots() throws {
        try withDatabasePath { path in
            let db = try Database(path: path)
            let observer = try SQLiteObserver(path: path)
            let emptyVersion = try observer.integer("PRAGMA data_version")
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/missing/child", roots: ["/missing"]))
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/", roots: ["/"]))
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/missing", roots: []))
            XCTAssertEqual(try db.count(), 0)
            XCTAssertEqual(db.entryChangeGeneration, 0)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), emptyVersion)
            let tree = TestTree(db: db, rootPath: "/file-root")
            let id = try tree.add(path: "/file-root", isDir: true)
            try db.insert(rows: [IndexRow(id: id, parent: 0, name: "/file-root", isDir: false, size: 7, modified: 0)])
            let generation = db.entryChangeGeneration
            let version = try observer.integer("PRAGMA data_version")
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/file-root", roots: ["/file-root"]))
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/file-root/child", roots: ["/file-root"]))
            XCTAssertNil(try db.indexedDirectoryAncestor(path: "/file-root-other/child", roots: ["/file-root"]))
            XCTAssertEqual(try db.count(), 1)
            XCTAssertEqual(db.entryChangeGeneration, generation)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), version)
        }
    }

    func testIndexedDirectoryAncestorPreservesAliasesAndUsesShortestConfiguredRoot() throws {
        try withDatabasePath { path in
            let directory = (path as NSString).deletingLastPathComponent
            let physical = directory + "/physical"
            let alias = directory + "/configured"
            try FileManager.default.createDirectory(atPath: physical + "/nested/deep/newer", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: physical)
            let db = try Database(path: path)
            let tree = TestTree(db: db, rootPath: alias)
            let deepID = try tree.add(path: alias + "/nested/deep", isDir: true)
            let nestedTree = TestTree(db: db, rootPath: alias + "/nested")
            _ = try nestedTree.add(path: alias + "/nested/deep/newer", isDir: true)
            let observer = try SQLiteObserver(path: path)
            let count = try db.count()
            let generation = db.entryChangeGeneration
            let version = try observer.integer("PRAGMA data_version")
            let roots = [alias + "/nested/", alias + "///"]
            let ancestor = try XCTUnwrap(db.indexedDirectoryAncestor(path: alias + "/nested/deep/newer/leaf/", roots: roots))
            XCTAssertEqual(ancestor.path, alias + "/nested/deep")
            XCTAssertEqual(ancestor.id, deepID)
            let canonical = Walk.canonicalPath(alias)
            XCTAssertNotEqual(canonical, alias)
            XCTAssertNil(try db.indexedDirectoryAncestor(path: canonical + "/nested/deep", roots: roots))
            XCTAssertNil(try db.indexedDirectoryAncestor(path: alias + "/nested/deep", roots: roots + ["/"]))
            XCTAssertEqual(try db.count(), count)
            XCTAssertEqual(db.entryChangeGeneration, generation)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), version)
        }
    }

    func testChildLookupReturnsIndexedMetadataWithoutMaterializingPaths() throws {
        try withDatabasePath { path in
            let db = try Database(path: path)
            let tree = TestTree(db: db)
            let name = "café's?.txt"
            let id = try tree.add(path: "/first/" + name, size: 19, modified: 123.9)
            let otherID = try tree.add(path: "/second/" + name, size: 23, modified: 456)
            let parent = try XCTUnwrap(tree.id(for: "/first"))
            let otherParent = try XCTUnwrap(tree.id(for: "/second"))
            let observer = try SQLiteObserver(path: path)
            let generation = db.entryChangeGeneration
            let version = try observer.integer("PRAGMA data_version")
            let child = try XCTUnwrap(db.child(ofParent: parent, name: name))
            XCTAssertEqual(child, Entry(id: id, path: "", name: name, isDirectory: false, size: 19,
                                        modified: Date(timeIntervalSince1970: 123)))
            XCTAssertEqual(try db.child(ofParent: otherParent, name: name)?.id, otherID)
            XCTAssertNil(try db.child(ofParent: parent, name: "missing"))
            XCTAssertNil(try db.child(ofParent: 0, name: name))
            XCTAssertEqual(try db.child(ofParent: parent, name: name), child)
            XCTAssertEqual(db.entryChangeGeneration, generation)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), version)
            try db.insert(rows: [IndexRow(id: id, parent: parent, name: name, isDir: true, size: 0, modified: 789)])
            XCTAssertTrue(try XCTUnwrap(db.child(ofParent: parent, name: name)).isDirectory)
            XCTAssertEqual(try db.child(ofParent: parent, name: name)?.modified, Date(timeIntervalSince1970: 789))
            try db.deleteIDs([id])
            XCTAssertNil(try db.child(ofParent: parent, name: name))
        }
    }

    func testMetadataUpdatesPreserveFTSAndReplacementIDsRefreshMemory() throws {
        try withDatabasePath { path in
            let db = try Database(path: path)
            let tree = TestTree(db: db)
            let id = try tree.add(path: "/annual report.txt", size: 10, modified: 100)
            for number in 0..<32 {
                try tree.add(path: "/filler-\(number).txt")
            }
            let parent = try db.ensureRootRow(path: "/")
            let observer = try SQLiteObserver(path: path)
            let initialFTS = try observer.ftsSnapshot()
            let initialMemory = try db.search(SearchRequest(text: "annual"), useMemory: true)
            var row = IndexRow(id: id, parent: parent, name: "annual report.txt", isDir: false, size: 8192, modified: 600)
            try db.insert(rows: [row])
            XCTAssertEqual(try observer.ftsSnapshot(), initialFTS)
            let request = SearchRequest(text: "\"annual report\"", kind: .files, wholeWord: true, sortKey: .size)
            let updated = try db.search(request, useMemory: true)
            XCTAssertEqual(updated.entries.map(\.id), [id])
            XCTAssertEqual(updated.entries.first?.size, 8192)
            XCTAssertEqual(updated.entries.first?.modified, Date(timeIntervalSince1970: 600))
            XCTAssertEqual(updated.entries.first?.path, "/annual report.txt")
            let updatedMemory = try db.search(SearchRequest(text: "annual"), useMemory: true)
            XCTAssertEqual(updatedMemory.entries.first?.size, 8192)
            XCTAssertEqual(updatedMemory.cacheStatistics.fullLoads, initialMemory.cacheStatistics.fullLoads)
            let replacement = db.nextID()
            row.id = replacement
            let generation = db.entryChangeGeneration
            try db.insert(rows: [row])
            XCTAssertEqual(db.entryChangeGeneration, generation + 1)
            XCTAssertNotEqual(try observer.ftsSnapshot(), initialFTS)
            XCTAssertEqual(try db.search(request, useMemory: true).entries.map(\.id), [replacement])
            let replacedMemory = try db.search(SearchRequest(text: "annual"), useMemory: true)
            XCTAssertEqual(replacedMemory.entries.map(\.id), [replacement])
            XCTAssertEqual(replacedMemory.cacheStatistics.fullLoads, initialMemory.cacheStatistics.fullLoads)
            XCTAssertEqual(replacedMemory.cacheStatistics.incrementalRefreshes, updatedMemory.cacheStatistics.incrementalRefreshes + 1)
            try observer.execute("UPDATE entries SET name = 'renamed ledger.txt' WHERE id = \(replacement)")
            XCTAssertEqual(try db.search(request).total, 0)
            XCTAssertEqual(try db.search(SearchRequest(text: "ledger", wholeWord: true)).entries.map(\.id), [replacement])
            try db.deleteIDs([replacement])
            XCTAssertEqual(try db.search(SearchRequest(text: "ledger", wholeWord: true)).total, 0)
        }
    }

    func testBulkLoadOnlyAdvancesEntryGenerationForEntryWritesAndRestoresSelectiveFTS() throws {
        try withDatabasePath { path in
            let db = try Database(path: path)
            let tree = TestTree(db: db)
            let root = try tree.add(path: "/", isDir: true)
            XCTAssertEqual(try db.child(ofParent: 0, name: "")?.id, root)
            let observer = try SQLiteObserver(path: path)
            let generation = db.entryChangeGeneration
            try db.beginBulkLoad()
            XCTAssertEqual(db.entryChangeGeneration, generation)
            XCTAssertEqual(try observer.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'entries'"), 0)
            let id = try tree.add(path: "/bulk report.txt", size: 10, modified: 100)
            XCTAssertEqual(db.entryChangeGeneration, generation + 1)
            try db.endBulkLoad()
            XCTAssertEqual(db.entryChangeGeneration, generation + 1)
            XCTAssertEqual(try observer.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'entries_au_name'"), 1)
            XCTAssertEqual(try db.child(ofParent: root, name: "bulk report.txt")?.id, id)
            let fts = try observer.ftsSnapshot()
            try db.insert(rows: [IndexRow(id: id, parent: root, name: "bulk report.txt", isDir: false, size: 20, modified: 200)])
            XCTAssertEqual(try observer.ftsSnapshot(), fts)
            XCTAssertEqual(try db.search(SearchRequest(text: "report", wholeWord: true)).entries.first?.size, 20)
        }
    }

    func testReopeningLegacyVersionFourTriggerUpgradesWithoutRebuildingOrRepeatedWrites() throws {
        try withDatabasePath { path in
            let saved = try { () throws -> (root: Int64, file: Int64) in
                let db = try Database(path: path)
                let tree = TestTree(db: db)
                let id = try tree.add(path: "/legacy report.txt", size: 10, modified: 100)
                return (try db.ensureRootRow(path: "/"), id)
            }()
            let observer = try SQLiteObserver(path: path)
            try observer.execute("""
            DROP TRIGGER entries_au_name;
            CREATE TRIGGER entries_au AFTER UPDATE ON entries BEGIN
                INSERT INTO entries_fts(entries_fts, rowid, name) VALUES ('delete', old.id, old.name);
                INSERT INTO entries_fts(rowid, name) VALUES (new.id, new.name);
            END;
            """)
            let identity = IndexCheckpoint.identity(of: path)
            let initialFTS = try observer.ftsSnapshot()
            do {
                let db = try Database(path: path)
                XCTAssertEqual(IndexCheckpoint.identity(of: path), identity)
                XCTAssertEqual(try observer.integer("PRAGMA user_version"), 4)
                XCTAssertEqual(try db.count(), 2)
                XCTAssertEqual(try db.child(ofParent: saved.root, name: "legacy report.txt")?.id, saved.file)
                XCTAssertEqual(try db.search(SearchRequest(text: "report", wholeWord: true)).entries.map(\.id), [saved.file])
                XCTAssertEqual(try observer.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'entries_au'"), 0)
                XCTAssertEqual(try observer.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'entries_au_name'"), 1)
                XCTAssertEqual(try observer.ftsSnapshot(), initialFTS)
                try db.insert(rows: [IndexRow(id: saved.file, parent: saved.root, name: "legacy report.txt", isDir: false, size: 20, modified: 200)])
                XCTAssertEqual(try observer.ftsSnapshot(), initialFTS)
                XCTAssertEqual(try db.search(SearchRequest(text: "report", wholeWord: true)).entries.first?.size, 20)
            }
            let schemaVersion = try observer.integer("PRAGMA schema_version")
            let dataVersion = try observer.integer("PRAGMA data_version")
            do {
                let db = try Database(path: path)
                XCTAssertEqual(try db.count(), 2)
                XCTAssertEqual(try db.child(ofParent: saved.root, name: "legacy report.txt")?.id, saved.file)
            }
            XCTAssertEqual(try observer.integer("PRAGMA schema_version"), schemaVersion)
            XCTAssertEqual(try observer.integer("PRAGMA data_version"), dataVersion)
            XCTAssertEqual(try observer.ftsSnapshot(), initialFTS)
        }
    }

    private func withDatabasePath(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("index.sqlite").path)
    }
}

private final class SQLiteObserver {
    private let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw DatabaseError.open(path)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 10000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw DatabaseError.sql(description, sql: sql)
        }
    }

    func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return result
    }

    func integer(_ sql: String) throws -> Int64 {
        let value = try XCTUnwrap(rows(sql).first?.first)
        return try XCTUnwrap(Int64(value))
    }

    func ftsSnapshot() throws -> [[String]] {
        try rows("""
        SELECT 'data', CAST(id AS TEXT), hex(block), '' FROM entries_fts_data
        UNION ALL
        SELECT 'idx', CAST(segid AS TEXT), hex(term), CAST(pgno AS TEXT) FROM entries_fts_idx
        UNION ALL
        SELECT 'config', k, CAST(v AS TEXT), '' FROM entries_fts_config
        ORDER BY 1, 2, 3, 4
        """)
    }
}
