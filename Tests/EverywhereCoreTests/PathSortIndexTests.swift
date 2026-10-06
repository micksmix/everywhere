import XCTest
@testable import EverywhereCore

final class PathSortIndexTests: XCTestCase {
    func testDirectoryRanksAndAncestorComparisonsAgreeWithFullPaths() throws {
        let names = ["a", "a.b", "a-", "A", "a0", "é", "e\u{301}", "ß", "ss", "📁", "x\u{ad}", "x", "İ", "i"]
        var directories = [PathSortIndex.Directory(id: 1, parent: 0, name: "")]
        var prefixes: [Int64: String] = [0: "", 1: "/"]
        var nextID: Int64 = 2
        for name in names {
            let id = nextID
            nextID += 1
            directories.append(PathSortIndex.Directory(id: id, parent: 1, name: name))
            prefixes[id] = "/\(name)/"
            for child in ["inside", "inside.b", "é"] {
                directories.append(PathSortIndex.Directory(id: nextID, parent: id, name: child))
                prefixes[nextID] = "/\(name)/\(child)/"
                nextID += 1
            }
        }
        directories.append(PathSortIndex.Directory(id: nextID, parent: 0, name: "/a/inside"))
        prefixes[nextID] = "/a/inside/"
        let index = try PathSortIndex(directories: directories.reversed(), cancellation: nil)
        for (left, prefix) in prefixes {
            for (right, otherPrefix) in prefixes {
                for name in ["a", "a.b", "inside", "é", "ss"] {
                    let expected = (prefix + name).compare(otherPrefix + "inside", options: .caseInsensitive)
                    XCTAssertEqual(index.compare(leftParent: left, leftName: name, rightParent: right, rightName: "inside"), expected,
                                   "\(prefix + name) vs \(otherPrefix + "inside")")
                }
            }
        }
    }

    func testMissingParentsFallBackToNamesAndCyclesFail() throws {
        let index = try PathSortIndex(directories: [PathSortIndex.Directory(id: 1, parent: 99, name: "orphan")], cancellation: nil)
        XCTAssertEqual(index.compare(leftParent: 1, leftName: "a", rightParent: 0, rightName: "b"), .orderedAscending)
        XCTAssertThrowsError(try PathSortIndex(directories: [PathSortIndex.Directory(id: 1, parent: 2, name: "one"),
                                                          PathSortIndex.Directory(id: 2, parent: 1, name: "two")], cancellation: nil))
        let token = SearchCancellation()
        token.cancel()
        XCTAssertThrowsError(try PathSortIndex(directories: [], cancellation: token))
    }
}
