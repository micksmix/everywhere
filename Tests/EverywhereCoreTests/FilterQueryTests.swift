import XCTest
@testable import EverywhereCore

final class FilterQueryTests: XCTestCase {
    func testFiltersPreserveBooleanLogicAndPagination() throws {
        try fixture { db, tree in
            try tree.add(path: "/Docs/report.PDF", size: 2_000_000, modified: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12))!.timeIntervalSince1970)
            try tree.add(path: "/Docs/nested/notes.txt", size: 10)
            try tree.add(path: "/Docs-old/report.pdf", size: 100)
            try tree.add(path: "/Docs/.hidden.pdf", size: 5)
            try tree.add(path: "/other/image.png", size: 1)
            try tree.add(path: "/Docs/folder.pdf", isDir: true)
            let cases: [(String, [String])] = [
                ("ext:pdf size:>1MB", ["/Docs/report.PDF"]),
                ("in:/Docs ext:txt", ["/Docs/nested/notes.txt"]),
                ("parent:/Docs ext:txt", []),
                ("in:/docs ext:pdf !size:>1MB", ["/Docs/.hidden.pdf"]),
                ("parent:/Docs ext:pdf | type:image", ["/Docs/.hidden.pdf", "/Docs/report.PDF", "/other/image.png"]),
                ("ext:pdf !in:/Docs", ["/Docs-old/report.pdf"]),
                ("size:1..10 file:", ["/Docs/.hidden.pdf", "/Docs/nested/notes.txt", "/other/image.png"]),
                ("dm:2025-01-01 ext:pdf", ["/Docs/report.PDF"]),
                ("dm:!=2025-01-01 ext:pdf", ["/Docs/.hidden.pdf", "/Docs-old/report.pdf"]),
                ("parent:/Docs folder:", ["/Docs/folder.pdf", "/Docs/nested"]),
                ("in:/Missing | ext:png", ["/other/image.png"]),
                ("in:/Docs /Docs/nested/", ["/Docs/nested/notes.txt"])
            ]
            for memory in [false, true] {
                for (query, expected) in cases {
                    let result = try db.search(SearchRequest(text: query), useMemory: memory)
                    XCTAssertEqual(result.entries.map(\.path).sorted(), expected.sorted(), query)
                    XCTAssertEqual(result.total, expected.count, query)
                }
                let hidden = try db.search(SearchRequest(text: "in:/Docs ext:pdf", includeHidden: false), useMemory: memory)
                XCTAssertEqual(hidden.entries.map(\.path), ["/Docs/report.PDF"])
                let sensitive = try db.search(SearchRequest(text: "in:/docs ext:pdf", matchCase: true), useMemory: memory)
                XCTAssertEqual(sensitive.total, 0)
                let all = try db.search(SearchRequest(text: "ext:pdf"), useMemory: memory)
                let page = try db.search(SearchRequest(text: "ext:pdf", limit: 1, offset: 1), useMemory: memory)
                XCTAssertEqual(page.entries, [all.entries[1]])
                XCTAssertEqual(page.total, all.total)
            }
        }
    }

    func testScopeHandlesIndependentRootsUnicodeAndQuotes() throws {
        try fixture { db, tree in
            let root = try db.ensureRootRow(path: "/Separate Root/Ärea")
            try db.insert(rows: [IndexRow(id: db.nextID(), parent: root, name: "file.pdf", isDir: false, size: 1, modified: 0)])
            try tree.add(path: "/Docs/ext:pdf")
            try tree.add(path: "/Docs/report.pdf")
            try tree.add(path: "/Docs/a|b.txt")
            XCTAssertEqual(try db.search(SearchRequest(text: "in:\"/separate root/ärea\" ext:pdf")).total, 1)
            XCTAssertEqual(try db.search(SearchRequest(text: "in:\"/Separate Root\" ext:pdf")).total, 1)
            XCTAssertEqual(try db.search(SearchRequest(text: "parent:\"/Separate Root\" folder:")).entries.map(\.path), ["/Separate Root/Ärea"])
            XCTAssertEqual(try db.search(SearchRequest(text: "parent:\"/Separate Root\" ext:pdf")).total, 0)
            XCTAssertEqual(try db.search(SearchRequest(text: "\"ext:pdf\"")).entries.map(\.name), ["ext:pdf"])
            XCTAssertEqual(try db.search(SearchRequest(text: "in:/Docs \"ext:pdf\"")).entries.map(\.name), ["ext:pdf"])
        }
    }

    func testInvalidFiltersAndCancellation() throws {
        try fixture { db, _ in
            for text in ["ext:", "size:abc", "size:10..1", "size:-1", "dm:2025-02-30", "dm:2025-02-01..2025-01-01", "in:relative", "type:unknown"] {
                XCTAssertThrowsError(try db.search(SearchRequest(text: text)), text)
            }
            let token = SearchCancellation()
            token.cancel()
            XCTAssertThrowsError(try db.search(SearchRequest(text: "in:/"), cancellation: token))
        }
    }

    func testDateAndSizeBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 12))!
        let today = try FilterQuery.dateRange("today", now: now, calendar: calendar)
        XCTAssertEqual(today.maximum - today.minimum, 23 * 3600)
        XCTAssertTrue(today.contains(today.minimum))
        XCTAssertFalse(today.contains(today.maximum))
        let earlier = try FilterQuery.dateRange("<2025-03-09", now: now, calendar: calendar)
        XCTAssertFalse(earlier.contains(today.minimum))
        let inclusive = try FilterQuery.dateRange("<=2025-03-09", now: now, calendar: calendar)
        XCTAssertTrue(inclusive.contains(today.maximum - 1))
        XCTAssertFalse(inclusive.contains(today.maximum))
        XCTAssertEqual(try FilterQuery.sizeValue("1MB"), 1_000_000)
        XCTAssertEqual(try FilterQuery.sizeValue("1MiB"), 1_048_576)
    }

    func testSharedNamesAndMasksKeepDiskParityAfterUpdates() throws {
        try fixture { db, tree in
            let names = ["README.md", "package.json", "report.PDF", "KELVIN.txt", "Kelvin.txt", "café.txt", "cafe\u{301}.txt", "a?b.txt", "line\nname.txt"]
            var removed: [Int64] = []
            for folder in 0..<12 {
                for name in names {
                    let id = try tree.add(path: "/project-\(folder)/" + name, size: Int64(folder), modified: Double(folder))
                    if folder == 0 { removed.append(id) }
                }
            }
            let queries = ["read", "README", "*.txt !*line*", "k", "café", "json | pdf", "!missing", "a?b*", "[literal]", "package", "package.json"]
            var expected: [SearchRequest] = []
            var entries: [[Entry]] = []
            for query in queries {
                for sort in [SortKey.name, .modified, .size] {
                    let request = SearchRequest(text: query, sortKey: sort, ascending: false, limit: 17, offset: 2)
                    expected.append(request)
                    entries.append(try db.search(request).entries)
                }
            }
            for (index, request) in expected.enumerated() {
                XCTAssertEqual(try db.search(request, useMemory: true).entries, entries[index], request.text)
            }
            try db.deleteIDs(removed)
            try tree.add(path: "/project-12/README.md")
            let parent = tree.id(for: "/project-1")!
            let id = tree.id(for: "/project-1/package.json")!
            try db.insert(rows: [IndexRow(id: id, parent: parent, name: "package.json", isDir: false, size: 9999, modified: 9999)])
            let patched = try db.search(SearchRequest(text: "README | json", sortKey: .size, ascending: false), useMemory: true)
            XCTAssertGreaterThan(patched.cacheStatistics.incrementalRefreshes, 0)
            XCTAssertEqual(patched.entries, try db.search(SearchRequest(text: "README | json", sortKey: .size, ascending: false)).entries)
        }
    }

    private func fixture(_ body: (Database, TestTree) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try body(db, TestTree(db: db))
    }
}

final class SearchInteractionTests: XCTestCase {
    func testQuotedOperatorsRemainLiteral() {
        let query = SearchQueryParser.parse("\"|\" !\"ext:pdf\" \"!draft\"")
        XCTAssertEqual(query.groups.count, 1)
        XCTAssertEqual(query.groups[0].terms.map(\.text), ["|", "ext:pdf", "!draft"])
        XCTAssertEqual(query.groups[0].terms.map(\.isNegated), [false, true, false])
        XCTAssertTrue(query.groups[0].terms.allSatisfy(\.isQuoted))
        XCTAssertFalse(FilterQuery.containsFilters("!\"ext:pdf\""))
    }

    func testHistoryDeduplicatesBoundsAndRestoresDraft() {
        var history = SearchHistory(entries: ["old", "old", ""], limit: 2)
        history.record("new")
        XCTAssertEqual(history.entries, ["new", "old"])
        XCTAssertEqual(history.previous(current: "draft"), "new")
        XCTAssertEqual(history.previous(current: "new"), "old")
        XCTAssertEqual(history.previous(current: "old"), "old")
        XCTAssertEqual(history.next(), "new")
        XCTAssertEqual(history.next(), "draft")
        XCTAssertNil(history.next())
        history.record("old")
        XCTAssertEqual(history.entries, ["old", "new"])
        history.record("third")
        XCTAssertEqual(history.entries, ["third", "old"])
    }

    func testHighlightRangesHandleUnicodeFiltersNegationAndRegex() {
        let text = "📁 Annual Report.pdf"
        let ranges = SearchHighlights.ranges(in: text, request: SearchRequest(text: "report ext:pdf !annual"))
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["Report"])
        XCTAssertTrue(SearchHighlights.ranges(in: text, request: SearchRequest(text: "report", matchCase: true)).isEmpty)
        XCTAssertEqual(SearchHighlights.ranges(in: "foobar foo", request: SearchRequest(text: "foo", wholeWord: true)), [NSRange(location: 7, length: 3)])
        XCTAssertEqual(SearchHighlights.ranges(in: "file123.txt", request: SearchRequest(text: "[0-9]+", useRegex: true)), [NSRange(location: 4, length: 3)])
        XCTAssertTrue(SearchHighlights.ranges(in: text, request: SearchRequest(text: "[", useRegex: true)).isEmpty)
    }
}
