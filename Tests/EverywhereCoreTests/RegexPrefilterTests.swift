import XCTest
@testable import EverywhereCore

final class RegexPrefilterTests: XCTestCase {
    func testPrefiltersNeverRejectUnicodeRegexCaseFolding() throws {
        try fixture { database, tree in
            let names = ["KELVIN-ASCII.txt", "Kelvin.txt", "kelvin.TXT", "ſample.txt", "sample.txt", "straße.txt", "STRASSE.txt", "other.txt"]
            for name in names { try tree.add(path: "/files/" + name) }
            for pattern in ["kelvin", "sample", "strasse", "KELVIN\\.TXT$", "^.*\\.txt$"] {
                for matchCase in [false, true] {
                    let regex = try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
                    let expected = names.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.sorted()
                    if pattern == "kelvin" && !matchCase { XCTAssertTrue(expected.contains("Kelvin.txt")) }
                    for memory in [false, true] {
                        let result = try database.search(SearchRequest(text: pattern, kind: .files, useRegex: true, matchCase: matchCase), useMemory: memory)
                        XCTAssertEqual(result.entries.map(\.name).sorted(), expected, "\(pattern), memory \(memory), case \(matchCase)")
                        XCTAssertEqual(result.total, expected.count)
                    }
                }
            }
        }
    }

    func testCompiledLiteralPrefilterTreatsRegexEscapedWildcardsLiterally() throws {
        try fixture { database, tree in
            let names = ["prefix-abc*def.txt", "prefix-abc?def.txt", "abc+def.txt", "AbC*DeF.TXT", "abcdef.txt", "a|b(c).txt"]
            for name in names { try tree.add(path: "/files/" + name) }
            for pattern in ["abc\\*def", "abc\\?def", "abc\\+def", "a\\|b\\(c\\)"] {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let expected = names.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.sorted()
                for memory in [false, true] {
                    XCTAssertEqual(try database.search(SearchRequest(text: pattern, kind: .files, useRegex: true), useMemory: memory).entries.map(\.name).sorted(), expected)
                }
            }
        }
    }

    func testRepeatedRegexNameDecisionsRetainRowFiltersPagingAndUpdates() throws {
        try fixture { database, tree in
            for index in 0..<300 {
                try tree.add(path: "/group\(index)/report-2026.pdf", size: Int64(index), modified: Double(index))
                try tree.add(path: "/group\(index)/.report-2026.pdf", modified: Double(index))
            }
            try tree.add(path: "/directory/report-2026.pdf", isDir: true)
            for key in [SortKey.name, .size, .modified, .path] {
                let request = SearchRequest(text: "report-\\d+\\.pdf$", kind: .files, includeHidden: false, useRegex: true, sortKey: key, ascending: false, limit: 15, offset: 140)
                let disk = try database.search(request, useMemory: false)
                let memory = try database.search(request, useMemory: true)
                XCTAssertEqual(disk.entries, memory.entries)
                XCTAssertEqual(memory.total, 300)
                XCTAssertEqual(memory.entries.count, 15)
            }
            try database.deleteSubtree(id: tree.id(for: "/group0")!)
            XCTAssertEqual(try database.search(SearchRequest(text: "report-\\d+", kind: .files, includeHidden: false, useRegex: true), useMemory: true).total, 299)
        }
    }

    func testRegexCandidateKeysAndRepeatedSortsPreserveDiskParity() throws {
        try fixture { database, tree in
            for group in 0..<4 {
                for (number, name) in ["Report.txt", "report.txt", ".report.txt", "report.md", "other.txt", "Kelvin.txt"].enumerated() {
                    try tree.add(path: "/group\(group)/" + name, size: Int64(group * 10 + number), modified: Double(number))
                }
                try tree.add(path: "/folders\(group)/report.txt", isDir: true)
            }
            let scope = SearchScope(name: "Selected reports", folders: ["/group1", "/group3"], expression: "Report size:>=20B | other ext:txt")
            var requests: [SearchRequest] = []
            for selectedScope in [nil, scope] {
                for pattern in ["report", "^report", "txt$", "never-matches"] {
                    for kind in KindFilter.allCases {
                        for includeHidden in [false, true] {
                            for matchCase in [false, true] {
                                for sort in SortKey.allCases {
                                    for ascending in [false, true] {
                                        requests.append(SearchRequest(text: pattern, kind: kind, includeHidden: includeHidden, useRegex: true,
                                                                      matchCase: matchCase, sortKey: sort, ascending: ascending, limit: 3, offset: 1,
                                                                      scope: selectedScope))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let expected = try requests.map { try database.search($0, useMemory: false) }
            for _ in 0..<2 {
                for (request, disk) in zip(requests, expected) {
                    let memory = try database.search(request, useMemory: true)
                    XCTAssertEqual(memory.entries, disk.entries, "\(request)")
                    XCTAssertEqual(memory.total, disk.total, "\(request)")
                }
            }
        }
    }

    func testRegexCandidatesInvalidateForLocalAndExternalWrites() throws {
        try fixture { database, tree in
            for number in 0..<8 { try tree.add(path: "/reports/report-\(number).txt", size: Int64(number)) }
            let scope = SearchScope(name: "Large", expression: "size:>=4B")
            var request = SearchRequest(text: "^report", kind: .files, useRegex: true, limit: 3, scope: scope)
            let initial = try database.search(request, useMemory: true)
            XCTAssertEqual(initial.total, 4)
            request.offset = 3
            XCTAssertEqual(try database.search(request, useMemory: true).entries.count, 1)
            let parent = try XCTUnwrap(tree.id(for: "/reports"))
            let id = try XCTUnwrap(tree.id(for: "/reports/report-0.txt"))
            try database.insert(rows: [IndexRow(id: id, parent: parent, name: "report-0.txt", isDir: false, size: 9, modified: 0)])
            let patched = try database.search(request, useMemory: true)
            XCTAssertEqual(patched.total, 5)
            XCTAssertEqual(patched.entries.count, 2)
            XCTAssertEqual(patched.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
            XCTAssertGreaterThan(patched.cacheStatistics.incrementalRefreshes, initial.cacheStatistics.incrementalRefreshes)
            let external = try Database(path: database.path)
            try external.insert(rows: [IndexRow(id: external.nextID(), parent: parent, name: "report-external.txt", isDir: false, size: 10, modified: 0)])
            let refreshed = try database.search(request, useMemory: true)
            XCTAssertEqual(refreshed.total, 6)
            XCTAssertEqual(refreshed.entries.count, 3)
            XCTAssertGreaterThan(refreshed.cacheStatistics.fullLoads, patched.cacheStatistics.fullLoads)
            let disk = try database.search(request, useMemory: false)
            XCTAssertEqual(refreshed.entries, disk.entries)
        }
    }

    private func fixture(_ body: (Database, TestTree) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-regex-prefilter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try body(database, TestTree(db: database))
    }
}
