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
        var identity: String? = nil
        var kind: IndexLocationKind = .local
        var validationIdentity: String? = nil

        func relativePath(for absolutePath: String) -> String? {
            guard let mapping = mappings.filter({ IndexedVolume.contains($0.absolutePath, absolutePath) })
                .max(by: { $0.absolutePath.count < $1.absolutePath.count }) else { return nil }
            let suffix = absolutePath.dropFirst(mapping.absolutePath == "/" ? 1 : mapping.absolutePath.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return [mapping.relativePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        }

        func absolutePath(for relativePath: String) -> String {
            let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let mapping = mappings.filter({ !$0.relativePath.isEmpty && IndexedVolume.contains($0.relativePath, relative) })
                .max(by: { $0.relativePath.count < $1.relativePath.count }) {
                let suffix = relative.dropFirst(mapping.relativePath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return suffix.isEmpty ? mapping.absolutePath : Walk.joinPath(mapping.absolutePath, suffix)
            }
            return relative.isEmpty ? path : Walk.joinPath(path, relative)
        }
    }

    var path: String
    var device: dev_t
    var journalIdentity: String?
    var journalEventID: UInt64
    var roots: [String]
    var canonicalRoots: [String] = []
    var mappings: [PathMapping]
    var preparedWatchPath: String? = nil

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

    private static let unidentifiedSession = UUID().uuidString

    static func networkIdentity(fileSystem: String, source: String) -> String? {
        let type = fileSystem.lowercased()
        guard !source.isEmpty else { return nil }
        if source.hasPrefix("//") || source.contains("://") {
            let text = source.hasPrefix("//") ? type + ":" + source : source
            guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
                  !components.path.isEmpty, components.path != "/" else { return nil }
            let port = components.port.map { ":\($0)" } ?? ""
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "share:\(type):\(host.lowercased())\(port)/\(path)"
        }
        if let separator = source.range(of: ":/") {
            let host = source[..<separator.lowerBound].lowercased()
            guard !host.isEmpty else { return nil }
            return "share:\(type):\(host):\(source[separator.upperBound...])"
        }
        return nil
    }

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
            let source = withUnsafePointer(to: &info.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fileSystem = withUnsafePointer(to: &info.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let network = info.f_flags & UInt32(MNT_LOCAL) == 0
                || ["smbfs", "nfs", "afpfs", "webdav"].contains(fileSystem.lowercased())
            var kind: IndexLocationKind = network ? .network : .local
            var identity = network ? networkIdentity(fileSystem: fileSystem, source: source) : nil
            if !network {
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                    .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey
                ])
                if values?.volumeIsRemovable == true || values?.volumeIsEjectable == true || values?.volumeIsInternal == false {
                    kind = .removable
                }
                if let uuid = values?.volumeUUIDString, !uuid.isEmpty { identity = "uuid:" + uuid.lowercased() }
                if identity == nil, let uuid = FSEventsCopyUUIDForDevice(info.f_fsid.val.0) {
                    identity = "journal:" + (CFUUIDCreateString(nil, uuid) as String).lowercased()
                }
            }
            if identity == nil { identity = "session:\(unidentifiedSession):\(info.f_fsid.val.0)" }
            var mappings = [PathMapping(relativePath: "", absolutePath: path)]
            if path == "/System/Volumes/Data" { mappings += firmlinks }
            let validation = validationIdentity(info: &info, path: path)
            return Mount(path: path, device: info.f_fsid.val.0, mappings: mappings, identity: identity, kind: kind,
                         validationIdentity: validation)
        }
    }

    static func validationIdentity(containing path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return validationIdentity(info: &info, path: path)
    }

    private static func validationIdentity(info: inout statfs, path: String) -> String {
        let fileSystem = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        if info.f_flags & UInt32(MNT_LOCAL) == 0 || ["smbfs", "nfs", "afpfs", "webdav"].contains(fileSystem.lowercased()) {
            let source = withUnsafePointer(to: &info.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return networkIdentity(fileSystem: fileSystem, source: source)
                ?? "session:\(unidentifiedSession):\(info.f_fsid.val.0)"
        }
        if let uuid = FSEventsCopyUUIDForDevice(info.f_fsid.val.0) {
            return "journal:" + (CFUUIDCreateString(nil, uuid) as String).lowercased()
        }
        if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]),
           let uuid = values.volumeUUIDString, !uuid.isEmpty {
            return "uuid:" + uuid.lowercased()
        }
        return "session:\(unidentifiedSession):\(info.f_fsid.val.0)"
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

    static func discover(config: IndexConfig, mounts: [Mount]? = nil) -> [Self] {
        select(config: config, mounts: mounts ?? mountedVolumes(), deviceForPath: device(containing:)).map { volume in
            var volume = volume
            if let uuid = FSEventsCopyUUIDForDevice(volume.device) {
                volume.journalIdentity = CFUUIDCreateString(nil, uuid) as String
                volume.journalEventID = currentJournalEventID(device: volume.device)
            }
            volume.preparedWatchPath = volume.relativeWatchPath
            return volume
        }
    }

    static func currentJournalEventID(device: dev_t) -> UInt64 {
        FSEventsGetLastEventIdForDeviceBeforeTime(device, Double.greatestFiniteMagnitude)
    }

    static func select(config: IndexConfig, mounts: [Mount], deviceForPath: (String) -> dev_t?) -> [Self] {
        let roots = config.roots.filter { !config.ignores(path: $0) && !config.knownUnavailableLocation(containing: $0) }.map {
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
                        if !config.ignores(path: path), !config.ignores(path: mapping.absolutePath),
                           !config.knownUnavailableLocation(containing: path) { covered.insert(path) }
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
        let mapping = mappings.lazy.filter {
            !$0.relativePath.isEmpty
                && (relative == $0.relativePath || relative.hasPrefix($0.relativePath + "/"))
        }.max { $0.relativePath.count < $1.relativePath.count }
        if let mapping {
            if relative == mapping.relativePath { return mapping.absolutePath }
            return Walk.joinPath(mapping.absolutePath, String(relative.dropFirst(mapping.relativePath.count + 1)))
        }
        return relative.isEmpty ? path : Walk.joinPath(path, relative)
    }

    var relativeWatchPath: String {
        if let preparedWatchPath { return preparedWatchPath }
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
