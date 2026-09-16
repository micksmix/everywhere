import Foundation
import SQLite3

final class FilenameIndex {
    struct Row {
        let id: Int64
        let parent: Int64
        let size: Int64
        let modified: Double
        let nameOffset: Int
        let nameLength: Int32
        let isDirectory: Bool
        let isASCII: Bool
        let mask: UInt64
    }

    private(set) var rows: [Row] = []
    private var names: [UInt8] = []
    private var idOrder: [UInt32] = []
    private struct Ordering: Hashable {
        let key: SortKey
        let ascending: Bool
    }
    private var sortOrders: [Ordering: [UInt32]] = [:]
    private var recentOrders: [Ordering] = []
    private var previousRequest: SearchRequest?
    private var previousTerms: [String]?
    private var previousMatches: [UInt32] = []
    private var repeatedNames = false
    private var deadRows = 0
    private var unusedNameBytes = 0

    var needsCompaction: Bool {
        deadRows > max(1024, rows.count / 10) || unusedNameBytes > max(65536, names.count / 4)
    }

    var statistics: SearchCacheStatistics {
        SearchCacheStatistics(itemCount: rows.count - deadRows,
                              storageBytes: rows.capacity * MemoryLayout<Row>.stride + names.capacity + (idOrder.capacity + previousMatches.capacity) * MemoryLayout<UInt32>.stride,
                              sortBytes: sortOrders.values.reduce(0) { $0 + $1.capacity * MemoryLayout<UInt32>.stride },
                              sortCount: sortOrders.count)
    }

    init(connection: OpaquePointer, step: (OpaquePointer) throws -> Int32) throws {
        let sizingSQL = "SELECT count(*), coalesce(sum(length(CAST(name AS BLOB))), 0) FROM entries WHERE name != ''"
        var sizing: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sizingSQL, -1, &sizing, nil) == SQLITE_OK, let sizing else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(connection)), sql: sizingSQL)
        }
        defer { sqlite3_finalize(sizing) }
        _ = try step(sizing)
        let count = Int(sqlite3_column_int64(sizing, 0))
        guard count < Int(UInt32.max) else { throw DatabaseError.invalidQuery("Filename cache exceeds its capacity. Disable the memory cache to search this index.") }
        rows.reserveCapacity(count + max(1024, count / 20))
        let nameBytes = Int(sqlite3_column_int64(sizing, 1))
        names.reserveCapacity(nameBytes + max(4096, nameBytes / 20))
        let sql = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE name != '' ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(connection)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        var nameLocations: [UInt64: Int] = [:]
        var duplicates = 0
        while try step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 2) else { continue }
            let length = sqlite3_column_bytes(statement, 2)
            let bytes = UnsafeBufferPointer(start: text, count: Int(length))
            let hash = bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            var nameOffset = names.count
            if let location = nameLocations[hash], rows[location].nameLength == length,
               names[rows[location].nameOffset..<(rows[location].nameOffset + Int(length))].elementsEqual(bytes) {
                nameOffset = rows[location].nameOffset
                duplicates += 1
            } else {
                nameLocations[hash] = rows.count
                names.append(contentsOf: bytes)
            }
            rows.append(Row(id: sqlite3_column_int64(statement, 0), parent: sqlite3_column_int64(statement, 1),
                            size: sqlite3_column_int64(statement, 4), modified: Double(sqlite3_column_int64(statement, 5)),
                            nameOffset: nameOffset, nameLength: length,
                            isDirectory: sqlite3_column_int(statement, 3) != 0, isASCII: bytes.allSatisfy { $0 < 128 }, mask: NameQuery.characterMask(bytes)))
        }
        repeatedNames = duplicates > rows.count / 2
        if duplicates > 0 { names = names.withUnsafeBufferPointer { Array($0) } }
        idOrder = rows.indices.map { UInt32($0) }
    }

    func name(for row: Row) -> String {
        String(decoding: names[row.nameOffset..<(row.nameOffset + Int(row.nameLength))], as: UTF8.self)
    }

    func prepareSort(key: SortKey, ascending: Bool, cancellation: SearchCancellation?) throws {
        let ordering = Ordering(key: key, ascending: ascending)
        if sortOrders[ordering] != nil { return }
        let sorted = try sortedIndices(idOrder, ordering: ordering, cancellation: cancellation)
        if recentOrders.count == 3, let oldest = recentOrders.first {
            sortOrders[oldest] = nil
            recentOrders.removeFirst()
        }
        recentOrders.append(ordering)
        sortOrders[ordering] = sorted
    }

    func select(request: SearchRequest, cancellation: SearchCancellation?) throws -> (rows: [(Row, String)], total: Int) {
        let query = NameQuery(request)
        var reuse = false
        var identical = false
        if let previous = previousRequest,
           previous.kind == request.kind, previous.includeHidden == request.includeHidden,
           previous.matchCase == request.matchCase, previous.wholeWord == request.wholeWord {
            identical = previous.text == request.text
            if identical {
                reuse = true
            } else if let old = previousTerms, let new = query.literalTerms {
                reuse = old.allSatisfy { term in new.contains { $0.contains(term) } }
            }
        }
        var matches: [UInt32] = []
        if identical {
            matches = previousMatches
        } else {
            let candidates = reuse ? previousMatches : idOrder
            var nameMatches: [Int: Bool] = [:]
            try names.withUnsafeBufferPointer { bytes in
                for (offset, index) in candidates.enumerated() {
                    if offset % 256 == 0 { try cancellation?.check() }
                    let row = rows[index]
                    guard request.includeHidden || bytes[row.nameOffset] != 46,
                          request.kind != .files || !row.isDirectory,
                          request.kind != .folders || row.isDirectory else { continue }
                    if row.isASCII && !query.mayMatch(mask: row.mask) { continue }
                    if repeatedNames, let matched = nameMatches[row.nameOffset] {
                        if matched { matches.append(index) }
                        continue
                    }
                    let name = UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: row.nameOffset), count: Int(row.nameLength))
                    let matched = query.matches(bytes: name, isASCII: row.isASCII)
                    if repeatedNames { nameMatches[row.nameOffset] = matched }
                    if matched { matches.append(index) }
                }
            }
        }
        let ordering = Ordering(key: request.sortKey, ascending: request.ascending)
        let alreadySorted = reuse && previousRequest?.sortKey == request.sortKey && previousRequest?.ascending == request.ascending
        if !alreadySorted {
            if sortOrders[ordering] == nil && matches.count >= max(1024, (rows.count - deadRows) / 4) {
                try prepareSort(key: request.sortKey, ascending: request.ascending, cancellation: cancellation)
            }
            if let order = sortOrders[ordering] {
                recentOrders.removeAll { $0 == ordering }
                recentOrders.append(ordering)
                var flags = [UInt64](repeating: 0, count: (rows.count + 63) / 64)
                for (offset, index) in matches.enumerated() {
                    if offset % 1024 == 0 { try cancellation?.check() }
                    flags[index / 64] |= UInt64(1) << (index % 64)
                }
                matches.removeAll(keepingCapacity: true)
                for (offset, index) in order.enumerated() {
                    if offset % 1024 == 0 { try cancellation?.check() }
                    if flags[index / 64] & (UInt64(1) << (index % 64)) != 0 { matches.append(index) }
                }
            } else {
                matches = try sortedIndices(matches, ordering: ordering, cancellation: cancellation)
            }
        }
        try cancellation?.check()
        previousRequest = request
        previousTerms = query.literalTerms
        previousMatches = matches
        let page = matches.dropFirst(max(0, request.offset)).prefix(max(1, min(request.limit, 100_000)))
        return (page.map { (rows[$0], name(for: rows[$0])) }, matches.count)
    }

    func apply(changedIDs: Set<Int64>, replacements: [Int64: IndexRow], cancellation: SearchCancellation?) throws {
        guard !changedIDs.isEmpty else { return }
        previousRequest = nil
        previousTerms = nil
        previousMatches = []
        let positions = Dictionary(uniqueKeysWithValues: changedIDs.compactMap { id in position(for: id).map { (id, $0) } })
        var touched = Set<UInt32>()
        var live: [UInt32] = []
        for (offset, id) in changedIDs.enumerated() {
            if offset % 256 == 0 { try cancellation?.check() }
            let existing = positions[id]
            if let existing { touched.insert(existing) }
            guard let replacement = replacements[id], !replacement.name.isEmpty else {
                if let existing {
                    let old = rows[existing]
                    unusedNameBytes += Int(old.nameLength)
                    rows[existing] = Row(id: 0, parent: old.parent, size: 0, modified: 0,
                                         nameOffset: old.nameOffset, nameLength: old.nameLength,
                                         isDirectory: old.isDirectory, isASCII: old.isASCII, mask: old.mask)
                    deadRows += 1
                }
                continue
            }
            let bytes = Array(replacement.name.utf8)
            let nameOffset: Int
            if let existing, names[rows[existing].nameOffset..<(rows[existing].nameOffset + Int(rows[existing].nameLength))].elementsEqual(bytes) {
                nameOffset = rows[existing].nameOffset
            } else {
                if let existing { unusedNameBytes += Int(rows[existing].nameLength) }
                nameOffset = names.count
                names.append(contentsOf: bytes)
            }
            let row = Row(id: id, parent: replacement.parent, size: replacement.size, modified: replacement.modified,
                          nameOffset: nameOffset, nameLength: Int32(bytes.count), isDirectory: replacement.isDir,
                          isASCII: bytes.allSatisfy { $0 < 128 }, mask: NameQuery.characterMask(bytes))
            if let existing {
                rows[existing] = row
                live.append(existing)
            } else {
                guard let index = UInt32(exactly: rows.count), index < UInt32.max else { throw DatabaseError.invalidQuery("Filename cache exceeds its capacity. Disable the memory cache to search this index.") }
                live.append(index)
                rows.append(row)
            }
        }
        var unchanged: [UInt32] = []
        for (offset, index) in idOrder.enumerated() {
            if offset % 1024 == 0 { try cancellation?.check() }
            if !touched.contains(index) { unchanged.append(index) }
        }
        idOrder = try merged(unchanged, live.sorted { rows[$0].id < rows[$1].id }, cancellation: cancellation) { rows[$0].id < rows[$1].id }
        for ordering in recentOrders {
            guard let previous = sortOrders[ordering] else { continue }
            var retained: [UInt32] = []
            for (offset, index) in previous.enumerated() {
                if offset % 1024 == 0 { try cancellation?.check() }
                if !touched.contains(index) { retained.append(index) }
            }
            let sorted = try sortedIndices(live, ordering: ordering, cancellation: cancellation)
            sortOrders[ordering] = try merged(retained, sorted, cancellation: cancellation) { less($0, $1, ordering: ordering) }
        }
    }

    private func position(for id: Int64) -> UInt32? {
        var lower = 0
        var upper = idOrder.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let candidate = rows[idOrder[middle]].id
            if candidate < id { lower = middle + 1 } else { upper = middle }
        }
        guard lower < idOrder.count, rows[idOrder[lower]].id == id else { return nil }
        return idOrder[lower]
    }

    private func sortedIndices(_ indices: [UInt32], ordering: Ordering, cancellation: SearchCancellation?) throws -> [UInt32] {
        var comparisons = 0
        return try indices.sorted {
            comparisons += 1
            if comparisons % 1024 == 0 { try cancellation?.check() }
            return less($0, $1, ordering: ordering)
        }
    }

    private func less(_ leftIndex: UInt32, _ rightIndex: UInt32, ordering: Ordering) -> Bool {
        let left = rows[leftIndex]
        let right = rows[rightIndex]
        let primary: ComparisonResult
        switch ordering.key {
        case .name: primary = compareNames(left, right)
        case .size: primary = left.size == right.size ? .orderedSame : (left.size < right.size ? .orderedAscending : .orderedDescending)
        case .modified: primary = left.modified == right.modified ? .orderedSame : (left.modified < right.modified ? .orderedAscending : .orderedDescending)
        case .kind: primary = left.isDirectory == right.isDirectory ? .orderedSame : (!left.isDirectory ? .orderedAscending : .orderedDescending)
        case .path: primary = left.id == right.id ? .orderedSame : (left.id < right.id ? .orderedAscending : .orderedDescending)
        }
        if primary != .orderedSame { return primary == (ordering.ascending ? .orderedAscending : .orderedDescending) }
        if ordering.key != .name {
            let nameOrder = compareNames(left, right)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        }
        return left.id < right.id
    }

    private func compareNames(_ left: Row, _ right: Row) -> ComparisonResult {
        if left.isASCII && right.isASCII {
            for offset in 0..<min(Int(left.nameLength), Int(right.nameLength)) {
                let a = names[left.nameOffset + offset]
                let b = names[right.nameOffset + offset]
                let foldedA = a >= 65 && a <= 90 ? a + 32 : a
                let foldedB = b >= 65 && b <= 90 ? b + 32 : b
                if foldedA != foldedB { return foldedA < foldedB ? .orderedAscending : .orderedDescending }
            }
            return left.nameLength == right.nameLength ? .orderedSame : (left.nameLength < right.nameLength ? .orderedAscending : .orderedDescending)
        }
        return name(for: left).compare(name(for: right), options: .caseInsensitive)
    }

    private func merged(_ left: [UInt32], _ right: [UInt32], cancellation: SearchCancellation?, less: (UInt32, UInt32) -> Bool) throws -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(left.count + right.count)
        var a = 0
        var b = 0
        while a < left.count || b < right.count {
            if result.count % 1024 == 0 { try cancellation?.check() }
            if b == right.count || (a < left.count && less(left[a], right[b])) {
                result.append(left[a]); a += 1
            } else {
                result.append(right[b]); b += 1
            }
        }
        return result
    }

}

private extension Array {
    subscript(position: UInt32) -> Element {
        get { self[Int(position)] }
        set { self[Int(position)] = newValue }
    }
}
