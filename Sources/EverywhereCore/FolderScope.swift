import Foundation

struct FolderScope {
    struct Key: Hashable {
        let paths: [String]
        let recursive: Bool
        let matchCase: Bool
    }

    struct Filter {
        let scope: FolderScope
        let negated: Bool

        func matches(id: Int64, parent: Int64) -> Bool {
            let found = scope.parents.contains(parent) || scope.included.contains(id)
            return negated ? !found : found
        }
    }

    let parents: Set<Int64>
    let included: Set<Int64>

    var storageBytes: Int {
        (parents.capacity + included.capacity) * MemoryLayout<Int64>.stride
    }
}
