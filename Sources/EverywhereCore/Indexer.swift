import Foundation

public struct IndexConfig: Sendable {
    public var roots: [String]
    public var exclusions: [String]
    public var namePatterns: [String] {
        didSet { compiledNamePatterns = Self.compile(namePatterns) }
    }
    private var compiledNamePatterns: [NSRegularExpression]
    public var skipPathPrefixes: [String]
    public var skipDirNames: [String]
    public var batchSize: Int
    public var useBulkReader: Bool

    public init(roots: [String],
                exclusions: [String] = [],
                namePatterns: [String] = [],
                skipPathPrefixes: [String] = [],
                skipDirNames: [String] = [],
                batchSize: Int = 8192,
                useBulkReader: Bool = true) {
        self.roots = roots
        self.exclusions = exclusions.map { $0.lowercased() }
        self.namePatterns = namePatterns
        compiledNamePatterns = Self.compile(namePatterns)
        self.skipPathPrefixes = skipPathPrefixes
        self.skipDirNames = skipDirNames
        self.batchSize = batchSize
        self.useBulkReader = useBulkReader
    }

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            let body = pattern.map { character -> String in
                if character == "*" { return ".*" }
                if character == "?" { return "." }
                return NSRegularExpression.escapedPattern(for: String(character))
            }.joined()
            return try? NSRegularExpression(pattern: "\\A" + body + "\\z", options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }

    public func ignores(name: String) -> Bool {
        if skipDirNames.contains(name) { return true }
        if !compiledNamePatterns.isEmpty {
            let range = NSRange(name.startIndex..., in: name)
            if compiledNamePatterns.contains(where: { $0.firstMatch(in: name, range: range) != nil }) { return true }
        }
        guard !exclusions.isEmpty else { return false }
        let lower = name.lowercased()
        return exclusions.contains { lower.contains($0) }
    }

    func ignoresPrefix(of path: String) -> Bool {
        for prefix in skipPathPrefixes {
            if path == prefix { return true }
            let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if path.hasPrefix(normalized) { return true }
        }
        return false
    }

    public func ignores(path: String) -> Bool {
        if ignoresPrefix(of: path) { return true }
        for component in path.split(separator: "/") {
            if ignores(name: String(component)) { return true }
        }
        return false
    }
}

public struct IndexerStats: Sendable {
    public var rows = 0
    public var dirs = 0
    public var files = 0
    public var deleted = 0
    public var skipped = 0
    public var scannedItems = 0
    public var scannedDirectories = 0

    public init() {}

    public var total: Int { dirs + files }
}

public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

final class DirCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var dirs: [String] = []

    func add(_ dir: String) {
        lock.lock()
        dirs.append(dir)
        lock.unlock()
    }

    func take() -> [String] {
        lock.lock()
        defer { dirs = []; lock.unlock() }
        return dirs
    }
}

final class RowBuffer: @unchecked Sendable {
    private let db: Database
    private let limit: Int
    private let lock = NSLock()
    private var pending: [IndexRow] = []

    init(db: Database, limit: Int) {
        self.db = db
        self.limit = max(1, limit)
    }

    func add(_ row: IndexRow) throws {
        lock.lock()
        pending.append(row)
        var batch: [IndexRow] = []
        if pending.count >= limit {
            swap(&batch, &pending)
        }
        lock.unlock()
        if !batch.isEmpty {
            try db.insert(rows: batch)
        }
    }

    func flush() throws {
        lock.lock()
        var batch: [IndexRow] = []
        swap(&batch, &pending)
        lock.unlock()
        if !batch.isEmpty {
            try db.insert(rows: batch)
        }
    }
}

public class IndexEngine {
    let db: Database
    let config: IndexConfig
    let buffer: RowBuffer

    private let statsLock = NSLock()
    private var statsValue = IndexerStats()
    private let progressLock = NSLock()
    private var lastProgressTime: UInt64 = 0
    private var firstError: Error?
    private var idBlockStart: Int64 = 0
    private var idBlockRemaining = 0

    public init(db: Database, config: IndexConfig) {
        self.db = db
        self.config = config
        self.buffer = RowBuffer(db: db, limit: config.batchSize)
    }

    var snapshot: IndexerStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return statsValue
    }

    func bump(_ mutate: (inout IndexerStats) -> Void) {
        statsLock.lock()
        mutate(&statsValue)
        statsLock.unlock()
    }

    func reportProgress(_ progress: @Sendable (IndexerStats) -> Void, force: Bool = false) {
        progressLock.lock()
        defer { progressLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now - lastProgressTime >= 200_000_000 else { return }
        lastProgressTime = now
        progress(snapshot)
    }

    func recordError(_ error: Error) {
        statsLock.lock()
        if firstError == nil { firstError = error }
        statsLock.unlock()
    }

    func checkError() throws {
        statsLock.lock()
        defer { statsLock.unlock() }
        if let firstError { throw firstError }
    }

    func takeID() throws -> Int64 {
        statsLock.lock()
        if idBlockRemaining == 0 {
            idBlockStart = db.allocateIDs(4096)
            idBlockRemaining = 4096
        }
        let id = idBlockStart
        idBlockStart += 1
        idBlockRemaining -= 1
        statsLock.unlock()
        return id
    }
}

final class DirPairCollector: @unchecked Sendable {
    struct Root {
        let path: String
        let id: Int64
    }

    private let lock = NSLock()
    private var dirs: [Root] = []

    func add(_ path: String, id: Int64) {
        lock.lock()
        dirs.append(Root(path: path, id: id))
        lock.unlock()
    }

    func take() -> [Root] {
        lock.lock()
        defer { dirs = []; lock.unlock() }
        return dirs
    }
}

enum DirectoryReader {
    struct Item {
        let name: String
        let isDir: Bool
        let isSymlink: Bool
        let size: Int64
        let modified: Double
        let created: Double
    }

    static func read(_ directory: String, preferBulk: Bool, out: inout [Item]) -> Bool {
        read(directory, preferBulk: preferBulk, out: &out, bulkReader: bulk, posixReader: posix)
    }

    static func read(_ directory: String, preferBulk: Bool, out: inout [Item],
                     bulkReader: (String, inout [Item]) -> Bool,
                     posixReader: (String, inout [Item]) -> Bool) -> Bool {
        var items: [Item] = []
        if preferBulk, bulkReader(directory, &items) {
            out = items
            return true
        }
        items.removeAll(keepingCapacity: true)
        guard posixReader(directory, &items) else { return false }
        out = items
        return true
    }

    private static func posix(_ directory: String, out: inout [Item]) -> Bool {
        guard let dir = opendir(directory) else { return false }
        defer { let failure = errno; closedir(dir); errno = failure }
        while true {
            errno = 0
            guard let entry = readdir(dir) else { return errno == 0 }
            let name = direntName(entry)
            if name == "." || name == ".." { continue }
            guard let info = lstatInfo(Walk.joinPath(directory, name)) else {
                if errno == ENOENT { continue }
                return false
            }
            out.append(Item(name: name, isDir: info.isDir, isSymlink: info.isSymlink, size: info.isDir ? 0 : info.size, modified: info.modified, created: info.created))
        }
    }

    private static func bulk(_ directory: String, out: inout [Item]) -> Bool {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_CRTIME)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let bufferSize = 262_144
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        let fd = open(directory, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { let failure = errno; close(fd); errno = failure }

        while true {
            let count = Int(getattrlistbulk(fd, &list, &buffer, bufferSize, 0))
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            var offset = 0
            for _ in 0..<count {
                guard offset <= bufferSize - 4 else { errno = EIO; return false }
                let entryLength = Int(u32(in: buffer, at: offset))
                guard entryLength > 0, offset + entryLength <= bufferSize,
                      let item = parseEntry(buffer, base: offset, length: entryLength) else {
                    errno = EIO
                    return false
                }
                if item.name != "." && item.name != ".." {
                    out.append(item)
                }
                offset += entryLength
            }
        }
    }

    private static func u32(in buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }

    private static func i64(in buffer: [UInt8], at offset: Int) -> Int64 {
        buffer.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
        }
    }

    private static func parseEntry(_ buffer: [UInt8], base: Int, length: Int) -> Item? {
        let attrBase = base + 4
        guard base + length <= buffer.count, length >= 4 + 20 + 8 + 4 + 16 + 16 else { return nil }

        let returnedCommon = u32(in: buffer, at: attrBase)
        let returnedFile = u32(in: buffer, at: attrBase + 12)
        let requiredCommon = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        guard returnedCommon & requiredCommon == requiredCommon else { return nil }

        let nameReference = attrBase + 20
        let nameDataOffset = Int(u32(in: buffer, at: nameReference))
        let nameLength = Int(u32(in: buffer, at: nameReference + 4))
        guard nameDataOffset > 0, nameLength > 0 else { return nil }
        let nameStart = nameReference + nameDataOffset
        guard nameStart + nameLength <= base + length else { return nil }
        guard buffer[nameStart + nameLength - 1] == 0 else { return nil }
        let name = String(decoding: buffer[nameStart..<(nameStart + nameLength - 1)], as: UTF8.self)

        let objType = Int32(bitPattern: u32(in: buffer, at: attrBase + 28))
        let createdSeconds = i64(in: buffer, at: attrBase + 32)
        let createdNanoseconds = i64(in: buffer, at: attrBase + 40)
        let modSeconds = i64(in: buffer, at: attrBase + 48)
        let modNanoseconds = i64(in: buffer, at: attrBase + 56)
        var size: Int64 = 0
        if returnedFile & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            guard length >= 4 + 20 + 8 + 4 + 16 + 16 + 8 else { return nil }
            size = i64(in: buffer, at: attrBase + 64)
        }

        return Item(
            name: name,
            isDir: objType == 2,
            isSymlink: objType == 5,
            size: size,
            modified: Double(modSeconds) + Double(modNanoseconds) / 1_000_000_000,
            created: Double(createdSeconds) + Double(createdNanoseconds) / 1_000_000_000
        )
    }
}

enum Walk {
    struct StatInfo {
        let isDir: Bool
        let isSymlink: Bool
        let size: Int64
        let modified: Double
        let created: Double
    }

    static func joinPath(_ parent: String, _ name: String) -> String {
        if parent == "/" { return "/" + name }
        if parent.hasSuffix("/") { return parent + name }
        return parent + "/" + name
    }

    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return normalizePath(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func normalizePath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    static func lstatInfo(_ path: String) -> StatInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
        let created = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1_000_000_000
        return StatInfo(
            isDir: kind == S_IFDIR,
            isSymlink: kind == S_IFLNK,
            size: Int64(st.st_size),
            modified: modified,
            created: created
        )
    }

    static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &flag) else { return false }
        return flag.boolValue
    }

    static func direntName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: base)
        }
    }
}

extension DirectoryReader {
    static func lstatInfo(_ path: String) -> Walk.StatInfo? { Walk.lstatInfo(path) }
    static func joinPath(_ parent: String, _ name: String) -> String { Walk.joinPath(parent, name) }
    static func direntName(_ entry: UnsafeMutablePointer<dirent>) -> String { Walk.direntName(entry) }
}

public final class FilesystemIndexer: IndexEngine {
    public static let defaultSkipPathPrefixes = [
        "/dev",
        "/System/Volumes",
        "/private/tmp",
        "/private/var/folders",
        "/.Spotlight-V100",
        "/.DocumentRevisions-V100",
        "/.Trashes",
        "/.fseventsd"
    ]

    public static let defaultSkipDirNames = [
        ".Spotlight-V100",
        ".DocumentRevisions-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".Trash"
    ]

    public func run(isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (IndexerStats) -> Void = { _ in }) throws {
        if isCancelled() { return }
        var seenRootIDs = Set<Int64>()
        var level: [DirPairCollector.Root] = []
        for root in config.roots {
            if isCancelled() { return }
            if config.ignores(path: root) { continue }
            let id = try db.ensureRootRow(path: root)
            guard seenRootIDs.insert(id).inserted else { continue }
            level.append(DirPairCollector.Root(path: Walk.normalizePath(root), id: id))
        }
        while !level.isEmpty {
            if isCancelled() { return }
            let collector = DirPairCollector()
            let dirs = level
            DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
                if isCancelled() { return }
                self.walk(directory: dirs[index].path, parentID: dirs[index].id, collector: collector, isCancelled: isCancelled, progress: progress)
            }
            try buffer.flush()
            try checkError()
            level = collector.take().sorted { $0.path < $1.path }
            reportProgress(progress, force: true)
        }
        try buffer.flush()
        reportProgress(progress, force: true)
    }

    private func walk(directory: String, parentID: Int64, collector: DirPairCollector,
                      isCancelled: @Sendable () -> Bool, progress: @Sendable (IndexerStats) -> Void) {
        defer {
            bump { $0.scannedDirectories += 1 }
            reportProgress(progress)
        }
        var items: [DirectoryReader.Item] = []
        items.reserveCapacity(128)
        let ok = DirectoryReader.read(directory, preferBulk: config.useBulkReader, out: &items)
        guard ok else {
            bump { $0.skipped += 1 }
            return
        }

        for (offset, item) in items.enumerated() {
            if isCancelled() { return }
            bump { $0.scannedItems += 1 }
            if offset % 256 == 0 { reportProgress(progress) }
            if config.ignores(name: item.name) { continue }
            let path = Walk.joinPath(directory, item.name)
            if config.ignoresPrefix(of: path) { continue }
            let id = try? takeID()
            guard let id else { return }
            if item.isDir {
                collector.add(path, id: id)
            }
            let row = IndexRow(id: id, parent: parentID, name: item.name, isDir: item.isDir, size: item.size, modified: item.modified)
            do {
                try buffer.add(row)
                bump {
                    if item.isDir { $0.dirs += 1 } else { $0.files += 1 }
                    $0.rows += 1
                }
            } catch {
                recordError(error)
                return
            }
        }
    }
}

public final class Reconciler: IndexEngine {
    var readDirectory: (String, Bool, inout [DirectoryReader.Item]) -> Bool = DirectoryReader.read
    public let skipUnchangedDirs: Bool
    public let scanKnownSubdirectories: Bool

    private let indexRoots: [String]
    private let deletesLock = NSLock()
    private var pendingDeletes: [Int64] = []

    public init(db: Database, config: IndexConfig, roots: [String], skipUnchangedDirs: Bool, scanKnownSubdirectories: Bool = true) {
        self.indexRoots = config.roots
        self.scanKnownSubdirectories = scanKnownSubdirectories
        self.skipUnchangedDirs = skipUnchangedDirs
        var config = config
        config.roots = roots
        super.init(db: db, config: config)
    }

    public func run(isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (IndexerStats) -> Void = { _ in }) throws {
        if isCancelled() { return }
        var seenRootIDs = Set<Int64>()
        var level: [DirPairCollector.Root] = []
        for root in config.roots {
            if isCancelled() { return }
            guard let id = try db.ensureDirectoryRow(path: root, roots: indexRoots) else { continue }
            if config.ignores(path: root) {
                try db.deleteSubtree(id: id)
                continue
            }
            guard seenRootIDs.insert(id).inserted else { continue }
            level.append(DirPairCollector.Root(path: Walk.normalizePath(root), id: id))
        }
        while !level.isEmpty {
            if isCancelled() { return }
            let collector = DirPairCollector()
            let dirs = level
            DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
                if isCancelled() { return }
                self.reconcile(directory: dirs[index].path, dirID: dirs[index].id, collector: collector, isCancelled: isCancelled, progress: progress)
            }
            try buffer.flush()
            try flushDeletes()
            try checkError()
            level = collector.take().sorted { $0.path < $1.path }
            reportProgress(progress, force: true)
        }
        try buffer.flush()
        try flushDeletes()
        reportProgress(progress, force: true)
    }

    private func appendDelete(_ id: Int64) throws {
        deletesLock.lock()
        pendingDeletes.append(id)
        var batch: [Int64] = []
        if pendingDeletes.count >= 256 {
            swap(&batch, &pendingDeletes)
        }
        deletesLock.unlock()
        if !batch.isEmpty {
            try db.deleteIDs(batch)
        }
    }

    private func flushDeletes() throws {
        deletesLock.lock()
        var batch: [Int64] = []
        swap(&batch, &pendingDeletes)
        deletesLock.unlock()
        if !batch.isEmpty {
            try db.deleteIDs(batch)
        }
    }

    private func reconcile(directory: String, dirID: Int64, collector: DirPairCollector,
                           isCancelled: @Sendable () -> Bool, progress: @Sendable (IndexerStats) -> Void) {
        defer {
            bump { $0.scannedDirectories += 1 }
            reportProgress(progress)
        }
        let existing: [Entry]
        do {
            existing = try db.children(ofParent: dirID)
        } catch {
            recordError(error)
            return
        }
        var byName = Dictionary(uniqueKeysWithValues: existing.filter { !$0.name.isEmpty }.map { ($0.name, $0) })

        var items: [DirectoryReader.Item] = []
        items.reserveCapacity(128)
        let ok = readDirectory(directory, config.useBulkReader, &items)
        guard ok else {
            let failure = errno
            bump { $0.skipped += 1 }
            var info = stat()
            let missing = lstat(directory, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
            if missing {
                do {
                    try db.deleteSubtree(id: dirID)
                    bump { $0.deleted += existing.count }
                } catch {
                    recordError(error)
                }
            } else if failure != EACCES && failure != EPERM {
                recordError(NSError(domain: NSPOSIXErrorDomain, code: Int(failure == 0 ? EIO : failure),
                                    userInfo: [NSFilePathErrorKey: directory]))
            }
            return
        }

        for (offset, item) in items.enumerated() {
            if isCancelled() { return }
            bump { $0.scannedItems += 1 }
            if offset % 256 == 0 { reportProgress(progress) }
            if config.ignores(name: item.name) { continue }
            let path = Walk.joinPath(directory, item.name)
            if config.ignoresPrefix(of: path) { continue }
            let row = byName.removeValue(forKey: item.name)
            let unchanged = row.map { stored in
                stored.isDirectory == item.isDir
                    && stored.size == item.size
                    && stored.modified.timeIntervalSince1970 == Double(Int64(item.modified))
            } ?? false

            let id: Int64
            if unchanged {
                id = row?.id ?? 0
            } else {
                id = row?.id ?? (try? takeID()) ?? 0
                let indexRow = IndexRow(id: id, parent: dirID, name: item.name, isDir: item.isDir, size: item.size, modified: item.modified)
                do {
                    try buffer.add(indexRow)
                    bump {
                        if item.isDir { $0.dirs += 1 } else { $0.files += 1 }
                        $0.rows += 1
                    }
                } catch {
                    recordError(error)
                    return
                }
            }

            if item.isDir && (scanKnownSubdirectories || row?.isDirectory != true) {
                collector.add(path, id: id)
            }
        }

        let vanished = byName
        if !vanished.isEmpty {
            for (_, entry) in vanished {
                if isCancelled() { return }
                do {
                    if entry.isDirectory {
                        try db.deleteSubtree(id: entry.id)
                    } else {
                        try appendDelete(entry.id)
                    }
                } catch {
                    recordError(error)
                    return
                }
            }
            bump { $0.deleted += vanished.count }
        }
    }
}
