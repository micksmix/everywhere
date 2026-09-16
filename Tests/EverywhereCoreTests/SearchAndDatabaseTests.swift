import XCTest
@testable import EverywhereCore

final class SearchQueryTests: XCTestCase {
    func testSimpleTermsBecomePrefixPhrases() {
        let parsed = SearchQueryParser.parse("hello world")
        XCTAssertEqual(parsed.groups.count, 1)
        XCTAssertEqual(parsed.groups[0].terms.map(\.text), ["hello", "world"])
        XCTAssertFalse(parsed.groups[0].terms[0].isNegated)
    }

    func testEmptyReturnsNilFTSAndEmptyParse() {
        XCTAssertNil(SearchQueryBuilder.fts5Query(for: ""))
        XCTAssertNil(SearchQueryBuilder.fts5Query(for: "   \t\n "))
        XCTAssertTrue(SearchQueryParser.parse("  ").isEmpty)
    }

    func testEscapesQuotes() {
        XCTAssertEqual(SearchQueryBuilder.fts5Query(for: "a\"b"), "\"a\"\"b\"*")
    }

    func testVerticalBarSplitsGroups() {
        let parsed = SearchQueryParser.parse("alpha txt | beta log")
        XCTAssertEqual(parsed.groups.count, 2)
        XCTAssertEqual(parsed.groups[0].terms.map(\.text), ["alpha", "txt"])
        XCTAssertEqual(parsed.groups[1].terms.map(\.text), ["beta", "log"])
    }

    func testNegationAndQuotesAndWildcards() {
        let parsed = SearchQueryParser.parse("invoice !draft \"annual report\" *.pdf ca?t?2024")
        XCTAssertEqual(parsed.groups.count, 1)
        let terms = parsed.groups[0].terms
        XCTAssertEqual(terms.map(\.text), ["invoice", "draft", "annual report", "*.pdf", "ca?t?2024"])
        XCTAssertTrue(terms[1].isNegated)
        XCTAssertFalse(terms[0].isNegated)
        XCTAssertTrue(terms[3].hasWildcards)
        XCTAssertTrue(terms[4].hasWildcards)
        XCTAssertFalse(terms[2].hasWildcards)
        XCTAssertTrue(terms[2].text.contains(" "))
    }

    func testPathSeparatorsDetected() {
        let parsed = SearchQueryParser.parse("/downloads/ invoice")
        XCTAssertTrue(parsed.groups[0].terms[0].endsWithPathSeparator)
        XCTAssertTrue(parsed.groups[0].terms[0].hasPathSeparator)
        XCTAssertFalse(parsed.groups[0].terms[1].hasPathSeparator)
    }
}

final class TestTree {
    let db: Database
    private var ids: [String: Int64] = [:]

    init(db: Database) {
        self.db = db
    }

    @discardableResult
    func add(path: String, isDir: Bool = false, size: Int64 = 0, modified: Double = 0) throws -> Int64 {
        if let cached = ids[path] { return cached }
        let name = (path as NSString).lastPathComponent
        let parentPath = (path as NSString).deletingLastPathComponent
        let parentID: Int64
        if parentPath == "/" || parentPath.isEmpty {
            parentID = try db.ensureRootRow(path: "/")
        } else {
            parentID = try add(path: parentPath, isDir: true)
        }
        let id = db.nextID()
        try db.insert(rows: [IndexRow(id: id, parent: parentID, name: name, isDir: isDir, size: isDir ? 0 : size, modified: modified)])
        ids[path] = id
        return id
    }

    func id(for path: String) -> Int64? {
        ids[path]
    }
}

final class DatabaseTests: XCTestCase {
    private var tempDir: URL!
    private var tree: TestTree!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("everywhere-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tree = TestTree(db: try makeDatabase())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDatabase() throws -> Database {
        try Database(path: tempDir.appendingPathComponent("index.sqlite").path)
    }

    private var db: Database { tree.db }

    func testBroadSearchesExcludeEmptyRoot() throws {
        try tree.add(path: "/bar.txt")
        for request in [SearchRequest(text: "!foo"), SearchRequest(text: "*"),
                        SearchRequest(text: ".*", useRegex: true),
                        SearchRequest(text: ".*", matchPath: true, useRegex: true)] {
            let result = try db.search(request)
            XCTAssertEqual(result.entries.map(\.name), ["bar.txt"])
            XCTAssertEqual(result.total, 1)
        }
    }

    func testCaseSensitiveWholeWordLimitPreservesTotal() throws {
        for name in ["Alpha one", "Alpha two", "Alpha three", "alpha four"] {
            try tree.add(path: "/" + name)
        }
        let result = try db.search(SearchRequest(text: "Alpha", matchCase: true, wholeWord: true, limit: 1))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.total, 3)
    }

    func testLiteralSearchModesPreservePunctuationAndSubstrings() throws {
        try tree.add(path: "/unit.pas")
        try tree.add(path: "/password.txt")
        try tree.add(path: "/notes.PAS")
        try tree.add(path: "/myreport.txt")
        try tree.add(path: "/.hidden.pas")
        try tree.add(path: "/folder.pas", isDir: true)
        try tree.add(path: "/café.pas")
        for memory in [false, true] {
            let request = SearchRequest(text: ".pas", kind: .files, includeHidden: false)
            XCTAssertEqual(try db.search(request, useMemory: memory).entries.map(\.name).sorted(),
                           ["café.pas", "notes.PAS", "unit.pas"])
            XCTAssertEqual(try db.search(SearchRequest(text: ".pas", matchCase: true), useMemory: memory).total, 4)
            XCTAssertEqual(try db.search(SearchRequest(text: "report"), useMemory: memory).entries.map(\.name), ["myreport.txt"])
            XCTAssertEqual(try db.search(SearchRequest(text: "CAFÉ"), useMemory: memory).entries.map(\.name), ["café.pas"])
            XCTAssertEqual(try db.search(SearchRequest(text: "unit .pas"), useMemory: memory).total, 1)
            XCTAssertEqual(try db.search(SearchRequest(text: ".pas", limit: 1), useMemory: memory).total, 5)
            XCTAssertEqual(try db.search(SearchRequest(text: ".pas", limit: 1), useMemory: memory).entries.count, 1)
        }
    }

    func testMemorySearchRefreshesAfterInsertDeleteAndClear() throws {
        let removed = try tree.add(path: "/old.pas")
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: true).total, 1)
        try tree.add(path: "/new.pas")
        try db.deleteIDs([removed])
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: true).entries.map(\.name), ["new.pas"])
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: false).entries.map(\.name), ["new.pas"])
        try db.clear()
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: true).total, 0)
    }

    func testMemorySearchRefreshesMetadataAndDeletedSubtrees() throws {
        let id = try tree.add(path: "/folder/unit.pas", size: 10)
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: true).entries.first?.size, 10)
        let parent = try XCTUnwrap(tree.id(for: "/folder"))
        try db.insert(rows: [IndexRow(id: id, parent: parent, name: "unit.pas", isDir: false, size: 99, modified: 500)])
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: true).entries.first?.size, 99)
        try db.deleteSubtree(id: parent)
        XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: true).total, 0)
    }

    func testPhraseSearchSurvivesCompactFTSUpdates() throws {
        let first = try tree.add(path: "/annual report.txt")
        try tree.add(path: "/annual revised report.txt")
        let request = SearchRequest(text: "\"annual report\"", wholeWord: true)
        XCTAssertEqual(try db.search(request).entries.map(\.id), [first])
        try db.deleteIDs([first])
        XCTAssertEqual(try db.search(request).total, 0)
        let replacement = try tree.add(path: "/new annual report.txt")
        XCTAssertEqual(try db.search(request).entries.map(\.id), [replacement])
    }

    func testSearchClearThenNewQueryAndCancellationRecovery() throws {
        try tree.add(path: "/first.pas", modified: 100)
        try tree.add(path: "/second.swift", modified: 200)
        for memory in [false, true] {
            XCTAssertEqual(try db.search(SearchRequest(text: ".pas"), useMemory: memory).total, 1)
            let cleared = try db.search(SearchRequest(), useMemory: memory)
            XCTAssertEqual(cleared.entries.map(\.name), ["second.swift", "first.pas"])
            XCTAssertEqual(try db.search(SearchRequest(text: ".swift"), useMemory: memory).entries.map(\.name), ["second.swift"])
            let cancellation = SearchCancellation()
            cancellation.cancel()
            XCTAssertThrowsError(try db.search(SearchRequest(text: ".pas"), useMemory: memory, cancellation: cancellation)) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(try db.search(SearchRequest(text: ".swift"), useMemory: memory).total, 1)
        }
    }

    func testConcurrentSearchesDoNotShareRegexState() throws {
        try tree.add(path: "/alpha.pas")
        try tree.add(path: "/beta.swift")
        let completed = expectation(description: "Concurrent searches")
        completed.expectedFulfillmentCount = 20
        let database = db
        for i in 0..<20 {
            DispatchQueue.global().async {
                defer { completed.fulfill() }
                do {
                    let name = i % 2 == 0 ? "alpha" : "beta"
                    let result = try database.search(SearchRequest(text: "^" + name, useRegex: true))
                    XCTAssertEqual(result.entries.count, 1)
                    XCTAssertTrue(result.entries.first?.name.hasPrefix(name) == true)
                } catch { XCTFail("Search failed: \(error)") }
            }
        }
        wait(for: [completed], timeout: 10)
    }

    func testFastSortParityBoundedOrdersAndIncrementalRefresh() throws {
        try db.beginBulkLoad()
        for number in 0..<1300 {
            try tree.add(path: "/record-\(number).txt", size: Int64(number % 13), modified: Double(number % 17))
        }
        try db.endBulkLoad()
        var expected: [String: [Int64]] = [:]
        for key in [SortKey.name, .size, .modified, .kind] {
            for ascending in [true, false] {
                let request = SearchRequest(text: "record", sortKey: key, ascending: ascending, limit: 73)
                expected[key.rawValue + String(ascending)] = try db.search(request).entries.map(\.id)
            }
        }
        for key in [SortKey.name, .size, .modified, .kind] {
            for ascending in [true, false] {
                let request = SearchRequest(text: "record", sortKey: key, ascending: ascending, limit: 73)
                let result = try db.search(request, useMemory: true)
                XCTAssertEqual(result.entries.map(\.id), expected[key.rawValue + String(ascending)])
                XCTAssertLessThanOrEqual(result.cacheStatistics.sortCount, 3)
                XCTAssertEqual(result.cacheStatistics.fullLoads, 1)
                XCTAssertGreaterThan(result.cacheStatistics.sortBytes, 0)
            }
        }
        let removed = try XCTUnwrap(tree.id(for: "/record-0.txt"))
        let changed = try XCTUnwrap(tree.id(for: "/record-1.txt"))
        let parent = try db.ensureRootRow(path: "/")
        try db.deleteIDs([removed, try XCTUnwrap(tree.id(for: "/record-7.txt"))])
        try db.insert(rows: [IndexRow(id: changed, parent: parent, name: "record-1.txt", isDir: false, size: 9999, modified: 9999)])
        try tree.add(path: "/record-added.txt", size: 10000, modified: 10000)
        let request = SearchRequest(text: "record", sortKey: .modified, ascending: false, limit: 20)
        let refreshed = try db.search(request, useMemory: true)
        XCTAssertEqual(refreshed.cacheStatistics.fullLoads, 1)
        XCTAssertEqual(refreshed.cacheStatistics.incrementalRefreshes, 1)
        XCTAssertEqual(refreshed.cacheStatistics.sortCount, 3)
        XCTAssertEqual(refreshed.entries.map(\.id), try db.search(request).entries.map(\.id))
        XCTAssertEqual(refreshed.total, 1299)
    }

    func testConcurrentWritesAndMemoryRefreshEndWithCurrentResults() throws {
        try tree.add(path: "/initial.txt")
        _ = try db.search(SearchRequest(text: ".txt"), useMemory: true)
        let root = try db.ensureRootRow(path: "/")
        let first = db.allocateIDs(150)
        let database = db
        let completed = expectation(description: "Writer finished")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                for offset in 0..<150 {
                    try database.insert(rows: [IndexRow(id: first + Int64(offset), parent: root, name: "item-\(offset).txt",
                                                        isDir: false, size: Int64(offset), modified: 1)])
                }
                try database.deleteIDs((0..<50).map { first + Int64($0) })
            } catch { XCTFail("Writer failed: \(error)") }
        }
        for _ in 0..<20 {
            let result = try db.search(SearchRequest(text: ".txt"), useMemory: true)
            XCTAssertEqual(result.total, result.entries.count)
            XCTAssertEqual(Set(result.entries.map(\.id)).count, result.total)
        }
        wait(for: [completed], timeout: 10)
        let memory = try db.search(SearchRequest(text: ".txt"), useMemory: true)
        let disk = try db.search(SearchRequest(text: ".txt"))
        XCTAssertEqual(memory.total, 101)
        XCTAssertEqual(memory.entries, disk.entries)
    }

    func testMemoryRefreshHandlesReplacementIDsAndExternalWriters() throws {
        let old = try tree.add(path: "/same.txt")
        let external = try makeDatabase()
        let initial = try db.search(SearchRequest(text: ".txt"), useMemory: true)
        let root = try db.ensureRootRow(path: "/")
        let newID = db.nextID()
        try db.insert(rows: [IndexRow(id: newID, parent: root, name: "same.txt", isDir: false, size: 10, modified: 2)])
        let changed = try db.search(SearchRequest(text: ".txt"), useMemory: true)
        XCTAssertEqual(changed.entries.map(\.id), [newID])
        XCTAssertNotEqual(newID, old)
        XCTAssertEqual(changed.cacheStatistics.fullLoads, initial.cacheStatistics.fullLoads)
        XCTAssertEqual(changed.cacheStatistics.incrementalRefreshes, 1)
        let externalID = db.nextID()
        try external.insert(rows: [IndexRow(id: externalID, parent: root, name: "external.txt", isDir: false, size: 20, modified: 3)])
        try tree.add(path: "/local.txt")
        let mixed = try db.search(SearchRequest(text: ".txt"), useMemory: true)
        XCTAssertEqual(mixed.entries.map(\.name), ["external.txt", "local.txt", "same.txt"])
        XCTAssertEqual(mixed.cacheStatistics.fullLoads, 2)
    }

    func testCachedSortAgreesForUnicodePunctuationAndFilters() throws {
        let names = ["a.txt", "A.txt", "_a.txt", "[a].txt", "á.txt", "Ä.txt", "a-1.txt", "a 2.txt", "a_3.txt", ".hidden.txt"]
        for (i, name) in names.enumerated() {
            try tree.add(path: "/" + name, isDir: i % 3 == 0, size: Int64(i % 2), modified: Double(i % 3))
        }
        for key in [SortKey.name, .size, .modified, .kind] {
            for ascending in [true, false] {
                for kind in [KindFilter.all, .files, .folders] {
                    let request = SearchRequest(text: ".txt", kind: kind, includeHidden: false, sortKey: key, ascending: ascending)
                    let disk = try db.search(request)
                    let memory = try db.search(request, useMemory: true)
                    XCTAssertEqual(memory.entries.map(\.id), disk.entries.map(\.id))
                    XCTAssertEqual(memory.total, disk.total)
                }
            }
        }
    }

    func testInsertAndCount() throws {
        try tree.add(path: "/a.txt", size: 12)
        try tree.add(path: "/b/c.txt", size: 5)
        XCTAssertEqual(try db.count(), 4)
    }

    func testSearchByNamePrefix() throws {
        try tree.add(path: "/Users/mick/readme.md", size: 100)
        try tree.add(path: "/Applications/App Store.app", isDir: true)
        try tree.add(path: "/usr/bin/notepad", size: 5)

        let result = try db.search(SearchRequest(text: "read"))
        XCTAssertEqual(result.entries.map(\.path), ["/Users/mick/readme.md"])
        XCTAssertEqual(result.total, 1)
        XCTAssertGreaterThan(result.elapsedMS, 0)
    }

    func testPathIsNotMatchedByDefault() throws {
        try tree.add(path: "/Users/mick/readme.md")
        let nameOnly = try db.search(SearchRequest(text: "mick"))
        XCTAssertEqual(nameOnly.entries.map(\.path), ["/Users/mick"])

        let withPath = try db.search(SearchRequest(text: "mick", matchPath: true))
        XCTAssertEqual(withPath.entries.map(\.path).sorted(), ["/Users/mick", "/Users/mick/readme.md"])
    }

    func testMatchPathFindsFolderNamesInPath() throws {
        try tree.add(path: "/Volumes/Photos/cam.jpg", size: 2)
        let result = try db.search(SearchRequest(text: "photos", matchPath: true))
        XCTAssertEqual(
            result.entries.map(\.path).sorted(),
            ["/Volumes/Photos", "/Volumes/Photos/cam.jpg"]
        )
    }

    func testRegexMatchesNameByDefault() throws {
        try tree.add(path: "/a/Alpha.txt")
        try tree.add(path: "/a/beta.log")
        try tree.add(path: "/Users/mick/readme.md")

        let result = try db.search(SearchRequest(text: "^alpha.*\\.txt$", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path), ["/a/Alpha.txt"])

        let partial = try db.search(SearchRequest(text: "adme", useRegex: true))
        XCTAssertEqual(partial.entries.map(\.path), ["/Users/mick/readme.md"])

        let nameMatchesDirToo = try db.search(SearchRequest(text: "mick", useRegex: true))
        XCTAssertEqual(nameMatchesDirToo.entries.map(\.path), ["/Users/mick"])
    }

    func testRegexMatchesPathWhenEnabled() throws {
        try tree.add(path: "/Users/mick/readme.md")
        try tree.add(path: "/a/notes.txt")
        let result = try db.search(SearchRequest(text: "^/Users/.*/read.*$", matchPath: true, useRegex: true))
        XCTAssertEqual(result.entries.map(\.path), ["/Users/mick/readme.md"])
    }

    func testInvalidRegexThrows() throws {
        XCTAssertThrowsError(try db.search(SearchRequest(text: "([unclosed", useRegex: true)))
    }

    func testRegexCaseInsensitive() throws {
        try tree.add(path: "/MixedCase.File")
        let result = try db.search(SearchRequest(text: "mixedcase", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path), ["/MixedCase.File"])

        let caseSensitive = try db.search(SearchRequest(text: "mixedcase", useRegex: true, matchCase: true))
        XCTAssertTrue(caseSensitive.entries.isEmpty)

        let insensitiveAgain = try db.search(SearchRequest(text: "mixedcase", useRegex: true))
        XCTAssertEqual(insensitiveAgain.entries.map(\.path), ["/MixedCase.File"])
    }

    func testRegexPrefilterFindsMidTokenLiterals() throws {
        try tree.add(path: "/XalphaY.txt")
        try tree.add(path: "/beta.log")
        let result = try db.search(SearchRequest(text: "alpha", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path), ["/XalphaY.txt"])
    }

    func testRegexAlternationFallsBackToScanAndFindsBoth() throws {
        try tree.add(path: "/cat.jpg")
        try tree.add(path: "/parrot.png")
        try tree.add(path: "/dog.gif")
        let result = try db.search(SearchRequest(text: "cat|parrot", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path).sorted(), ["/cat.jpg", "/parrot.png"])
    }

    func testRegexQuantifiedRunIsTruncatedForPrefilter() throws {
        try tree.add(path: "/fobar.txt")
        try tree.add(path: "/fooooooobar.txt")
        try tree.add(path: "/unrelated.txt")
        let result = try db.search(SearchRequest(text: "fo+b", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path).sorted(), ["/fobar.txt", "/fooooooobar.txt"])
    }

    func testRegexEscapedClassBreaksRunButMatches() throws {
        try tree.add(path: "/invoice-2024.pdf")
        try tree.add(path: "/invoice-1999.pdf")
        let result = try db.search(SearchRequest(text: "invoice-20\\d\\d\\.pdf", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path), ["/invoice-2024.pdf"])
    }

    func testRegexSuffixPattern() throws {
        try tree.add(path: "/photo.png")
        try tree.add(path: "/photo.png.bak")
        let result = try db.search(SearchRequest(text: "\\.png$", useRegex: true))
        XCTAssertEqual(result.entries.map(\.path), ["/photo.png"])
    }

    func testMultipleTokensAreANDed() throws {
        try tree.add(path: "/swift handbook.pdf")
        try tree.add(path: "/swift bird.txt")

        let both = try db.search(SearchRequest(text: "swift hand"))
        XCTAssertEqual(both.entries.map(\.path), ["/swift handbook.pdf"])
        let none = try db.search(SearchRequest(text: "swift missing"))
        XCTAssertTrue(none.entries.isEmpty)
        XCTAssertEqual(none.total, 0)
    }

    func testHiddenFilter() throws {
        try tree.add(path: "/Users/.hidden")
        try tree.add(path: "/Users/visible")

        let includingHidden = try db.search(SearchRequest(text: "", includeHidden: true))
        XCTAssertTrue(includingHidden.entries.contains { $0.name == ".hidden" })
        let excludingHidden = try db.search(SearchRequest(text: "", includeHidden: false))
        XCTAssertFalse(excludingHidden.entries.contains { $0.name == ".hidden" })
        XCTAssertTrue(excludingHidden.entries.contains { $0.name == "visible" })
    }

    func testKindFilter() throws {
        try tree.add(path: "/Users", isDir: true)
        try tree.add(path: "/Users/notes.txt", size: 3)

        let folders = try db.search(SearchRequest(text: "notes", kind: .folders))
        XCTAssertTrue(folders.entries.isEmpty)
        let files = try db.search(SearchRequest(text: "notes", kind: .files))
        XCTAssertEqual(files.entries.map(\.path), ["/Users/notes.txt"])
    }

    func testSortByNameCaseInsensitive() throws {
        try tree.add(path: "/zebra.txt")
        try tree.add(path: "/Apple.txt")
        try tree.add(path: "/banana.txt")

        let ascending = try db.search(SearchRequest(text: "txt", sortKey: .name, ascending: true))
        XCTAssertEqual(ascending.entries.map(\.name), ["Apple.txt", "banana.txt", "zebra.txt"])
        let descending = try db.search(SearchRequest(text: "txt", sortKey: .name, ascending: false))
        XCTAssertEqual(descending.entries.map(\.name), ["zebra.txt", "banana.txt", "Apple.txt"])
    }

    func testSortBySize() throws {
        try tree.add(path: "/small.txt", size: 1)
        try tree.add(path: "/large.txt", size: 900)
        try tree.add(path: "/mid.txt", size: 50)

        let ascending = try db.search(SearchRequest(text: "txt", sortKey: .size, ascending: true))
        XCTAssertEqual(ascending.entries.map(\.name), ["small.txt", "mid.txt", "large.txt"])
    }

    func testUpsertOnConflict() throws {
        let id = try tree.add(path: "/file.txt", size: 1)
        try db.insert(rows: [IndexRow(id: id + 500, parent: try db.ensureRootRow(path: "/"), name: "file.txt", isDir: false, size: 42, modified: 0)])
        XCTAssertEqual(try db.count(), 2)
        let result = try db.search(SearchRequest(text: "file"))
        XCTAssertEqual(result.entries.first?.size, 42)
    }

    func testDeleteSubtree() throws {
        try tree.add(path: "/root/a.txt")
        try tree.add(path: "/root/sub/deep.txt")
        try tree.add(path: "/other.txt")

        let rootID = try XCTUnwrap(tree.id(for: "/root"))
        try db.deleteSubtree(id: rootID)

        let remaining = try db.search(SearchRequest(text: "", limit: 100))
        XCTAssertEqual(remaining.entries.map(\.name), ["other.txt"])
    }

    func testDeleteIDs() throws {
        try tree.add(path: "/a")
        try tree.add(path: "/b")
        try tree.add(path: "/c")

        try db.deleteIDs([tree.id(for: "/a")!, tree.id(for: "/c")!, 999_999])
        let remaining = try db.search(SearchRequest(text: "", limit: 100))
        XCTAssertEqual(remaining.entries.map(\.name), ["b"])
    }

    func testChildrenReturnsDepthOneOnly() throws {
        try tree.add(path: "/root/a/deep", isDir: true)
        try tree.add(path: "/root/b.txt")

        let children = try db.children(ofParent: tree.id(for: "/root")!)
        XCTAssertEqual(Set(children.map(\.name)), ["a", "b.txt"])
    }

    func testEmptyQueryListsAll() throws {
        for i in 0..<100 {
            try tree.add(path: "/dir/file\(i).txt")
        }
        let result = try db.search(SearchRequest(text: "", limit: 10_000))
        XCTAssertEqual(result.total, 102)
        XCTAssertEqual(result.entries.count, 101)
    }

    func testQuoteInNameDoesNotThrow() throws {
        try tree.add(path: "/weird\"name.txt")
        let result = try db.search(SearchRequest(text: "weird"))
        XCTAssertEqual(result.entries.map(\.path), ["/weird\"name.txt"])
    }

    func testMaterializesDeepPaths() throws {
        try tree.add(path: "/a/b/c/deeply-nested.txt", size: 7)
        let result = try db.search(SearchRequest(text: "deeply"))
        XCTAssertEqual(result.entries.map(\.path), ["/a/b/c/deeply-nested.txt"])
        XCTAssertEqual(result.entries.first?.size, 7)
    }

    func testCustomRootMaterializesCorrectPaths() throws {
        let customRootID = try db.ensureRootRow(path: "/Users/mick")
        let childID = db.nextID()
        try db.insert(rows: [IndexRow(id: childID, parent: customRootID, name: "Documents", isDir: true, size: 0, modified: 0)])
        let fileID = db.nextID()
        try db.insert(rows: [IndexRow(id: fileID, parent: childID, name: "resume.pdf", isDir: false, size: 9, modified: 0)])

        let result = try db.search(SearchRequest(text: "resume"))
        XCTAssertEqual(result.entries.map(\.path), ["/Users/mick/Documents/resume.pdf"])
    }

    func testWildcardSuffixOnName() throws {
        try tree.add(path: "/report.pdf", size: 1)
        try tree.add(path: "/report.txt", size: 2)

        let pdfs = try db.search(SearchRequest(text: "*.pdf"))
        XCTAssertEqual(pdfs.entries.map(\.path), ["/report.pdf"])

        let allReports = try db.search(SearchRequest(text: "report.*"))
        XCTAssertEqual(allReports.entries.count, 2)
    }

    func testWildcardQuestionMark() throws {
        try tree.add(path: "/file1.txt")
        try tree.add(path: "/file12.txt")

        let result = try db.search(SearchRequest(text: "file?.txt"))
        XCTAssertEqual(result.entries.map(\.path), ["/file1.txt"])
    }

    func testPathTermMatchesFullPath() throws {
        try tree.add(path: "/Users/mick/Downloads/invoice.pdf")
        try tree.add(path: "/Screenshots/photo.png")

        let slashTerm = try db.search(SearchRequest(text: "/downloads invoice"))
        XCTAssertEqual(slashTerm.entries.map(\.path), ["/Users/mick/Downloads/invoice.pdf"])

        let nameOnly = try db.search(SearchRequest(text: "invoice"))
        XCTAssertEqual(nameOnly.entries.map(\.path), ["/Users/mick/Downloads/invoice.pdf"])
    }

    func testTrailingSlashMeansPathPrefix() throws {
        try tree.add(path: "/Users/mick/Downloads/invoice.pdf")
        try tree.add(path: "/Users/mick/Downloads2/invoice.pdf")

        let insideFolder = try db.search(SearchRequest(text: "/users/mick/downloads/ invoice"))
        XCTAssertEqual(insideFolder.entries.map(\.path), ["/Users/mick/Downloads/invoice.pdf"])
    }

    func testVerticalBarAlternatives() throws {
        try tree.add(path: "/alpha.txt")
        try tree.add(path: "/beta.log")

        let either = try db.search(SearchRequest(text: "alpha | beta"))
        XCTAssertEqual(either.entries.count, 2)
        let neither = try db.search(SearchRequest(text: "alpha | gamma"))
        XCTAssertEqual(neither.entries.map(\.path), ["/alpha.txt"])
    }

    func testNegationExcludes() throws {
        try tree.add(path: "/Alpha.txt")
        try tree.add(path: "/alphabet.log")

        let result = try db.search(SearchRequest(text: "alpha !log"))
        XCTAssertEqual(result.entries.map(\.path), ["/Alpha.txt"])
    }

    func testQuotedPhraseMatchesAdjacentWords() throws {
        try tree.add(path: "/swift handbook.pdf")
        try tree.add(path: "/swift-bird.txt")

        let phrase = try db.search(SearchRequest(text: "\"swift handbook\""))
        XCTAssertEqual(phrase.entries.map(\.path), ["/swift handbook.pdf"])
    }

    func testMatchCaseForcesScan() throws {
        try tree.add(path: "/Alpha.txt")
        try tree.add(path: "/lowercase-alpha.txt")

        let sensitive = try db.search(SearchRequest(text: "alpha", matchCase: true))
        XCTAssertEqual(sensitive.entries.map(\.path), ["/lowercase-alpha.txt"])

        let upper = try db.search(SearchRequest(text: "Alpha", matchCase: true))
        XCTAssertEqual(upper.entries.map(\.path), ["/Alpha.txt"])
    }

    func testMatchCaseFiltersCase() throws {
        try tree.add(path: "/WIFISettings.plist")
        try tree.add(path: "/wifi-notes.txt")
        try tree.add(path: "/WifiScanner.app", isDir: true)

        let upper = try db.search(SearchRequest(text: "WIFI", matchCase: true))
        XCTAssertEqual(upper.entries.map(\.path), ["/WIFISettings.plist"])
        XCTAssertEqual(upper.total, 1)

        let insensitive = try db.search(SearchRequest(text: "wifi"))
        XCTAssertEqual(insensitive.entries.count, 3)
    }

    func testMatchCaseWithWholeWords() throws {
        try tree.add(path: "/WIFI Router.app", isDir: true)
        try tree.add(path: "/WIFIRouter.app", isDir: true)

        let result = try db.search(SearchRequest(text: "WIFI", matchCase: true, wholeWord: true))
        XCTAssertEqual(result.entries.map(\.path), ["/WIFI Router.app"])
    }

    func testWholeWordMatchesExactTokenOnly() throws {
        try tree.add(path: "/man.txt")
        try tree.add(path: "/manager.txt")

        let whole = try db.search(SearchRequest(text: "man", wholeWord: true))
        XCTAssertEqual(whole.entries.map(\.path), ["/man.txt"])

        let partial = try db.search(SearchRequest(text: "man", wholeWord: false))
        XCTAssertEqual(partial.entries.count, 2)
    }
}
