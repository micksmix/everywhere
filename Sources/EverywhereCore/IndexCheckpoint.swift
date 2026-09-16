import Foundation
import CoreServices

struct IndexCheckpoint: Codable, Equatable {
    var eventID: UInt64
    var scannedAt: Date
    var databaseIdentity: String
    var roots: [String]
    var exclusions: [String]
    var namePatterns: [String]?
    var skipPathPrefixes: [String]
    var skipDirNames: [String]
    var volumes: [String: String]

    static func identity(of path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    static func volumeIdentities() -> [String: String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        var result: [String: String] = [:]
        for url in urls {
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            if let uuid = FSEventsCopyUUIDForDevice(info.st_dev) {
                result[url.path] = CFUUIDCreateString(nil, uuid) as String
            } else {
                result[url.path] = "device:\(info.st_dev)"
            }
        }
        return result
    }

    init(eventID: UInt64, databasePath: String, config: IndexConfig, now: Date = Date(),
         volumes: [String: String] = Self.volumeIdentities()) {
        self.eventID = eventID
        scannedAt = now
        databaseIdentity = Self.identity(of: databasePath) ?? ""
        roots = config.roots
        exclusions = config.exclusions
        namePatterns = config.namePatterns
        skipPathPrefixes = config.skipPathPrefixes
        skipDirNames = config.skipDirNames
        self.volumes = volumes
    }

    func isValid(databasePath: String, config: IndexConfig, currentEventID: UInt64,
                 now: Date = Date(), volumes: [String: String] = Self.volumeIdentities()) -> Bool {
        eventID > 0 && eventID <= currentEventID
            && now >= scannedAt && now.timeIntervalSince(scannedAt) < 7 * 24 * 60 * 60
            && databaseIdentity == Self.identity(of: databasePath)
            && roots == config.roots && exclusions == config.exclusions
            && (namePatterns ?? []) == config.namePatterns
            && skipPathPrefixes == config.skipPathPrefixes && skipDirNames == config.skipDirNames
            && !volumes.isEmpty && self.volumes == volumes
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

    func commit(eventID: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        checkpoint.eventID = max(checkpoint.eventID, eventID)
        try checkpoint.save(databasePath: databasePath)
    }
}
