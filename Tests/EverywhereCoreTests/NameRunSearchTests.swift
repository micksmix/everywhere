import SQLite3
import XCTest
@testable import EverywhereCore

final class NameRunSearchTests: XCTestCase {
    private var directory: URL!
    private var db: Database!
    private var disk: Database!
    private var tree: TestTree!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-name-runs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        tree = TestTree(db: db)
        try populate()
        disk = try Database(path: db.path)
    }

    override func tearDownWithError() throws {
        disk = nil
        tree = nil
        db = nil
        guard directory.lastPathComponent.hasPrefix("everywhere-name-runs-"),
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
            return XCTFail("Unexpected name-run fixture directory")
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func groupPath(_ group: Int) -> String {
        "/Runs/\(group < 20 ? "left" : "right")/group-\(String(format: "%03d", group))"
    }

    private func populate() throws {
        let names = ["report.txt", "report-2026.pdf", "notes.md", "data.csv", "image.png", "archive.zip", "package.json", "readme",
                     "build.log", "doc.swift", "invoice.pdf", "license", "twin.txt", ".hidden.txt", "café-notes.txt", "a*b?.txt"]
        try db.beginBulkLoad()
        for group in 0..<40 {
            for (number, name) in names.enumerated() {
                let isDirectory = name == "twin.txt" && group % 3 == 0 || name == ".hidden.txt" && group % 2 == 0
                try tree.add(path: groupPath(group) + "/" + name, isDir: isDirectory,
                             size: Int64(group * 1000 + number), modified: 1_735_732_800 + Double(group * 86400 + number))
            }
        }
        let interleaved = [["A.txt", "a.txt", "A.txt"], ["Kelvin.txt", "kelvin.txt", "Kelvin.txt"],
                           ["ſample.txt", "sample.txt", "ſample.txt"], ["straße.txt", "STRASSE.txt", "straße.txt"],
                           ["café.txt", "cafe\u{301}.txt", "café.txt"]]
        for names in interleaved {
            for (group, name) in names.enumerated() {
                try tree.add(path: groupPath(group) + "/" + name, size: Int64(group + 1), modified: Double(group + 1))
            }
        }
        try db.endBulkLoad()
    }

    @discardableResult
    private func assertParity(_ request: SearchRequest, file: StaticString = #filePath, line: UInt = #line) throws -> SearchResult {
        let expected = try disk.search(request, useMemory: false)
        let actual = try db.search(request, useMemory: true)
        let label = "\(request.text), \(request.sortKey), ascending \(request.ascending), case \(request.matchCase), offset \(request.offset)"
        XCTAssertEqual(actual.entries, expected.entries, label, file: file, line: line)
        XCTAssertEqual(actual.total, expected.total, label, file: file, line: line)
        XCTAssertLessThanOrEqual(actual.cacheStatistics.sortCount, 3, file: file, line: line)
        return actual
    }

    private func prepareNameOrders() throws {
        try db.prepareSearchIndex(sortKey: .name, ascending: true)
        try db.prepareSearchIndex(sortKey: .name, ascending: false)
    }

    func testExactRunsKeepMixedCaseAndUnicodeDecisionsSeparate() throws {
        try prepareNameOrders()
        for ascending in [true, false] {
            for matchCase in [false, true] {
                for text in ["report", "*.txt", "report | notes", "!report", "A.txt", "a.txt", "kelvin", "Kelvin",
                             "sample", "ſample", "strasse", "straße", "café", "absent-name"] {
                    try assertParity(SearchRequest(text: text, matchCase: matchCase, ascending: ascending, limit: 13, offset: 1))
                }
                for pattern in ["^a\\.txt$", "kelvin", "sample", "strasse", "café"] {
                    try assertParity(SearchRequest(text: pattern, useRegex: true, matchCase: matchCase,
                                                   ascending: ascending, limit: 13, offset: 1))
                }
            }
        }
        XCTAssertEqual(try assertParity(SearchRequest(text: "A.txt", matchCase: true)).total, 2)
        XCTAssertEqual(try assertParity(SearchRequest(text: "a.txt", matchCase: true)).total, 1)
        let upper = try XCTUnwrap(tree.id(for: groupPath(0) + "/A.txt"))
        let lower = try XCTUnwrap(tree.id(for: groupPath(1) + "/a.txt"))
        let upperAgain = try XCTUnwrap(tree.id(for: groupPath(2) + "/A.txt"))
        XCTAssertLessThan(upper, lower)
        XCTAssertLessThan(lower, upperAgain)
    }

    func testRunsApplyHiddenKindMetadataAndScopeOrFiltersPerRow() throws {
        try prepareNameOrders()
        for ascending in [true, false] {
            for kind in KindFilter.allCases {
                for includeHidden in [false, true] {
                    for text in ["twin.txt | hidden", "size:>19000 report", "dm:2025-01-15..2025-01-25 report",
                                 "in:/Runs/left twin.txt file: | in:/Runs/right twin.txt folder:",
                                 "in:/Runs/left report size:>9000 | in:/Runs/right notes size:<30000",
                                 "parent:/Runs/left/group-000 *.txt | in:/Runs/right .hidden.txt"] {
                        try assertParity(SearchRequest(text: text, kind: kind, includeHidden: includeHidden,
                                                       ascending: ascending, limit: 11, offset: 2))
                    }
                }
            }
        }
        let all = try assertParity(SearchRequest(text: "twin.txt"))
        let files = try assertParity(SearchRequest(text: "twin.txt", kind: .files))
        let folders = try assertParity(SearchRequest(text: "twin.txt", kind: .folders))
        XCTAssertEqual(all.total, 40)
        XCTAssertEqual(files.total, 26)
        XCTAssertEqual(folders.total, 14)
        XCTAssertEqual(try assertParity(SearchRequest(text: "hidden", includeHidden: false)).total, 0)
        XCTAssertEqual(try assertParity(SearchRequest(text: "hidden", kind: .folders)).total, 20)
        let scope = SearchScope(name: "Left", folders: ["/Runs/left"], expression: "size:>9000 | folder:")
        try assertParity(SearchRequest(text: "report | twin", limit: 9, offset: 3, scope: scope))
    }

    func testEvictedOrdersReleaseRunStorageAndRebuildWithDiskParity() throws {
        let orderings: [(SortKey, Bool)] = [(.name, true), (.name, false), (.size, false), (.modified, true),
                                          (.path, false), (.kind, true), (.name, true), (.name, false)]
        for (number, ordering) in orderings.enumerated() {
            try db.prepareSearchIndex(sortKey: ordering.0, ascending: ordering.1)
            let result = try assertParity(SearchRequest(text: "!absent-\(number)", sortKey: ordering.0,
                                                        ascending: ordering.1, limit: 37, offset: 19))
            let statistics = result.cacheStatistics
            XCTAssertGreaterThan(statistics.sortCount, 0)
            XCTAssertLessThanOrEqual(statistics.sortCount, 3)
            XCTAssertLessThanOrEqual(statistics.sortBytes, statistics.sortCount * (statistics.itemCount * 10 + 128))
            if number >= 2 { XCTAssertEqual(statistics.sortCount, 3) }
        }
        let first = try assertParity(SearchRequest(text: "report", limit: 17))
        let next = try assertParity(SearchRequest(text: "report", limit: 17, offset: 17))
        XCTAssertTrue(Set(first.entries.map(\.id)).isDisjoint(with: next.entries.map(\.id)))
        XCTAssertEqual(first.total, next.total)
        XCTAssertEqual(first.cacheStatistics, next.cacheStatistics)
    }

    func testInsertDeleteRenameAndMetadataPatchesPreserveRunParity() throws {
        try prepareNameOrders()
        let request = SearchRequest(text: "report | twin", limit: 1000)
        let initial = try assertParity(request)
        let report = groupPath(0) + "/report.txt"
        let reportID = try XCTUnwrap(tree.id(for: report))
        let parent = try XCTUnwrap(tree.id(for: groupPath(0)))
        try db.insert(rows: [IndexRow(id: reportID, parent: parent, name: "report.txt", isDir: false, size: 999_999, modified: 1_800_000_000)])
        let metadata = try assertParity(request)
        XCTAssertEqual(metadata.total, initial.total)
        XCTAssertEqual(metadata.entries.first { $0.id == reportID }?.size, 999_999)
        XCTAssertEqual(metadata.cacheStatistics.sortBytes, initial.cacheStatistics.sortBytes)
        XCTAssertEqual(metadata.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertGreaterThan(metadata.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes)
        let inserted = groupPath(39) + "/report-new.txt"
        try tree.add(path: inserted, size: 800_000, modified: 1_800_000_001)
        let afterInsert = try assertParity(request)
        XCTAssertEqual(afterInsert.total, initial.total + 1)
        XCTAssertTrue(afterInsert.entries.contains { $0.path == inserted })
        XCTAssertEqual(afterInsert.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        try db.deleteIDs([reportID])
        let renamed = groupPath(0) + "/renamed-report.txt"
        try tree.add(path: renamed, size: 999_999, modified: 1_800_000_000)
        let afterRename = try assertParity(request)
        XCTAssertEqual(afterRename.total, afterInsert.total)
        XCTAssertFalse(afterRename.entries.contains { $0.path == report })
        XCTAssertTrue(afterRename.entries.contains { $0.path == renamed })
        let removed = try XCTUnwrap(tree.id(for: groupPath(39) + "/twin.txt"))
        try db.deleteSubtree(id: removed)
        let afterDelete = try assertParity(request)
        XCTAssertEqual(afterDelete.total, initial.total)
        XCTAssertFalse(afterDelete.entries.contains { $0.id == removed })
        XCTAssertEqual(afterDelete.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertGreaterThan(afterDelete.cacheStatistics.incrementalRefreshes, afterInsert.cacheStatistics.incrementalRefreshes)
        for ordering in [(SortKey.size, false), (.modified, true), (.name, false), (.name, true)] {
            try assertParity(SearchRequest(text: "size:>700000 report | in:/Runs/right twin.txt", sortKey: ordering.0,
                                           ascending: ordering.1, limit: 13, offset: 1))
        }
    }

    func testCancelledRunScanRetainsCompletedCandidatesAndRecovers() throws {
        try withIndex { index in
            try index.prepareSort(key: .name, ascending: true, cancellation: nil, pathIndex: unexpectedPathIndex)
            let storage = index.statistics
            XCTAssertGreaterThan(storage.sortBytes, index.rows.count * MemoryLayout<UInt32>.stride)
            XCTAssertLessThanOrEqual(storage.sortBytes, index.rows.count * 10 + 128)
            let previous = SearchRequest(text: "^report", kind: .files, useRegex: true, limit: 17)
            let initial = try index.selectRegex(request: previous, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) {
                $0.hasPrefix("report")
            }
            XCTAssertEqual(initial.total, 80)
            let changed = SearchRequest(text: ".*", kind: .files, useRegex: true, limit: 17)
            let cancellation = SearchCancellation()
            var evaluations = 0
            XCTAssertThrowsError(try index.selectRegex(request: changed, cancellation: cancellation, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                if evaluations == 3 { cancellation.cancel() }
                return true
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(evaluations, 3)
            var repeatedEvaluations = 0
            let reused = try index.selectRegex(request: previous, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                repeatedEvaluations += 1
                return false
            }
            XCTAssertEqual(repeatedEvaluations, 0)
            XCTAssertEqual(reused.total, initial.total)
            XCTAssertEqual(reused.rows.map { $0.0.id }, initial.rows.map { $0.0.id })
            let recovered = try index.selectRegex(request: changed, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in true }
            XCTAssertEqual(recovered.total, index.rows.filter { !$0.isDirectory }.count)
            XCTAssertEqual(index.statistics.sortBytes, storage.sortBytes)
        }
    }

    private func withIndex(_ body: (FilenameIndex) throws -> Void) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let reader = try XCTUnwrap(connection)
        defer { sqlite3_close(reader) }
        let index = try FilenameIndex(connection: reader) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else {
                throw DatabaseError.sql(String(cString: sqlite3_errmsg(reader)), sql: String(cString: sqlite3_sql(statement)))
            }
            return status
        }
        try body(index)
    }

    private func unexpectedPathIndex() throws -> PathSortIndex {
        throw DatabaseError.invalidQuery("A name-run workload must not construct a path index")
    }
}
