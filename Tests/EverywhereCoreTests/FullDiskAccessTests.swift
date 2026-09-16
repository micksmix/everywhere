import Combine
import Darwin
import XCTest
@testable import EverywhereCore

final class FullDiskAccessTests: XCTestCase {
    func testProbeDistinguishesRestrictionsFromMissingFilesAndUnixPermissions() {
        XCTAssertEqual(FullDiskAccess.probe(paths: ["test"], openFile: { _ in EPERM }), .denied)
        for error in [ENOENT, EACCES, EIO, ENOTDIR] {
            XCTAssertEqual(FullDiskAccess.probe(paths: ["test"], openFile: { _ in error }), .unknown)
        }
        XCTAssertEqual(FullDiskAccess.probe(paths: ["denied", "allowed"], openFile: {
            $0 == "denied" ? EPERM : 0
        }), .accessible)
        XCTAssertEqual(FullDiskAccess.probe(paths: ["missing", "denied"], openFile: {
            $0 == "missing" ? ENOENT : EPERM
        }), .denied)
    }

    @MainActor
    func testLaunchPromptOnlyForEmptyIndexWithDeniedAccess() async throws {
        for populated in [false, true] {
            for status in [FullDiskAccessStatus.accessible, .denied, .unknown] {
                let fixture = try AccessFixture()
                defer { fixture.cleanUp() }
                fixture.settings.roots = []
                fixture.settings.indexingEnabled = false
                if populated { try TestTree(db: fixture.database).add(path: "/saved.txt") }
                let check = AccessProbe(status)
                let service = IndexService(settings: fixture.settings, database: fixture.database, accessCheck: { check.check() })
                defer { service.setIndexingEnabled(false) }
                let checked = expectation(description: "Launch access resolved")
                let subscription = service.$launchAccessState.filter { $0 == .ready || $0 == .needsAccess }.prefix(1).sink { _ in checked.fulfill() }
                service.startIfNeeded()
                await fulfillment(of: [checked], timeout: 5)
                withExtendedLifetime(subscription) {}
                XCTAssertEqual(service.showsLaunchAccessPrompt, !populated && status == .denied)
                XCTAssertEqual(check.calls, populated ? 0 : 1)
                XCTAssertEqual(service.phase, .idle)
            }
        }
    }

    @MainActor
    func testPermissionPromptPrecedesLocationSetupAndRechecksWithoutStartingScan() async throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.settings.needsLocationSetup)
        let check = AccessProbe(.denied)
        let service = IndexService(settings: fixture.settings, database: fixture.database, accessCheck: { check.check() })
        defer { service.setIndexingEnabled(false) }
        let denied = expectation(description: "Prompt before choosing locations")
        let subscription = service.$launchAccessState.filter { $0 == .needsAccess }.prefix(1).sink { _ in denied.fulfill() }
        service.startIfNeeded()
        service.rebuild()
        await fulfillment(of: [denied], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertTrue(service.showsLaunchAccessPrompt)
        service.rebuild()
        service.setLive(true)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertFalse(service.live)
        XCTAssertEqual(try fixture.database.count(), 0)
        check.setStatus(.accessible)
        let granted = expectation(description: "Access granted on retry")
        let retrySubscription = service.$launchAccessState.filter { $0 == .ready }.prefix(1).sink { _ in granted.fulfill() }
        service.checkLaunchAccess()
        await fulfillment(of: [granted], timeout: 5)
        withExtendedLifetime(retrySubscription) {}
        XCTAssertFalse(service.showsLaunchAccessPrompt)
        XCTAssertTrue(fixture.settings.needsLocationSetup)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(try fixture.database.count(), 0)
    }

    @MainActor
    func testLimitedAccessStartsIndexingAndDoesNotPromptAgainThisLaunch() async throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanUp() }
        let root = fixture.directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("example.txt"))
        fixture.settings.roots = [root.path]
        fixture.settings.liveUpdates = false
        let check = AccessProbe(.denied)
        let service = IndexService(settings: fixture.settings, database: fixture.database, accessCheck: { check.check() })
        defer { service.setIndexingEnabled(false) }
        let denied = expectation(description: "Access denied")
        let subscription = service.$launchAccessState.filter { $0 == .needsAccess }.prefix(1).sink { _ in denied.fulfill() }
        service.startIfNeeded()
        await fulfillment(of: [denied], timeout: 5)
        withExtendedLifetime(subscription) {}
        service.rebuild()
        service.setLive(true)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(try fixture.database.count(), 0)
        let finished = expectation(description: "Limited scan completes")
        let scanSubscription = service.$phase.dropFirst().filter { $0 == .idle }.prefix(1).sink { _ in finished.fulfill() }
        service.continueWithLimitedAccess()
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(scanSubscription) {}
        XCTAssertFalse(service.showsLaunchAccessPrompt)
        XCTAssertEqual(try fixture.database.search(SearchRequest(text: "example")).total, 1)
        service.startIfNeeded()
        service.checkLaunchAccess()
        XCTAssertEqual(check.calls, 1)
    }
}

private final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var status: FullDiskAccessStatus
    private var count = 0

    init(_ status: FullDiskAccessStatus) { self.status = status }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func setStatus(_ status: FullDiskAccessStatus) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
    }

    func check() -> FullDiskAccessStatus {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return status
    }
}

private final class AccessFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everywhere-access-\(UUID())")
    let suite = "EverywhereTests.\(UUID())"
    let defaults: UserDefaults
    let settings: IndexSettings
    let database: Database

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(directory.appendingPathComponent("storage/index.sqlite").path, forKey: "IndexDatabasePath")
        settings = IndexSettings(defaults: defaults)
        database = try Database(path: settings.indexPath)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
