import XCTest
@testable import EverywhereCore

final class IndexCheckpointTests: XCTestCase {
    func testCheckpointValidationAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path
        let db = try Database(path: path)
        let config = IndexConfig(roots: ["/Users/example"], exclusions: ["skip"])
        let now = Date()
        let volumes = ["/": "journal-uuid"]
        let checkpoint = IndexCheckpoint(eventID: 42, databasePath: path, config: config, now: now, volumes: volumes)
        try checkpoint.save(databasePath: path)
        XCTAssertEqual(IndexCheckpoint.load(databasePath: path), checkpoint)
        XCTAssertTrue(checkpoint.isValid(databasePath: path, config: config, currentEventID: 50, now: now, volumes: volumes))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, currentEventID: 41, now: now, volumes: volumes))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, currentEventID: 50, now: now, volumes: ["/": "new-journal"]))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, currentEventID: 50,
                                          now: now.addingTimeInterval(8 * 86400), volumes: volumes))
        var changed = config
        changed.exclusions = []
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: changed, currentEventID: 50, now: now, volumes: volumes))
        changed = config
        changed.namePatterns = ["*.tmp"]
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: changed, currentEventID: 50, now: now, volumes: volumes))
        changed = config
        changed.skipPathPrefixes = ["/Users/example/cache"]
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: changed, currentEventID: 50, now: now, volumes: volumes))
        let otherPath = directory.appendingPathComponent("other.sqlite").path
        let other = try Database(path: otherPath)
        XCTAssertFalse(checkpoint.isValid(databasePath: otherPath, config: config, currentEventID: 50, now: now, volumes: volumes))
        IndexCheckpoint.remove(databasePath: path)
        XCTAssertNil(IndexCheckpoint.load(databasePath: path))
        withExtendedLifetime((db, other)) {}
    }
}
