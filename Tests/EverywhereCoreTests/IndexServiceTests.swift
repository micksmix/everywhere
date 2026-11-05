import Combine
import SQLite3
import XCTest
@testable import EverywhereCore

final class IndexServiceTests: XCTestCase {
    func testFullCheckScheduleDefaultsToOffAndPersists() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        XCTAssertEqual(settings.fullCheckInterval, .off)
        XCTAssertNil(settings.fullCheckInterval.seconds)
        settings.fullCheckInterval = .daily
        XCTAssertEqual(IndexSettings(defaults: defaults).fullCheckInterval.seconds, 86400)
        settings.fullCheckInterval = .monthly
        XCTAssertEqual(IndexSettings(defaults: defaults).fullCheckInterval.seconds, 30 * 86400)
    }

    @MainActor
    func testLiveUpdatesChangesPreserveRunningAndPausedStartupDelays() async throws {
        for paused in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "EverywhereTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(directory.appendingPathComponent("db/index.sqlite").path, forKey: "IndexDatabasePath")
            let settings = IndexSettings(defaults: defaults)
            settings.roots = [directory.path]
            settings.startupDelay = 3600
            let db = try Database(path: settings.indexPath)
            try TestTree(db: db).add(path: "/saved.txt")
            let service = IndexService(settings: settings, database: db)
            defer { service.setIndexingEnabled(false) }
            let loaded = expectation(description: "Saved index loads before startup delay changes")
            let subscription = service.$hasLoadedIndexCount.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
            service.startIfNeeded()
            await fulfillment(of: [loaded], timeout: 10)
            if paused { service.togglePause() }
            let seconds = service.countdownSeconds
            XCTAssertGreaterThan(seconds, 0)
            for enabled in [false, true, false, true] {
                service.setLive(enabled)
                XCTAssertEqual(settings.liveUpdates, enabled)
                XCTAssertEqual(IndexSettings(defaults: defaults).liveUpdates, enabled)
                XCTAssertFalse(service.live)
                XCTAssertEqual(service.phase, .waiting)
                XCTAssertEqual(service.isPaused, paused)
                XCTAssertEqual(service.countdownSeconds, seconds)
            }
            if paused {
                service.updateCountdown(now: Date().addingTimeInterval(7200))
                XCTAssertEqual(service.phase, .waiting)
                XCTAssertTrue(service.isPaused)
                XCTAssertEqual(service.countdownSeconds, seconds)
            }
            withExtendedLifetime(subscription) {}
        }
    }

    @MainActor
    func testLiveUpdatesPreferenceTogglesDuringPausedScanAndAppliesAfterCatchUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: root.appendingPathComponent("example.txt"))
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(directory.appendingPathComponent("db/index.sqlite").path, forKey: "IndexDatabasePath")
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        let db = try Database(path: settings.indexPath)
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        let monitoring = expectation(description: "Baseline starts suspended monitoring")
        let monitorSubscription = service.$live.filter { $0 }.prefix(1).sink { _ in
            service.togglePause()
            monitoring.fulfill()
        }
        service.rebuild()
        service.togglePause()
        XCTAssertTrue(settings.liveUpdates)
        XCTAssertFalse(service.live)
        service.setLive(false)
        XCTAssertFalse(settings.liveUpdates)
        XCTAssertFalse(IndexSettings(defaults: defaults).liveUpdates)
        service.setLive(true)
        XCTAssertTrue(settings.liveUpdates)
        XCTAssertTrue(IndexSettings(defaults: defaults).liveUpdates)
        XCTAssertFalse(service.live)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(service.phase, .indexing)
        service.togglePause()
        await fulfillment(of: [monitoring], timeout: 10)
        XCTAssertTrue(service.live)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(service.phase, .indexing)
        service.setLive(false)
        XCTAssertFalse(settings.liveUpdates)
        XCTAssertFalse(IndexSettings(defaults: defaults).liveUpdates)
        XCTAssertTrue(service.live)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(service.phase, .indexing)
        let finished = expectation(description: "Scan and catch-up finish with live updates disabled")
        let finishSubscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
        service.togglePause()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertFalse(settings.liveUpdates)
        XCTAssertFalse(service.live)
        XCTAssertFalse(service.isPaused)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(try db.search(SearchRequest(text: "example")).total, 1)
        XCTAssertNotNil(IndexCheckpoint.load(databasePath: db.path))
        let resumed = expectation(description: "Live updates can be enabled again from idle")
        let resumeSubscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in resumed.fulfill() }
        service.setLive(true)
        XCTAssertTrue(settings.liveUpdates)
        XCTAssertTrue(IndexSettings(defaults: defaults).liveUpdates)
        await fulfillment(of: [resumed], timeout: 10)
        XCTAssertTrue(service.live)
        XCTAssertNil(service.lastError)
        service.setLive(false)
        XCTAssertFalse(settings.liveUpdates)
        XCTAssertFalse(service.live)
        XCTAssertEqual(service.phase, .idle)
        withExtendedLifetime((monitorSubscription, finishSubscription, resumeSubscription)) {}
    }

    func testReplayWaitsForEveryVolumeAndIgnoresDuplicateCompletion() {
        var replay = JournalReplayProgress(volumes: ["/", "/Volumes/Work"])
        XCTAssertFalse(replay.finish(volume: "/"))
        XCTAssertFalse(replay.finish(volume: "/"))
        XCTAssertFalse(replay.finish(volume: "/unrelated"))
        XCTAssertEqual(replay.pendingVolumes, ["/Volumes/Work"])
        XCTAssertTrue(replay.finish(volume: "/Volumes/Work"))
        XCTAssertFalse(replay.finish(volume: "/Volumes/Work"))
    }

    func testBaselineFailureWaitsForChangedSnapshotOrExplicitRetry() {
        let config = IndexConfig(roots: ["/indexed"])
        let volume = IndexedVolume(path: "/", device: 1, journalIdentity: "journal", journalEventID: 10,
                                   roots: config.roots, mappings: [.init(relativePath: "", absolutePath: "/")])
        var state = IndexReconciliationState()
        state.beginAttempt(config: config, volumes: [volume])
        state.failBaseline()
        XCTAssertTrue(state.baselineFailed)
        for eventID in [UInt64(10), 20, 30] {
            var current = volume
            current.journalEventID = eventID
            XCTAssertFalse(state.needsReconciliation(config: config, volumes: [current], compareTopology: true))
        }
        var replacement = volume
        replacement.journalIdentity = "replacement"
        XCTAssertTrue(state.needsReconciliation(config: config, volumes: [replacement], compareTopology: true))
        state.beginAttempt(config: config, volumes: [replacement])
        XCTAssertFalse(state.baselineFailed)
        XCTAssertFalse(state.needsReconciliation(config: config, volumes: [replacement], compareTopology: true))
        state.failBaseline()
        state.prepareForRetry()
        XCTAssertFalse(state.baselineFailed)
    }

    func testAttemptSnapshotConsumesCoveredChangesButPreservesNewerTopology() {
        let config = IndexConfig(roots: ["/indexed"])
        let first = IndexedVolume(path: "/", device: 1, journalIdentity: "first", journalEventID: 10,
                                  roots: config.roots, mappings: [.init(relativePath: "", absolutePath: "/")])
        var second = first
        second.journalIdentity = "second"
        var state = IndexReconciliationState()
        state.beginAttempt(config: config, volumes: [first])
        XCTAssertTrue(state.needsReconciliation(config: config, volumes: [second], compareTopology: true))
        state.beginAttempt(config: config, volumes: [second])
        XCTAssertFalse(state.needsReconciliation(config: config, volumes: [second], compareTopology: true))
        XCTAssertTrue(state.needsReconciliation(config: config, volumes: [], compareTopology: true))
        XCTAssertFalse(state.needsReconciliation(config: config, volumes: [second], compareTopology: true))
    }

    func testReconciliationSnapshotDetectsAccessAndConfigurationChangesWithoutLiveUpdates() {
        var config = IndexConfig(roots: ["/indexed", "/other"])
        config.locationAccess = [
            .init(path: "/indexed", device: 1, isAvailable: true, identity: "journal"),
            .init(path: "/other", device: 2, isAvailable: true, identity: "other")
        ]
        config.locationIdentities = ["retained"]
        var state = IndexReconciliationState()
        state.beginAttempt(config: config, volumes: [])
        var current = config
        current.locationAccess.reverse()
        XCTAssertFalse(state.needsReconciliation(config: current, volumes: [], compareTopology: false))
        current = config
        current.locationAccess[0].isAvailable = false
        XCTAssertTrue(state.needsReconciliation(config: current, volumes: [], compareTopology: false))
        current = config
        current.locationAccess[0].identity = "replacement"
        XCTAssertTrue(state.needsReconciliation(config: current, volumes: [], compareTopology: false))
        current = config
        current.locationIdentities = ["remove-offline"]
        XCTAssertTrue(state.needsReconciliation(config: current, volumes: [], compareTopology: false))
        current = config
        current.exclusions = ["excluded"]
        XCTAssertTrue(state.needsReconciliation(config: current, volumes: [], compareTopology: false))
        XCTAssertFalse(state.needsReconciliation(config: config, volumes: [], compareTopology: false))
    }

    @MainActor
    func testCheckpointFailurePreservesServiceHandlerBatchForTargetedRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        let db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        let healthyRoot = root.appendingPathComponent("healthy")
        try FileManager.default.createDirectory(at: healthyRoot, withIntermediateDirectories: true)
        let config = service.makeConfig(includeLocationAccess: false).preparingFilesystemPaths()
        try FilesystemIndexer(db: db, config: config).run()
        let volume = IndexedVolume(path: root.path, device: try XCTUnwrap(IndexedVolume.device(containing: root.path)),
                                   journalIdentity: "test", journalEventID: 0, roots: config.roots,
                                   mappings: [.init(relativePath: "", absolutePath: root.path)])
        let healthyVolume = IndexedVolume(path: healthyRoot.path, device: volume.device,
                                          journalIdentity: "healthy", journalEventID: 0, roots: [healthyRoot.path],
                                          mappings: [.init(relativePath: "", absolutePath: healthyRoot.path)])
        let checkpoint = IndexCheckpoint(databasePath: db.path, config: config, volumes: [volume, healthyVolume])
        let writer = IndexCheckpointWriter(checkpoint, databasePath: db.path)
        let handler = service.makeChangeHandler(volume: volume, config: config, writer: writer)
        defer { handler.stop() }
        let healthyHandler = service.makeChangeHandler(volume: healthyVolume, config: config, writer: writer)
        defer { healthyHandler.stop(cancelControl: false) }
        service.noteMonitoringUnavailable()
        let monitoringWarning = try XCTUnwrap(service.lastError)
        try Data([1]).write(to: root.appendingPathComponent("pending.txt"))
        let sidecar = db.path + ".checkpoint"
        try FileManager.default.createDirectory(atPath: sidecar, withIntermediateDirectories: false)
        let failed = expectation(description: "Checkpoint error is surfaced")
        let failure = service.$lastError.dropFirst().compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
        handler.ingest(events: [FileSystemEvent(path: root.path, id: 42, flags: 0)])
        handler.flushPendingNow()
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertNil(IndexCheckpoint.load(databasePath: db.path))
        XCTAssertEqual(try db.search(SearchRequest(text: "pending")).total, 1)
        let revision = service.indexRevision
        let handlerError = try XCTUnwrap(service.lastError)
        XCTAssertNotEqual(handlerError, monitoringWarning)
        XCTAssertEqual(URL(fileURLWithPath: sidecar).standardizedFileURL.path, db.path + ".checkpoint")
        try FileManager.default.removeItem(atPath: sidecar)
        healthyHandler.ingest(events: [FileSystemEvent(path: healthyRoot.path, id: 21, flags: 0)])
        healthyHandler.flushPendingNow()
        let healthyCommitted = expectation(description: "Healthy handler publishes its successful commit")
        DispatchQueue.main.async { healthyCommitted.fulfill() }
        await fulfillment(of: [healthyCommitted], timeout: 10)
        XCTAssertEqual(IndexCheckpoint.load(databasePath: db.path)?.volumeCursors[healthyRoot.path]?.eventID, 21)
        XCTAssertEqual(IndexCheckpoint.load(databasePath: db.path)?.volumeCursors[root.path]?.eventID, 0)
        XCTAssertEqual(service.lastError, handlerError)
        let recovered = expectation(description: "Owner retry restores the unsupported-monitor warning")
        let recovery = service.$lastError.dropFirst().filter { $0 == monitoringWarning }.prefix(1).sink { _ in recovered.fulfill() }
        handler.flushPendingNow()
        await fulfillment(of: [recovered], timeout: 10)
        withExtendedLifetime((failure, recovery)) {}
        XCTAssertEqual(IndexCheckpoint.load(databasePath: db.path)?.volumeCursors[root.path]?.eventID, 42)
        XCTAssertGreaterThan(service.indexRevision, revision)
        XCTAssertEqual(service.lastError, monitoringWarning)
    }

    @MainActor
    func testFailedBaselineDoesNotRetryFromOverdueScheduleAndAllowsExplicitRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.startupDelay = 0
        settings.liveUpdates = false
        settings.fullCheckInterval = .daily
        let db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
        try Data([1]).write(to: root.appendingPathComponent("existing.txt"))
        try FilesystemIndexer(db: db, config: IndexConfig(roots: [root.path])).run()
        try Data([2]).write(to: root.appendingPathComponent("pending.txt"))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TRIGGER fail_pending BEFORE INSERT ON entries WHEN NEW.name = 'pending.txt' BEGIN SELECT RAISE(FAIL, 'injected baseline failure'); END", nil, nil, nil), SQLITE_OK)
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        let failed = expectation(description: "Baseline failure is surfaced")
        let failure = service.$lastError.compactMap { $0 }.filter { $0.contains("injected baseline failure") }
            .prefix(1).sink { _ in failed.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(IndexCheckpoint.load(databasePath: db.path))
        for day in 1...3 {
            service.checkScheduledFullCheck(now: Date().addingTimeInterval(Double(day) * 86400))
            XCTAssertEqual(service.phase, .idle)
        }
        XCTAssertEqual(sqlite3_exec(connection, "DROP TRIGGER fail_pending", nil, nil, nil), SQLITE_OK)
        let rebuilt = expectation(description: "Explicit retry completes")
        let completion = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in rebuilt.fulfill() }
        service.rebuild()
        XCTAssertEqual(service.phase, .indexing)
        await fulfillment(of: [rebuilt], timeout: 10)
        withExtendedLifetime((failure, completion)) {}
        XCTAssertNil(service.lastError)
        XCTAssertEqual(try db.search(SearchRequest(text: "pending")).total, 1)
    }

    @MainActor
    func testScheduledCheckRunsWithoutLiveUpdatesAndPreservesIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.startupDelay = 0
        settings.liveUpdates = false
        let db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        try Data([1]).write(to: root.appendingPathComponent("existing.txt"))
        let built = expectation(description: "Initial baseline completes")
        let initial = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in built.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [built], timeout: 15)
        let maintenanceDone = expectation(description: "Maintenance is idle")
        let maintenance = service.$isCompacting.filter { !$0 }.prefix(1).sink { _ in maintenanceDone.fulfill() }
        await fulfillment(of: [maintenanceDone], timeout: 10)
        withExtendedLifetime((initial, maintenance)) {}
        let baseline = try XCTUnwrap(IndexCheckpoint.load(databasePath: db.path))
        let existingID = try XCTUnwrap(db.search(SearchRequest(text: "existing")).entries.first?.id)
        let rebuildDate = settings.lastFullRebuildDate
        try Data([2]).write(to: root.appendingPathComponent("scheduled.txt"))
        let overdue = baseline.scannedAt.addingTimeInterval(2 * 86400)
        service.checkScheduledFullCheck(now: overdue)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(try db.search(SearchRequest(text: "scheduled")).total, 0)
        settings.fullCheckInterval = .daily
        let checked = expectation(description: "Scheduled full check completes")
        let scheduled = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in checked.fulfill() }
        service.checkScheduledFullCheck(now: overdue)
        XCTAssertEqual(service.phase, .reconciling)
        service.checkScheduledFullCheck(now: overdue)
        await fulfillment(of: [checked], timeout: 15)
        withExtendedLifetime(scheduled) {}
        XCTAssertEqual(try db.search(SearchRequest(text: "scheduled")).total, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "existing")).entries.first?.id, existingID)
        XCTAssertEqual(settings.lastFullRebuildDate, rebuildDate)
        let updated = try XCTUnwrap(IndexCheckpoint.load(databasePath: db.path))
        XCTAssertGreaterThan(updated.scannedAt, baseline.scannedAt)
        XCTAssertEqual(updated.databaseIdentity, baseline.databaseIdentity)
        XCTAssertFalse(service.live)
        service.setIndexingEnabled(false)
        service.checkScheduledFullCheck(now: overdue)
        XCTAssertEqual(service.phase, .idle)
    }

    @MainActor
    func testOverdueSchedulePerformsFullCheckAtStartup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.startupDelay = 0
        settings.liveUpdates = false
        settings.fullCheckInterval = .daily
        let db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
        try FilesystemIndexer(db: db, config: IndexConfig(roots: [root.path])).run()
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        let old = Date().addingTimeInterval(-2 * 86400)
        let checkpoint = IndexCheckpoint(databasePath: db.path, config: service.makeConfig(), now: old)
        try checkpoint.save(databasePath: db.path)
        XCTAssertTrue(checkpoint.isValid(databasePath: db.path, config: service.makeConfig()))
        try Data([1]).write(to: root.appendingPathComponent("offline.txt"))
        let finished = expectation(description: "Overdue startup check completes")
        let subscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [finished], timeout: 15)
        withExtendedLifetime(subscription) {}
        XCTAssertGreaterThan(try XCTUnwrap(IndexCheckpoint.load(databasePath: db.path)).scannedAt, old)
        XCTAssertEqual(try db.search(SearchRequest(text: "offline")).total, 1)
        XCTAssertNil(settings.lastFullRebuildDate)
    }

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

    @MainActor
    func testStartIndexingNowSkipsRunningAndFrozenCountdowns() async throws {
        for frozen in [false, true] {
            let suite = "EverywhereTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("everywhere-start-now-\(UUID())", isDirectory: true)
            defaults.set(directory.appendingPathComponent("index.sqlite").path, forKey: "IndexDatabasePath")
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = IndexSettings(defaults: defaults)
            settings.liveUpdates = false
            settings.roots = [directory.path]
            let database = try Database(path: settings.indexPath)
            try TestTree(db: database).add(path: "/notes/todo.txt")
            let service = IndexService(settings: settings, database: database)
            defer { service.setIndexingEnabled(false) }
            service.startIfNeeded()
            XCTAssertEqual(service.phase, .waiting)
            XCTAssertGreaterThan(service.countdownSeconds, 0)
            if frozen { service.togglePause() }
            let finished = expectation(description: "Catch-up finishes")
            let subscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
            service.startIndexingNow()
            await fulfillment(of: [finished], timeout: 10)
            withExtendedLifetime(subscription) {}
            XCTAssertFalse(service.isPaused)
            XCTAssertEqual(service.phase, .idle)
        }
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
        let checkpoint = IndexCheckpoint(databasePath: db.path, config: original)
        settings.builtInExcludedFolders.removeAll { $0 == "/System/Volumes" }
        settings.builtInExcludedDirectoryNames.removeAll { $0 == ".Trash" }
        let changed = service.makeConfig()
        XCTAssertFalse(changed.ignores(path: "/System/Volumes/Preboot/photo.heic"))
        XCTAssertFalse(changed.ignores(path: "/Users/example/.Trash/photo.heic"))
        XCTAssertTrue(changed.ignores(path: "/dev/disk0"))
        XCTAssertFalse(checkpoint.isValid(databasePath: db.path, config: changed))
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
    func testStaleBuiltInExclusionsGainNewDefaultsOnce() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-builtin-migration-\(UUID())")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(["/dev", "/.Spotlight-V100", "/.DocumentRevisions-V100", "/.Trashes", "/.fseventsd"],
                     forKey: "IndexBuiltInExcludedFolders")
        defaults.set([".Spotlight-V100"], forKey: "IndexBuiltInExcludedDirectoryNames")
        let settings = IndexSettings(defaults: defaults)
        settings.roots = ["/"]
        XCTAssertTrue(settings.builtInExcludedFolders.contains("/System/Volumes"))
        XCTAssertTrue(settings.builtInExcludedFolders.contains("/private/tmp"))
        XCTAssertTrue(settings.builtInExcludedFolders.contains("/private/var/folders"))
        XCTAssertTrue(settings.builtInExcludedDirectoryNames.contains(".Trash"))
        let db = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        let service = IndexService(settings: settings, database: db)
        XCTAssertTrue(service.makeConfig().ignores(path: "/System/Volumes/Data/Users/example/notes.txt"))
        XCTAssertTrue(service.makeConfig().ignores(path: "/private/tmp/scratch"))
        settings.builtInExcludedFolders.removeAll { $0 == "/System/Volumes" }
        let restored = IndexSettings(defaults: defaults)
        XCTAssertFalse(restored.builtInExcludedFolders.contains("/System/Volumes"))
        XCTAssertTrue(restored.builtInExcludedFolders.contains("/private/tmp"))
    }

    @MainActor
    func testRebuildSuggestionFollowsRebuildAgeAndDismissal() async throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-rebuild-hint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("note.txt"))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(root.appendingPathComponent("index.sqlite").path, forKey: "IndexDatabasePath")
        let settings = IndexSettings(defaults: defaults)
        settings.liveUpdates = false
        settings.startupDelay = 0
        settings.startupDelayUnit = .seconds
        settings.roots = [root.path]
        let db = try Database(path: root.appendingPathComponent("storage/index.sqlite").path)
        let rootID = try db.ensureRootRow(path: root.path)
        try db.insert(rows: [IndexRow(id: db.allocateIDs(1), parent: rootID, name: "note.txt", isDir: false, size: 4, modified: 1)])
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }

        let startup = expectation(description: "Startup scan finishes")
        let startupSubscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in startup.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [startup], timeout: 30)
        withExtendedLifetime(startupSubscription) {}
        XCTAssertNil(settings.lastFullRebuildDate)
        service.updateRebuildSuggestion()
        XCTAssertTrue(service.showsRebuildSuggestion)

        let finished = expectation(description: "Rebuild finishes")
        let subscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
        service.rebuild()
        await fulfillment(of: [finished], timeout: 30)
        withExtendedLifetime(subscription) {}
        XCTAssertNotNil(settings.lastFullRebuildDate)
        XCTAssertFalse(service.showsRebuildSuggestion)

        settings.noteFullRebuild(Date().addingTimeInterval(-IndexService.rebuildRecommendationInterval - 3600))
        service.updateRebuildSuggestion()
        XCTAssertTrue(service.showsRebuildSuggestion)

        service.dismissRebuildSuggestion()
        XCTAssertFalse(service.showsRebuildSuggestion)
        service.updateRebuildSuggestion()
        XCTAssertFalse(service.showsRebuildSuggestion)
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
        XCTAssertEqual(Set(updated.volumeCursors.keys), Set(baseline.volumeCursors.keys))
        for (volume, cursor) in baseline.volumeCursors {
            XCTAssertGreaterThanOrEqual(updated.volumeCursors[volume]?.eventID ?? 0, cursor.eventID)
        }
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
        XCTAssertGreaterThanOrEqual(service.progressStats.scannedItems, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "example")).total, 1)
    }
}
