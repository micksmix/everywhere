import Combine
import XCTest
@testable import EverywhereCore

final class IndexServiceTests: XCTestCase {
    func testLocationSetupPersistsUntilSelectionAndKeepsLibraryIncluded() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-setup-\(UUID()).sqlite")
        defaults.set(path.path, forKey: "IndexDatabasePath")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: path)
        }
        let settings = IndexSettings(defaults: defaults)
        XCTAssertTrue(settings.needsLocationSetup)
        XCTAssertEqual(settings.roots, [FileManager.default.homeDirectoryForCurrentUser.path])
        XCTAssertTrue(settings.excludedFolders.isEmpty)
        try Data().write(to: path)
        let reopened = IndexSettings(defaults: defaults)
        XCTAssertTrue(reopened.needsLocationSetup)
        XCTAssertEqual(reopened.roots, settings.roots)
        reopened.roots = ["/selected"]
        let saved = IndexSettings(defaults: defaults)
        XCTAssertFalse(saved.needsLocationSetup)
        XCTAssertEqual(saved.roots, ["/selected"])
        saved.roots = []
        XCTAssertEqual(IndexSettings(defaults: defaults).roots, [])
    }

    func testExistingIndexKeepsLegacyRootWithoutSetup() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-legacy-\(UUID()).sqlite")
        defaults.set(path.path, forKey: "IndexDatabasePath")
        try Data().write(to: path)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: path)
        }
        let settings = IndexSettings(defaults: defaults)
        XCTAssertFalse(settings.needsLocationSetup)
        XCTAssertEqual(settings.roots, ["/"])
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(IndexSettings(defaults: defaults).roots, ["/"])
    }

    @MainActor
    func testSetupBlocksAutomaticAndManualIndexing() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-gate-\(UUID())")
        defaults.set(directory.appendingPathComponent("index.sqlite").path, forKey: "IndexDatabasePath")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = IndexSettings(defaults: defaults)
        let database = try Database(path: settings.indexPath)
        let service = IndexService(settings: settings, database: database)
        defer { service.setIndexingEnabled(false) }
        service.startIfNeeded()
        service.rebuild()
        service.setLive(true)
        service.setIndexingEnabled(true)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertFalse(service.live)
        XCTAssertEqual(try database.count(), 0)
    }

    func testExclusionSettingsPersist() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.excludedFolders = ["/Users/example/cache"]
        settings.excludedNamePatterns = ["*.tmp", "cache-?"]
        let restored = IndexSettings(defaults: defaults)
        XCTAssertEqual(restored.excludedFolders, settings.excludedFolders)
        XCTAssertEqual(restored.excludedNamePatterns, settings.excludedNamePatterns)
    }

    @MainActor
    func testBuiltInExclusionsCanBeRemovedPersistedAndRestored() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-defaults-\(UUID())")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = ["/"]
        XCTAssertEqual(settings.builtInExcludedFolders, FilesystemIndexer.defaultSkipPathPrefixes)
        XCTAssertEqual(settings.builtInExcludedDirectoryNames, FilesystemIndexer.defaultSkipDirNames)
        let db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        let original = service.makeConfig()
        XCTAssertTrue(original.ignores(path: "/System/Volumes/Preboot/photo.heic"))
        XCTAssertTrue(original.ignores(path: "/Users/example/.Trash/photo.heic"))
        let checkpoint = IndexCheckpoint(eventID: 1, databasePath: db.path, config: original, volumes: ["/": "test"])
        settings.builtInExcludedFolders.removeAll { $0 == "/System/Volumes" }
        settings.builtInExcludedDirectoryNames.removeAll { $0 == ".Trash" }
        let changed = service.makeConfig()
        XCTAssertFalse(changed.ignores(path: "/System/Volumes/Preboot/photo.heic"))
        XCTAssertFalse(changed.ignores(path: "/Users/example/.Trash/photo.heic"))
        XCTAssertTrue(changed.ignores(path: "/dev/disk0"))
        XCTAssertFalse(checkpoint.isValid(databasePath: db.path, config: changed, currentEventID: 1, volumes: ["/": "test"]))
        let restored = IndexSettings(defaults: defaults)
        XCTAssertEqual(restored.builtInExcludedFolders, settings.builtInExcludedFolders)
        XCTAssertEqual(restored.builtInExcludedDirectoryNames, settings.builtInExcludedDirectoryNames)
        settings.builtInExcludedFolders = []
        settings.builtInExcludedDirectoryNames = []
        let empty = IndexSettings(defaults: defaults)
        XCTAssertTrue(empty.builtInExcludedFolders.isEmpty)
        XCTAssertTrue(empty.builtInExcludedDirectoryNames.isEmpty)
        XCTAssertTrue(service.makeConfig().ignores(path: db.path))
        settings.builtInExcludedFolders = FilesystemIndexer.defaultSkipPathPrefixes
        settings.builtInExcludedDirectoryNames = FilesystemIndexer.defaultSkipDirNames
        XCTAssertTrue(service.makeConfig().ignores(path: "/System/Volumes/Preboot/photo.heic"))
        settings.roots = ["/System/Volumes/Preboot"]
        XCTAssertFalse(service.makeConfig().ignores(path: "/System/Volumes/Preboot/photo.heic"))
    }

    @MainActor
    func testRemovedBuiltInNameExclusionAppliesToRebuildAndEvents() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-default-events-\(UUID())")
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try Data().write(to: trash.appendingPathComponent("vacation.heic"))
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        let db = try Database(path: root.appendingPathComponent("storage/index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        try FilesystemIndexer(db: db, config: service.makeConfig()).run()
        XCTAssertEqual(try db.search(SearchRequest(text: "vacation")).total, 0)
        settings.builtInExcludedDirectoryNames.removeAll { $0 == ".Trash" }
        let config = service.makeConfig()
        try Reconciler(db: db, config: config, roots: config.roots, skipUnchangedDirs: false).run()
        XCTAssertEqual(try db.search(SearchRequest(text: "vacation")).total, 1)
        let handler = ChangeHandler(db: db, config: config)
        defer { handler.stop() }
        try Data().write(to: trash.appendingPathComponent("new.heic"))
        handler.ingest(events: [FileSystemEvent(path: trash.path, id: 1)])
        handler.flushPendingNow()
        XCTAssertEqual(try db.search(SearchRequest(text: "new.heic")).total, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "sqlite")).total, 0)
    }

    @MainActor
    func testRebuildHonorsStorageFolderAndPatternExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-exclusions-\(UUID())")
        let excluded = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("keep.txt"))
        try Data().write(to: root.appendingPathComponent("scratch.tmp"))
        try Data().write(to: excluded.appendingPathComponent("secret.txt"))
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.excludedFolders = [excluded.path]
        settings.excludedNamePatterns = ["*.tmp"]
        settings.liveUpdates = false
        let db = try Database(path: root.appendingPathComponent("storage/index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        let completed = expectation(description: "Filtered rebuild completed")
        let subscription = service.$phase.dropFirst().filter { $0 == .idle }.sink { _ in completed.fulfill() }
        service.rebuild()
        await fulfillment(of: [completed], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(service.lastError)
        XCTAssertEqual(try db.search(SearchRequest(text: ".txt")).entries.map(\.name), ["keep.txt"])
        XCTAssertEqual(try db.search(SearchRequest(text: ".tmp")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "sqlite")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "storage")).total, 0)
    }

    @MainActor
    func testManualCompactionWithIndexingDisabledReclaimsSpace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.indexingEnabled = false
        let path = directory.appendingPathComponent("index.sqlite").path
        let db = try Database(path: path)
        let tree = TestTree(db: db)
        try db.beginBulkLoad()
        for number in 0..<2000 {
            try tree.add(path: "/discard/document-\(number)-\(String(repeating: "x", count: 100)).txt")
        }
        let survivor = try tree.add(path: "/keep/survivor.txt")
        try db.endBulkLoad()
        try db.deleteSubtree(id: XCTUnwrap(tree.id(for: "/discard")))
        XCTAssertFalse(try db.compactIfNeeded())
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).int64Value
        let service = IndexService(settings: settings, database: db)
        service.setIndexingEnabled(false)
        XCTAssertTrue(service.canCompactIndex)
        let finished = expectation(description: "Manual compaction completes")
        let subscription = service.$isCompacting.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        service.compactIndexNow()
        XCTAssertTrue(service.isCompacting)
        XCTAssertFalse(service.canCompactIndex)
        service.compactIndexNow()
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(service.compactionMessage, "Index compaction complete.")
        XCTAssertTrue(service.canCompactIndex)
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).int64Value
        XCTAssertLessThan(after, before)
        let result = try db.search(SearchRequest(text: "survivor"))
        XCTAssertEqual(result.entries.map(\.id), [survivor])
        XCTAssertEqual(result.entries.map(\.path), ["/keep/survivor.txt"])
    }

    @MainActor
    func testSavedIndexLoadsDuringStartupDelay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = directory.appendingPathComponent("saved.sqlite").path
        do {
            let db = try Database(path: path)
            try TestTree(db: db).add(path: "/saved-document.txt")
        }
        defaults.set(path, forKey: "IndexDatabasePath")
        let settings = IndexSettings(defaults: defaults)
        try settings.setIndexPath(path)
        let restored = IndexSettings(defaults: defaults)
        XCTAssertEqual(restored.indexPath, path)
        let db = try Database(path: restored.indexPath)
        let expectedCount = try db.count()
        XCTAssertGreaterThan(expectedCount, 0)
        let service = IndexService(settings: restored, database: db)
        defer { service.setIndexingEnabled(false) }
        XCTAssertFalse(service.hasLoadedIndexCount)
        let loaded = expectation(description: "Saved count loads before indexing")
        let subscription = service.$hasLoadedIndexCount.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [loaded], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(service.phase, .waiting)
        XCTAssertEqual(service.indexedRows, expectedCount)
        XCTAssertNil(service.indexCountError)
        XCTAssertEqual(try db.search(SearchRequest(text: "saved")).total, 1)
    }

    @MainActor
    func testEmptyIndexBuildsImmediatelyButHonorsDisabledIndexing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("new".utf8).write(to: root.appendingPathComponent("immediate.txt"))
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.liveUpdates = false
        settings.startupDelay = 3600
        let db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
        let disabled = IndexService(settings: settings, database: db)
        settings.indexingEnabled = false
        let loaded = expectation(description: "Disabled index count loads")
        let countSubscription = disabled.$hasLoadedIndexCount.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        disabled.startIfNeeded()
        await fulfillment(of: [loaded], timeout: 10)
        withExtendedLifetime(countSubscription) {}
        XCTAssertEqual(disabled.phase, .idle)
        XCTAssertEqual(try db.count(), 0)
        disabled.setIndexingEnabled(false)
        settings.indexingEnabled = true
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        let finished = expectation(description: "Empty index builds without countdown advancement")
        let subscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(service.countdownSeconds, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "immediate")).total, 1)
    }

    func testIndexPathValidationPreservesFilesAndPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        let path = directory.appendingPathComponent("new.sqlite").path
        try settings.setIndexPath(path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let unrelated = directory.appendingPathComponent("unrelated.sqlite")
        let contents = Data("Keep this file".utf8)
        try contents.write(to: unrelated)
        XCTAssertThrowsError(try settings.setIndexPath(unrelated.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), contents)
        XCTAssertThrowsError(try settings.setIndexPath(directory.path))
        XCTAssertThrowsError(try settings.setIndexPath("relative.sqlite"))
        XCTAssertEqual(settings.indexPath, path)
        XCTAssertEqual(IndexSettings(defaults: defaults).indexPath, path)
    }

    func testDelaySettingsPersistAndConvertUnits() throws {
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        XCTAssertEqual(settings.startupDelaySeconds, 120)
        XCTAssertTrue(settings.indexingEnabled)
        settings.startupDelay = 2
        settings.startupDelayUnit = .minutes
        XCTAssertEqual(settings.startupDelaySeconds, 120)
        settings.startupDelayUnit = .hours
        settings.indexingEnabled = false
        let restored = IndexSettings(defaults: defaults)
        XCTAssertEqual(restored.startupDelaySeconds, 7200)
        XCTAssertFalse(restored.indexingEnabled)
        settings.startupDelay = -1
        XCTAssertEqual(settings.startupDelaySeconds, 0)
    }

    @MainActor
    func testCountdownPauseDisableAndDelayedCatchUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.liveUpdates = false
        let db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
        try TestTree(db: db).add(path: "/saved.txt")
        let initialCount = try db.count()
        let service = IndexService(settings: settings, database: db)
        service.startIfNeeded()
        XCTAssertEqual(service.phase, .waiting)
        XCTAssertEqual(service.countdownSeconds, 120)
        service.startIfNeeded()
        service.togglePause()
        let remaining = service.countdownSeconds
        service.updateCountdown(now: Date().addingTimeInterval(180))
        XCTAssertEqual(service.countdownSeconds, remaining)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(try db.count(), initialCount)
        service.togglePause()
        XCTAssertEqual(service.phase, .reconciling)
        XCTAssertEqual(service.countdownSeconds, 0)
        XCTAssertFalse(service.isPaused)
        service.setIndexingEnabled(false)
        service.updateCountdown(now: Date().addingTimeInterval(180))
        service.rebuild()
        service.setLive(true)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertFalse(service.live)
        XCTAssertEqual(try db.count(), initialCount)
        service.setIndexingEnabled(true)
        XCTAssertEqual(service.phase, .waiting)
        try Data("new".utf8).write(to: root.appendingPathComponent("during-delay.txt"))
        let finished = expectation(description: "Delayed indexing completes")
        let subscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
        service.updateCountdown(now: Date().addingTimeInterval(180))
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(try db.search(SearchRequest(text: "during")).total, 1)
        service.setIndexingEnabled(false)
        XCTAssertEqual(try db.search(SearchRequest(text: "during")).total, 1)
    }

    @MainActor
    func testStartupReplaysOfflineChangesWithoutReplacingBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        let databasePath = directory.appendingPathComponent("db/index.sqlite").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.startupDelay = 0
        settings.roots = [root.path]
        settings.liveUpdates = false
        let db = try Database(path: databasePath)
        let initial = IndexService(settings: settings, database: db)
        let indexed = expectation(description: "Initial scan complete")
        let firstSubscription = initial.$phase.dropFirst().filter { $0 == .idle }.sink { _ in indexed.fulfill() }
        initial.startIfNeeded()
        await fulfillment(of: [indexed], timeout: 10)
        withExtendedLifetime(firstSubscription) {}
        let baseline = try XCTUnwrap(IndexCheckpoint.load(databasePath: databasePath))

        let recorded = expectation(description: "Offline change recorded by the OS")
        recorded.assertForOverFulfill = false
        let monitor = FSEventsMonitor(roots: [root.path], latency: 0.1) { _ in recorded.fulfill() }
        XCTAssertTrue(monitor.start())
        try Data("offline".utf8).write(to: root.appendingPathComponent("offline.txt"))
        await fulfillment(of: [recorded], timeout: 10)
        monitor.stop()
        XCTAssertEqual(try db.search(SearchRequest(text: "offline")).total, 0)

        settings.startupDelay = 30
        let restarted = IndexService(settings: settings, database: db)
        let caughtUp = expectation(description: "Journal replay complete")
        let subscription = restarted.$phase.dropFirst().filter { $0 == .idle }.sink { _ in caughtUp.fulfill() }
        restarted.startIfNeeded()
        XCTAssertEqual(restarted.phase, .waiting)
        XCTAssertEqual(try db.search(SearchRequest(text: "offline")).total, 0)
        restarted.updateCountdown(now: Date().addingTimeInterval(180))
        await fulfillment(of: [caughtUp], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(restarted.lastError)
        XCTAssertEqual(try db.search(SearchRequest(text: "offline")).total, 1)
        let updated = try XCTUnwrap(IndexCheckpoint.load(databasePath: databasePath))
        XCTAssertEqual(updated.scannedAt, baseline.scannedAt)
        XCTAssertGreaterThanOrEqual(updated.eventID, baseline.eventID)
    }

    @MainActor
    func testRebuildReplacesPausedJobAndFinishesWithSearchableIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("example.txt"))
        let suite = "EverywhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.startupDelay = 0
        settings.roots = [root.path]
        settings.liveUpdates = false
        let db = try Database(path: directory.appendingPathComponent("storage/index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        let completed = expectation(description: "Replacement rebuild finished")
        let subscription = service.$phase.dropFirst().filter { $0 == .idle }.sink { _ in
            completed.fulfill()
        }
        service.rebuild()
        service.togglePause()
        XCTAssertTrue(service.isPaused)
        service.rebuild()
        XCTAssertFalse(service.isPaused)
        await fulfillment(of: [completed], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isPaused)
        XCTAssertFalse(service.canPause)
        XCTAssertEqual(service.progressStats.scannedItems, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "example")).total, 1)
    }
}
