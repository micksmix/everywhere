import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case sql(String, sql: String)
    case invalidRegex(String)
    case invalidQuery(String)

    public var errorDescription: String? {
        switch self {
        case .open(let path):
            return "Could not open index database at \(path)."
        case .sql(let message, let sql):
            return "SQL error: \(message) — \(sql)"
        case .invalidQuery(let message):
            return message
        case .invalidRegex(let pattern):
            return "Invalid regular expression: \(pattern)"
        }
    }
}

final class RegexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pattern: String?
    private var compiledCaseSensitive: NSRegularExpression?
    private var compiledCaseInsensitive: NSRegularExpression?
    private var activeCaseSensitive = false

    func set(pattern: String, caseSensitive: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if self.pattern == pattern {
            if caseSensitive && compiledCaseSensitive != nil {
                activeCaseSensitive = true
                return
            }
            if !caseSensitive && compiledCaseInsensitive != nil {
                activeCaseSensitive = false
                return
            }
        } else {
            self.pattern = pattern
            compiledCaseSensitive = nil
            compiledCaseInsensitive = nil
        }
        do {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            let compiled = try NSRegularExpression(pattern: pattern, options: options)
            if caseSensitive {
                compiledCaseSensitive = compiled
            } else {
                compiledCaseInsensitive = compiled
            }
            activeCaseSensitive = caseSensitive
        } catch {
            self.pattern = nil
            compiledCaseSensitive = nil
            compiledCaseInsensitive = nil
            throw DatabaseError.invalidRegex(pattern)
        }
    }

    func matches(_ value: String) -> Bool {
        lock.lock()
        let compiled = activeCaseSensitive ? compiledCaseSensitive : compiledCaseInsensitive
        lock.unlock()
        guard let compiled else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return compiled.firstMatch(in: value, options: [], range: range) != nil
    }
}

final class PatternCache: @unchecked Sendable {
    private let lock = NSLock()
    private var patterns: [String: NSRegularExpression] = [:]

    func regex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = patterns[key] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        if patterns.count > 200 {
            patterns.removeAll()
        }
        patterns[key] = compiled
        return compiled
    }
}

public final class Database: @unchecked Sendable {
    public let path: String

    private let writer: OpaquePointer
    private let reader: OpaquePointer
    private let searchReader: OpaquePointer
    private let searchLock = NSLock()
    private var searchCancellation: SearchCancellation?
    private typealias BareRow = (id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double)
    private var memoryRows: FilenameIndex?
    private var memoryVersion: Int64 = -1
    private var memoryWriterVersion: Int64?
    private var pendingMemoryChanges = Set<Int64>()
    private var memoryRequiresFullReload = true
    private var memoryFullLoads = 0
    private var memoryIncrementalRefreshes = 0
    private let lock = NSRecursiveLock()
    private var upsertStatement: OpaquePointer?
    private var fastInsertStatement: OpaquePointer?
    private var bulkMode = false
    private let regexBox = RegexBox()
    private var nextIDValue: Int64 = 1

    static let schemaVersion: Int32 = 4

    private static let tableSQL = """
    CREATE TABLE IF NOT EXISTS entries (
        id INTEGER PRIMARY KEY,
        parent INTEGER NOT NULL,
        name TEXT NOT NULL,
        is_dir INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        modified INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS entries_parent_name ON entries(parent, name);
    CREATE INDEX IF NOT EXISTS entries_size ON entries(size);
    CREATE INDEX IF NOT EXISTS entries_modified ON entries(modified);
    """

    private static let ftsSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        name,
        content='entries', content_rowid='id', columnsize=0
    );
    """

    private static let triggerSQL = """
    CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, name) VALUES (new.id, new.name);
    END;
    CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, name) VALUES ('delete', old.id, old.name);
    END;
    CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, name) VALUES ('delete', old.id, old.name);
        INSERT INTO entries_fts(rowid, name) VALUES (new.id, new.name);
    END;
    """

    private static let fastInsertSQL = """
    INSERT INTO entries (id, parent, name, is_dir, size, modified)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    """

    private static let upsertSQL = """
    INSERT INTO entries (id, parent, name, is_dir, size, modified)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT(parent, name) DO UPDATE SET
        id = excluded.id,
        is_dir = excluded.is_dir,
        size = excluded.size,
        modified = excluded.modified
    """

    public init(path: String) throws {
        try Self.removeOutdatedDatabase(at: path)
        self.path = path

        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let createFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, createFlags, nil) == SQLITE_OK, let writer = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError.open("\(path): \(message)")
        }
        self.writer = writer

        var readHandle: OpaquePointer?
        let readFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &readHandle, readFlags, nil) == SQLITE_OK, let reader = readHandle else {
            let message = readHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(readHandle)
            sqlite3_close(writer)
            throw DatabaseError.open("\(path): \(message)")
        }
        self.reader = reader
        var searchHandle: OpaquePointer?
        guard sqlite3_open_v2(path, &searchHandle, readFlags, nil) == SQLITE_OK, let searchReader = searchHandle else {
            sqlite3_close(searchHandle)
            sqlite3_close(reader)
            sqlite3_close(writer)
            throw DatabaseError.open(path)
        }
        self.searchReader = searchReader

        try exec(writer, "PRAGMA page_size=8192")
        try exec(writer, "PRAGMA journal_mode=WAL")
        try exec(writer, "PRAGMA synchronous=NORMAL")
        try exec(writer, "PRAGMA case_sensitive_like=ON")
        try exec(writer, "PRAGMA temp_store=MEMORY")
        try exec(writer, "PRAGMA busy_timeout=10000")
        try exec(writer, "PRAGMA cache_size=-131072")
        try exec(reader, "PRAGMA busy_timeout=10000")
        try exec(searchReader, "PRAGMA busy_timeout=1000")
        try exec(writer, Self.tableSQL)
        try exec(writer, Self.ftsSQL)
        try exec(writer, Self.triggerSQL)
        try exec(writer, "PRAGMA user_version=\(Self.schemaVersion)")
        try exec(searchReader, "PRAGMA cache_size=-8192")
        nextIDValue = (try? loadMaxID()) ?? 1
        sqlite3_update_hook(writer, { context, _, _, table, id in
            guard let context, let table else { return }
            let database = Unmanaged<Database>.fromOpaque(context).takeUnretainedValue()
            guard strcmp(table, "entries") == 0 else { return }
            database.recordMemoryChange(id)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private static func removeOutdatedDatabase(at path: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }

        var probe: OpaquePointer?
        guard sqlite3_open_v2(path, &probe, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(probe)
            return
        }
        defer { sqlite3_close(probe) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(probe, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return }
        let version = sqlite3_column_int(statement, 0)
        guard version != schemaVersion else { return }

        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: path + suffix)
        }
    }

    deinit {
        sqlite3_update_hook(writer, nil, nil)
        sqlite3_finalize(upsertStatement)
        sqlite3_finalize(fastInsertStatement)
        sqlite3_close(writer)
        sqlite3_close(reader)
        sqlite3_close(searchReader)
    }

    public static func validateIndexLocation(_ path: String) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            let parent = (path as NSString).deletingLastPathComponent
            guard manager.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue,
                  manager.isWritableFile(atPath: parent) else {
                throw DatabaseError.open("Choose a file in an existing writable folder.")
            }
            return
        }
        guard !isDirectory.boolValue, manager.isWritableFile(atPath: path) else {
            throw DatabaseError.open("Choose a writable index file, not a folder.")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw DatabaseError.open("The selected index could not be read.")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int(statement, 0) == schemaVersion else {
            throw DatabaseError.open("Choose an Everywhere index with the current format, or a new file.")
        }
        sqlite3_finalize(statement)
        statement = nil
        guard sqlite3_prepare_v2(handle, "SELECT id, parent, name, is_dir, size, modified FROM entries LIMIT 0", -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.open("The selected file is not an Everywhere index.")
        }
    }

    public static func defaultPath() -> String {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("Everywhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("index.sqlite").path
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.sql(message, sql: sql)
        }
    }

    private static func errorMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func entry(from statement: OpaquePointer) -> Entry {
        let id = sqlite3_column_int64(statement, 0)
        let path = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let name = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let isDir = sqlite3_column_int(statement, 3) != 0
        let size = sqlite3_column_int64(statement, 4)
        let modified = sqlite3_column_int64(statement, 5)
        return Entry(
            id: id,
            path: path,
            name: name,
            isDirectory: isDir,
            size: size,
            modified: Date(timeIntervalSince1970: Double(modified))
        )
    }

    public func nextID() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextIDValue
        nextIDValue += 1
        return id
    }

    public func allocateIDs(_ count: Int) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let start = nextIDValue
        nextIDValue += Int64(max(1, count))
        return start
    }

    private func loadMaxID() throws -> Int64 {
        let sql = "SELECT COALESCE(MAX(id), 0) FROM entries"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(reader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(reader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_ROW else {
            throw DatabaseError.sql(Self.errorMessage(reader), sql: sql)
        }
        return sqlite3_column_int64(prepared, 0) + 1
    }

    public func ensureRootRow(path: String) throws -> Int64 {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let name = trimmed == "/" ? "" : trimmed

        lock.lock()
        defer { lock.unlock() }
        let lookupSQL = "SELECT id FROM entries WHERE parent = 0 AND name = ?1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, lookupSQL, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: lookupSQL)
        }
        defer { sqlite3_finalize(prepared) }
        Self.bindText(prepared, 1, name)
        if sqlite3_step(prepared) == SQLITE_ROW {
            return sqlite3_column_int64(prepared, 0)
        }

        let id = nextID()
        let now = Int64(Date().timeIntervalSince1970)
        try insert(rows: [IndexRow(id: id, parent: 0, name: name, isDir: true, size: 0, modified: Double(now))])
        return id
    }

    func ensureDirectoryRow(path: String, roots: [String]) throws -> Int64? {
        let path = Walk.normalizePath(path)
        guard let root = roots.map(Walk.normalizePath).filter({
            $0 == path || $0 == "/" || path.hasPrefix($0 + "/")
        }).min(by: { $0.count < $1.count }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var parent = try ensureRootRow(path: root)
        let components = path.dropFirst(root == "/" ? 1 : root.count).split(separator: "/")
        let sql = "SELECT id FROM entries WHERE parent = ?1 AND name = ?2"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        for component in components {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, parent)
            Self.bindText(statement, 2, String(component))
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                parent = sqlite3_column_int64(statement, 0)
            } else if result == SQLITE_DONE {
                let id = nextID()
                try insert(rows: [IndexRow(id: id, parent: parent, name: String(component), isDir: true, size: 0, modified: 0)])
                parent = id
            } else {
                throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
            }
        }
        return parent
    }

    public func beginBulkLoad() throws {
        lock.lock()
        defer { lock.unlock() }
        memoryRequiresFullReload = true
        pendingMemoryChanges.removeAll()
        bulkMode = true
        try exec(writer, "DROP TRIGGER IF EXISTS entries_ai")
        try exec(writer, "DROP TRIGGER IF EXISTS entries_ad")
        try exec(writer, "DROP TRIGGER IF EXISTS entries_au")
    }

    public func endBulkLoad() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try exec(writer, "INSERT INTO entries_fts(entries_fts) VALUES('rebuild')")
            try exec(writer, "INSERT INTO entries_fts(entries_fts) VALUES('optimize')")
        } catch {
            bulkMode = false
            try exec(writer, Self.triggerSQL)
            throw error
        }
        bulkMode = false
        try exec(writer, Self.triggerSQL)
        try exec(writer, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func insert(rows: [IndexRow]) throws {
        guard !rows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let statement: OpaquePointer
        if bulkMode {
            if fastInsertStatement == nil {
                var prepared: OpaquePointer?
                guard sqlite3_prepare_v2(writer, Self.fastInsertSQL, -1, &prepared, nil) == SQLITE_OK, let p = prepared else {
                    throw DatabaseError.sql(Self.errorMessage(writer), sql: Self.fastInsertSQL)
                }
                fastInsertStatement = p
            }
            statement = fastInsertStatement!
        } else {
            if upsertStatement == nil {
                var prepared: OpaquePointer?
                guard sqlite3_prepare_v2(writer, Self.upsertSQL, -1, &prepared, nil) == SQLITE_OK, let p = prepared else {
                    throw DatabaseError.sql(Self.errorMessage(writer), sql: Self.upsertSQL)
                }
                upsertStatement = p
            }
            statement = upsertStatement!
        }

        try rememberReplacedIDs(rows)
        try exec(writer, "BEGIN IMMEDIATE")
        do {
            for row in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, row.id)
                sqlite3_bind_int64(statement, 2, row.parent)
                Self.bindText(statement, 3, row.name)
                sqlite3_bind_int(statement, 4, row.isDir ? 1 : 0)
                sqlite3_bind_int64(statement, 5, row.size)
                sqlite3_bind_int64(statement, 6, Int64(row.modified))
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.sql(Self.errorMessage(writer), sql: Self.upsertSQL)
                }
            }
            try exec(writer, "COMMIT")
        } catch {
            try? exec(writer, "ROLLBACK")
            throw error
        }
    }

    public func deleteSubtree(id: Int64) throws {
        let sql = """
        WITH RECURSIVE sub(id) AS (
            SELECT id FROM entries WHERE id = ?1
            UNION ALL
            SELECT e.id FROM entries e JOIN sub ON e.parent = sub.id
        )
        DELETE FROM entries WHERE id IN (SELECT id FROM sub)
        """
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_int64(prepared, 1, id)
        guard sqlite3_step(prepared) == SQLITE_DONE else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
        }
    }

    public func deleteIDs(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for chunk in ids.chunked(into: 400) {
            let placeholders = (1...chunk.count).map { "?\($0)" }.joined(separator: ", ")
            let sql = "DELETE FROM entries WHERE id IN (\(placeholders))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
                throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
            }
            defer { sqlite3_finalize(prepared) }
            for (index, id) in chunk.enumerated() {
                sqlite3_bind_int64(prepared, Int32(index + 1), id)
            }
            guard sqlite3_step(prepared) == SQLITE_DONE else {
                throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
            }
        }
    }

    public func children(ofParent parent: Int64) throws -> [Entry] {
        let sql = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE parent = ?1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(reader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(reader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_int64(prepared, 1, parent)
        var entries: [Entry] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let id = sqlite3_column_int64(prepared, 0)
            let name = sqlite3_column_text(prepared, 2).map { String(cString: $0) } ?? ""
            let isDir = sqlite3_column_int(prepared, 3) != 0
            let size = sqlite3_column_int64(prepared, 4)
            let modified = sqlite3_column_int64(prepared, 5)
            entries.append(Entry(id: id, path: "", name: name, isDirectory: isDir, size: size, modified: Date(timeIntervalSince1970: Double(modified))))
        }
        return entries
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        memoryRequiresFullReload = true
        pendingMemoryChanges.removeAll()
        try exec(writer, "BEGIN IMMEDIATE")
        do {
            try exec(writer, "DELETE FROM entries")
            try exec(writer, "COMMIT")
        } catch {
            try? exec(writer, "ROLLBACK")
            throw error
        }
        nextIDValue = 1
    }

    @discardableResult
    func compactIfNeeded(minimumFreeBytes: Int64 = 128 * 1024 * 1024,
                         minimumFreeFraction: Double = 0.25) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !bulkMode else { return false }
        let pageSize = try pragmaInteger("page_size")
        let pages = try pragmaInteger("page_count")
        let freePages = try pragmaInteger("freelist_count")
        guard pages > 0, freePages > 0,
              freePages * pageSize >= minimumFreeBytes,
              Double(freePages) / Double(pages) >= minimumFreeFraction else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory)
        guard let available = attributes[.systemFreeSize] as? NSNumber,
              available.int64Value >= pages * pageSize * 2 else { return false }
        sqlite3_finalize(upsertStatement)
        upsertStatement = nil
        sqlite3_finalize(fastInsertStatement)
        fastInsertStatement = nil
        try exec(writer, "INSERT INTO entries_fts(entries_fts) VALUES('optimize')")
        try exec(writer, "VACUUM")
        try exec(writer, "PRAGMA wal_checkpoint(TRUNCATE)")
        return true
    }

    private func pragmaInteger(_ name: String) throws -> Int64 {
        let sql = "PRAGMA \(name)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
        }
        return sqlite3_column_int64(statement, 0)
    }

    public func count() throws -> Int {
        let sql = "SELECT COUNT(*) FROM entries"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(reader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(reader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_ROW else {
            throw DatabaseError.sql(Self.errorMessage(reader), sql: sql)
        }
        return Int(sqlite3_column_int64(prepared, 0))
    }

    public func search(_ request: SearchRequest, useMemory: Bool = false,
                       cancellation: SearchCancellation = SearchCancellation()) throws -> SearchResult {
        try performSearch(request, useMemory: useMemory, cancellation: cancellation, preparing: false)
    }

    public func prepareSearchIndex(sortKey: SortKey = .name, ascending: Bool = true,
                                   cancellation: SearchCancellation = SearchCancellation()) throws {
        _ = try performSearch(SearchRequest(sortKey: sortKey, ascending: ascending), useMemory: true,
                              cancellation: cancellation, preparing: true)
    }

    private func performSearch(_ request: SearchRequest, useMemory: Bool,
                               cancellation: SearchCancellation, preparing: Bool) throws -> SearchResult {
        searchLock.lock()
        defer { searchLock.unlock() }
        try cancellation.check()
        searchCancellation = cancellation
        sqlite3_progress_handler(searchReader, 1000, { context in
            guard let context else { return 0 }
            return Unmanaged<SearchCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer {
            sqlite3_progress_handler(searchReader, 0, nil, nil)
            sqlite3_exec(searchReader, "ROLLBACK", nil, nil, nil)
            searchCancellation = nil
        }
        try exec(searchReader, "BEGIN")
        if !useMemory {
            memoryRows = nil
            memoryVersion = -1
            memoryWriterVersion = nil
        }
        let started = CFAbsoluteTimeGetCurrent()
        let useRegex = request.useRegex && !request.text.isEmpty
        if useRegex {
            try regexBox.set(pattern: request.text, caseSensitive: request.matchCase)
        }

        let result: SearchResult
        if preparing {
            try refreshMemoryIndex()
            try memoryRows?.prepareSort(key: request.sortKey, ascending: request.ascending, cancellation: cancellation)
            result = SearchResult(entries: [], total: 0, elapsedMS: 0)
        } else if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = try recentItems(request)
        } else if useRegex && request.matchPath {
            result = try scanSearch(request, useRegex: true)
        } else if useRegex {
            result = try regexSearch(request)
        } else if FilterQuery.containsFilters(request.text) {
            result = try filteredSearch(request, useMemory: useMemory)
        } else if isNameQuery(request), !request.wholeWord {
            result = try nameSearch(request, useMemory: useMemory)
        } else if let match = ftsQueryFor(request) {
            result = try ftsSearch(request, match: match)
        } else {
            result = try scanSearch(request, useRegex: false)
        }

        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, "PRAGMA data_version", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { throw DatabaseError.sql(Self.errorMessage(searchReader), sql: "PRAGMA data_version") }
        defer { sqlite3_finalize(versionStatement) }
        _ = try stepSearch(versionStatement)
        let snapshotVersion = sqlite3_column_int64(versionStatement, 0)
        try cancellation.check()
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        var completed = SearchResult(entries: result.entries, total: result.total, elapsedMS: elapsed)
        completed.snapshotVersion = snapshotVersion
        completed.cacheStatistics = memoryRows?.statistics ?? SearchCacheStatistics()
        completed.cacheStatistics.fullLoads = memoryFullLoads
        completed.cacheStatistics.incrementalRefreshes = memoryIncrementalRefreshes
        return completed
    }

    private func recordMemoryChange(_ id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !memoryRequiresFullReload else { return }
        if pendingMemoryChanges.count >= 50_000 {
            memoryRequiresFullReload = true
            pendingMemoryChanges.removeAll()
        } else {
            pendingMemoryChanges.insert(id)
        }
    }

    private func rememberReplacedIDs(_ rows: [IndexRow]) throws {
        guard !bulkMode, !memoryRequiresFullReload else { return }
        let sql = "SELECT id FROM entries WHERE parent = ?1 AND name = ?2 AND id != ?3"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sql(Self.errorMessage(writer), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            if memoryRequiresFullReload { break }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, row.parent)
            Self.bindText(statement, 2, row.name)
            sqlite3_bind_int64(statement, 3, row.id)
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { recordMemoryChange(sqlite3_column_int64(statement, 0)) }
            else if status != SQLITE_DONE { throw DatabaseError.sql(Self.errorMessage(writer), sql: sql) }
        }
    }

    private func refreshMemoryIndex() throws {
        var holdsWriterLock = lock.try()
        defer { if holdsWriterLock { lock.unlock() } }
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, "PRAGMA data_version", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { throw DatabaseError.sql(Self.errorMessage(searchReader), sql: "PRAGMA data_version") }
        defer { sqlite3_finalize(versionStatement) }
        _ = try stepSearch(versionStatement)
        let version = sqlite3_column_int64(versionStatement, 0)
        _ = try bareRows("SELECT id, parent, name, is_dir, size, modified FROM entries LIMIT 1")
        if let memoryRows, memoryVersion == version, !memoryRows.needsCompaction { return }
        var changedIDs: Set<Int64>?
        if holdsWriterLock {
            let writerVersion = try pragmaInteger("data_version")
            if memoryRows != nil && !memoryRequiresFullReload && memoryWriterVersion == writerVersion {
                changedIDs = pendingMemoryChanges
            }
            pendingMemoryChanges.removeAll()
            memoryRequiresFullReload = false
            memoryWriterVersion = writerVersion
            lock.unlock()
            holdsWriterLock = false
        } else {
            memoryWriterVersion = nil
        }
        do {
            if let changedIDs, let memoryRows, !memoryRows.needsCompaction {
                var replacements: [Int64: IndexRow] = [:]
                for chunk in Array(changedIDs).chunked(into: 400) {
                    let ids = chunk.map(String.init).joined(separator: ",")
                    for row in try bareRows("SELECT id, parent, name, is_dir, size, modified FROM entries WHERE id IN (\(ids))") {
                        replacements[row.id] = IndexRow(id: row.id, parent: row.parent, name: row.name, isDir: row.isDir,
                                                        size: row.size, modified: row.modified)
                    }
                }
                try memoryRows.apply(changedIDs: changedIDs, replacements: replacements, cancellation: searchCancellation)
                memoryIncrementalRefreshes += 1
            } else {
                memoryRows = nil
                memoryRows = try FilenameIndex(connection: searchReader, step: stepSearch)
                memoryFullLoads += 1
            }
            memoryVersion = version
        } catch {
            memoryRows = nil
            memoryVersion = -1
            memoryWriterVersion = nil
            throw error
        }
    }

    private func stepSearch(_ statement: OpaquePointer) throws -> Int32 {
        try searchCancellation?.check()
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else {
            try searchCancellation?.check()
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: String(cString: sqlite3_sql(statement)))
        }
        return status
    }

    private func isNameQuery(_ request: SearchRequest) -> Bool {
        !request.useRegex && !request.matchPath && !SearchQueryParser.parse(request.text).groups.contains {
            $0.terms.contains { $0.hasPathSeparator }
        }
    }

    private func filteredSearch(_ request: SearchRequest, useMemory: Bool) throws -> SearchResult {
        let query = try FilterQuery(request.text)
        if useMemory, !request.matchPath, query.groups.count == 1, let group = query.groups.first,
           !group.terms.contains(where: { $0.hasPathSeparator }),
           !group.filters.contains(where: { if case .scope = $0.predicate { return true }; return false }) {
            try refreshMemoryIndex()
            guard let memoryRows else { return SearchResult(entries: [], total: 0, elapsedMS: 0) }
            let selected = try memoryRows.select(request: request, cancellation: searchCancellation, filteredGroup: group)
            let paths = try materializePaths(ids: selected.rows.map { $0.0.id })
            let entries = selected.rows.map { row, name in
                Entry(id: row.id, path: paths[row.id] ?? name, name: name, isDirectory: row.isDirectory,
                      size: row.size, modified: Date(timeIntervalSince1970: row.modified))
            }
            return SearchResult(entries: entries, total: selected.total, elapsedMS: 0)
        }
        var scopes: [String] = []
        var conditions: [String] = []
        for group in query.groups {
            var predicates: [String] = []
            for filter in group.filters {
                let predicate: String
                switch filter.predicate {
                case .scope(let path, let recursive):
                    let roots = try scopeRoots(path: path, recursive: recursive, matchCase: request.matchCase)
                    let parents = roots.folders.map(String.init).joined(separator: ",")
                    let included = roots.included.map(String.init).joined(separator: ",")
                    let name = "scope\(scopes.count)"
                    let anchor = "SELECT id FROM entries WHERE parent IN (\(parents)) OR id IN (\(included))"
                    scopes.append("\(name)(id) AS (\(anchor)" + (recursive ? " UNION ALL SELECT e.id FROM entries e JOIN \(name) s ON e.parent = s.id" : "") + ")")
                    predicate = "id IN (SELECT id FROM \(name))"
                case .directory(let directory): predicate = "is_dir = \(directory ? 1 : 0)"
                case .size(let range): predicate = "is_dir = 0 AND (\(rangeSQL(range, column: "size")))"
                case .modified(let range): predicate = rangeSQL(range, column: "modified")
                case .extensions: continue
                }
                predicates.append(filter.negated ? "NOT (\(predicate))" : "(\(predicate))")
            }
            if !request.matchPath {
                for term in group.terms where !term.isNegated && !term.hasWildcards && !term.hasPathSeparator && term.text.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) {
                    let literal = term.text.lowercased().replacingOccurrences(of: "'", with: "''")
                    predicates.append("(instr(lower(name), '\(literal)') > 0 OR name GLOB '*[^ -~]*')")
                }
            }
            conditions.append(predicates.isEmpty ? "1" : predicates.joined(separator: " AND "))
        }
        let matchers = query.groups.map { group in
            group.terms.map { term -> (NameQuery, Bool, String?, Bool) in
                let parsed = ParsedQuery(groups: [ParsedGroup(terms: [ParsedTerm(text: term.text, isNegated: false, isQuoted: term.isQuoted)])])
                return (NameQuery(request, parsed: parsed), request.matchPath || term.hasPathSeparator,
                        term.endsWithPathSeparator && !term.hasWildcards ? term.text : nil, term.isNegated)
            }
        }
        let columns = conditions.enumerated().map { "(\($0.element)) AS g\($0.offset)" }.joined(separator: ", ")
        let allowed = conditions.indices.map { "g\($0)" }.joined(separator: " OR ")
        let sql = (scopes.isEmpty ? "" : "WITH RECURSIVE " + scopes.joined(separator: ", ") + " ") +
            "SELECT id, parent, name, is_dir, size, modified, \(columns) FROM entries WHERE name != '' AND (\(allowed))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        var matches: [BareRow] = []
        while try stepSearch(statement) == SQLITE_ROW {
            let row = Self.bareRow(statement)
            guard request.includeHidden || !row.name.hasPrefix("."),
                  request.kind != .files || !row.isDir, request.kind != .folders || row.isDir else { continue }
            var path: String?
            for (index, group) in query.groups.enumerated() {
                guard sqlite3_column_int(statement, Int32(6 + index)) != 0,
                      group.filters.allSatisfy({ $0.matches(name: row.name, isDirectory: row.isDir, size: row.size, modified: row.modified) }) else { continue }
                var matched = true
                for (matcher, usesPath, prefix, negated) in matchers[index] {
                    if usesPath && path == nil { path = try resolvePath(for: row.id) }
                    let target = usesPath ? path! : row.name
                    let found: Bool
                    if let prefix {
                        found = request.matchCase ? target.hasPrefix(prefix) : target.lowercased().hasPrefix(prefix.lowercased())
                    } else {
                        found = matcher.matches(target)
                    }
                    if negated ? found : !found { matched = false; break }
                }
                if matched { matches.append(row); break }
            }
        }
        let sorted = try sortedRows(matches, request: request)
        let page = sorted.dropFirst(max(0, request.offset)).prefix(max(1, min(request.limit, 100_000)))
        let paths = try materializePaths(ids: page.map(\.id))
        let entries = page.map { Entry(id: $0.id, path: paths[$0.id] ?? $0.name, name: $0.name,
                                      isDirectory: $0.isDir, size: $0.size, modified: Date(timeIntervalSince1970: $0.modified)) }
        return SearchResult(entries: entries, total: matches.count, elapsedMS: 0)
    }

    private func rangeSQL(_ range: FilterQuery.NumericRange, column: String) -> String {
        var conditions: [String] = []
        if range.minimum.isFinite { conditions.append("\(column) \(range.includesMinimum ? ">=" : ">") \(range.minimum)") }
        if range.maximum.isFinite { conditions.append("\(column) \(range.includesMaximum ? "<=" : "<") \(range.maximum)") }
        let condition = conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
        return range.inverted ? "NOT (\(condition))" : condition
    }

    private func scopeRoots(path: String, recursive: Bool, matchCase: Bool) throws -> (folders: [Int64], included: [Int64]) {
        func components(_ path: String) -> [String] { path.split(separator: "/").map { matchCase ? String($0) : $0.lowercased() } }
        func directories(parent: Int64) throws -> [(Int64, String)] {
            let sql = "SELECT id, name FROM entries WHERE parent = ?1 AND is_dir = 1"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, parent)
            var result: [(Int64, String)] = []
            while try stepSearch(statement) == SQLITE_ROW {
                result.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1))))
            }
            return result
        }
        let target = components(path)
        var folders: [Int64] = []
        var included: [Int64] = []
        for (id, name) in try directories(parent: 0) {
            let root = components(name)
            if root.count > target.count, Array(root.prefix(target.count)) == target {
                if recursive || root.count == target.count + 1 { included.append(id) }
            } else if target.count >= root.count, Array(target.prefix(root.count)) == root {
                var parents = [id]
                for component in target.dropFirst(root.count) {
                    var next: [Int64] = []
                    for parent in parents {
                        for (child, name) in try directories(parent: parent) where (matchCase ? name : name.lowercased()) == component { next.append(child) }
                    }
                    parents = next
                    if parents.isEmpty { break }
                }
                folders.append(contentsOf: parents)
            }
        }
        return (folders, included)
    }

    private func nameSearch(_ request: SearchRequest, useMemory: Bool) throws -> SearchResult {
        let query = NameQuery(request)
        let limit = max(1, min(request.limit, 100_000))
        var matched: [BareRow] = []
        func consider(_ row: BareRow) {
            guard !row.name.isEmpty,
                  request.includeHidden || !row.name.hasPrefix("."),
                  request.kind != .files || !row.isDir,
                  request.kind != .folders || row.isDir else { return }
            if query.matches(row.name) { matched.append(row) }
        }
        if useMemory {
            try refreshMemoryIndex()
            guard let memoryRows else { return SearchResult(entries: [], total: 0, elapsedMS: 0) }
            let selected = try memoryRows.select(request: request, cancellation: searchCancellation)
            let paths = try materializePaths(ids: selected.rows.map { $0.0.id })
            let entries = selected.rows.map { row, name in
                Entry(id: row.id, path: paths[row.id] ?? name, name: name, isDirectory: row.isDirectory,
                      size: row.size, modified: Date(timeIntervalSince1970: row.modified))
            }
            return SearchResult(entries: entries, total: selected.total, elapsedMS: 0)
        } else {
            let sql = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE name != ''"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
            }
            defer { sqlite3_finalize(statement) }
            while try stepSearch(statement) == SQLITE_ROW { consider(Self.bareRow(statement)) }
        }
        matched = try sortedRows(matched, request: request)
        let rows = Array(matched.dropFirst(max(0, request.offset)).prefix(limit))
        let paths = try materializePaths(ids: rows.map(\.id))
        let entries = rows.map { row in
            Entry(id: row.id, path: paths[row.id] ?? row.name, name: row.name, isDirectory: row.isDir,
                  size: row.size, modified: Date(timeIntervalSince1970: row.modified))
        }
        return SearchResult(entries: entries, total: matched.count, elapsedMS: 0)
    }

    private func sortedRows(_ rows: [BareRow], request: SearchRequest) throws -> [BareRow] {
        var matched = rows
        try searchCancellation?.check()
        var comparisons = 0
        try matched.sort { left, right in
            comparisons += 1
            if comparisons % 4096 == 0 { try searchCancellation?.check() }
            let order: ComparisonResult
            switch request.sortKey {
            case .name: order = left.name.compare(right.name, options: .caseInsensitive)
            case .path: order = left.id == right.id ? .orderedSame : (left.id < right.id ? .orderedAscending : .orderedDescending)
            case .size: order = left.size == right.size ? .orderedSame : (left.size < right.size ? .orderedAscending : .orderedDescending)
            case .kind: order = left.isDir == right.isDir ? .orderedSame : (!left.isDir ? .orderedAscending : .orderedDescending)
            case .modified: order = left.modified == right.modified ? .orderedSame : (left.modified < right.modified ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame {
                if request.sortKey != .name {
                    let nameOrder = left.name.compare(right.name, options: .caseInsensitive)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                }
                return left.id < right.id
            }
            return order == (request.ascending ? .orderedAscending : .orderedDescending)
        }
        try searchCancellation?.check()
        return matched
    }

    private func ftsQueryFor(_ request: SearchRequest) -> String? {
        guard !request.useRegex, !request.matchPath else { return nil }
        let parsed = SearchQueryParser.parse(request.text)
        guard parsed.groups.count == 1, !parsed.groups[0].terms.isEmpty else { return nil }
        for term in parsed.groups[0].terms {
            guard !term.isNegated, !term.hasWildcards, !term.hasPathSeparator else { return nil }
        }
        return parsed.groups[0].terms
            .map { term in
                let escaped = term.text.lowercased().replacingOccurrences(of: "\"", with: "\"\"")
                let star = request.wholeWord ? "" : "*"
                return "\"\(escaped)\"\(star)"
            }
            .joined(separator: " AND ")
    }

    private func recentItems(_ request: SearchRequest) throws -> SearchResult {
        var sql = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE name != ''"
        if !request.includeHidden {
            sql += " AND substr(name, 1, 1) != '.'"
        }
        switch request.kind {
        case .all: break
        case .folders: sql += " AND is_dir = 1"
        case .files: sql += " AND is_dir = 0"
        }
        let countSQL = sql.replacingOccurrences(of: "SELECT id, parent, name, is_dir, size, modified", with: "SELECT count(*)")
        var countStatement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, countSQL, -1, &countStatement, nil) == SQLITE_OK,
              let countStatement else { throw DatabaseError.sql(Self.errorMessage(searchReader), sql: countSQL) }
        defer { sqlite3_finalize(countStatement) }
        _ = try stepSearch(countStatement)
        let total = Int(sqlite3_column_int64(countStatement, 0))
        sql += " ORDER BY modified DESC, id DESC LIMIT \(max(1, min(request.limit, 100_000))) OFFSET \(max(0, request.offset))"
        let rows = try bareRows(sql)
        let paths = try materializePaths(ids: rows.map(\.id))
        let entries = rows.map { row in
            Entry(id: row.id, path: paths[row.id] ?? row.name, name: row.name, isDirectory: row.isDir, size: row.size, modified: Date(timeIntervalSince1970: row.modified))
        }
        return SearchResult(entries: entries, total: total, elapsedMS: 0)
    }

    private func ftsSearch(_ request: SearchRequest, match: String) throws -> SearchResult {
        var sql = "SELECT entries.id, entries.parent, entries.name, entries.is_dir, entries.size, entries.modified FROM entries "
        sql += "JOIN entries_fts ON entries_fts.rowid = entries.id WHERE entries_fts MATCH ?1"
        if !request.includeHidden {
            sql += " AND substr(entries.name, 1, 1) != '.'"
        }
        switch request.kind {
        case .all: break
        case .folders: sql += " AND entries.is_dir = 1"
        case .files: sql += " AND entries.is_dir = 0"
        }
        sql += " ORDER BY \(Self.orderClause(for: request.sortKey, ascending: request.ascending))"
        if !request.matchCase {
            sql += " LIMIT \(max(1, min(request.limit, 100_000))) OFFSET \(max(0, request.offset))"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        Self.bindText(prepared, 1, match)

        var rows: [(id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double)] = []
        while try stepSearch(prepared) == SQLITE_ROW {
            rows.append(Self.bareRow(prepared))
        }

        if request.matchCase {
            let patternCache = PatternCache()
            let parsed = SearchQueryParser.parse(request.text)
            func passes(_ name: String) -> Bool {
                guard parsed.groups.count == 1 else { return false }
                return parsed.groups[0].terms.allSatisfy { term in
                    if request.wholeWord {
                        let escaped = NSRegularExpression.escapedPattern(for: term.text)
                        let pattern = "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])"
                        guard let regex = patternCache.regex(for: pattern) else { return false }
                        let range = NSRange(name.startIndex..., in: name)
                        return regex.firstMatch(in: name, options: [], range: range) != nil
                    }
                    return name.contains(term.text)
                }
            }
            rows = try rows.filter {
                try searchCancellation?.check()
                return passes($0.name)
            }
        }

        let total = request.matchCase ? rows.count : try count(match: match, request: request)
        rows = Array(rows.dropFirst(request.matchCase ? max(0, request.offset) : 0).prefix(max(1, min(request.limit, 100_000))))
        let paths = try materializePaths(ids: rows.map(\.id))
        let entries = rows.map { row in
            Entry(id: row.id, path: paths[row.id] ?? row.name, name: row.name, isDirectory: row.isDir, size: row.size, modified: Date(timeIntervalSince1970: row.modified))
        }
        return SearchResult(entries: entries, total: total, elapsedMS: 0)
    }

    private func regexSearch(_ request: SearchRequest) throws -> SearchResult {
        var candidates: [(id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double)] = []

        if let literal = Self.longestGuaranteedLiteralRun(in: request.text),
           literal.count >= 3,
           literal.allSatisfy({ $0.isASCII }) {
            let escaped = Self.escapeLike(literal.lowercased())
            var sql = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE lower(name) LIKE '%\(escaped)%' ESCAPE '\\'"
            if !request.includeHidden {
                sql += " AND substr(name, 1, 1) != '.'"
            }
            switch request.kind {
            case .all: break
            case .folders: sql += " AND is_dir = 1"
            case .files: sql += " AND is_dir = 0"
            }
            sql += " ORDER BY \(Self.orderClause(for: request.sortKey, ascending: request.ascending))"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
                throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
            }
            defer { sqlite3_finalize(prepared) }
            while try stepSearch(prepared) == SQLITE_ROW {
                candidates.append(Self.bareRow(prepared))
            }
        } else {
            let scanSQL = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE name != '' ORDER BY id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(searchReader, scanSQL, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
                throw DatabaseError.sql(Self.errorMessage(searchReader), sql: scanSQL)
            }
            defer { sqlite3_finalize(prepared) }
            while try stepSearch(prepared) == SQLITE_ROW {
                let row = Self.bareRow(prepared)
                if !request.includeHidden && row.name.hasPrefix(".") { continue }
                switch request.kind {
                case .all: break
                case .folders where !row.isDir: continue
                case .files where row.isDir: continue
                default: break
                }
                candidates.append(row)
            }
        }

        let filtered = try candidates.filter {
            try searchCancellation?.check()
            return regexBox.matches($0.name)
        }
        let matched = try sortedRows(filtered, request: request)
        let limited = matched.dropFirst(max(0, request.offset)).prefix(max(1, min(request.limit, 100_000)))
        let paths = try materializePaths(ids: limited.map(\.id))
        let entries = limited.map { row in
            Entry(id: row.id, path: paths[row.id] ?? row.name, name: row.name, isDirectory: row.isDir, size: row.size, modified: Date(timeIntervalSince1970: row.modified))
        }
        return SearchResult(entries: entries, total: matched.count, elapsedMS: 0)
    }

    static func longestGuaranteedLiteralRun(in pattern: String) -> String? {
        let quantifierCharacters = "*+?{"
        let specials = "^$.()[]}"
        let characters = Array(pattern)
        var runs: [(text: String, safe: Bool)] = []
        var current = ""
        var index = 0
        var sawAlternation = false
        var sawGroupConstruct = false

        func endRun(safe: Bool = true) {
            if !current.isEmpty {
                runs.append((current, safe))
            }
            current = ""
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else { index += 1; continue }
                let escaped = characters[index + 1]
                if escaped.isLetter || escaped.isNumber {
                    endRun()
                } else {
                    current.append(escaped)
                }
                index += 2
                continue
            }
            if character == "[" {
                endRun()
                var scan = index + 1
                if scan < characters.count && characters[scan] == "^" { scan += 1 }
                if scan < characters.count && characters[scan] == "]" { scan += 1 }
                while scan < characters.count && characters[scan] != "]" {
                    if characters[scan] == "\\" { scan += 1 }
                    scan += 1
                }
                index = min(scan + 1, characters.count)
                continue
            }
            if character == "(" {
                if index + 1 < characters.count && characters[index + 1] == "?" {
                    sawGroupConstruct = true
                }
                endRun()
                index += 1
                continue
            }
            if character == "|" {
                sawAlternation = true
                endRun()
                index += 1
                continue
            }
            if quantifierCharacters.contains(character) {
                if !current.isEmpty {
                    current.removeLast()
                }
                endRun()
                if character == "{" {
                    var scan = index + 1
                    while scan < characters.count && characters[scan] != "}" { scan += 1 }
                    index = min(scan + 1, characters.count)
                } else {
                    index += 1
                }
                continue
            }
            if specials.contains(character) {
                var safe = true
                if character == ")",
                   index + 1 < characters.count,
                   quantifierCharacters.contains(characters[index + 1]) {
                    safe = false
                }
                endRun(safe: safe)
                index += 1
                continue
            }
            if character.isLetter || character.isNumber || character == " " || character == "_" {
                current.append(character)
                index += 1
                continue
            }
            endRun()
            index += 1
        }
        endRun()

        if sawAlternation || sawGroupConstruct { return nil }
        let best = runs.filter(\.safe).map(\.text).max(by: { $0.count < $1.count })
        guard let best, best.count >= 3 else { return nil }
        return best
    }

    private func scanSearch(_ request: SearchRequest, useRegex: Bool) throws -> SearchResult {
        let parsed = SearchQueryParser.parse(request.text)
        let patternCache = PatternCache()
        let matchCase = request.matchCase
        let wholeWord = request.wholeWord

        func termRegex(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
            patternCache.regex(for: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        }

        func termMatches(_ term: ParsedTerm, name: String, fullPath: String) -> Bool {
            let usePath = request.matchPath || term.hasPathSeparator
            if term.hasWildcards {
                var pattern = "^"
                for character in term.text {
                    switch character {
                    case "*": pattern += ".*"
                    case "?": pattern += "."
                    default: pattern += NSRegularExpression.escapedPattern(for: String(character))
                    }
                }
                pattern += "$"
                guard let regex = termRegex(pattern, caseSensitive: matchCase) else { return false }
                let target = usePath ? fullPath : name
                let range = NSRange(target.startIndex..., in: target)
                return regex.firstMatch(in: target, options: [], range: range) != nil
            }

            if term.endsWithPathSeparator {
                let prefix = matchCase ? term.text : term.text.lowercased()
                let subject = matchCase ? fullPath : fullPath.lowercased()
                return subject.hasPrefix(prefix)
            }

            let target = usePath ? fullPath : name

            if wholeWord {
                let escaped = NSRegularExpression.escapedPattern(for: term.text)
                let pattern = "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])"
                guard let regex = termRegex(pattern, caseSensitive: matchCase) else { return false }
                let range = NSRange(target.startIndex..., in: target)
                return regex.firstMatch(in: target, options: [], range: range) != nil
            }

            let needle = matchCase ? term.text : term.text.lowercased()
            let subject = matchCase ? target : target.lowercased()
            return subject.contains(needle)
        }

        func rowMatches(name: String, fullPath: String) -> Bool {
            parsed.groups.contains { group in
                group.terms.allSatisfy { term in
                    let matched = termMatches(term, name: name, fullPath: fullPath)
                    return term.isNegated ? !matched : matched
                }
            }
        }

        let sql = "SELECT id, parent, name, is_dir, size, modified FROM entries WHERE name != '' ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }

        let needsPaths = request.matchPath || parsed.groups.contains { $0.terms.contains { $0.hasPathSeparator } }
        let limit = max(1, min(request.limit, 100_000))
        var dirPaths: [Int64: String] = [:]
        var matches: [BareRow] = []

        func dirPath(for id: Int64) throws -> String {
            if id == 0 { return "" }
            if let cached = dirPaths[id] { return cached }
            let path = try resolvePath(for: id)
            dirPaths[id] = path
            return path
        }

        while try stepSearch(prepared) == SQLITE_ROW {
            let row = Self.bareRow(prepared)
            if !request.includeHidden && row.name.hasPrefix(".") { continue }
            switch request.kind {
            case .all: break
            case .folders where !row.isDir: continue
            case .files where row.isDir: continue
            default: break
            }

            let parentPath = needsPaths ? try dirPath(for: row.parent) : ""
            let fullPath = parentPath.isEmpty ? "/" + row.name : parentPath + "/" + row.name

            let matched = useRegex ? regexBox.matches(fullPath) : rowMatches(name: row.name, fullPath: fullPath)
            guard matched else { continue }
            matches.append(row)
        }
        let sorted = try sortedRows(matches, request: request)
        let page = sorted.dropFirst(max(0, request.offset)).prefix(limit)
        let paths = try materializePaths(ids: page.map(\.id))
        let entries = page.map { row in
            Entry(id: row.id, path: paths[row.id] ?? row.name, name: row.name, isDirectory: row.isDir,
                  size: row.size, modified: Date(timeIntervalSince1970: row.modified))
        }
        return SearchResult(entries: entries, total: matches.count, elapsedMS: 0)
    }

    private func resolvePath(for id: Int64) throws -> String {
        let sql = """
        WITH RECURSIVE up(parent, path) AS (
            SELECT parent, name FROM entries WHERE id = ?1
            UNION ALL
            SELECT e.parent, e.name || '/' || up.path FROM entries e JOIN up ON up.parent = e.id
        )
        SELECT path FROM up WHERE parent = 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_int64(prepared, 1, id)
        guard try stepSearch(prepared) == SQLITE_ROW else { return "" }
        return sqlite3_column_text(prepared, 0).map { String(cString: $0) } ?? ""
    }

    private func materializePaths(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        var paths: [Int64: String] = [:]
        let sql = """
        WITH RECURSIVE up(origin, parent, path) AS (
            SELECT id, parent, name FROM entries WHERE id IN
        """
        for chunk in ids.chunked(into: 500) {
            let placeholders = (1...chunk.count).map { "?\($0)" }.joined(separator: ", ")
            let fullSQL = """
            \(sql) (\(placeholders))
            UNION ALL
            SELECT up.origin, e.parent, e.name || '/' || up.path FROM entries e JOIN up ON up.parent = e.id
            )
            SELECT origin, path FROM up WHERE parent = 0
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(searchReader, fullSQL, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
                throw DatabaseError.sql(Self.errorMessage(searchReader), sql: fullSQL)
            }
            defer { sqlite3_finalize(prepared) }
            for (index, id) in chunk.enumerated() {
                sqlite3_bind_int64(prepared, Int32(index + 1), id)
            }
            while try stepSearch(prepared) == SQLITE_ROW {
                let origin = sqlite3_column_int64(prepared, 0)
                let path = sqlite3_column_text(prepared, 1).map { String(cString: $0) } ?? ""
                paths[origin] = path
            }
        }
        return paths
    }

    private func bareRows(_ sql: String) throws -> [(id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        var rows: [(id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double)] = []
        while try stepSearch(prepared) == SQLITE_ROW {
            rows.append(Self.bareRow(prepared))
        }
        return rows
    }

    private static func bareRow(_ statement: OpaquePointer) -> (id: Int64, parent: Int64, name: String, isDir: Bool, size: Int64, modified: Double) {
        let id = sqlite3_column_int64(statement, 0)
        let parent = sqlite3_column_int64(statement, 1)
        let name = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let isDir = sqlite3_column_int(statement, 3) != 0
        let size = sqlite3_column_int64(statement, 4)
        let modified = sqlite3_column_int64(statement, 5)
        return (id, parent, name, isDir, size, Double(modified))
    }

    private func count(match: String, request: SearchRequest) throws -> Int {
        var sql = "SELECT COUNT(entries.id) FROM entries JOIN entries_fts ON entries_fts.rowid = entries.id WHERE entries_fts MATCH ?1"
        if !request.includeHidden { sql += " AND substr(entries.name, 1, 1) != '.'" }
        switch request.kind {
        case .all: break
        case .folders: sql += " AND entries.is_dir = 1"
        case .files: sql += " AND entries.is_dir = 0"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(searchReader, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        defer { sqlite3_finalize(prepared) }
        Self.bindText(prepared, 1, match)
        guard try stepSearch(prepared) == SQLITE_ROW else {
            throw DatabaseError.sql(Self.errorMessage(searchReader), sql: sql)
        }
        return Int(sqlite3_column_int64(prepared, 0))
    }

    private static func orderClause(for key: SortKey, ascending: Bool) -> String {
        let direction = ascending ? "ASC" : "DESC"
        switch key {
        case .name: return "entries.name COLLATE NOCASE \(direction), entries.id ASC"
        case .path: return "entries.id \(direction)"
        case .size: return "entries.size \(direction), entries.name COLLATE NOCASE ASC"
        case .kind: return "entries.is_dir \(direction), entries.name COLLATE NOCASE ASC"
        case .modified: return "entries.modified \(direction), entries.name COLLATE NOCASE ASC"
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
