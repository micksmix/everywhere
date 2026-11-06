import SQLite3
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

    func testScopedSearchUsesOneMemoryCacheAcrossLocationAndQueryChanges() throws {
        try fixture { database, tree in
            let homeReport = try tree.add(path: "/Home/report.txt")
            let nasReport = try tree.add(path: "/Volumes/Offline/report.txt")
            try tree.add(path: "/Home/review.txt")
            let home = SearchScope(name: "Home", folders: ["/Home"])
            let nas = SearchScope(name: "Offline", folders: ["/Volumes/Offline"])
            let requests = [
                SearchRequest(text: "report", scope: home),
                SearchRequest(text: "report", scope: nas),
                SearchRequest(text: "rep", scope: home),
                SearchRequest(text: "report", scope: home),
                SearchRequest(text: "report"),
                SearchRequest(text: "re", scope: home)
            ]
            let expected = [[homeReport], [nasReport], [homeReport], [homeReport], [homeReport, nasReport]]
            for (index, request) in requests.enumerated() {
                let result = try database.search(request, useMemory: true)
                XCTAssertTrue(database.isMemoryIndexLoaded)
                XCTAssertEqual(result.cacheStatistics.fullLoads, 1)
                if index < expected.count { XCTAssertEqual(Set(result.entries.map(\.id)), Set(expected[index])) }
                else { XCTAssertEqual(result.total, 2) }
            }
            _ = try database.search(SearchRequest(text: "report", scope: home))
            XCTAssertFalse(database.isMemoryIndexLoaded)
        }
    }

    func testScopedMemoryParityForCorrelatedORFiltersSortingAndPages() throws {
        try fixture { database, tree in
            for directory in ["/Home", "/Home/Sub", "/Home-other", "/Volumes/Offline"] {
                for (index, name) in ["report.txt", "report.pdf", "report-final.txt", ".report.txt", "Kelvin.txt", "ſample.txt", "notes.txt"].enumerated() {
                    try tree.add(path: directory + "/" + name, size: Int64(index * 20), modified: Double(index / 2))
                }
            }
            let scopes = [
                SearchScope(name: "Home", folders: ["/Home"]),
                SearchScope(name: "Union", folders: ["/Home", "/Home/Sub", "/Volumes/Offline"]),
                SearchScope(name: "Missing", folders: ["/Missing"]),
                SearchScope(name: "Correlated", folders: ["/Home", "/Volumes/Offline"],
                            expression: "parent:/Home report ext:txt | in:/Volumes/Offline notes size:>=100"),
                SearchScope(name: "Excluded", folders: ["/Home"], expression: "!in:/Home/Sub")
            ]
            let searches: [(String, Bool, Bool)] = [
                ("report", false, false), ("report !final | notes", false, false),
                ("ext:txt report | ext:pdf final", false, false), ("r*txt", false, false),
                ("report", false, true), ("kelvin | sample", false, false),
                ("report.*\\.txt$", true, false), ("report|notes", true, false), ("", false, false)
            ]
            for scope in scopes {
                for (text, regex, wholeWord) in searches {
                    for key in [SortKey.name, .path, .size, .modified, .kind] {
                        for ascending in [true, false] {
                            for offset in [0, 3] {
                                let request = SearchRequest(text: text, includeHidden: false, useRegex: regex, wholeWord: wholeWord,
                                                            sortKey: key, ascending: ascending, limit: 3, offset: offset, scope: scope)
                                let disk = try database.search(request)
                                let memory = try database.search(request, useMemory: true)
                                XCTAssertEqual(memory.entries, disk.entries, "\(scope.name): \(text) \(key) \(offset)")
                                XCTAssertEqual(memory.total, disk.total)
                                let warm = try database.search(request, useMemory: true)
                                XCTAssertEqual(warm.entries, disk.entries)
                                XCTAssertEqual(warm.total, disk.total)
                            }
                        }
                    }
                }
            }
        }
    }

    func testScopedMemoryInvalidatesFolderMembershipForLocalAndExternalChanges() throws {
        try fixture { database, tree in
            let home = SearchScope(name: "Home", folders: ["/Home"])
            let report = try tree.add(path: "/Home/Sub/report.txt")
            let homeID = try tree.add(path: "/Home", isDir: true)
            let subID = try tree.add(path: "/Home/Sub", isDir: true)
            let outsideID = try tree.add(path: "/Outside", isDir: true)
            let request = SearchRequest(text: "report", scope: home)
            let initial = try database.search(request, useMemory: true)
            XCTAssertEqual(initial.entries.map(\.id), [report])
            XCTAssertEqual(initial.cacheStatistics.fullLoads, 1)
            try database.deleteIDs([subID])
            try database.insert(rows: [IndexRow(id: subID, parent: outsideID, name: "Sub", isDir: true, size: 0, modified: 2)])
            let moved = try database.search(request, useMemory: true)
            XCTAssertEqual(moved.total, 0)
            XCTAssertEqual(moved.cacheStatistics.fullLoads, 1)
            XCTAssertGreaterThan(moved.cacheStatistics.incrementalRefreshes, 0)
            let external = try Database(path: database.path)
            try external.deleteIDs([subID])
            try external.insert(rows: [IndexRow(id: subID, parent: homeID, name: "Sub", isDir: true, size: 0, modified: 3)])
            let returned = try database.search(request, useMemory: true)
            XCTAssertEqual(returned.entries.map(\.id), [report])
            XCTAssertEqual(returned.cacheStatistics.fullLoads, 2)
            try database.deleteSubtree(id: subID)
            XCTAssertEqual(try database.search(request, useMemory: true).total, 0)
            let replacement = try tree.add(path: "/Home/New/report.txt")
            XCTAssertEqual(try database.search(request, useMemory: true).entries.map(\.id), [replacement])
        }
    }

    func testScopedRegexOptionalGroupsNeverRequireOptionalLiteralRuns() throws {
        try fixture { database, tree in
            for name in ["x", "report-x", "projectx", "projectreport-x"] { try tree.add(path: "/Docs/" + name) }
            try tree.add(path: "/Other/x")
            let scope = SearchScope(name: "Docs", folders: ["/Docs"])
            let patterns = ["^(report.*)?x$", "^(report.*)*x$", "^(report.*){0,2}x$", "^((report.*)tail)?x$", "^project(report.*)?x$"]
            for pattern in patterns {
                for selectedScope in [scope, nil] {
                    let request = SearchRequest(text: pattern, kind: .files, useRegex: true, scope: selectedScope)
                    let result = try database.search(request, useMemory: true)
                    let expected = pattern.contains("project") ? ["/Docs/projectx", "/Docs/projectreport-x"]
                        : pattern.contains("tail") ? ["/Docs/x"] : ["/Docs/x", "/Docs/report-x"]
                    XCTAssertEqual(Set(result.entries.map(\.path)), Set(expected + (selectedScope == nil && !pattern.contains("project") ? ["/Other/x"] : [])), pattern)
                    XCTAssertEqual(result.total, result.entries.count)
                }
            }
        }
    }

    func testWarmScopedQueriesKeepCorrelatedFiltersAndNarrowerCandidates() throws {
        try fixture { database, tree in
            for directory in ["/Docs", "/Docs/Excluded", "/Docs/Archive", "/Docs/Private", "/Outside"] {
                for name in ["report.txt", "report.pdf", "review.txt", ".report.txt"] { try tree.add(path: directory + "/" + name) }
            }
            let scope = SearchScope(name: "Docs", folders: ["/Docs"],
                                    expression: "!in:/Docs/Excluded !in:/Docs/Archive !in:/Docs/Private ext:txt | !in:/Docs/Excluded !in:/Docs/Archive !in:/Docs/Private ext:pdf")
            let requests = [
                SearchRequest(text: "re", includeHidden: false, scope: scope),
                SearchRequest(text: "report", includeHidden: false, scope: scope),
                SearchRequest(text: "report", includeHidden: false, ascending: false, scope: scope),
                SearchRequest(text: "re", includeHidden: false, limit: 1, offset: 1, scope: scope),
                SearchRequest(text: "report ext:pdf", includeHidden: false, scope: scope),
                SearchRequest(text: "report", kind: .folders, includeHidden: false, scope: scope),
                SearchRequest(text: "report", includeHidden: true, scope: scope)
            ]
            let expected = try requests.map { try database.search($0) }
            for _ in 0..<2 {
                for (request, disk) in zip(requests, expected) {
                    let memory = try database.search(request, useMemory: true)
                    XCTAssertEqual(memory.entries, disk.entries)
                    XCTAssertEqual(memory.total, disk.total)
                    XCTAssertEqual(memory.cacheStatistics.fullLoads, 1)
                }
            }
        }
    }

    func testSharedNameGroupsDoNotReuseDifferentlyCorrelatedCandidates() throws {
        try fixture { database, tree in
            for name in ["alpha", "beta"] {
                for ext in ["txt", "pdf", "log"] { try tree.add(path: "/Docs/" + name + "." + ext) }
            }
            let requests = [
                SearchRequest(text: "alpha ext:txt | beta ext:pdf | alpha ext:log"),
                SearchRequest(text: "alpha ext:txt | alpha ext:pdf | beta ext:log")
            ]
            let expected = try requests.map { try database.search($0) }
            for (request, disk) in zip(requests, expected) {
                let memory = try database.search(request, useMemory: true)
                XCTAssertEqual(memory.entries, disk.entries)
                XCTAssertEqual(memory.total, disk.total)
            }
        }
    }

    func testFolderScopeCacheEvictsAndDoesNotPublishCancelledLoads() throws {
        try fixture { database, tree in
            try tree.add(path: "/Docs/report.txt")
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            let handle = try XCTUnwrap(connection)
            defer { sqlite3_close(handle) }
            let index = try FilenameIndex(connection: handle, step: sqlite3_step)
            var loads = 0
            func scope(_ name: String, cancellation: SearchCancellation? = nil) throws -> FolderScope {
                try index.folderScope(for: FolderScope.Key(paths: [name], recursive: true, matchCase: false), cancellation: cancellation) {
                    loads += 1
                    cancellation?.cancel()
                    return FolderScope(parents: [1], included: [])
                }
            }
            for name in ["A", "B", "C", "A", "D", "B"] { _ = try scope(name) }
            XCTAssertEqual(loads, 5)
            let token = SearchCancellation()
            XCTAssertThrowsError(try scope("E", cancellation: token))
            XCTAssertEqual(loads, 6)
            _ = try scope("E")
            _ = try scope("E")
            XCTAssertEqual(loads, 7)
            let missing = SearchScope(name: "Missing", folders: ["/New"])
            let request = SearchRequest(text: "report", scope: missing)
            XCTAssertEqual(try database.search(request, useMemory: true).total, 0)
            let report = try tree.add(path: "/New/report.txt")
            XCTAssertEqual(try database.search(request, useMemory: true).entries.map(\.id), [report])
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
