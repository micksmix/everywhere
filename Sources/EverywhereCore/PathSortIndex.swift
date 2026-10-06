import Foundation

final class PathSortIndex {
    struct Directory {
        let id: Int64
        let parent: Int64
        let name: String
    }

    private struct Node {
        let parent: Int64
        let name: String
        let bytes: [UInt8]
        var components: [Int64]?
        var isASCII = false
        var valid = true
        var rank = 0
    }

    private struct Cursor {
        let components: ArraySlice<Int64>
        let leaf: [UInt8]
        var component = 0
        var offset = 0
        var current: [UInt8]?
        var leafOffset = 0

        mutating func next(in nodes: [Int64: Node]) -> UInt8? {
            while component < components.count {
                if current == nil { current = nodes[components[components.startIndex + component]]?.bytes ?? [] }
                if offset < current!.count {
                    defer { offset += 1 }
                    return current![offset]
                }
                if offset == current!.count {
                    offset += 1
                    return 47
                }
                component += 1
                offset = 0
                current = nil
            }
            guard leafOffset < leaf.count else { return nil }
            defer { leafOffset += 1 }
            return leaf[leafOffset]
        }
    }

    private var nodes: [Int64: Node] = [:]
    private var prefixEnds: [Int] = []

    var storageBytes: Int {
        nodes.capacity * (MemoryLayout<Int64>.stride + MemoryLayout<Node>.stride)
            + prefixEnds.capacity * MemoryLayout<Int>.stride
            + nodes.values.reduce(0) { $0 + $1.bytes.capacity + $1.name.utf8.count + ($1.components?.capacity ?? 0) * MemoryLayout<Int64>.stride }
    }

    init(directories: [Directory], cancellation: SearchCancellation?) throws {
        nodes.reserveCapacity(directories.count + 1)
        nodes[0] = Node(parent: 0, name: "", bytes: [], components: [], isASCII: true)
        for (offset, directory) in directories.enumerated() {
            if offset % 256 == 0 { try cancellation?.check() }
            nodes[directory.id] = Node(parent: directory.parent, name: directory.name, bytes: Array(directory.name.utf8))
        }
        for (offset, directory) in directories.enumerated() {
            if offset % 256 == 0 { try cancellation?.check() }
            try prepareComponents(for: directory.id, cancellation: cancellation)
        }
        var comparisons = 0
        let ordered = try nodes.keys.filter { nodes[$0]!.valid }.sorted { left, right in
            comparisons += 1
            if comparisons % 256 == 0 { try cancellation?.check() }
            let order = comparePrefixes(left, right)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
        var representatives: [Int64] = []
        for (offset, id) in ordered.enumerated() {
            if offset % 256 == 0 { try cancellation?.check() }
            if let previous = representatives.last, comparePrefixes(previous, id) == .orderedSame {
                nodes[id]!.rank = representatives.count - 1
            } else {
                nodes[id]!.rank = representatives.count
                representatives.append(id)
            }
        }
        prefixEnds = [Int](repeating: representatives.count - 1, count: representatives.count)
        var stack: [Int] = []
        for (rank, id) in representatives.enumerated() {
            if rank % 256 == 0 { try cancellation?.check() }
            while let previous = stack.last, !isPrefix(representatives[previous], of: id) {
                prefixEnds[previous] = rank - 1
                stack.removeLast()
            }
            stack.append(rank)
        }
        try cancellation?.check()
    }

    func compareParents(_ left: Int64, _ right: Int64) -> ComparisonResult? {
        let a = node(for: left).rank
        let b = node(for: right).rank
        if a == b { return .orderedSame }
        if a < b && b > prefixEnds[a] { return .orderedAscending }
        if b < a && a > prefixEnds[b] { return .orderedDescending }
        return nil
    }

    func compare(leftParent: Int64, leftName: String, rightParent: Int64, rightName: String) -> ComparisonResult {
        if let order = compareParents(leftParent, rightParent) {
            return order == .orderedSame ? leftName.compare(rightName, options: .caseInsensitive) : order
        }
        let left = node(for: leftParent)
        let right = node(for: rightParent)
        let leftBytes = Array(leftName.utf8)
        let rightBytes = Array(rightName.utf8)
        if left.isASCII && right.isASCII && leftBytes.allSatisfy({ $0 < 128 }) && rightBytes.allSatisfy({ $0 < 128 }) {
            let common = commonComponents(left, right)
            return compareBytes(Cursor(components: (left.components ?? []).dropFirst(common), leaf: leftBytes),
                                Cursor(components: (right.components ?? []).dropFirst(common), leaf: rightBytes))
        }
        return (prefixText(left) + leftName).compare(prefixText(right) + rightName, options: .caseInsensitive)
    }

    private func node(for id: Int64) -> Node {
        guard let node = nodes[id], node.valid else { return nodes[0]! }
        return node
    }

    private func prepareComponents(for id: Int64, cancellation: SearchCancellation?) throws {
        var pending: [Int64] = []
        var visited = Set<Int64>()
        var current = id
        while let node = nodes[current], node.components == nil {
            try cancellation?.check()
            guard visited.insert(current).inserted else { throw DatabaseError.invalidQuery("The index contains a directory cycle. Rebuild the index.") }
            pending.append(current)
            current = node.parent
        }
        var components = nodes[current]?.components ?? []
        let valid = nodes[current]?.valid ?? false
        var ascii = nodes[current]?.isASCII ?? false
        while let next = pending.popLast() {
            try cancellation?.check()
            var node = nodes[next]!
            if valid { components.append(next) }
            ascii = ascii && node.bytes.allSatisfy { $0 < 128 }
            node.components = components
            node.valid = valid
            node.isASCII = ascii
            nodes[next] = node
        }
    }

    private func comparePrefixes(_ leftID: Int64, _ rightID: Int64) -> ComparisonResult {
        let left = node(for: leftID)
        let right = node(for: rightID)
        if left.isASCII && right.isASCII {
            let common = commonComponents(left, right)
            return compareBytes(Cursor(components: (left.components ?? []).dropFirst(common), leaf: []),
                                Cursor(components: (right.components ?? []).dropFirst(common), leaf: []))
        }
        return prefixText(left).compare(prefixText(right), options: .caseInsensitive)
    }

    private func isPrefix(_ prefixID: Int64, of id: Int64) -> Bool {
        let prefix = node(for: prefixID)
        let target = node(for: id)
        if prefix.isASCII && target.isASCII {
            let common = commonComponents(prefix, target)
            var left = Cursor(components: (prefix.components ?? []).dropFirst(common), leaf: [])
            var right = Cursor(components: (target.components ?? []).dropFirst(common), leaf: [])
            while let byte = left.next(in: nodes) {
                guard let other = right.next(in: nodes), fold(byte) == fold(other) else { return false }
            }
            return true
        }
        let text = prefixText(prefix)
        return text.isEmpty || (prefixText(target) as NSString).range(of: text, options: [.anchored, .caseInsensitive]).location != NSNotFound
    }

    private func compareBytes(_ left: Cursor, _ right: Cursor) -> ComparisonResult {
        var left = left
        var right = right
        while true {
            let a = left.next(in: nodes)
            let b = right.next(in: nodes)
            if a == nil { return b == nil ? .orderedSame : .orderedAscending }
            if b == nil { return .orderedDescending }
            let foldedA = fold(a!)
            let foldedB = fold(b!)
            if foldedA != foldedB { return foldedA < foldedB ? .orderedAscending : .orderedDescending }
        }
    }

    private func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private func commonComponents(_ left: Node, _ right: Node) -> Int {
        let a = left.components ?? []
        let b = right.components ?? []
        var common = 0
        while common < min(a.count, b.count) && a[common] == b[common] { common += 1 }
        return common
    }

    private func prefixText(_ node: Node) -> String {
        let components = node.components ?? []
        return components.isEmpty ? "" : components.map { nodes[$0]!.name }.joined(separator: "/") + "/"
    }
}
