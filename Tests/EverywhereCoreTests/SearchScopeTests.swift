import XCTest
@testable import EverywhereCore

final class SearchScopeTests: XCTestCase {
    func testLocationUnionIntersectsSavedAndTypedBooleanExpressions() throws {
        try fixture { database, tree in
            try tree.add(path: "/NAS/report.pdf", size: 2_000, modified: 2)
            try tree.add(path: "/NAS/nested/invoice.txt", size: 5_000, modified: 5)
            try tree.add(path: "/Work/invoice.PDF", size: 3_000, modified: 3)
            try tree.add(path: "/Work/draft.pdf", size: 4_000, modified: 4)
            try tree.add(path: "/NAS-old/report.pdf", size: 1_000)
            try tree.add(path: "/Other/invoice.pdf", size: 6_000)
            let scope = SearchScope(name: "Documents", folders: ["/NAS", "/NAS/nested", "/Work"], expression: "ext:pdf !draft | ext:txt size:>4KB")
            for memory in [false, true] {
                let request = SearchRequest(text: "report | invoice", scope: scope)
                let result = try database.search(request, useMemory: memory)
                XCTAssertEqual(result.entries.map(\.path).sorted(), ["/NAS/nested/invoice.txt", "/NAS/report.pdf", "/Work/invoice.PDF"])
                XCTAssertEqual(result.total, 3)
                let outside = try database.search(SearchRequest(text: "in:/Other | in:/NAS-old", scope: scope), useMemory: memory)
                XCTAssertEqual(outside.total, 0)
                let page = try database.search(SearchRequest(text: "report | invoice", limit: 1, offset: 1, scope: scope), useMemory: memory)
                XCTAssertEqual(page.total, 3)
                XCTAssertEqual(page.entries, [result.entries[1]])
            }
        }
    }

    func testSavedOnlyScopesPreserveRegexPathWordsAndLiteralPunctuation() throws {
        try fixture { database, tree in
            try tree.add(path: "/Docs/annual report.PDF")
            try tree.add(path: "/Docs/myreport.pdf")
            try tree.add(path: "/Docs/annual-report.txt")
            try tree.add(path: "/Elsewhere/annual report.PDF")
            let scope = SearchScope(name: "PDFs", folders: ["/Docs"], expression: "ext:pdf")
            for memory in [false, true] {
                let cases: [(SearchRequest, [String])] = [
                    (SearchRequest(text: "annual.*\\.PDF$", useRegex: true, scope: scope), ["/Docs/annual report.PDF"]),
                    (SearchRequest(text: "^/Docs/annual", matchPath: true, useRegex: true, scope: scope), ["/Docs/annual report.PDF"]),
                    (SearchRequest(text: "report", wholeWord: true, scope: scope), ["/Docs/annual report.PDF"]),
                    (SearchRequest(text: ".PDF", matchCase: true, scope: scope), ["/Docs/annual report.PDF"]),
                    (SearchRequest(text: "*.pdf !myreport", scope: scope), ["/Docs/annual report.PDF"]),
                    (SearchRequest(text: "/Docs/annual", scope: scope), ["/Docs/annual report.PDF"])
                ]
                for (request, expected) in cases {
                    XCTAssertEqual(try database.search(request, useMemory: memory).entries.map(\.path), expected, request.text)
                }
                XCTAssertThrowsError(try database.search(SearchRequest(text: "[", useRegex: true, scope: scope), useMemory: memory))
            }
        }
    }

    func testEmptyScopesRecentOrderingHiddenKindAndMissingLocations() throws {
        try fixture { database, tree in
            try tree.add(path: "/Docs/older.pdf", modified: 1)
            try tree.add(path: "/Docs/.newer.pdf", modified: 3)
            try tree.add(path: "/Docs/folder.pdf", isDir: true, modified: 2)
            try tree.add(path: "/Other/newest.pdf", modified: 4)
            let scope = SearchScope(name: "Docs", folders: ["/Docs"])
            for memory in [false, true] {
                let recent = try database.search(SearchRequest(scope: scope), useMemory: memory)
                XCTAssertEqual(recent.entries.map(\.name), [".newer.pdf", "folder.pdf", "older.pdf"])
                XCTAssertEqual(try database.search(SearchRequest(kind: .files, includeHidden: false, scope: scope), useMemory: memory).entries.map(\.name), ["older.pdf"])
                XCTAssertEqual(try database.search(SearchRequest(scope: SearchScope(name: "Missing", folders: ["/Missing"])), useMemory: memory).total, 0)
                let all = try database.search(SearchRequest(), useMemory: memory)
                let unrestricted = try database.search(SearchRequest(scope: SearchScope(name: "Unrestricted")), useMemory: memory)
                XCTAssertEqual(all.entries, unrestricted.entries)
            }
        }
    }

    func testSavedScopeWithoutFoldersUpdatesAndSortsLikeUnscopedSearch() throws {
        try fixture { database, tree in
            try tree.add(path: "/Docs/beta.pdf", size: 2)
            try tree.add(path: "/Work/alpha.PDF", size: 1)
            let scope = SearchScope(name: "PDFs", expression: "ext:pdf !draft")
            for memory in [false, true] {
                for key in SortKey.allCases {
                    for ascending in [false, true] {
                        let scoped = try database.search(SearchRequest(text: "*", sortKey: key, ascending: ascending, scope: scope), useMemory: memory)
                        let expanded = try database.search(SearchRequest(text: "ext:pdf !draft *", sortKey: key, ascending: ascending), useMemory: memory)
                        XCTAssertEqual(scoped.entries, expanded.entries)
                        XCTAssertEqual(scoped.total, expanded.total)
                    }
                }
            }
            try tree.add(path: "/Docs/gamma.pdf")
            XCTAssertEqual(try database.search(SearchRequest(text: "gamma", scope: scope), useMemory: true).total, 1)
            XCTAssertEqual(try database.search(SearchRequest(text: "alpha", scope: SearchScope(name: "Text", expression: "ext:txt")), useMemory: true).total, 0)
        }
    }

    func testScopeQuotedExpressionsAndNestedIndexRoots() throws {
        try fixture { database, _ in
            let tree = TestTree(db: database, rootPath: "/Volumes/Offline/Documents")
            try tree.add(path: "/Volumes/Offline/Documents/ext:pdf.txt")
            try tree.add(path: "/Volumes/Offline/Documents/other.txt")
            for memory in [false, true] {
                let scope = SearchScope(name: "Offline", folders: ["/Volumes/Offline"], expression: "\"ext:pdf\"")
                let result = try database.search(SearchRequest(text: "txt", scope: scope), useMemory: memory)
                XCTAssertEqual(result.entries.map(\.name), ["ext:pdf.txt"])
            }
        }
    }

    func testEmptyLocationScopeUsesRecentOrderingIncludingTiesAndPages() throws {
        try fixture { database, tree in
            for index in 0..<24 {
                try tree.add(path: "/Docs/\(24 - index).txt", size: Int64(index), modified: Double(index / 4))
            }
            try tree.add(path: "/Docs/.hidden", modified: 50)
            let scope = SearchScope(name: "Entire Index", folders: ["/"])
            for memory in [false, true] {
                for offset in [0, 5, 20] {
                    let all = try database.search(SearchRequest(kind: .files, includeHidden: false, limit: 5, offset: offset), useMemory: memory)
                    let scoped = try database.search(SearchRequest(kind: .files, includeHidden: false, limit: 5, offset: offset, scope: scope), useMemory: memory)
                    XCTAssertEqual(scoped.entries, all.entries)
                    XCTAssertEqual(scoped.total, all.total)
                }
                let filtered = SearchScope(name: "Large files", folders: ["/Docs"], expression: "size:>=10")
                let result = try database.search(SearchRequest(scope: filtered), useMemory: memory)
                XCTAssertEqual(result.total, 14)
                XCTAssertEqual(result.entries.map(\.id), result.entries.map(\.id).sorted(by: >))
            }
        }
    }

    func testScopedSQLLiteralPrefilterPreservesPunctuationAndUnicode() throws {
        try fixture { database, tree in
            let names = ["100%_done\\\\path'quote.txt", "100xxdone-path.txt", "Kelvin.txt", "ſample.txt", "work_report.pdf"]
            for name in names { try tree.add(path: "/Docs/" + name) }
            let scope = SearchScope(name: "Text", folders: ["/Docs"])
            for text in ["100%_done", "\\\\path'quote", "kelvin", "sample", "work_report"] {
                for matchCase in [false, true] {
                    let ordinary = try database.search(SearchRequest(text: text, kind: .files, matchCase: matchCase), useMemory: false)
                    for memory in [false, true] {
                        let scoped = try database.search(SearchRequest(text: text, kind: .files, matchCase: matchCase, scope: scope), useMemory: memory)
                        XCTAssertEqual(scoped.entries, ordinary.entries, text)
                        XCTAssertEqual(scoped.total, ordinary.total)
                    }
                }
            }
        }
    }

    func testInvalidScopeExpressionsAndExcessiveCombinationsFailClearly() throws {
        try fixture { database, _ in
            XCTAssertThrowsError(try database.search(SearchRequest(scope: SearchScope(name: "Bad", expression: "size:invalid"))))
            let alternatives = Array(repeating: "ext:pdf", count: 17).joined(separator: " | ")
            XCTAssertThrowsError(try database.search(SearchRequest(text: alternatives, scope: SearchScope(name: "Many", expression: alternatives))))
            let cancellation = SearchCancellation()
            cancellation.cancel()
            XCTAssertThrowsError(try database.search(SearchRequest(scope: SearchScope(name: "PDF", expression: "ext:pdf")), cancellation: cancellation))
        }
    }

    private func fixture(_ body: (Database, TestTree) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-scopes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try body(database, TestTree(db: database))
    }
}

final class SearchScopeSettingsTests: XCTestCase {
    func testPersistenceEditingPinningDefaultAndDeletion() throws {
        let name = "everywhere-scope-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchScopeSettings(defaults: defaults)
        var work = SearchScope(name: " Work ", folders: ["~/Projects/", "~/Projects"], expression: " ext:pdf ")
        try store.save(work)
        XCTAssertEqual(store.scopes[0].name, "Work")
        XCTAssertEqual(store.scopes[0].folders.count, 1)
        XCTAssertEqual(store.scopes[0].expression, "ext:pdf")
        let pinned = SearchScope(name: "Zoo", expression: "type:video", isPinned: true)
        try store.save(pinned)
        XCTAssertEqual(store.orderedScopes.first?.id, pinned.id)
        store.defaultScopeID = work.id
        let reloaded = SearchScopeSettings(defaults: defaults)
        XCTAssertEqual(reloaded.scopes, store.scopes)
        XCTAssertEqual(reloaded.defaultScopeID, work.id)
        work.name = "Renamed"
        try store.save(work)
        XCTAssertEqual(store.scopes.count, 2)
        XCTAssertEqual(store.defaultScopeID, work.id)
        store.delete(id: work.id)
        XCTAssertNil(store.defaultScopeID)
        XCTAssertEqual(SearchScopeSettings(defaults: defaults).scopes, [pinned])
    }

    func testMovedVolumeFoldersFollowStableLocationWithoutRewritingExpressions() throws {
        let name = "everywhere-scope-mounts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchScopeSettings(defaults: defaults)
        let scope = SearchScope(name: "NAS", folders: ["/Volumes/NAS", "/Volumes/NAS/Docs", "/Volumes/NAS/Nested/Work", "/Volumes/NAS-other", "/Volumes/NewNAS/Docs"], expression: "in:/Volumes/NAS ext:pdf", isPinned: true)
        try store.save(scope)
        store.defaultScopeID = scope.id
        store.relocateFolders(using: ["/Volumes/NAS": "/Volumes/NewNAS", "/Volumes/NAS/Nested": "/Volumes/NestedMoved"])
        let moved = try XCTUnwrap(store.scopes.first)
        XCTAssertEqual(moved.id, scope.id)
        XCTAssertEqual(moved.name, scope.name)
        XCTAssertEqual(moved.expression, scope.expression)
        XCTAssertEqual(moved.isPinned, scope.isPinned)
        XCTAssertEqual(moved.folders, ["/Volumes/NAS-other", "/Volumes/NestedMoved/Work", "/Volumes/NewNAS", "/Volumes/NewNAS/Docs"])
        XCTAssertEqual(store.defaultScopeID, scope.id)
        XCTAssertEqual(SearchScopeSettings(defaults: defaults).scopes, [moved])
        store.relocateFolders(using: ["relative": "/Ignored", "/Volumes/NewNAS": "relative"])
        XCTAssertEqual(store.scopes, [moved])
    }

    func testValidationRejectsAmbiguousNamesInvalidFoldersAndFilters() throws {
        let name = "everywhere-scope-validation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchScopeSettings(defaults: defaults)
        for scope in [SearchScope(name: " "), SearchScope(name: "ALL"), SearchScope(name: "Bad", folders: ["relative"]), SearchScope(name: "Bad", expression: "ext:")] {
            XCTAssertThrowsError(try store.save(scope))
        }
        let excessive = Array(repeating: "ext:pdf", count: 257).joined(separator: " | ")
        XCTAssertThrowsError(try store.save(SearchScope(name: "Too many alternatives", expression: excessive)))
        try store.save(SearchScope(name: "Work"))
        XCTAssertThrowsError(try store.save(SearchScope(name: "work")))
        defaults.set(UUID().uuidString, forKey: "DefaultSearchScope")
        XCTAssertNil(SearchScopeSettings(defaults: defaults).defaultScopeID)
        defaults.set(Data("broken".utf8), forKey: "SearchScopes")
        XCTAssertTrue(SearchScopeSettings(defaults: defaults).scopes.isEmpty)
    }
}
