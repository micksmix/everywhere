import XCTest
@testable import EverywhereCore

final class DirectoryWorkerTests: XCTestCase {
    func testParallelismIsBoundedAndEveryDirectoryIsVisitedOnce() {
        let state = WorkerState()
        let overlapWindow = DispatchSemaphore(value: 0)
        let directories = (0..<64).map { DirPairCollector.Root(path: "/\($0)", id: Int64($0)) }
        IndexEngine.forEachDirectory(directories, isCancelled: { false }) { directory in
            state.enter(directory.id)
            if directory.id < 2 { _ = overlapWindow.wait(timeout: .now() + 0.05) }
            state.leave()
        }
        XCTAssertLessThanOrEqual(state.peak, 2)
        XCTAssertEqual(state.visited.sorted(), directories.map(\.id))
    }

    func testCancellationStopsWorkersBeforeTakingAnotherDirectory() {
        let control = IndexingControl()
        let state = WorkerState()
        let directories = (0..<64).map { DirPairCollector.Root(path: "/\($0)", id: Int64($0)) }
        IndexEngine.forEachDirectory(directories, isCancelled: { !control.waitUntilRunning() }) { directory in
            state.enter(directory.id)
            control.cancel()
            state.leave()
        }
        XCTAssertFalse(state.visited.isEmpty)
        XCTAssertLessThanOrEqual(state.visited.count, 2)
    }

    func testEmptyAndCancelledBatchesDoNotVisitDirectories() {
        IndexEngine.forEachDirectory([], isCancelled: { false }) { _ in XCTFail("Unexpected directory") }
        let directories = [DirPairCollector.Root(path: "/unused", id: 1)]
        IndexEngine.forEachDirectory(directories, isCancelled: { true }) { _ in XCTFail("Unexpected directory") }
    }
}

private final class WorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peakValue = 0
    private var visitedValue: [Int64] = []

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }

    var visited: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return visitedValue
    }

    func enter(_ id: Int64) {
        lock.lock()
        active += 1
        peakValue = max(peakValue, active)
        visitedValue.append(id)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
