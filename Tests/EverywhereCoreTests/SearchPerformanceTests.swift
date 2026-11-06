import SQLite3
import XCTest
@testable import EverywhereCore

final class SearchPerformanceTests: XCTestCase {
    private var directory: URL!
    private var db: Database!
    private var tree: TestTree!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        tree = TestTree(db: db)
    }

    override func tearDownWithError() throws {
        tree = nil
        db = nil
        guard directory.lastPathComponent.hasPrefix("everywhere-performance-"),
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
            return XCTFail("Unexpected performance fixture directory")
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func populate(directories: Int = 20, files: Int = 64, repeatedNames: Bool = false) throws {
        try db.beginBulkLoad()
        for group in 0..<directories {
            let parent = group % 10 == 0 ? "/Home/group-\(group)" : "/Volumes/NAS/group-\(group)"
            for number in 0..<files {
                let name = repeatedNames ? "report-\(number).txt" : "report-\(group)-\(number).txt"
                try tree.add(path: parent + "/" + name, size: Int64(number), modified: Double(number))
            }
        }
        try db.endBulkLoad()
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
        throw DatabaseError.invalidQuery("A filename-only workload must not construct a path index")
    }

    func testScopedRegexWorkIsBoundedByScopeNotGlobalCandidates() throws {
        try populate()
        try withIndex { index in
            let root = try XCTUnwrap(tree.id(for: "/Home"))
            let scope = try index.folderScope(for: FolderScope.Key(paths: ["/Home"], recursive: true, matchCase: false), cancellation: nil) {
                FolderScope(parents: [root], included: [])
            }
            let request = SearchRequest(text: "^report", kind: .files, useRegex: true, limit: 13,
                                        scope: SearchScope(name: "Home", folders: ["/Home"]))
            let groups = try FilterQuery("", scope: request.scope).groups
            var evaluations = 0
            let result = try index.selectRegex(request: request, cancellation: nil, filteredGroups: groups,
                                               folderFilters: [[FolderScope.Filter(scope: scope, negated: false)]], literal: "report",
                                               pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return true
            }
            XCTAssertEqual(result.total, 128)
            XCTAssertEqual(result.rows.count, 13)
            XCTAssertEqual(evaluations, 128)
        }
    }

    func testSavedNameAndMetadataFiltersRunBeforeRegex() throws {
        try populate()
        try withIndex { index in
            let scope = SearchScope(name: "Large reports", expression: "report-0- size:>=32B")
            let request = SearchRequest(text: "^report", kind: .files, useRegex: true, scope: scope)
            let groups = try FilterQuery("", scope: scope).groups
            var evaluations = 0
            let result = try index.selectRegex(request: request, cancellation: nil, filteredGroups: groups,
                                               literal: "report", pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return true
            }
            XCTAssertEqual(result.total, 32)
            XCTAssertEqual(evaluations, 32)
        }
    }

    func testRepeatedRegexNamesShareDecisionsAfterPerRowFiltering() throws {
        try populate(repeatedNames: true)
        try withIndex { index in
            let scope = SearchScope(name: "Large reports", expression: "size:>=32B")
            let request = SearchRequest(text: "^report", kind: .files, useRegex: true, scope: scope)
            let groups = try FilterQuery("", scope: scope).groups
            var evaluations = 0
            let result = try index.selectRegex(request: request, cancellation: nil, filteredGroups: groups,
                                               literal: "report", pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return true
            }
            XCTAssertEqual(result.total, 640)
            XCTAssertEqual(evaluations, 32)
        }
    }

    func testSharedRegexNamesDoNotReuseScopeOrMetadataFailures() throws {
        try db.beginBulkLoad()
        for group in 0..<12 {
            let location = group < 6 ? "/Outside" : "/Allowed"
            for number in 0..<8 {
                try tree.add(path: "\(location)/group-\(group)/report-\(number).txt", size: group % 2 == 0 ? 0 : 100)
            }
        }
        try db.endBulkLoad()
        try withIndex { index in
            let root = try XCTUnwrap(tree.id(for: "/Allowed"))
            let membership = try index.folderScope(for: FolderScope.Key(paths: ["/Allowed"], recursive: true, matchCase: false), cancellation: nil) {
                FolderScope(parents: [root], included: [])
            }
            let scope = SearchScope(name: "Allowed large reports", folders: ["/Allowed"], expression: "size:>50B")
            let request = SearchRequest(text: ".*", kind: .files, useRegex: true, scope: scope)
            var evaluations = 0
            let result = try index.selectRegex(request: request, cancellation: nil, filteredGroups: FilterQuery("", scope: scope).groups,
                                               folderFilters: [[FolderScope.Filter(scope: membership, negated: false)]], literal: nil,
                                               pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return true
            }
            XCTAssertEqual(result.total, 24)
            XCTAssertEqual(evaluations, 8)
            XCTAssertTrue(result.rows.allSatisfy { $0.0.size == 100 && membership.parents.contains($0.0.parent) })
        }
    }

    func testRegexPrefilterKeepsORNameAndMetadataCorrelation() throws {
        for name in ["alpha.txt", "beta.pdf", "alpha.pdf", "beta.txt", "gamma.txt"] {
            try tree.add(path: "/Home/" + name)
        }
        let scope = SearchScope(name: "Reports", expression: "alpha ext:txt | beta ext:pdf")
        let request = SearchRequest(text: ".*", kind: .files, useRegex: true, scope: scope)
        try withIndex { index in
            var evaluations = 0
            let result = try index.selectRegex(request: request, cancellation: nil, filteredGroups: FilterQuery("", scope: scope).groups,
                                               literal: nil, pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return true
            }
            XCTAssertEqual(Set(result.rows.map { $0.1 }), ["alpha.txt", "beta.pdf"])
            XCTAssertEqual(evaluations, 2)
        }
        let memory = try db.search(request, useMemory: true)
        let disk = try db.search(request)
        XCTAssertEqual(memory.entries, disk.entries)
        XCTAssertEqual(memory.total, 2)
    }

    func testDeletingOmittedSlashRootInvalidatesScopeMembership() throws {
        try populate(directories: 2, files: 5)
        let root = try db.ensureRootRow(path: "/")
        let request = SearchRequest(text: "report", scope: SearchScope(name: "Root", folders: ["/"]))
        XCTAssertEqual(try db.search(request, useMemory: true).total, 10)
        try db.deleteIDs([root])
        let memory = try db.search(request, useMemory: true)
        let disk = try db.search(request)
        XCTAssertEqual(memory.total, 0)
        XCTAssertEqual(memory.entries, disk.entries)
        XCTAssertEqual(memory.total, disk.total)
    }

    func testGuaranteedLiteralRejectsASCIIWithoutRunningRegexButKeepsUnicodeConservative() throws {
        try populate()
        try tree.add(path: "/Home/unrelated-é.txt")
        try withIndex { index in
            var evaluations = 0
            let result = try index.selectRegex(request: SearchRequest(text: "needle", kind: .files, useRegex: true), cancellation: nil,
                                               literal: "needle", pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return false
            }
            XCTAssertEqual(result.total, 0)
            XCTAssertEqual(evaluations, 1)
        }
    }

    func testRegexCancellationBoundsExtraEvaluationsAndAllowsRecovery() throws {
        try populate()
        try withIndex { index in
            let cancellation = SearchCancellation()
            var evaluations = 0
            XCTAssertThrowsError(try index.selectRegex(request: SearchRequest(text: ".*", kind: .files, useRegex: true),
                                                      cancellation: cancellation, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                if evaluations == 32 { cancellation.cancel() }
                return true
            }) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertGreaterThanOrEqual(evaluations, 32)
            XCTAssertLessThanOrEqual(evaluations, 256)
            let recovered = try index.select(request: SearchRequest(text: "report", kind: .files, limit: 13), cancellation: nil,
                                             pathIndex: unexpectedPathIndex)
            XCTAssertEqual(recovered.total, 1280)
            XCTAssertEqual(recovered.rows.count, 13)
        }
    }

    func testRegexPagingAndResortingReuseCompletedCandidates() throws {
        try populate(directories: 4)
        try withIndex { index in
            var evaluations = 0
            var ids = Set<Int64>()
            for offset in stride(from: 0, to: 256, by: 64) {
                let request = SearchRequest(text: ".*", kind: .files, useRegex: true, limit: 64, offset: offset)
                let result = try index.selectRegex(request: request, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                    evaluations += 1
                    return true
                }
                XCTAssertEqual(result.total, 256)
                XCTAssertEqual(result.rows.count, 64)
                XCTAssertTrue(ids.isDisjoint(with: result.rows.map { $0.0.id }))
                ids.formUnion(result.rows.map { $0.0.id })
            }
            XCTAssertEqual(ids.count, 256)
            for key in [SortKey.name, .size, .kind, .modified] {
                for ascending in [false, true] {
                    let request = SearchRequest(text: ".*", kind: .files, useRegex: true, sortKey: key, ascending: ascending, limit: 11, offset: 3)
                    let result = try index.selectRegex(request: request, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                        evaluations += 1
                        return true
                    }
                    XCTAssertEqual(result.total, 256)
                    XCTAssertEqual(result.rows.count, 11)
                }
            }
            XCTAssertEqual(evaluations, 256)
        }
    }

    func testEmptyRegexCandidatesAreReusedAndNotMixedWithLiteralCandidates() throws {
        try populate(directories: 4)
        try withIndex { index in
            var evaluations = 0
            var request = SearchRequest(text: "report", kind: .files, useRegex: true, limit: 17)
            for offset in [0, 17, 34] {
                request.offset = offset
                let result = try index.selectRegex(request: request, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                    evaluations += 1
                    return false
                }
                XCTAssertEqual(result.total, 0)
                XCTAssertTrue(result.rows.isEmpty)
            }
            XCTAssertEqual(evaluations, 256)
            request.useRegex = false
            let literal = try index.select(request: request, cancellation: nil, pathIndex: unexpectedPathIndex)
            XCTAssertEqual(literal.total, 256)
            request.useRegex = true
            let regex = try index.selectRegex(request: request, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                return false
            }
            XCTAssertEqual(regex.total, 0)
            XCTAssertEqual(evaluations, 512)
        }
    }

    func testCancelledRegexQueryDoesNotPublishPartialCandidates() throws {
        try populate(directories: 4)
        try withIndex { index in
            let previous = SearchRequest(text: "^report", kind: .files, useRegex: true, limit: 17)
            let initial = try index.selectRegex(request: previous, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in true }
            let changed = SearchRequest(text: ".*", kind: .files, useRegex: true, limit: 17)
            let cancellation = SearchCancellation()
            var evaluations = 0
            XCTAssertThrowsError(try index.selectRegex(request: changed, cancellation: cancellation, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                evaluations += 1
                if evaluations == 32 { cancellation.cancel() }
                return true
            }) { XCTAssertTrue($0 is CancellationError) }
            var previousEvaluations = 0
            let reused = try index.selectRegex(request: previous, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                previousEvaluations += 1
                return false
            }
            XCTAssertEqual(reused.total, initial.total)
            XCTAssertEqual(reused.rows.map { $0.0.id }, initial.rows.map { $0.0.id })
            XCTAssertEqual(previousEvaluations, 0)
            var recoveredEvaluations = 0
            let recovered = try index.selectRegex(request: changed, cancellation: nil, literal: nil, pathIndex: unexpectedPathIndex) { _ in
                recoveredEvaluations += 1
                return true
            }
            XCTAssertEqual(recovered.total, 256)
            XCTAssertEqual(recoveredEvaluations, 256)
        }
    }

    func testSparseSearchDoesNotAllocateGlobalSortOrders() throws {
        try populate()
        try withIndex { index in
            for sort in SortKey.allCases {
                let result = try index.select(request: SearchRequest(text: "report-17-33.txt", sortKey: sort), cancellation: nil,
                                              pathIndex: unexpectedPathIndex)
                XCTAssertEqual(result.total, 1)
                XCTAssertEqual(index.statistics.sortCount, 0)
                XCTAssertEqual(index.statistics.sortBytes, 0)
            }
        }
    }

    func testSameParentPathSortAndPagingAvoidDirectoryIndexAndExtraStorage() throws {
        try db.beginBulkLoad()
        for number in 0..<1300 { try tree.add(path: "/report-\(number).txt") }
        try db.endBulkLoad()
        try withIndex { index in
            var request = SearchRequest(text: "report", sortKey: .path, limit: 20)
            let first = try index.select(request: request, cancellation: nil, pathIndex: unexpectedPathIndex)
            let initial = index.statistics
            var ids = Set(first.rows.map { $0.0.id })
            for offset in stride(from: 20, to: 200, by: 20) {
                request.offset = offset
                let page = try index.select(request: request, cancellation: nil, pathIndex: unexpectedPathIndex)
                XCTAssertEqual(page.total, 1300)
                XCTAssertEqual(page.rows.count, 20)
                XCTAssertTrue(ids.isDisjoint(with: page.rows.map { $0.0.id }))
                ids.formUnion(page.rows.map { $0.0.id })
                XCTAssertEqual(index.statistics, initial)
            }
            XCTAssertEqual(ids.count, 200)
            XCTAssertEqual(initial.sortCount, 1)
        }
    }

    func testFileMetadataAndMovePatchesRetainFolderMembershipCache() throws {
        try populate()
        try withIndex { index in
            let home = try XCTUnwrap(tree.id(for: "/Home"))
            let key = FolderScope.Key(paths: ["/Home"], recursive: true, matchCase: false)
            var loads = 0
            func load() -> FolderScope {
                loads += 1
                return FolderScope(parents: [home], included: [])
            }
            let original = try index.folderScope(for: key, cancellation: nil, load: load)
            let id = try XCTUnwrap(tree.id(for: "/Home/group-0/report-0-0.txt"))
            let parent = try XCTUnwrap(tree.id(for: "/Home/group-0"))
            for number in 0..<16 {
                let row = IndexRow(id: id, parent: parent, name: "report-0-0.txt", isDir: false, size: Int64(number), modified: Double(number))
                try index.apply(changedIDs: [id], replacements: [id: row], cancellation: nil, pathIndex: unexpectedPathIndex)
                let cached = try index.folderScope(for: key, cancellation: nil, load: load)
                XCTAssertEqual(cached.parents, original.parents)
            }
            let otherParent = try XCTUnwrap(tree.id(for: "/Volumes/NAS/group-1"))
            let moved = IndexRow(id: id, parent: otherParent, name: "report-0-0.txt", isDir: false, size: 16, modified: 16)
            try index.apply(changedIDs: [id], replacements: [id: moved], cancellation: nil, pathIndex: unexpectedPathIndex)
            let cached = try index.folderScope(for: key, cancellation: nil, load: load)
            XCTAssertFalse(FolderScope.Filter(scope: cached, negated: false).matches(id: id, parent: otherParent))
            XCTAssertEqual(loads, 1)
            let renamed = IndexRow(id: parent, parent: home, name: "renamed", isDir: true, size: 0, modified: 17)
            try index.apply(changedIDs: [parent], replacements: [parent: renamed], cancellation: nil, pathIndex: unexpectedPathIndex)
            _ = try index.folderScope(for: key, cancellation: nil, load: load)
            XCTAssertEqual(loads, 2)
            let directoryMetadata = IndexRow(id: parent, parent: home, name: "renamed", isDir: true, size: 0, modified: 18)
            try index.apply(changedIDs: [parent], replacements: [parent: directoryMetadata], cancellation: nil, pathIndex: unexpectedPathIndex)
            _ = try index.folderScope(for: key, cancellation: nil, load: load)
            XCTAssertEqual(loads, 2)
            for isDirectory in [true, false] {
                let converted = IndexRow(id: id, parent: otherParent, name: "report-0-0.txt", isDir: isDirectory, size: 0, modified: 19)
                try index.apply(changedIDs: [id], replacements: [id: converted], cancellation: nil, pathIndex: unexpectedPathIndex)
                _ = try index.folderScope(for: key, cancellation: nil, load: load)
            }
            XCTAssertEqual(loads, 4)
        }
    }

    func testMetadataPatchesDoNotAppendNameBytesOrRebuildNameSort() throws {
        try populate()
        try withIndex { index in
            try index.prepareSort(key: .name, ascending: true, cancellation: nil, pathIndex: unexpectedPathIndex)
            let initial = index.statistics
            let id = try XCTUnwrap(tree.id(for: "/Home/group-0/report-0-0.txt"))
            let parent = try XCTUnwrap(tree.id(for: "/Home/group-0"))
            for number in 0..<64 {
                let row = IndexRow(id: id, parent: parent, name: "report-0-0.txt", isDir: false, size: Int64(number), modified: Double(number))
                try index.apply(changedIDs: [id], replacements: [id: row], cancellation: nil, pathIndex: unexpectedPathIndex)
                XCTAssertEqual(index.statistics, initial)
                XCTAssertFalse(index.needsCompaction)
            }
        }
    }
}
