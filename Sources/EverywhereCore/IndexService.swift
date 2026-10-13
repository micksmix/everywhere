import Foundation
import Combine
import CoreServices

struct JournalReplayProgress {
    private(set) var pendingVolumes: Set<String>

    init(volumes: [String] = []) {
        pendingVolumes = Set(volumes)
    }

    mutating func finish(volume: String) -> Bool {
        guard pendingVolumes.remove(volume) != nil else { return false }
        return pendingVolumes.isEmpty
    }
}

public final class IndexService: ObservableObject, @unchecked Sendable {
    public enum Phase: Equatable {
        case waiting
        case idle
        case indexing
        case reconciling
        case finalizing
    }

    @Published public private(set) var countdownSeconds = 0
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progressRows = 0
    @Published public private(set) var progressStats = IndexerStats()
    @Published public private(set) var isPaused = false
    @Published public private(set) var indexedRows = 0
    @Published public private(set) var hasLoadedIndexCount = false
    @Published public private(set) var indexCountError: String?
    @Published public private(set) var indexRevision = 0
    @Published public private(set) var live = false
    @Published public private(set) var lastError: String?

    public enum LaunchAccessState: Equatable {
        case unchecked
        case checking
        case needsAccess
        case ready
    }

    @Published public private(set) var launchAccessState: LaunchAccessState
    @Published public private(set) var accessCheckMessage: String?
    @Published public private(set) var showsLaunchAccessPrompt = false
    @Published public private(set) var showsPrivacyHint = false
    @Published public private(set) var showsRebuildSuggestion = false
    private let accessCheck: (@Sendable () -> FullDiskAccessStatus)?
    private var privacyHintDismissed = false
    private var rebuildSuggestionDismissed = false

    public static let rebuildRecommendationInterval: TimeInterval = 30 * 24 * 3600

    public let settings: IndexSettings
    public let database: Database

    private var monitors: [FSEventsMonitor] = []
    private var changeHandlers: [ChangeHandler] = []
    private var monitoredVolumes: [IndexedVolume] = []
    private var replayProgress = JournalReplayProgress()
    private var lastFullCheckDate: Date?
    private var activeControl = IndexingControl()
    private let indexingQueue = DispatchQueue(label: "app.everywhere.indexing", qos: .utility)
    private let changesQueue = DispatchQueue(label: "app.everywhere.volume-changes", qos: .utility)
    private var started = false
    @Published public private(set) var isCompacting = false
    @Published public private(set) var compactionMessage: String?
    private var maintenanceTimer: Timer?
    private var lastMaintenanceCheck: Date?
    private var countdownTimer: Timer?
    private var countdownDeadline: Date?
    private var remainingDelay: TimeInterval = 0

    public init(settings: IndexSettings, database: Database, accessCheck: (@Sendable () -> FullDiskAccessStatus)? = nil) {
        self.settings = settings
        self.database = database
        self.accessCheck = accessCheck
        lastFullCheckDate = IndexCheckpoint.load(databasePath: database.path)?.scannedAt
        launchAccessState = accessCheck == nil ? .ready : .unchecked
    }

    public var isBusy: Bool { phase != .idle }
    public var canPause: Bool { phase == .waiting || phase == .indexing || phase == .reconciling }
    public var canCompactIndex: Bool { !isCompacting && (phase == .idle || phase == .waiting) }

    public func compactIndexNow() {
        guard canCompactIndex else { return }
        isCompacting = true
        compactionMessage = nil
        lastMaintenanceCheck = Date()
        let db = database
        indexingQueue.async { [weak self] in
            let message: String
            do {
                let compacted = try db.compactIfNeeded(minimumFreeBytes: 0, minimumFreeFraction: 0)
                message = compacted ? "Index compaction complete." : "No space reclaimed. The index has no unused pages, or there is insufficient temporary disk space."
            } catch {
                message = "Index compaction failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { [weak self] in
                self?.compactionMessage = message
                self?.isCompacting = false
            }
        }
    }

    public func togglePause() {
        guard canPause else { return }
        if phase == .waiting {
            if isPaused {
                countdownDeadline = Date()
                isPaused = false
                updateCountdown()
            } else {
                remainingDelay = max(0, countdownDeadline?.timeIntervalSinceNow ?? remainingDelay)
                countdownSeconds = Int(ceil(remainingDelay))
                countdownDeadline = nil
                isPaused = true
            }
            return
        }
        if isPaused {
            activeControl.resume()
        } else {
            activeControl.pause()
        }
        isPaused.toggle()
    }

    deinit {
        countdownTimer?.invalidate()
        maintenanceTimer?.invalidate()
        activeControl.cancel()
        monitors.forEach { $0.stop() }
        changeHandlers.forEach { $0.stop() }
    }

    public var indexDirectory: String {
        (database.path as NSString).deletingLastPathComponent
    }

    public func checkLaunchAccess() {
        guard let accessCheck, launchAccessState == .unchecked || launchAccessState == .needsAccess else { return }
        launchAccessState = .checking
        accessCheckMessage = nil
        let db = database
        indexingQueue.async { [weak self] in
            do {
                let count = try db.count()
                let status = count == 0 ? accessCheck() : .accessible
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.indexedRows = count
                    self.hasLoadedIndexCount = true
                    self.showsLaunchAccessPrompt = count == 0 && status == .denied
                    self.launchAccessState = self.showsLaunchAccessPrompt ? .needsAccess : .ready
                    if self.launchAccessState == .needsAccess {
                        self.accessCheckMessage = "Protected file access is still restricted. If you enabled Everywhere, quit and reopen the app to apply the change."
                    } else {
                        self.startIfNeeded()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.indexCountError = "Could not read saved index: \(error)"
                    self.showsLaunchAccessPrompt = false
                    self.launchAccessState = .ready
                    self.startIfNeeded()
                }
            }
        }
    }

    public func continueWithLimitedAccess() {
        guard launchAccessState == .needsAccess else { return }
        showsLaunchAccessPrompt = false
        launchAccessState = .ready
        accessCheckMessage = nil
        startIfNeeded()
    }

    public func dismissPrivacyHint() {
        privacyHintDismissed = true
        showsPrivacyHint = false
    }

    public func dismissRebuildSuggestion() {
        rebuildSuggestionDismissed = true
        showsRebuildSuggestion = false
    }

    func updateRebuildSuggestion(now: Date = Date()) {
        guard !rebuildSuggestionDismissed else { return }
        guard started, settings.indexingEnabled, phase == .idle else { return }
        let overdue = settings.lastFullRebuildDate
            .map { now.timeIntervalSince($0) >= Self.rebuildRecommendationInterval } ?? true
        showsRebuildSuggestion = overdue && indexedRows > 0
    }

    /// A walk finished in the idle phase. Skips plus a current denial is the
    /// one combination where Full Disk Access explains what was missed; a
    /// dismissed hint stays dismissed for the session.
    private func noteScanFinished() {
        guard !privacyHintDismissed, progressStats.skipped > 0, let accessCheck else { return }
        if accessCheck() == .denied {
            showsPrivacyHint = true
        }
    }

    public func startIfNeeded() {
        if launchAccessState == .unchecked { checkLaunchAccess() }
        guard launchAccessState == .ready, !started, !settings.needsLocationSetup else { return }
        started = true
        let db = database
        indexingQueue.async { [weak self] in
            do {
                let count = try db.count()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.indexedRows = count
                    self.hasLoadedIndexCount = true
                    if count == 0 && self.phase == .waiting && !self.isPaused {
                        self.rebuild()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.indexCountError = "Could not read saved index: \(error)"
                }
            }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIndexedVolumes()
            self?.checkScheduledFullCheck()
            self?.compactIndexIfNeeded()
            self?.updateRebuildSuggestion()
        }
        maintenanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleStartup()
    }

    public func checkScheduledFullCheck(now: Date = Date()) {
        guard started, settings.indexingEnabled, launchAccessState == .ready,
              !settings.needsLocationSetup, phase == .idle, !isCompacting,
              scheduledFullCheckIsDue(now: now) else { return }
        reconcileAndMonitor()
    }

    private func scheduledFullCheckIsDue(now: Date) -> Bool {
        guard let interval = settings.fullCheckInterval.seconds else { return false }
        guard let baseline = lastFullCheckDate else { return true }
        return now.timeIntervalSince(baseline) >= interval
    }

    private func checkIndexedVolumes() {
        guard started, settings.indexingEnabled, settings.liveUpdates, phase == .idle, !isCompacting,
              !settings.needsLocationSetup else { return }
        let volumes = IndexedVolume.discover(config: makeConfig())
        guard volumes.count != monitoredVolumes.count
            || !zip(volumes, monitoredVolumes).allSatisfy({ $0.hasSameTopology(as: $1) }) else { return }
        reconcileAndMonitor()
    }

    func compactIndexIfNeeded(now: Date = Date()) {
        guard started, settings.indexingEnabled, phase == .idle, !isCompacting,
              lastMaintenanceCheck.map({ now.timeIntervalSince($0) >= 3600 }) ?? true else { return }
        lastMaintenanceCheck = now
        isCompacting = true
        let db = database
        let control = activeControl
        indexingQueue.async { [weak self] in
            var failure: String?
            if !control.isCancelled {
                do { try db.compactIfNeeded() }
                catch { failure = "Index compaction failed: \(error.localizedDescription)" }
            }
            let message = failure
            DispatchQueue.main.async { [weak self] in
                self?.isCompacting = false
                if !control.isCancelled, let message { self?.lastError = message }
            }
        }
    }

    public func setIndexingEnabled(_ enabled: Bool) {
        settings.indexingEnabled = enabled
        cancelCountdown()
        activeControl.cancel()
        stopMonitor()
        isPaused = false
        phase = .idle
        if enabled && started { scheduleStartup() }
    }

    public func restartStartupDelay() {
        guard phase == .waiting else { return }
        let paused = isPaused
        scheduleStartup()
        if paused && phase == .waiting { togglePause() }
    }

    /// Leave the startup countdown and begin the catch-up immediately,
    /// whether the countdown is running or frozen.
    public func startIndexingNow() {
        guard phase == .waiting else { return }
        isPaused = false
        beginCatchUp()
    }

    private func scheduleStartup() {
        cancelCountdown()
        guard launchAccessState == .ready, settings.indexingEnabled, !settings.needsLocationSetup else { return }
        isPaused = false
        remainingDelay = hasLoadedIndexCount && indexedRows == 0 ? 0 : settings.startupDelaySeconds
        countdownDeadline = Date().addingTimeInterval(remainingDelay)
        countdownSeconds = Int(ceil(remainingDelay))
        phase = .waiting
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateCountdown()
    }

    func updateCountdown(now: Date = Date()) {
        guard phase == .waiting, !isPaused, let deadline = countdownDeadline else { return }
        remainingDelay = max(0, deadline.timeIntervalSince(now))
        countdownSeconds = Int(ceil(remainingDelay))
        guard remainingDelay == 0 else { return }
        beginCatchUp()
    }

    private func beginCatchUp() {
        cancelCountdown()
        activeControl.cancel()
        let control = IndexingControl()
        activeControl = control
        phase = .reconciling
        let db = database
        indexingQueue.async { [weak self] in
            guard control.waitUntilRunning() else { return }
            do {
                let count = try db.count()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !control.isCancelled else { return }
                    self.indexedRows = count
                    let paused = self.isPaused
                    if count == 0 { self.rebuild() }
                    else if let checkpoint = self.validCheckpoint() {
                        self.lastFullCheckDate = checkpoint.scannedAt
                        if self.scheduledFullCheckIsDue(now: Date()) { self.reconcileAndMonitor() }
                        else { self.replayChanges(checkpoint) }
                    }
                    else { self.reconcileAndMonitor() }
                    if paused && self.canPause { self.togglePause() }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard !control.isCancelled else { return }
                    self?.lastError = String(describing: error)
                    self?.isPaused = false
                    self?.phase = .idle
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
        countdownSeconds = 0
    }

    private func validCheckpoint() -> IndexCheckpoint? {
        guard let checkpoint = IndexCheckpoint.load(databasePath: database.path),
              checkpoint.isValid(databasePath: database.path, config: makeConfig()) else { return nil }
        return checkpoint
    }

    private func replayChanges(_ checkpoint: IndexCheckpoint) {
        activeControl.cancel()
        stopMonitor()
        activeControl = IndexingControl()
        phase = .reconciling
        isPaused = false
        progressRows = 0
        progressStats = IndexerStats()
        lastError = nil
        if !startMonitor(checkpoint: checkpoint) {
            reconcileAndMonitor()
        }
    }

    public func rebuild() {
        guard launchAccessState == .ready, settings.indexingEnabled, !settings.needsLocationSetup else { return }
        cancelCountdown()
        beginIndexing(rebuild: true)
    }

    private func reconcileAndMonitor() {
        beginIndexing(rebuild: false)
    }

    private func beginIndexing(rebuild: Bool) {
        activeControl.cancel()
        stopMonitor()
        IndexCheckpoint.remove(databasePath: database.path)
        let control = IndexingControl()
        activeControl = control
        isPaused = false
        phase = rebuild ? .indexing : .reconciling
        progressRows = 0
        progressStats = IndexerStats()
        lastError = nil

        let db = database
        let config = makeConfig()
        let volumes = IndexedVolume.discover(config: config)
        let checkpoint = IndexCheckpoint(databasePath: db.path, config: config, volumes: volumes)
        let monitoring = startMonitor(checkpoint: checkpoint, suspended: true, volumes: volumes)
        indexingQueue.async { [weak self] in
            guard control.waitUntilRunning() else { return }
            let progress: @Sendable (IndexerStats) -> Void = { [weak self] stats in
                DispatchQueue.main.async { [weak self] in
                    guard !control.isCancelled else { return }
                    self?.progressRows = stats.rows
                    self?.progressStats = stats
                    self?.indexRevision += 1
                }
            }
            do {
                if rebuild {
                    try db.clear()
                    try db.beginBulkLoad()
                    do {
                        try FilesystemIndexer(db: db, config: config).run(
                            isCancelled: { !control.waitUntilRunning() }, progress: progress
                        )
                    } catch {
                        try? db.endBulkLoad()
                        throw error
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard !control.isCancelled else { return }
                        self?.phase = .finalizing
                        self?.isPaused = false
                        control.resume()
                    }
                    try db.endBulkLoad()
                } else {
                    try Reconciler(db: db, config: config, roots: config.roots, skipUnchangedDirs: false).run(
                        isCancelled: { !control.waitUntilRunning() }, progress: progress
                    )
                }
                let count = try db.count()
                DispatchQueue.main.async { [weak self] in
                    guard !control.isCancelled else { return }
                    guard let self else { return }
                    self.indexedRows = count
                    self.indexRevision += 1
                    self.isPaused = false
                    self.lastFullCheckDate = checkpoint.scannedAt
                    if rebuild { self.settings.noteFullRebuild() }
                    if monitoring {
                        do { try checkpoint.save(databasePath: db.path) }
                        catch { self.lastError = String(describing: error) }
                        self.phase = .reconciling
                        self.changeHandlers.forEach { $0.resume() }
                    } else {
                        self.phase = .idle
                        self.noteScanFinished()
                        self.compactIndexIfNeeded()
                    }
                    self.updateRebuildSuggestion()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard !control.isCancelled else { return }
                    control.cancel()
                    self?.stopMonitor()
                    IndexCheckpoint.remove(databasePath: db.path)
                    self?.lastError = String(describing: error)
                    self?.isPaused = false
                    self?.phase = .idle
                }
            }
        }
    }

    public func setLive(_ enabled: Bool) {
        settings.liveUpdates = enabled
        guard enabled else {
            if phase == .idle { stopMonitor() }
            return
        }
        guard launchAccessState == .ready, settings.indexingEnabled, !settings.needsLocationSetup else { return }
        if !monitors.isEmpty {
            live = true
            return
        }
        if phase == .waiting {
            cancelCountdown()
        }
        guard phase == .waiting || phase == .idle else { return }
        if let checkpoint = validCheckpoint() {
            lastFullCheckDate = checkpoint.scannedAt
            if scheduledFullCheckIsDue(now: Date()) { reconcileAndMonitor() }
            else { replayChanges(checkpoint) }
        }
        else { reconcileAndMonitor() }
    }

    private func startMonitor(checkpoint: IndexCheckpoint, suspended: Bool = false,
                              volumes: [IndexedVolume]? = nil) -> Bool {
        guard monitors.isEmpty else { return true }
        let control = activeControl
        let db = database
        let config = makeConfig()
        let volumes = volumes ?? IndexedVolume.discover(config: config)
        monitoredVolumes = volumes
        guard !volumes.isEmpty, Set(volumes.map(\.path)) == Set(checkpoint.volumeCursors.keys) else { return false }
        replayProgress = JournalReplayProgress(volumes: volumes.map(\.path))
        let writer = IndexCheckpointWriter(checkpoint, databasePath: db.path)
        for volume in volumes {
            guard let cursor = checkpoint.volumeCursors[volume.path] else { return false }
            let handler = ChangeHandler(db: db, config: config, suspended: suspended, control: control,
                recoveryRoots: volume.roots, queue: changesQueue,
                onCommit: { [weak self] eventID, historyDone, stats in
                    guard !control.isCancelled else { return }
                    try writer.commit(volume: volume.path, eventID: eventID,
                                      journalEventID: IndexedVolume.currentJournalEventID(device: volume.device))
                    let count = historyDone ? try db.count() : nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !control.isCancelled else { return }
                        if let count { self.indexedRows = count }
                        self.indexRevision += 1
                        self.progressStats.scannedItems += stats.scannedItems
                        self.progressStats.scannedDirectories += stats.scannedDirectories
                        self.progressStats.skipped += stats.skipped
                        if historyDone {
                            guard self.replayProgress.finish(volume: volume.path) else { return }
                            self.isPaused = false
                            self.phase = .idle
                            self.live = self.settings.liveUpdates
                            if !self.settings.liveUpdates { self.stopMonitor() }
                            self.noteScanFinished()
                            self.compactIndexIfNeeded()
                            self.updateRebuildSuggestion()
                        }
                    }
                }, onError: { [weak self] error in
                    DispatchQueue.main.async { [weak self] in
                        guard !control.isCancelled else { return }
                        control.cancel()
                        self?.stopMonitor()
                        self?.phase = .idle
                        self?.isPaused = false
                        self?.lastError = String(describing: error)
                    }
                })
            let since = suspended || volume.journalIdentity == nil ? UInt64(kFSEventStreamEventIdSinceNow) : cursor.eventID
            let monitor = FSEventsMonitor(volume: volume, since: since) { events in
                handler.ingest(events: events)
            }
            guard monitor.start() else {
                monitor.stop()
                handler.stop(cancelControl: false)
                monitors.forEach { $0.stop() }
                changeHandlers.forEach { $0.stop(cancelControl: false) }
                monitors = []
                changeHandlers = []
                replayProgress = JournalReplayProgress()
                lastError = "File-system monitoring could not start. Full checks will be used until monitoring is available."
                return false
            }
            monitors.append(monitor)
            changeHandlers.append(handler)
            if suspended || volume.journalIdentity == nil {
                handler.ingest(events: [FileSystemEvent(path: "", id: cursor.eventID,
                                                       flags: UInt32(kFSEventStreamEventFlagHistoryDone))])
            }
        }
        live = settings.liveUpdates
        return true
    }

    private func stopMonitor() {
        monitors.forEach { $0.stop() }
        monitors = []
        changeHandlers.forEach { $0.stop() }
        changeHandlers = []
        replayProgress = JournalReplayProgress()
        live = false
    }

    func makeConfig() -> IndexConfig {
        var prefixes = settings.builtInExcludedFolders.filter { prefix in
            !settings.roots.contains { root in
                let canonical = Walk.canonicalPath(root)
                return canonical == prefix || canonical.hasPrefix(prefix + "/")
            }
        }
        prefixes.append(indexDirectory)
        for folder in settings.excludedFolders {
            prefixes.append(Walk.normalizePath(folder))
            prefixes.append(Walk.canonicalPath(folder))
        }
        var seenPrefixes = Set<String>()
        prefixes = prefixes.filter { seenPrefixes.insert($0).inserted }
        return IndexConfig(
            roots: settings.roots,
            exclusions: settings.exclusions,
            namePatterns: settings.excludedNamePatterns,
            skipPathPrefixes: prefixes,
            skipDirNames: settings.builtInExcludedDirectoryNames
        )
    }
}
