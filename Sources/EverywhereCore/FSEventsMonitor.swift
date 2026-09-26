import Foundation
import CoreServices

public struct FileSystemEvent: Sendable {
    public let path: String
    public let id: UInt64
    public let flags: UInt32

    public init(path: String, id: UInt64 = 0, flags: UInt32 = 0) {
        self.path = path
        self.id = id
        self.flags = flags
    }

    var isHistoryDone: Bool { flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
    var requiresFullScan: Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                       | kFSEventStreamEventFlagEventIdsWrapped) != 0
    }
    var requiresRecursiveScan: Bool {
        flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                       | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
    }
}

public final class FSEventsMonitor: @unchecked Sendable {
    public typealias Sink = @Sendable ([String]) -> Void
    private final class CallbackBox {
        let sink: @Sendable ([FileSystemEvent]) -> Void
        init(_ sink: @escaping @Sendable ([FileSystemEvent]) -> Void) { self.sink = sink }
    }

    private var stream: FSEventStreamRef?
    private var started = false
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let callbackBox: CallbackBox

    public convenience init(roots: [String], latency: TimeInterval = 0.5, queue: DispatchQueue? = nil,
                            sink: @escaping Sink) {
        self.init(roots: roots, latency: latency, queue: queue, eventsSink: { events in
            sink(events.filter { !$0.isHistoryDone }.map(\.path))
        })
    }

    public init(roots: [String], since: UInt64 = UInt64(kFSEventStreamEventIdSinceNow),
                latency: TimeInterval = 0.5, queue: DispatchQueue? = nil,
                eventsSink: @escaping @Sendable ([FileSystemEvent]) -> Void) {
        self.queue = queue ?? DispatchQueue(label: "app.everywhere.fsevents", qos: .utility)
        callbackBox = CallbackBox(eventsSink)
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<CallbackBox>.fromOpaque(pointer).release() }
            }, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let events = (0..<min(count, array.count)).compactMap { index -> FileSystemEvent? in
                guard let path = array[index] as? String else { return nil }
                return FileSystemEvent(path: path, id: ids[index], flags: flags[index])
            }
            box.sink(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray, since, latency, flags)
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return false }
        if started { return true }
        FSEventStreamSetDispatchQueue(stream, queue)
        started = FSEventStreamStart(stream)
        return started
    }

    public func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        let wasStarted = started
        started = false
        lock.unlock()
        if let stream {
            if wasStarted { FSEventStreamStop(stream) }
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

public final class ChangeHandler: @unchecked Sendable {
    private struct PendingChange {
        var recursive: Bool
        var id: UInt64
    }

    private let db: Database
    private let config: IndexConfig
    private let rootPaths: [(path: String, canonical: String)]
    private let debounce: TimeInterval
    private let maxDebounce: TimeInterval
    private let pathCooldown: TimeInterval
    private let control: IndexingControl
    private let onCommit: @Sendable (UInt64, Bool, IndexerStats) throws -> Void
    private let onError: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "app.everywhere.changes", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var pending: [String: PendingChange] = [:]
    private var historyDoneID: UInt64 = 0
    private var historyDone = false
    private var suspended: Bool
    private var stopped = false
    private var flushItem: DispatchWorkItem?
    private var debounceInterval: TimeInterval
    private var lastFlushEnd: Date?
    private var lastReconciled: [String: Date] = [:]

    public init(db: Database, config: IndexConfig, debounce: TimeInterval = 0.5,
                maxDebounce: TimeInterval = 8, pathCooldown: TimeInterval = 5,
                suspended: Bool = false, control: IndexingControl = IndexingControl(),
                onCommit: @escaping @Sendable (UInt64, Bool, IndexerStats) throws -> Void = { _, _, _ in },
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.db = db
        self.config = config
        rootPaths = config.roots.sorted { $0.count > $1.count }.map {
            (Self.normalizedPath($0), Walk.canonicalPath($0))
        }
        self.debounce = debounce
        self.maxDebounce = max(maxDebounce, debounce)
        self.pathCooldown = pathCooldown
        self.suspended = suspended
        self.control = control
        self.onCommit = onCommit
        self.onError = onError
        debounceInterval = debounce
        queue.setSpecific(key: queueKey, value: true)
    }

    var effectiveDebounce: TimeInterval {
        queue.sync { debounceInterval }
    }

    public func ingest(_ paths: [String]) {
        ingest(events: paths.map { FileSystemEvent(path: $0) })
    }

    public func ingest(events: [FileSystemEvent]) {
        queue.async { [self] in
            guard !stopped else { return }
            var accepted = false
            for event in events {
                if event.isHistoryDone {
                    historyDone = true
                    historyDoneID = max(historyDoneID, event.id)
                    accepted = true
                    continue
                }
                if event.requiresFullScan {
                    for root in config.roots { mergePending(root, id: event.id, recursive: true) }
                    accepted = true
                } else if let path = indexedPath(event.path), !config.ignores(path: path) {
                    mergePending(path, id: event.id, recursive: event.requiresRecursiveScan)
                    accepted = true
                } else {
                    continue
                }
            }
            if accepted && !suspended { scheduleFlush() }
        }
    }

    private func mergePending(_ path: String, id: UInt64, recursive: Bool) {
        var change = pending[path] ?? PendingChange(recursive: false, id: 0)
        change.recursive = change.recursive || recursive
        change.id = max(change.id, id)
        pending[path] = change
    }

    static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private func indexedPath(_ rawPath: String) -> String? {
        let path = Self.normalizedPath(rawPath)
        for mapping in rootPaths {
            let root = mapping.path
            let canonical = mapping.canonical
            if path == canonical { return root }
            let prefix = canonical == "/" ? "/" : canonical + "/"
            if path.hasPrefix(prefix) {
                return Walk.joinPath(root, String(path.dropFirst(prefix.count)))
            }
            if path == root || path.hasPrefix(root == "/" ? "/" : root + "/") { return path }
        }
        return nil
    }

    private func scheduleFlush(after delay: TimeInterval? = nil) {
        flushItem?.cancel()
        let interval: TimeInterval
        if let delay {
            interval = delay
        } else if let end = lastFlushEnd, end.timeIntervalSinceNow > -maxDebounce {
            debounceInterval = min(debounceInterval * 2, maxDebounce)
            interval = debounceInterval
        } else {
            debounceInterval = debounce
            interval = debounce
        }
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushItem = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    public func resume() {
        queue.async { [self] in
            guard !stopped else { return }
            suspended = false
            flush(bypassCooldown: true)
        }
    }

    public func flushPendingNow() {
        if DispatchQueue.getSpecific(key: queueKey) == true { flush(bypassCooldown: true) }
        else { queue.sync { flush(bypassCooldown: true) } }
    }

    private func flush(bypassCooldown: Bool = false) {
        flushItem?.cancel()
        flushItem = nil
        guard !stopped, !suspended, !pending.isEmpty || historyDone else { return }
        let now = Date()
        if lastReconciled.count > 4096 {
            lastReconciled = lastReconciled.filter { now.timeIntervalSince($0.value) < pathCooldown * 2 }
        }
        let completedHistory = historyDone
        let sentinelID = historyDoneID
        let bypass = bypassCooldown || completedHistory
        var immediate: [String: PendingChange] = [:]
        var deferred: [String: PendingChange] = [:]
        var earliestEligible: Date?
        for (path, change) in pending {
            let withinCooldown = lastReconciled[path].map { now.timeIntervalSince($0) < pathCooldown } ?? false
            if !bypass && !change.recursive && withinCooldown {
                deferred[path] = change
                let eligibleAt = lastReconciled[path]!.addingTimeInterval(pathCooldown)
                if earliestEligible.map({ eligibleAt < $0 }) ?? true { earliestEligible = eligibleAt }
            } else {
                immediate[path] = change
            }
        }
        pending = deferred
        let eventID: UInt64
        if deferred.isEmpty {
            eventID = max(immediate.values.map(\.id).max() ?? 0, completedHistory ? sentinelID : 0)
        } else {
            let floor = deferred.values.map(\.id).min() ?? 0
            eventID = floor > 0 ? floor - 1 : 0
        }
        do {
            var total = IndexerStats()
            for recursive in [false, true] {
                let roots = immediate.filter { $0.value.recursive == recursive }.map(\.key)
                guard !roots.isEmpty else { continue }
                let reconciler = Reconciler(db: db, config: config, roots: roots, skipUnchangedDirs: false, scanKnownSubdirectories: recursive)
                try reconciler.run(isCancelled: { !self.control.waitUntilRunning() })
                let stats = reconciler.snapshot
                total.rows += stats.rows
                total.scannedItems += stats.scannedItems
                total.scannedDirectories += stats.scannedDirectories
                total.skipped += stats.skipped
            }
            lastFlushEnd = Date()
            for path in immediate.keys { lastReconciled[path] = lastFlushEnd! }
            guard !control.isCancelled else { return }
            historyDone = false
            historyDoneID = 0
            try onCommit(eventID, completedHistory, total)
            scheduleFollowUp(earliest: earliestEligible)
        } catch {
            lastFlushEnd = Date()
            for (path, change) in immediate {
                var merged = pending[path] ?? change
                merged.recursive = merged.recursive || change.recursive
                merged.id = max(merged.id, change.id)
                pending[path] = merged
            }
            onError(error)
            scheduleFlush(after: pathCooldown)
        }
    }

    private func scheduleFollowUp(earliest: Date?) {
        guard !pending.isEmpty else { return }
        let delay: TimeInterval
        if let earliest { delay = max(0.05, earliest.timeIntervalSinceNow) }
        else { delay = pathCooldown }
        scheduleFlush(after: delay)
    }

    public func stop() {
        control.cancel()
        queue.sync {
            self.flushItem?.cancel()
            self.flushItem = nil
            self.pending = [:]
            self.historyDone = false
            self.historyDoneID = 0
            self.stopped = true
        }
    }
}
