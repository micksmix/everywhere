import XCTest
@testable import EverywhereCore

final class IndexedRootSynchronizationTests: XCTestCase {
    func testNarrowingRootPromotesDescendantAndRemovesObsoleteSiblings() throws {
        try fixture { database in
            let tree = TestTree(db: database, rootPath: "/base")
            let kept = try tree.add(path: "/base/keep/x.txt")
            let directory = try XCTUnwrap(tree.id(for: "/base/keep"))
            try tree.add(path: "/base/other/y.txt")
            _ = try database.search(SearchRequest(text: "*"), useMemory: true)
            try database.synchronizeIndexedRoots(roots: ["/base/keep"], previousRoots: ["/base"])
            try assertFiles(["/base/keep/x.txt": kept], in: database)
            XCTAssertEqual(try database.child(ofParent: 0, name: "/base/keep")?.id, directory)
            XCTAssertNil(try database.child(ofParent: 0, name: "/base"))
        }
    }

    func testNarrowingToSeveralDescendantsPreservesAllTheirIDs() throws {
        try fixture { database in
            let tree = TestTree(db: database, rootPath: "/base")
            let first = try tree.add(path: "/base/one/a.txt")
            let second = try tree.add(path: "/base/two/b.txt")
            try tree.add(path: "/base/three/c.txt")
            try database.synchronizeIndexedRoots(roots: ["/base/two", "/base/one/", "/base/one"], previousRoots: ["/base"])
            try assertFiles(["/base/one/a.txt": first, "/base/two/b.txt": second], in: database)
        }
    }

    func testBroadeningAttachesExistingRootWithoutChangingDescendantIDs() throws {
        try fixture { database in
            let tree = TestTree(db: database, rootPath: "/base/keep")
            let kept = try tree.add(path: "/base/keep/deep/x.txt")
            let root = try database.ensureRootRow(path: "/base/keep")
            try database.synchronizeIndexedRoots(roots: ["/base"], previousRoots: ["/base/keep"])
            try assertFiles(["/base/keep/deep/x.txt": kept], in: database)
            let parent = try XCTUnwrap(database.child(ofParent: 0, name: "/base"))
            XCTAssertEqual(try database.child(ofParent: parent.id, name: "keep")?.id, root)
            XCTAssertNil(try database.child(ofParent: 0, name: "/base/keep"))
        }
    }

    func testOverlappingTreesMergeUniqueFilesAndKeepStandaloneRootIDs() throws {
        try fixture { database in
            let parent = TestTree(db: database, rootPath: "/base")
            let parentOnly = try parent.add(path: "/base/keep/parentonly.txt")
            try parent.add(path: "/base/keep/deep/shared.txt")
            let standalone = TestTree(db: database, rootPath: "/base/keep")
            let shared = try standalone.add(path: "/base/keep/deep/shared.txt")
            let standaloneOnly = try standalone.add(path: "/base/keep/standalone.txt")
            let root = try database.ensureRootRow(path: "/base/keep")
            _ = try database.search(SearchRequest(text: "*"), useMemory: true)
            try database.synchronizeIndexedRoots(roots: ["/base", "/base/keep"], previousRoots: ["/base", "/base/keep"])
            try assertFiles([
                "/base/keep/parentonly.txt": parentOnly,
                "/base/keep/deep/shared.txt": shared,
                "/base/keep/standalone.txt": standaloneOnly
            ], in: database)
            let parentRoot = try XCTUnwrap(database.child(ofParent: 0, name: "/base"))
            XCTAssertEqual(try database.child(ofParent: parentRoot.id, name: "keep")?.id, root)
            XCTAssertEqual(try database.search(SearchRequest(text: "standalone", wholeWord: true), useMemory: false).entries.map(\.id), [standaloneOnly])
        }
    }

    func testNarrowingDuplicatedRootMergesBeforeDeletingRetiredAncestor() throws {
        try fixture { database in
            let parent = TestTree(db: database, rootPath: "/base")
            let parentOnly = try parent.add(path: "/base/keep/deep/parentonly.txt")
            try parent.add(path: "/base/discard.txt")
            let standalone = TestTree(db: database, rootPath: "/base/keep")
            let standaloneOnly = try standalone.add(path: "/base/keep/standalone.txt")
            try database.synchronizeIndexedRoots(roots: ["/base/keep"], previousRoots: ["/base", "/base/keep"])
            try assertFiles(["/base/keep/deep/parentonly.txt": parentOnly, "/base/keep/standalone.txt": standaloneOnly], in: database)
        }
    }

    func testMergingPreservesDirectoryCachesWhenOtherTreeHasStaleFile() throws {
        try fixture { database in
            let parent = TestTree(db: database, rootPath: "/base")
            let kept = try parent.add(path: "/base/keep/mount/cached.txt")
            let directory = try XCTUnwrap(parent.id(for: "/base/keep/mount"))
            let standalone = TestTree(db: database, rootPath: "/base/keep")
            try standalone.add(path: "/base/keep/mount")
            try database.synchronizeIndexedRoots(roots: ["/base/keep"], previousRoots: ["/base", "/base/keep"])
            try assertFiles(["/base/keep/mount/cached.txt": kept], in: database)
            let root = try XCTUnwrap(database.child(ofParent: 0, name: "/base/keep"))
            XCTAssertEqual(try database.child(ofParent: root.id, name: "mount")?.id, directory)
            XCTAssertEqual(try database.child(ofParent: root.id, name: "mount")?.isDirectory, true)
        }
    }

    func testSimilarlyNamedRetiredRootIsNotTreatedAsDescendant() throws {
        try fixture { database in
            let kept = try TestTree(db: database, rootPath: "/base").add(path: "/base/kept.txt")
            try TestTree(db: database, rootPath: "/base-other").add(path: "/base-other/removed.txt")
            try database.synchronizeIndexedRoots(roots: ["/base"], previousRoots: ["/base", "/base-other"])
            try assertFiles(["/base/kept.txt": kept], in: database)
        }
    }

    func testPruningNonretainedAncestorPreservesRetainedDescendantAndItsAncestors() throws {
        try fixture { database in
            let tree = TestTree(db: database, rootPath: "/base")
            let kept = try tree.add(path: "/base/projects/deep/kept.txt")
            let root = try database.ensureRootRow(path: "/base")
            let projects = try XCTUnwrap(tree.id(for: "/base/projects"))
            try tree.add(path: "/base/removed.txt")
            let unrelated = try TestTree(db: database, rootPath: "/separate").add(path: "/separate/unrelated.txt")
            _ = try database.search(SearchRequest(text: "*"), useMemory: true)
            XCTAssertTrue(try database.removeIndexedSubtree(path: "/base", roots: ["/base", "/separate"], preservingSubtreesAt: ["/base/projects"]))
            try assertFiles(["/base/projects/deep/kept.txt": kept, "/separate/unrelated.txt": unrelated], in: database)
            XCTAssertEqual(try database.child(ofParent: 0, name: "/base")?.id, root)
            XCTAssertEqual(try database.child(ofParent: root, name: "projects")?.id, projects)
        }
    }

    func testRetainingTargetPreventsDeletionAndMissingDescendantDoesNot() throws {
        try fixture { database in
            let kept = try TestTree(db: database, rootPath: "/base").add(path: "/base/kept.txt")
            XCTAssertFalse(try database.removeIndexedSubtree(path: "/base", roots: ["/base"], preservingSubtreesAt: ["/base"]))
            try assertFiles(["/base/kept.txt": kept], in: database)
            XCTAssertTrue(try database.removeIndexedSubtree(path: "/base", roots: ["/base"], preservingSubtreesAt: ["/base/missing"]))
            try assertFiles([:], in: database)
        }
    }

    func testMovingVolumeOnlyReplacesExplicitlyAllowedEmptyPlaceholder() throws {
        try fixture { database in
            let tree = TestTree(db: database)
            let kept = try tree.add(path: "/Volumes/Old/kept.txt")
            let oldRoot = try XCTUnwrap(tree.id(for: "/Volumes/Old"))
            try tree.add(path: "/Volumes/New", isDir: true)
            XCTAssertThrowsError(try database.relocateIndexedSubtree(from: "/Volumes/Old", to: "/Volumes/New", roots: ["/"]))
            XCTAssertTrue(try database.relocateIndexedSubtree(from: "/Volumes/Old", to: "/Volumes/New", roots: ["/"], replacingEmptyDestination: true))
            try assertFiles(["/Volumes/New/kept.txt": kept], in: database)
            let volumes = try XCTUnwrap(database.indexedDirectoryAncestor(path: "/Volumes", roots: ["/"]))
            XCTAssertEqual(try database.child(ofParent: volumes.id, name: "New")?.id, oldRoot)
            let occupied = try tree.add(path: "/Volumes/Occupied/existing.txt")
            XCTAssertThrowsError(try database.relocateIndexedSubtree(from: "/Volumes/New", to: "/Volumes/Occupied", roots: ["/"], replacingEmptyDestination: true))
            try assertFiles(["/Volumes/New/kept.txt": kept, "/Volumes/Occupied/existing.txt": occupied], in: database)
        }
    }

    func testMovingVolumeCoalescesEveryCachedRepresentationBeforeChangingPath() throws {
        try fixture { database in
            let parent = TestTree(db: database, rootPath: "/Volumes")
            let parentOnly = try parent.add(path: "/Volumes/Old/parentonly.txt")
            try parent.add(path: "/Volumes/Old/shared.txt")
            let standalone = TestTree(db: database, rootPath: "/Volumes/Old")
            let shared = try standalone.add(path: "/Volumes/Old/shared.txt")
            let standaloneOnly = try standalone.add(path: "/Volumes/Old/standalone.txt")
            _ = try database.search(SearchRequest(text: "*"), useMemory: true)
            XCTAssertTrue(try database.relocateIndexedSubtree(from: "/Volumes/Old", to: "/Volumes/New", roots: ["/Volumes", "/Volumes/New"]))
            try assertFiles([
                "/Volumes/New/parentonly.txt": parentOnly,
                "/Volumes/New/shared.txt": shared,
                "/Volumes/New/standalone.txt": standaloneOnly
            ], in: database)
            let root = try XCTUnwrap(database.child(ofParent: 0, name: "/Volumes"))
            XCTAssertNil(try database.child(ofParent: root.id, name: "Old"))
        }
    }

    func testBroadeningToFilesystemRootDoesNotExposeEmptyNameOrChangeIDs() throws {
        try fixture { database in
            let kept = try TestTree(db: database, rootPath: "/base/deep").add(path: "/base/deep/kept.txt")
            try database.synchronizeIndexedRoots(roots: ["/"], previousRoots: ["/base/deep"])
            try assertFiles(["/base/deep/kept.txt": kept], in: database)
            for memory in [false, true] {
                XCTAssertFalse(try database.search(SearchRequest(text: "*"), useMemory: memory).entries.contains { $0.name.isEmpty })
            }
        }
    }

    func testRepeatedSynchronizationIsStableAndRemovingAllRootsPrunesCache() throws {
        try fixture { database in
            let kept = try TestTree(db: database, rootPath: "/base").add(path: "/base/kept.txt")
            for _ in 0..<3 {
                try database.synchronizeIndexedRoots(roots: ["/base/"], previousRoots: ["/base"])
                try assertFiles(["/base/kept.txt": kept], in: database)
            }
            try database.synchronizeIndexedRoots(roots: [], previousRoots: ["/base"])
            try assertFiles([:], in: database)
            XCTAssertEqual(try database.count(), 0)
        }
    }

    func testCanonicalizationOnlyCreatesAncestorsRequiredByCachedSubtrees() throws {
        try fixture { database in
            let roots = ["/base", "/base/child", "/offline"]
            try database.synchronizeIndexedRoots(roots: roots, previousRoots: roots, createMissingRoots: false)
            XCTAssertEqual(try database.count(), 0)
            let tree = TestTree(db: database, rootPath: "/base/child")
            let kept = try tree.add(path: "/base/child/kept.txt")
            let child = try database.ensureRootRow(path: "/base/child")
            _ = try database.search(SearchRequest(text: "*"), useMemory: true)
            try database.synchronizeIndexedRoots(roots: roots, previousRoots: roots, createMissingRoots: false)
            try assertFiles(["/base/child/kept.txt": kept], in: database)
            let parent = try XCTUnwrap(database.child(ofParent: 0, name: "/base"))
            XCTAssertEqual(try database.child(ofParent: parent.id, name: "child")?.id, child)
            XCTAssertNil(try database.child(ofParent: 0, name: "/offline"))
            XCTAssertTrue(try database.removeIndexedSubtree(path: "/base", roots: roots))
            try database.synchronizeIndexedRoots(roots: roots, previousRoots: roots, createMissingRoots: false)
            XCTAssertEqual(try database.count(), 0)
        }
    }

    private func assertFiles(_ expected: [String: Int64], in database: Database, file: StaticString = #filePath, line: UInt = #line) throws {
        for memory in [true, false, true] {
            let result = try database.search(SearchRequest(text: "*", kind: .files), useMemory: memory)
            XCTAssertEqual(result.total, expected.count, file: file, line: line)
            XCTAssertEqual(result.entries.map(\.path).sorted(), expected.keys.sorted(), file: file, line: line)
            for entry in result.entries { XCTAssertEqual(entry.id, expected[entry.path], file: file, line: line) }
        }
    }

    private func fixture(_ run: (Database) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-root-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try run(database)
    }
}
