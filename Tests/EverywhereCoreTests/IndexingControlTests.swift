import XCTest
@testable import EverywhereCore

final class IndexingControlTests: XCTestCase {
    func testPauseBlocksWorkersUntilResume() {
        let control = IndexingControl()
        control.pause()
        let started = expectation(description: "Worker started")
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.fulfill()
            XCTAssertTrue(control.waitUntilRunning())
            finished.signal()
        }
        wait(for: [started], timeout: 3)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.15), .timedOut)
        control.resume()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
    }

    func testCancellationWakesEveryPausedWorker() {
        let control = IndexingControl()
        control.pause()
        let started = expectation(description: "Workers started")
        started.expectedFulfillmentCount = 4
        let completed = expectation(description: "Workers cancelled")
        completed.expectedFulfillmentCount = 4
        for _ in 0..<4 {
            DispatchQueue.global().async {
                started.fulfill()
                XCTAssertFalse(control.waitUntilRunning())
                completed.fulfill()
            }
        }
        wait(for: [started], timeout: 3)
        control.cancel()
        wait(for: [completed], timeout: 3)
        control.resume()
        XCTAssertFalse(control.waitUntilRunning())
    }
}
