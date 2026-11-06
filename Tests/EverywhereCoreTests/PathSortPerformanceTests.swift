import XCTest
@testable import EverywhereCore

final class PathSortPerformanceTests: XCTestCase {
    private func directoryIndex(count: Int, deep: Bool) throws -> PathSortIndex {
        var directories = [PathSortIndex.Directory(id: 1, parent: 0, name: "")]
        for number in 0..<count {
            directories.append(PathSortIndex.Directory(id: Int64(number + 2), parent: deep ? Int64(number + 1) : 1, name: "d\(number)"))
        }
        return try PathSortIndex(directories: directories, cancellation: nil)
    }

    func testWideDirectoryRankStorageGrowsNearLinearly() throws {
        let small = try directoryIndex(count: 256, deep: false)
        let large = try directoryIndex(count: 512, deep: false)
        XCTAssertLessThanOrEqual(Double(large.storageBytes) / Double(small.storageBytes), 2.75)
    }

    func testDeepDirectoryRankStorageHasKnownNonlinearGrowth() throws {
        let small = try directoryIndex(count: 128, deep: true)
        let large = try directoryIndex(count: 256, deep: true)
        XCTExpectFailure("Deep directory ranks retain copied ancestor arrays; the near-linear storage budget remains an open performance issue.") {
            XCTAssertLessThanOrEqual(Double(large.storageBytes) / Double(small.storageBytes), 2.75)
        }
    }
}
