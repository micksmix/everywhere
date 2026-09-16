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
}
