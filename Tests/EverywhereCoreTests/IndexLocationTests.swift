import Combine
import CoreServices
import XCTest
@testable import EverywhereCore

final class IndexLocationTests: XCTestCase {
    private func mount(_ path: String, device: Int32, identity: String, kind: IndexLocationKind = .local) -> IndexedVolume.Mount {
        .init(path: path, device: device, mappings: [.init(relativePath: "", absolutePath: path)], identity: identity, kind: kind)
    }

    private func resolve(_ locations: [IndexLocation], bindings: [IndexLocationBinding] = [], mounts: [IndexedVolume.Mount],
                         absent: Set<String> = [], config: IndexConfig? = nil) -> IndexLocationResolution {
        IndexLocationResolver.resolve(locations: locations, bindings: bindings,
            config: config ?? IndexConfig(roots: locations.map(\.path)), mounts: mounts,
            isDirectory: { !absent.contains($0) }, deviceForPath: { path in
                mounts.filter { IndexedVolume.contains($0.path, path) }.max { $0.path.count < $1.path.count }?.device
            })
    }

    func testClassificationOverrideAndDefaultRetention() {
        let location = IndexLocation(path: "/Volumes/Work/projects/")
        let disk = mount("/Volumes/Work", device: 2, identity: "uuid:work", kind: .removable)
        let first = resolve([location], mounts: [disk])
        XCTAssertEqual(first.locations.first?.path, "/Volumes/Work/projects")
        XCTAssertEqual(first.locations.first?.kind, .removable)
        XCTAssertEqual(first.statuses.first?.isAvailable, true)
        XCTAssertEqual(first.statuses.first?.keepIndexWhenUnavailable, true)
        var overridden = first.locations[0]
        overridden.kindOverride = .network
        let second = resolve([overridden], bindings: first.bindings, mounts: [disk])
        XCTAssertEqual(second.statuses.first?.kind, .network)
        XCTAssertEqual(second.locations.first?.detectedKind, .removable)
        XCTAssertEqual(second.bindings.first?.id, first.bindings.first?.id)
    }

    func testUnavailableLocationRetainsIdentityAndCanDisableRetention() {
        let location = IndexLocation(path: "/Volumes/Work/projects")
        let first = resolve([location], mounts: [mount("/Volumes/Work", device: 2, identity: "uuid:work", kind: .removable)])
        let offline = resolve(first.locations, bindings: first.bindings, mounts: [mount("/", device: 1, identity: "uuid:local")])
        XCTAssertFalse(offline.statuses[0].isAvailable)
        XCTAssertEqual(offline.statuses[0].kind, .removable)
        XCTAssertEqual(offline.bindings, first.bindings)
        XCTAssertTrue(offline.hasRetainedUnavailableLocations)
        XCTAssertTrue(offline.unavailablePathsToRemove.isEmpty)
        var withoutRetention = first.locations[0]
        withoutRetention.keepIndexWhenUnavailable = false
        let discarded = resolve([withoutRetention], bindings: first.bindings, mounts: [])
        XCTAssertEqual(discarded.unavailablePathsToRemove, [location.path])
        XCTAssertFalse(discarded.hasRetainedUnavailableLocations)
    }

    func testDifferentVolumeAtSamePathCannotAcquireCachedIndex() {
        let location = IndexLocation(path: "/Volumes/Work")
        let first = resolve([location], mounts: [mount(location.path, device: 2, identity: "uuid:first")])
        let replacement = resolve(first.locations, bindings: first.bindings,
            mounts: [mount(location.path, device: 3, identity: "uuid:replacement")])
        XCTAssertFalse(replacement.statuses[0].isAvailable)
        XCTAssertEqual(replacement.bindings[0].volumeIdentity, "uuid:first")
        XCTAssertTrue(replacement.relocations.isEmpty)
    }

    func testReturningVolumeAtNewMountPathKeepsLocationAndBindingIDs() {
        let location = IndexLocation(path: "/Volumes/Work/projects")
        let first = resolve([location], mounts: [mount("/Volumes/Work", device: 2, identity: "uuid:work")])
        let returned = resolve(first.locations, bindings: first.bindings,
            mounts: [mount("/", device: 1, identity: "uuid:local"), mount("/Volumes/Work 1", device: 9, identity: "uuid:work")])
        XCTAssertEqual(returned.locations[0].path, "/Volumes/Work 1/projects")
        XCTAssertEqual(returned.locations[0].id, location.id)
        XCTAssertEqual(returned.bindings[0].id, first.bindings[0].id)
        XCTAssertEqual(returned.relocations, [.init(from: location.path, to: "/Volumes/Work 1/projects")])
        XCTAssertTrue(returned.statuses[0].isAvailable)
        XCTAssertTrue(returned.access.contains { $0.path == location.path && !$0.isAvailable })
    }

    func testAmbiguousIdentityAndMissingSubfolderDoNotRelocate() {
        let location = IndexLocation(path: "/Volumes/Work/projects")
        let first = resolve([location], mounts: [mount("/Volumes/Work", device: 2, identity: "uuid:work")])
        let ambiguous = resolve(first.locations, bindings: first.bindings,
            mounts: [mount("/Volumes/A", device: 3, identity: "uuid:work"), mount("/Volumes/B", device: 4, identity: "uuid:work")])
        XCTAssertFalse(ambiguous.statuses[0].isAvailable)
        XCTAssertTrue(ambiguous.relocations.isEmpty)
        let missing = resolve(first.locations, bindings: first.bindings,
            mounts: [mount("/Volumes/A", device: 3, identity: "uuid:work")], absent: ["/Volumes/A/projects"])
        XCTAssertFalse(missing.statuses[0].isAvailable)
        XCTAssertTrue(missing.relocations.isEmpty)
    }

    func testWholeDiskTracksNestedOfflineAndReplacementVolumesIndependently() {
        let local = mount("/", device: 1, identity: "uuid:local")
        let work = mount("/Volumes/Work", device: 2, identity: "uuid:work", kind: .network)
        let first = resolve([IndexLocation(path: "/")], mounts: [local, work])
        XCTAssertEqual(first.statuses.count, 2)
        XCTAssertEqual(first.statuses.first?.path, work.path)
        XCTAssertEqual(first.statuses.first?.kind, .network)
        let offline = resolve(first.locations, bindings: first.bindings, mounts: [local])
        XCTAssertEqual(offline.statuses.first?.isAvailable, false)
        XCTAssertEqual(offline.statuses.last?.isAvailable, true)
        let replaced = resolve(first.locations, bindings: first.bindings,
            mounts: [local, mount(work.path, device: 3, identity: "uuid:other")])
        XCTAssertEqual(replaced.statuses.count, 2)
        XCTAssertFalse(replaced.statuses[0].isAvailable)
        XCTAssertEqual(replaced.bindings.first(where: { !$0.isConfiguredRoot })?.volumeIdentity, "uuid:work")
    }

    func testNestedVolumeRelocationAndExclusionsPreserveCorrectBindings() {
        let local = mount("/", device: 1, identity: "uuid:local")
        let first = resolve([IndexLocation(path: "/")], mounts: [local, mount("/Volumes/Work", device: 2, identity: "uuid:work")])
        let returned = resolve(first.locations, bindings: first.bindings,
            mounts: [local, mount("/Volumes/Renamed", device: 3, identity: "uuid:work")])
        XCTAssertEqual(returned.relocations, [.init(from: "/Volumes/Work", to: "/Volumes/Renamed")])
        XCTAssertEqual(returned.bindings.first(where: { !$0.isConfiguredRoot })?.id,
                       first.bindings.first(where: { !$0.isConfiguredRoot })?.id)
        let excluded = resolve(first.locations, bindings: first.bindings, mounts: [local],
                               config: IndexConfig(roots: ["/"], skipPathPrefixes: ["/Volumes/Work"]))
        XCTAssertEqual(excluded.statuses.count, 1)
        XCTAssertFalse(excluded.hasRetainedUnavailableLocations)
    }

    func testAmbiguousReturningImplicitMountDoesNotReuseBindingIDOrRelocate() {
        let local = mount("/", device: 1, identity: "uuid:local")
        let first = resolve([IndexLocation(path: "/")], mounts: [local, mount("/Volumes/Work", device: 2, identity: "uuid:work")])
        let returned = resolve(first.locations, bindings: first.bindings, mounts: [local,
            mount("/Volumes/A", device: 3, identity: "uuid:work"), mount("/Volumes/B", device: 4, identity: "uuid:work")])
        XCTAssertTrue(returned.relocations.isEmpty)
        XCTAssertEqual(Set(returned.statuses.map(\.id)).count, returned.statuses.count)
        XCTAssertEqual(returned.statuses.first(where: { $0.path == "/Volumes/Work" })?.isAvailable, false)
        XCTAssertTrue(returned.access.contains { $0.path == "/Volumes/A" && !$0.isAvailable })
        XCTAssertTrue(returned.access.contains { $0.path == "/Volumes/B" && !$0.isAvailable })
    }

    func testMoreSpecificLocationOwnsClassificationAndRetention() {
        let local = mount("/", device: 1, identity: "uuid:local")
        let work = mount("/Volumes/Work", device: 2, identity: "uuid:work", kind: .removable)
        let locations = [IndexLocation(path: "/"), IndexLocation(path: work.path, kindOverride: .network, keepIndexWhenUnavailable: false)]
        let first = resolve(locations, mounts: [local, work])
        XCTAssertEqual(first.statuses.count, 2)
        XCTAssertEqual(first.statuses[0].kind, .network)
        XCTAssertFalse(first.statuses[0].keepIndexWhenUnavailable)
        let offline = resolve(first.locations, bindings: first.bindings, mounts: [local])
        XCTAssertEqual(offline.unavailablePathsToRemove, [work.path])
        XCTAssertEqual(offline.statuses.last?.isAvailable, true)
    }

    func testExplicitChildOfWholeDiskAdoptsKnownOfflineIdentityWithoutDuplicateStatus() {
        let local = mount("/", device: 1, identity: "uuid:local")
        let work = mount("/Volumes/Work", device: 2, identity: "uuid:work", kind: .removable)
        let first = resolve([IndexLocation(path: "/")], mounts: [local, work])
        let child = IndexLocation(path: work.path)
        let offline = resolve(first.locations + [child], bindings: first.bindings, mounts: [local])
        XCTAssertEqual(offline.statuses.count, 2)
        XCTAssertEqual(offline.statuses[0].id, child.id)
        XCTAssertEqual(offline.statuses[0].kind, .removable)
        XCTAssertFalse(offline.statuses[0].isAvailable)
        XCTAssertEqual(offline.bindings.first(where: { $0.rootID == child.id })?.volumeIdentity, "uuid:work")
    }

    func testNetworkShareIdentityDoesNotPersistCredentialsAndSeparatesExports() {
        XCTAssertEqual(IndexedVolume.networkIdentity(fileSystem: "smbfs", source: "//alice:secret@SERVER/Team"), "share:smbfs:server/Team")
        XCTAssertEqual(IndexedVolume.networkIdentity(fileSystem: "smbfs", source: "//bob@server/Team"), "share:smbfs:server/Team")
        XCTAssertNotEqual(IndexedVolume.networkIdentity(fileSystem: "smbfs", source: "//server/Team"),
                          IndexedVolume.networkIdentity(fileSystem: "smbfs", source: "//server/Other"))
        XCTAssertEqual(IndexedVolume.networkIdentity(fileSystem: "nfs", source: "server:/export/work"), "share:nfs:server:export/work")
    }

    func testSettingsMigrateLegacyRootsAndPersistOverridesBindingsAndRetention() throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/Volumes/Work/", "/Volumes/Work"], forKey: "IndexRoots")
        let settings = IndexSettings(defaults: defaults)
        XCTAssertEqual(settings.locations.count, 1)
        XCTAssertTrue(settings.locations[0].keepIndexWhenUnavailable)
        let resolved = resolve(settings.locations, mounts: [mount("/Volumes/Work", device: 2, identity: "uuid:work", kind: .removable)])
        settings.applyLocationResolution(resolved)
        settings.setLocationKind(.network, for: "/Volumes/Work")
        settings.setKeepIndexWhenUnavailable(false, for: "/Volumes/Work")
        let loaded = IndexSettings(defaults: defaults)
        XCTAssertEqual(loaded.locations[0].id, settings.locations[0].id)
        XCTAssertEqual(loaded.locations[0].kind, .network)
        XCTAssertFalse(loaded.locations[0].keepIndexWhenUnavailable)
        XCTAssertEqual(loaded.locationBindings, settings.locationBindings)
        loaded.setLocationKind(nil, for: "/Volumes/Work")
        XCTAssertEqual(loaded.locations[0].kind, .removable)
        loaded.roots = []
        XCTAssertTrue(loaded.locationBindings.isEmpty)
        XCTAssertEqual(loaded.retiredLocationPaths, ["/Volumes/Work"])
    }

    func testAccessGuardRejectsReplacedDeviceAndMissingRoot() {
        let guardValue = IndexLocationAccess(path: "/Volumes/Work", device: 2, isAvailable: true)
        XCTAssertTrue(guardValue.permits("/Volumes/Work/file", deviceForPath: { _ in 2 }, isDirectory: { _ in true }))
        XCTAssertFalse(guardValue.permits("/Volumes/Work/file", deviceForPath: { _ in 3 }, isDirectory: { _ in true }))
        XCTAssertFalse(guardValue.permits("/Volumes/Work/file", deviceForPath: { _ in 2 }, isDirectory: { _ in false }))
        var bound = guardValue
        bound.identity = "journal:expected"
        XCTAssertTrue(bound.permits("/Volumes/Work/file", deviceForPath: { _ in 2 }, isDirectory: { _ in true },
                                   identityForPath: { _ in "journal:expected" }))
        XCTAssertFalse(bound.permits("/Volumes/Work/file", deviceForPath: { _ in 2 }, isDirectory: { _ in true },
                                    identityForPath: { _ in "journal:replacement" }))
    }
}

final class OfflineIndexRegressionTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var db: Database!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-locations-\(UUID())", isDirectory: true)
        root = directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("db/index.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testReconcilerPreservesUnavailableRootAndMissingNestedMount() throws {
        let tree = TestTree(db: db, rootPath: root.path)
        let offline = root.appendingPathComponent("mount")
        let cached = offline.appendingPathComponent("cached.txt")
        let cachedID = try tree.add(path: cached.path)
        var config = IndexConfig(roots: [root.path])
        config.locationAccess = [.init(path: offline.path, device: nil, isAvailable: false)]
        try Reconciler(db: db, config: config, roots: config.roots, skipUnchangedDirs: false).run()
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
        config.locationAccess = [.init(path: root.path, device: nil, isAvailable: false)]
        try FileManager.default.removeItem(at: root)
        try Reconciler(db: db, config: config, roots: config.roots, skipUnchangedDirs: false).run()
        try FileChangeReconciler(db: db, config: config).run(paths: [cached.path], isCancelled: { false })
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
    }

    func testMissingAncestorOfOfflineMountKeepsCachedSubtree() throws {
        let tree = TestTree(db: db, rootPath: root.path)
        let mountPath = root.appendingPathComponent("missing/mount").path
        let cachedID = try tree.add(path: mountPath + "/cached.txt")
        var config = IndexConfig(roots: [root.path])
        config.locationAccess = [.init(path: mountPath, device: nil, isAvailable: false)]
        try Reconciler(db: db, config: config, roots: config.roots, skipUnchangedDirs: false).run()
        try FileChangeReconciler(db: db, config: config).run(paths: [root.path + "/missing"], isCancelled: { false })
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
    }

    func testUnexpectedDisconnectThrowsWithoutPruningAndNeverCommitsCursor() throws {
        let tree = TestTree(db: db, rootPath: root.path)
        let cachedID = try tree.add(path: root.path + "/cached.txt")
        let actual = try XCTUnwrap(IndexedVolume.device(containing: root.path))
        var config = IndexConfig(roots: [root.path])
        config.locationAccess = [.init(path: root.path, device: actual &+ 1, isAvailable: true)]
        XCTAssertThrowsError(try Reconciler(db: db, config: config, roots: config.roots, skipUnchangedDirs: false).run())
        let failed = expectation(description: "Disconnected device cannot reconcile")
        let committed = expectation(description: "Cursor must not commit")
        committed.isInverted = true
        let handler = ChangeHandler(db: db, config: config, debounce: 60, onCommit: { _, _, _ in committed.fulfill() },
                                    onError: { _ in failed.fulfill() })
        handler.ingest(events: [FileSystemEvent(path: root.path, id: 42, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)),
                                FileSystemEvent(path: "", id: 43, flags: UInt32(kFSEventStreamEventFlagHistoryDone))])
        handler.flushPendingNow()
        wait(for: [failed, committed], timeout: 0.5)
        handler.stop()
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
    }

    func testPreservingClearKeepsAncestorAndDescendantIDsAndRefreshesMemory() throws {
        let tree = TestTree(db: db, rootPath: root.path)
        let retained = root.path + "/parent/mount"
        let cachedID = try tree.add(path: retained + "/cached.txt")
        let parentID = try XCTUnwrap(tree.id(for: root.path + "/parent"))
        let mountID = try XCTUnwrap(tree.id(for: retained))
        try tree.add(path: root.path + "/parent/unrelated.txt")
        try tree.add(path: root.path + "/other/removed.txt")
        XCTAssertEqual(try db.search(SearchRequest(text: "cached"), useMemory: true).total, 1)
        try db.clear(preservingSubtreesAt: [retained], roots: [root.path])
        XCTAssertEqual(try db.search(SearchRequest(text: "cached"), useMemory: true).entries.first?.id, cachedID)
        XCTAssertEqual(try db.search(SearchRequest(text: "removed | unrelated"), useMemory: true).total, 0)
        XCTAssertEqual(try db.child(ofParent: parentID, name: "mount")?.id, mountID)
        XCTAssertEqual(try db.count(), 4)
    }

    func testRelocatingConfiguredRootPreservesIDsPathsAndMemoryThenRemovesIt() throws {
        let old = "/Volumes/Old"
        let new = "/Volumes/New"
        let tree = TestTree(db: db, rootPath: old)
        let cachedID = try tree.add(path: old + "/folder/cached.txt")
        XCTAssertEqual(try db.search(SearchRequest(text: "cached"), useMemory: true).entries.first?.path, old + "/folder/cached.txt")
        XCTAssertTrue(try db.relocateIndexedSubtree(from: old, to: new, roots: [old, new]))
        let moved = try XCTUnwrap(db.search(SearchRequest(text: "cached"), useMemory: true).entries.first)
        XCTAssertEqual(moved.id, cachedID)
        XCTAssertEqual(moved.path, new + "/folder/cached.txt")
        XCTAssertTrue(try db.removeIndexedSubtree(path: new, roots: [new]))
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).total, 0)
        XCTAssertEqual(try db.count(), 0)
    }

    func testNestedMountRelocationRejectsCollisionAndCyclesWithoutLosingRows() throws {
        let tree = TestTree(db: db)
        let cachedID = try tree.add(path: "/Volumes/Old/folder/cached.txt")
        try tree.add(path: "/Volumes/Occupied/other.txt")
        XCTAssertThrowsError(try db.relocateIndexedSubtree(from: "/Volumes/Old", to: "/Volumes/Occupied", roots: ["/"]))
        XCTAssertThrowsError(try db.relocateIndexedSubtree(from: "/Volumes/Old", to: "/Volumes/Old/child", roots: ["/"]))
        XCTAssertTrue(try db.relocateIndexedSubtree(from: "/Volumes/Old", to: "/Volumes/New", roots: ["/"]))
        let moved = try XCTUnwrap(db.search(SearchRequest(text: "cached")).entries.first)
        XCTAssertEqual(moved.id, cachedID)
        XCTAssertEqual(moved.path, "/Volumes/New/folder/cached.txt")
        XCTAssertTrue(try db.removeIndexedSubtree(path: "/Volumes/New", roots: ["/"]))
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "other")).total, 1)
    }

    @MainActor
    func testRebuildRetainsOfflineCacheAndDisablingRetentionRemovesIt() async throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.liveUpdates = false
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        try Data([1]).write(to: root.appendingPathComponent("cached.txt"))
        let initial = expectation(description: "Initial scan")
        let first = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in initial.fulfill() }
        service.rebuild()
        await fulfillment(of: [initial], timeout: 15)
        let cachedID = try XCTUnwrap(db.search(SearchRequest(text: "cached")).entries.first?.id)
        try FileManager.default.removeItem(at: root)
        let retained = expectation(description: "Offline rebuild")
        let second = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in retained.fulfill() }
        service.rebuild()
        await fulfillment(of: [retained], timeout: 15)
        XCTAssertFalse(service.isAvailable(path: root.path + "/cached.txt"))
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
        settings.setKeepIndexWhenUnavailable(false, for: root.path)
        let removed = expectation(description: "Offline retention disabled")
        let third = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in removed.fulfill() }
        service.rebuild()
        await fulfillment(of: [removed], timeout: 15)
        XCTAssertEqual(try db.count(), 0)
        withExtendedLifetime((first, second, third)) {}
    }

    @MainActor
    func testRetentionEditDuringPausedPreparationCancelsStalePurgeAndPreservesPause() async throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.liveUpdates = false
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        try Data([1]).write(to: root.appendingPathComponent("cached.txt"))
        let initial = expectation(description: "Initial scan")
        let first = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in initial.fulfill() }
        service.rebuild()
        await fulfillment(of: [initial], timeout: 15)
        let cachedID = try XCTUnwrap(db.search(SearchRequest(text: "cached")).entries.first?.id)
        settings.setKeepIndexWhenUnavailable(false, for: root.path)
        try FileManager.default.removeItem(at: root)
        let probing = expectation(description: "Preparation is probing mounts")
        let inventory = BlockingLocationInventory(mounts: IndexedVolume.mountedVolumes()) { probing.fulfill() }
        defer { inventory.resume() }
        service.mountedVolumesProvider = { inventory.read() }
        service.rebuild()
        await fulfillment(of: [probing], timeout: 15)
        service.togglePause()
        let replacement = expectation(description: "Replacement control starts paused")
        let second = service.$phase.dropFirst().filter { $0 == .indexing }.prefix(1).sink { _ in replacement.fulfill() }
        settings.setKeepIndexWhenUnavailable(true, for: root.path)
        await fulfillment(of: [replacement], timeout: 15)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
        inventory.resume()
        let complete = expectation(description: "Replacement keeps the offline cache")
        let third = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in complete.fulfill() }
        service.togglePause()
        await fulfillment(of: [complete], timeout: 15)
        XCTAssertEqual(settings.location(for: root.path)?.keepIndexWhenUnavailable, true)
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
        withExtendedLifetime((first, second, third)) {}
    }

    @MainActor
    func testBulkRebuildNormalizesAvailableChildUnderUnavailableNonretainedParent() async throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data([1]).write(to: child.appendingPathComponent("cached.txt"))
        try Data([2]).write(to: root.appendingPathComponent("outside.txt"))
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path, child.path]
        settings.liveUpdates = false
        settings.setKeepIndexWhenUnavailable(false, for: root.path)
        var seed = IndexLocationResolver.resolve(locations: settings.locations, bindings: [],
            config: IndexConfig(roots: settings.roots), mounts: IndexedVolume.mountedVolumes())
        let parentID = try XCTUnwrap(settings.location(for: root.path)?.id)
        let parentIndex = try XCTUnwrap(seed.bindings.firstIndex { $0.rootID == parentID && $0.isConfiguredRoot })
        seed.bindings[parentIndex].volumeIdentity = "uuid:disconnected-parent"
        settings.applyLocationResolution(seed)
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        let complete = expectation(description: "Child scan finishes")
        let token = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in complete.fulfill() }
        service.rebuild()
        await fulfillment(of: [complete], timeout: 15)
        XCTAssertFalse(service.isAvailable(path: root.path))
        XCTAssertTrue(service.isAvailable(path: child.path))
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).total, 1)
        XCTAssertEqual(try db.search(SearchRequest(text: "outside")).total, 0)
        XCTAssertEqual(try db.indexedDirectoryAncestor(path: child.path, roots: settings.roots)?.path, child.path)
        try Data([3]).write(to: child.appendingPathComponent("new.txt"))
        try Reconciler(db: db, config: service.makeConfig().preparingFilesystemPaths(), roots: [child.path], skipUnchangedDirs: false).run()
        XCTAssertEqual(try db.search(SearchRequest(text: "new")).total, 1)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testPausedScanStillPublishesOfflineAvailabilityWithoutReplacingJob() async throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.liveUpdates = false
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        try Data([1]).write(to: root.appendingPathComponent("cached.txt"))
        let initial = expectation(description: "Initial scan")
        let first = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in initial.fulfill() }
        service.rebuild()
        await fulfillment(of: [initial], timeout: 15)
        service.rebuild()
        service.togglePause()
        XCTAssertTrue(service.isPaused)
        try FileManager.default.removeItem(at: root)
        let offline = expectation(description: "Paused job still updates availability")
        let second = service.$locationStatuses.filter { statuses in
            statuses.contains { $0.path == self.root.path && !$0.isAvailable }
        }.prefix(1).sink { _ in offline.fulfill() }
        service.refreshLocationAvailability()
        await fulfillment(of: [offline], timeout: 15)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(service.phase, .indexing)
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).total, 1)
        withExtendedLifetime((first, second)) {}
    }

    @MainActor
    func testReconnectWithLiveUpdatesOffReconcilesCachedRowsWithoutRebuilding() async throws {
        let suite = "EverywhereTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IndexSettings(defaults: defaults)
        settings.roots = [root.path]
        settings.startupDelay = 0
        settings.liveUpdates = false
        let service = IndexService(settings: settings, database: db)
        defer { service.setIndexingEnabled(false) }
        try Data([1]).write(to: root.appendingPathComponent("cached.txt"))
        try Data([2]).write(to: root.appendingPathComponent("stale.txt"))
        let initial = expectation(description: "Initial scan")
        let first = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in initial.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [initial], timeout: 15)
        let maintenanceDone = expectation(description: "Initial maintenance completes")
        let maintenance = service.$isCompacting.filter { !$0 }.prefix(1).sink { _ in maintenanceDone.fulfill() }
        await fulfillment(of: [maintenanceDone], timeout: 10)
        withExtendedLifetime(maintenance) {}
        let cachedID = try XCTUnwrap(db.search(SearchRequest(text: "cached")).entries.first?.id)
        let rebuildDate = settings.lastFullRebuildDate
        let holding = directory.appendingPathComponent("holding")
        try FileManager.default.moveItem(at: root, to: holding)
        let offline = expectation(description: "Offline location recognized")
        let second = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in offline.fulfill() }
        service.refreshLocationAvailability()
        await fulfillment(of: [offline], timeout: 15)
        XCTAssertFalse(service.isAvailable(path: root.path + "/cached.txt"))
        try FileManager.default.removeItem(at: holding.appendingPathComponent("stale.txt"))
        try Data([3]).write(to: holding.appendingPathComponent("new.txt"))
        try FileManager.default.moveItem(at: holding, to: root)
        let returned = expectation(description: "Reconnection reconciles")
        let third = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in returned.fulfill() }
        service.refreshLocationAvailability()
        await fulfillment(of: [returned], timeout: 15)
        XCTAssertTrue(service.isAvailable(path: root.path + "/cached.txt"))
        XCTAssertEqual(try db.search(SearchRequest(text: "cached")).entries.first?.id, cachedID)
        XCTAssertEqual(try db.search(SearchRequest(text: "stale")).total, 0)
        XCTAssertEqual(try db.search(SearchRequest(text: "new")).total, 1)
        XCTAssertEqual(settings.lastFullRebuildDate, rebuildDate)
        XCTAssertFalse(service.live)
        withExtendedLifetime((first, second, third)) {}
    }
}

private final class BlockingLocationInventory: @unchecked Sendable {
    private let mounts: [IndexedVolume.Mount]
    private let onStart: @Sendable () -> Void
    private let condition = NSCondition()
    private var started = false
    private var released = false

    init(mounts: [IndexedVolume.Mount], onStart: @escaping @Sendable () -> Void) {
        self.mounts = mounts
        self.onStart = onStart
    }

    func read() -> [IndexedVolume.Mount] {
        condition.lock()
        let notify = !started
        started = true
        condition.unlock()
        if notify { onStart() }
        condition.lock()
        let deadline = Date().addingTimeInterval(20)
        while !released && Date() < deadline { _ = condition.wait(until: deadline) }
        condition.unlock()
        return mounts
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
