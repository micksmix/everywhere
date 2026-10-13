import Foundation
import CoreServices
import Darwin

struct IndexedVolume: Equatable, Sendable {
    struct PathMapping: Equatable, Sendable {
        var relativePath: String
        var absolutePath: String
    }

    struct Mount: Sendable {
        var path: String
        var device: dev_t
        var mappings: [PathMapping]
    }

    var path: String
    var device: dev_t
    var journalIdentity: String?
    var journalEventID: UInt64
    var roots: [String]
    var canonicalRoots: [String] = []
    var mappings: [PathMapping]

    static func contains(_ parent: String, _ child: String) -> Bool {
        parent == child || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    private static let firmlinks: [PathMapping] = {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count == 2 else { return nil }
            return PathMapping(relativePath: String(fields[1]), absolutePath: String(fields[0]))
        }
    }()

    static func mountedVolumes() -> [Mount] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&pointer, MNT_NOWAIT)
        guard let pointer else { return [] }
        defer { free(pointer) }
        return (0..<Int(count)).map { index in
            var info = pointer[index]
            let path = withUnsafePointer(to: &info.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            var mappings = [PathMapping(relativePath: "", absolutePath: path)]
            if path == "/System/Volumes/Data" { mappings += firmlinks }
            return Mount(path: path, device: info.f_fsid.val.0, mappings: mappings)
        }
    }

    static func device(containing path: String) -> dev_t? {
        var candidate = path
        while true {
            var info = statfs()
            if statfs(candidate, &info) == 0 { return info.f_fsid.val.0 }
            guard candidate != "/" else { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate.isEmpty { candidate = "/" }
        }
    }

    static func discover(config: IndexConfig) -> [Self] {
        select(config: config, mounts: mountedVolumes(), deviceForPath: device(containing:)).map { volume in
            var volume = volume
            if let uuid = FSEventsCopyUUIDForDevice(volume.device) {
                volume.journalIdentity = CFUUIDCreateString(nil, uuid) as String
                volume.journalEventID = currentJournalEventID(device: volume.device)
            }
            return volume
        }
    }

    static func currentJournalEventID(device: dev_t) -> UInt64 {
        FSEventsGetLastEventIdForDeviceBeforeTime(device, Double.greatestFiniteMagnitude)
    }

    static func select(config: IndexConfig, mounts: [Mount], deviceForPath: (String) -> dev_t?) -> [Self] {
        let roots = config.roots.filter { !config.ignores(path: $0) }.map {
            (path: Walk.normalizePath($0), canonical: Walk.canonicalPath($0))
        }
        var devices: [String: dev_t] = [:]
        for root in Set(roots.map(\.canonical)) { devices[root] = deviceForPath(root) }
        return mounts.compactMap { mount in
            var covered = Set<String>()
            for root in roots {
                for mapping in mount.mappings {
                    if contains(mapping.absolutePath, root.canonical), devices[root.canonical] == mount.device {
                        covered.insert(root.path)
                    } else if contains(root.canonical, mapping.absolutePath) {
                        let suffix = mapping.absolutePath.dropFirst(root.canonical == "/" ? 1 : root.canonical.count)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let path = suffix.isEmpty ? root.path : Walk.joinPath(root.path, suffix)
                        if !config.ignores(path: path), !config.ignores(path: mapping.absolutePath) { covered.insert(path) }
                    }
                }
            }
            guard !covered.isEmpty else { return nil }
            let minimal = covered.filter { candidate in
                !covered.contains { $0 != candidate && contains($0, candidate) }
            }.sorted()
            return Self(path: mount.path, device: mount.device, journalIdentity: nil, journalEventID: 0,
                        roots: minimal, canonicalRoots: minimal.map(Walk.canonicalPath), mappings: mount.mappings)
        }.sorted { $0.path < $1.path }
    }

    func absolutePath(for relativePath: String) -> String {
        let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for mapping in mappings.sorted(by: { $0.relativePath.count > $1.relativePath.count }) {
            if mapping.relativePath.isEmpty { continue }
            if relative == mapping.relativePath { return mapping.absolutePath }
            if relative.hasPrefix(mapping.relativePath + "/") {
                return Walk.joinPath(mapping.absolutePath, String(relative.dropFirst(mapping.relativePath.count + 1)))
            }
        }
        return relative.isEmpty ? path : Walk.joinPath(path, relative)
    }

    var relativeWatchPath: String {
        let paths = canonicalRoots.isEmpty ? roots.map(Walk.canonicalPath) : canonicalRoots
        let parents = paths.compactMap { root -> [Substring]? in
            guard let mapping = mappings.filter({ Self.contains($0.absolutePath, root) })
                .max(by: { $0.absolutePath.count < $1.absolutePath.count }) else { return nil }
            let suffix = root.dropFirst(mapping.absolutePath == "/" ? 1 : mapping.absolutePath.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relative = [mapping.relativePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
            return Array(relative.split(separator: "/").dropLast())
        }
        guard var common = parents.first else { return "" }
        for parent in parents.dropFirst() {
            common = Array(zip(common, parent).prefix { $0 == $1 }.map { $0.0 })
        }
        while !common.isEmpty {
            var info = statfs()
            let relative = common.joined(separator: "/")
            if statfs(absolutePath(for: relative), &info) == 0, info.f_fsid.val.0 == device { return relative }
            common.removeLast()
        }
        return ""
    }

    func hasSameTopology(as other: Self) -> Bool {
        path == other.path && device == other.device && journalIdentity == other.journalIdentity
            && roots == other.roots && canonicalRoots == other.canonicalRoots && mappings == other.mappings
    }
}
