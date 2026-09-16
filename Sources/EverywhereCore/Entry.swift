import Foundation

public struct Entry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date

    public var kind: String {
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased() + " File"
    }

    public init(id: Int64, path: String, name: String, isDirectory: Bool, size: Int64, modified: Date) {
        self.id = id
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public struct IndexRow: Sendable {
    public var id: Int64
    public var parent: Int64
    public var name: String
    public var isDir: Bool
    public var size: Int64
    public var modified: Double

    public init(id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double) {
        self.id = id
        self.parent = parent
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modified = modified
    }
}

public enum KindFilter: String, CaseIterable, Sendable {
    case all
    case folders
    case files
}

public enum SortKey: String, CaseIterable, Hashable, Sendable {
    case name
    case path
    case size
    case kind
    case modified
}

public struct SearchRequest: Equatable, Sendable {
    public var text: String
    public var kind: KindFilter
    public var includeHidden: Bool
    public var matchPath: Bool
    public var useRegex: Bool
    public var matchCase: Bool
    public var wholeWord: Bool
    public var sortKey: SortKey
    public var ascending: Bool
    public var offset: Int
    public var limit: Int

    public init(text: String = "",
                kind: KindFilter = .all,
                includeHidden: Bool = true,
                matchPath: Bool = false,
                useRegex: Bool = false,
                matchCase: Bool = false,
                wholeWord: Bool = false,
                sortKey: SortKey = .name,
                ascending: Bool = true,
                limit: Int = 10_000,
                offset: Int = 0) {
        self.text = text
        self.kind = kind
        self.includeHidden = includeHidden
        self.matchPath = matchPath
        self.useRegex = useRegex
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.sortKey = sortKey
        self.ascending = ascending
        self.limit = limit
        self.offset = offset
    }
}

public struct SearchCacheStatistics: Sendable, Equatable {
    public var itemCount: Int = 0
    public var storageBytes: Int = 0
    public var sortBytes: Int = 0
    public var sortCount: Int = 0
    public var fullLoads: Int = 0
    public var incrementalRefreshes: Int = 0

    public init() {}

    init(itemCount: Int, storageBytes: Int, sortBytes: Int, sortCount: Int) {
        self.itemCount = itemCount
        self.storageBytes = storageBytes
        self.sortBytes = sortBytes
        self.sortCount = sortCount
    }
}

public struct SearchResult: Sendable {
    public var entries: [Entry]
    public var total: Int
    public var elapsedMS: Double
    public var snapshotVersion: Int64 = 0
    public var cacheStatistics = SearchCacheStatistics()

    public init(entries: [Entry], total: Int, elapsedMS: Double) {
        self.entries = entries
        self.total = total
        self.elapsedMS = elapsedMS
    }
}

public enum SearchQueryBuilder {
    public static func fts5Query(for text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }
}
