import Foundation

struct IndexCheckpoint: Codable, Equatable {
    struct VolumeCursor: Codable, Equatable {
        var journalIdentity: String?
        var eventID: UInt64
        var journalEventID: UInt64
        var roots: [String]
        var canonicalRoots: [String]
    }

    var version = 2
    var scannedAt: Date
    var databaseIdentity: String
    var roots: [String]
    var exclusions: [String]
    var namePatterns: [String]?
    var skipPathPrefixes: [String]
    var skipDirNames: [String]
    var volumeCursors: [String: VolumeCursor]

    static func identity(of path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    init(databasePath: String, config: IndexConfig, now: Date = Date(), volumes: [IndexedVolume]? = nil) {
        scannedAt = now
        databaseIdentity = Self.identity(of: databasePath) ?? ""
        roots = config.roots
        exclusions = config.exclusions
        namePatterns = config.namePatterns
        skipPathPrefixes = config.skipPathPrefixes
        skipDirNames = config.skipDirNames
        volumeCursors = Dictionary(uniqueKeysWithValues: (volumes ?? IndexedVolume.discover(config: config)).map {
            ($0.path, VolumeCursor(journalIdentity: $0.journalIdentity, eventID: $0.journalEventID,
                                  journalEventID: $0.journalEventID, roots: $0.roots, canonicalRoots: $0.canonicalRoots))
        })
    }

    func isValid(databasePath: String, config: IndexConfig, now: Date = Date(), volumes: [IndexedVolume]? = nil) -> Bool {
        guard version == 2, now >= scannedAt, now.timeIntervalSince(scannedAt) < 7 * 24 * 60 * 60,
              databaseIdentity == Self.identity(of: databasePath),
              roots == config.roots, exclusions == config.exclusions,
              (namePatterns ?? []) == config.namePatterns,
              skipPathPrefixes == config.skipPathPrefixes, skipDirNames == config.skipDirNames else { return false }
        let current = volumes ?? IndexedVolume.discover(config: config)
        guard !current.isEmpty, Set(current.map(\.path)) == Set(volumeCursors.keys) else { return false }
        return current.allSatisfy { volume in
            guard let cursor = volumeCursors[volume.path], let identity = volume.journalIdentity else { return false }
            return cursor.journalIdentity == identity && cursor.journalEventID <= volume.journalEventID
                && cursor.eventID >= cursor.journalEventID && cursor.roots == volume.roots
                && cursor.canonicalRoots == volume.canonicalRoots
        }
    }

    static func load(databasePath: String) -> Self? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: databasePath + ".checkpoint")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(databasePath: String) throws {
        try JSONEncoder().encode(self).write(to: URL(fileURLWithPath: databasePath + ".checkpoint"), options: .atomic)
    }

    static func remove(databasePath: String) {
        try? FileManager.default.removeItem(atPath: databasePath + ".checkpoint")
    }
}

final class IndexCheckpointWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoint: IndexCheckpoint
    private let databasePath: String

    init(_ checkpoint: IndexCheckpoint, databasePath: String) {
        self.checkpoint = checkpoint
        self.databasePath = databasePath
    }

    func commit(volume: String, eventID: UInt64, journalEventID: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var cursor = checkpoint.volumeCursors[volume] else { return }
        cursor.eventID = max(cursor.eventID, eventID)
        cursor.journalEventID = max(cursor.journalEventID, min(cursor.eventID, journalEventID))
        var next = checkpoint
        next.volumeCursors[volume] = cursor
        try next.save(databasePath: databasePath)
        checkpoint = next
    }
}
