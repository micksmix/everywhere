import XCTest
@testable import EverywhereCore

final class IndexCheckpointTests: XCTestCase {
    private func volume(path: String = "/", identity: String? = "journal", id: UInt64 = 42) -> IndexedVolume {
        IndexedVolume(path: path, device: 1, journalIdentity: identity, journalEventID: id,
                      roots: ["/Users/example"], mappings: [.init(relativePath: "", absolutePath: path)])
    }

    func testCheckpointValidationAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path
        let db = try Database(path: path)
        let config = IndexConfig(roots: ["/Users/example"], exclusions: ["skip"])
        let now = Date()
        let checkpoint = IndexCheckpoint(databasePath: path, config: config, now: now, volumes: [volume()])
        try checkpoint.save(databasePath: path)
        XCTAssertEqual(IndexCheckpoint.load(databasePath: path), checkpoint)
        XCTAssertTrue(checkpoint.isValid(databasePath: path, config: config, now: now, volumes: [volume(id: 50)]))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, now: now, volumes: [volume(id: 41)]))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, now: now, volumes: [volume(identity: "new-journal")]))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, now: now, volumes: [volume(identity: nil)]))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, now: now, volumes: []))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, now: now.addingTimeInterval(7 * 86400), volumes: [volume()]))
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: config, now: now.addingTimeInterval(-1), volumes: [volume()]))
        var changed = config
        changed.exclusions = []
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: changed, now: now, volumes: [volume()]))
        changed = config
        changed.namePatterns = ["*.tmp"]
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: changed, now: now, volumes: [volume()]))
        changed = config
        changed.skipPathPrefixes = ["/Users/example/cache"]
        XCTAssertFalse(checkpoint.isValid(databasePath: path, config: changed, now: now, volumes: [volume()]))
        let otherPath = directory.appendingPathComponent("other.sqlite").path
        let other = try Database(path: otherPath)
        XCTAssertFalse(checkpoint.isValid(databasePath: otherPath, config: config, now: now, volumes: [volume()]))
        IndexCheckpoint.remove(databasePath: path)
        XCTAssertNil(IndexCheckpoint.load(databasePath: path))
        withExtendedLifetime((db, other)) {}
    }

    func testCursorsRemainIndependentAndAllowUnarchivedDeliveredEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path
        let db = try Database(path: path)
        let config = IndexConfig(roots: ["/Users/example", "/Volumes/Work"])
        let volumes = [volume(id: 5), volume(path: "/Volumes/Work", identity: "work", id: 1000)]
        let checkpoint = IndexCheckpoint(databasePath: path, config: config, volumes: volumes)
        let writer = IndexCheckpointWriter(checkpoint, databasePath: path)
        try writer.commit(volume: "/Volumes/Work", eventID: 2000, journalEventID: 1500)
        try writer.commit(volume: "/", eventID: 19, journalEventID: 10)
        let saved = try XCTUnwrap(IndexCheckpoint.load(databasePath: path))
        XCTAssertEqual(saved.volumeCursors["/"]?.eventID, 19)
        XCTAssertEqual(saved.volumeCursors["/Volumes/Work"]?.eventID, 2000)
        XCTAssertEqual(saved.scannedAt, checkpoint.scannedAt)
        XCTAssertTrue(saved.isValid(databasePath: path, config: config,
                                    volumes: [volume(id: 10), volume(path: "/Volumes/Work", identity: "work", id: 1500)]))
        XCTAssertFalse(saved.isValid(databasePath: path, config: config,
                                     volumes: [volume(id: 10), volume(path: "/Volumes/Work", identity: "work", id: 1499)]))
        withExtendedLifetime(db) {}
    }

    func testFailedSaveDoesNotAdvanceInMemoryCursor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path
        let db = try Database(path: path)
        let checkpoint = IndexCheckpoint(databasePath: path, config: IndexConfig(roots: ["/"]), volumes: [volume(id: 5)])
        let writer = IndexCheckpointWriter(checkpoint, databasePath: path)
        try FileManager.default.createDirectory(atPath: path + ".checkpoint", withIntermediateDirectories: false)
        XCTAssertThrowsError(try writer.commit(volume: "/", eventID: 100, journalEventID: 100))
        try FileManager.default.removeItem(atPath: path + ".checkpoint")
        try writer.commit(volume: "/", eventID: 6, journalEventID: 6)
        XCTAssertEqual(IndexCheckpoint.load(databasePath: path)?.volumeCursors["/"]?.eventID, 6)
        withExtendedLifetime(db) {}
    }

    func testLegacyHostCursorRequiresNewBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path
        let legacy: [String: Any] = ["eventID": 42, "scannedAt": 0, "databaseIdentity": "old",
                                     "roots": ["/"], "exclusions": [], "skipPathPrefixes": [],
                                     "skipDirNames": [], "volumes": ["/": "journal"]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: URL(fileURLWithPath: path + ".checkpoint"))
        XCTAssertNil(IndexCheckpoint.load(databasePath: path))
    }

    func testRetargetedRootAliasInvalidatesCheckpointOnSameVolume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        let config = IndexConfig(roots: [alias.path])
        let checkpoint = IndexCheckpoint(databasePath: db.path, config: config)
        XCTAssertTrue(checkpoint.isValid(databasePath: db.path, config: config))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        XCTAssertFalse(checkpoint.isValid(databasePath: db.path, config: config))
    }
}

final class IndexedVolumeTests: XCTestCase {
    private let mounts: [IndexedVolume.Mount] = [
        .init(path: "/", device: 1, mappings: [.init(relativePath: "", absolutePath: "/")]),
        .init(path: "/Volumes/Work", device: 2, mappings: [.init(relativePath: "", absolutePath: "/Volumes/Work")]),
        .init(path: "/Volumes/Other", device: 3, mappings: [.init(relativePath: "", absolutePath: "/Volumes/Other")])
    ]

    func testHomeIndexIgnoresUnrelatedMountedVolumes() {
        let config = IndexConfig(roots: ["/Users/example"])
        let selected = IndexedVolume.select(config: config, mounts: mounts) { _ in 1 }
        XCTAssertEqual(selected.map(\.path), ["/"])
        XCTAssertEqual(selected.first?.roots, ["/Users/example"])
        XCTAssertEqual(selected, IndexedVolume.select(config: config, mounts: Array(mounts.prefix(1))) { _ in 1 })
    }

    func testNestedMountsAndExclusionsUsePathBoundaries() {
        let config = IndexConfig(roots: ["/"], namePatterns: ["Other"], skipPathPrefixes: ["/Volumes/Work/cache"])
        let selected = IndexedVolume.select(config: config, mounts: mounts) { _ in 1 }
        XCTAssertEqual(selected.map(\.path), ["/", "/Volumes/Work"])
        var excluded = config
        excluded.skipPathPrefixes = ["/Volumes/Work"]
        XCTAssertEqual(IndexedVolume.select(config: excluded, mounts: mounts) { _ in 1 }.map(\.path), ["/"])
        excluded.skipPathPrefixes = ["/Volumes/Work-other"]
        XCTAssertEqual(IndexedVolume.select(config: excluded, mounts: mounts) { _ in 1 }.map(\.path), ["/", "/Volumes/Work"])
    }

    func testFirmlinkedDataVolumeIsIncludedThroughVisibleRoots() {
        let data = IndexedVolume.Mount(path: "/System/Volumes/Data", device: 2,
                                      mappings: [.init(relativePath: "", absolutePath: "/System/Volumes/Data"),
                                                 .init(relativePath: "Users", absolutePath: "/Users")])
        let config = IndexConfig(roots: ["/"], skipPathPrefixes: ["/System/Volumes"])
        let selected = IndexedVolume.select(config: config, mounts: [mounts[0], data]) { _ in 1 }
        XCTAssertEqual(selected.map(\.path), ["/", "/System/Volumes/Data"])
        XCTAssertEqual(selected.last?.roots, ["/Users"])
        XCTAssertEqual(selected.last?.absolutePath(for: "Users/example/docs/"), "/Users/example/docs")
        XCTAssertEqual(selected.last?.absolutePath(for: "Users-other/file"), "/System/Volumes/Data/Users-other/file")
    }

    func testExplicitExternalRootDoesNotIncludeItsParentVolume() {
        let config = IndexConfig(roots: ["/Volumes/Work/projects"])
        XCTAssertEqual(IndexedVolume.select(config: config, mounts: mounts) { _ in 2 }.map(\.path), ["/Volumes/Work"])
    }

    func testRecoveryRootsPreserveConfiguredSymlinkAliases() {
        let config = IndexConfig(roots: ["/var"])
        let selected = IndexedVolume.select(config: config, mounts: mounts) { _ in 1 }
        XCTAssertEqual(selected.first?.roots, ["/var"])
    }
}
