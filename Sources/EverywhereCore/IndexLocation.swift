import Foundation

public enum IndexLocationKind: String, CaseIterable, Codable, Sendable {
    case local
    case network
    case removable

    public var title: String {
        switch self {
        case .local: return "Local Disk"
        case .network: return "Network Disk"
        case .removable: return "Removable Disk"
        }
    }
}

public struct IndexLocation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var kindOverride: IndexLocationKind?
    public var detectedKind: IndexLocationKind
    public var keepIndexWhenUnavailable: Bool

    public var kind: IndexLocationKind { kindOverride ?? detectedKind }

    public init(path: String, kindOverride: IndexLocationKind? = nil, keepIndexWhenUnavailable: Bool = true) {
        id = UUID()
        self.path = Walk.normalizePath(path)
        self.kindOverride = kindOverride
        detectedKind = .local
        self.keepIndexWhenUnavailable = keepIndexWhenUnavailable
    }
}

public struct IndexLocationStatus: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var rootID: UUID
    public var path: String
    public var kind: IndexLocationKind
    public var isAvailable: Bool
    public var keepIndexWhenUnavailable: Bool
    public var isConfiguredRoot: Bool
}

struct IndexLocationBinding: Codable, Equatable, Sendable {
    var id: UUID
    var rootID: UUID
    var path: String
    var mountPath: String
    var relativePath: String
    var volumeIdentity: String
    var detectedKind: IndexLocationKind
    var isConfiguredRoot: Bool
}

struct IndexLocationAccess: Equatable, Sendable {
    var path: String
    var device: Int32?
    var isAvailable: Bool
    var identity: String? = nil

    func permits(_ candidate: String, deviceForPath: (String) -> Int32? = IndexedVolume.device(containing:),
                 isDirectory: (String) -> Bool = Walk.isDirectory,
                 identityForPath: (String) -> String? = IndexedVolume.validationIdentity(containing:)) -> Bool {
        guard isAvailable, let device, isDirectory(path), deviceForPath(candidate) == device else { return false }
        return identity == nil || identityForPath(path) == identity
    }
}

struct IndexLocationUnavailable: LocalizedError {
    var path: String
    var errorDescription: String? { "Indexed location became unavailable: \(path)" }
}

struct IndexLocationResolution {
    struct Relocation: Equatable {
        var from: String
        var to: String
    }

    var locations: [IndexLocation]
    var bindings: [IndexLocationBinding]
    var statuses: [IndexLocationStatus]
    var access: [IndexLocationAccess]
    var relocations: [Relocation]

    var unavailablePathsToRemove: [String] {
        statuses.filter { !$0.isAvailable && !$0.keepIndexWhenUnavailable }.map(\.path)
    }

    var hasRetainedUnavailableLocations: Bool {
        statuses.contains { !$0.isAvailable && $0.keepIndexWhenUnavailable }
    }

    func applying(to config: IndexConfig) -> IndexConfig {
        var result = config
        result.roots = locations.map(\.path)
        result.locationAccess = access
        result.locationIdentities = bindings.map { binding in
            let keep = locations.first(where: { $0.id == binding.rootID })?.keepIndexWhenUnavailable ?? true
            return "\(binding.path)\u{0}\(binding.volumeIdentity)\u{0}\(keep)"
        }.sorted()
        return result.preparingFilesystemPaths()
    }
}

enum IndexLocationResolver {
    static func resolve(locations: [IndexLocation], bindings: [IndexLocationBinding], config: IndexConfig,
                        mounts: [IndexedVolume.Mount],
                        isDirectory: (String) -> Bool = Walk.isDirectory,
                        deviceForPath: (String) -> Int32? = IndexedVolume.device(containing:)) -> IndexLocationResolution {
        var result = IndexLocationResolution(locations: locations, bindings: [], statuses: [], access: [], relocations: [])
        var currentConfig = config
        for index in result.locations.indices {
            var location = result.locations[index]
            var previous = bindings.first { $0.rootID == location.id && $0.isConfiguredRoot }
                ?? bindings.first { !$0.isConfiguredRoot && $0.path == location.path }
            if var binding = previous {
                binding.id = location.id
                binding.rootID = location.id
                binding.isConfiguredRoot = true
                previous = binding
                location.detectedKind = binding.detectedKind
            }
            var path = location.path
            var mount = containing(path, mounts: mounts, isDirectory: isDirectory, deviceForPath: deviceForPath)
            if let previous {
                if mount?.identity != previous.volumeIdentity {
                    mount = matching(previous, mounts: mounts)
                    if let mount, mount.path != previous.mountPath {
                        path = mount.absolutePath(for: previous.relativePath)
                    } else {
                        mount = nil
                    }
                }
                if !isDirectory(path) || (mount != nil && deviceForPath(path) != mount?.device) { mount = nil }
                if let mount, mount.identity == previous.volumeIdentity {
                    var binding = previous
                    binding.path = path
                    binding.mountPath = mount.path
                    binding.detectedKind = mount.kind
                    result.bindings.append(binding)
                    location.detectedKind = mount.kind
                    if path != location.path {
                        result.relocations.append(.init(from: location.path, to: path))
                        location.path = path
                    }
                } else {
                    result.bindings.append(previous)
                }
            } else if let mount, let identity = mount.identity,
                      let relative = mount.relativePath(for: Walk.canonicalPath(path)) {
                location.detectedKind = mount.kind
                result.bindings.append(.init(id: location.id, rootID: location.id, path: path,
                    mountPath: mount.path, relativePath: relative, volumeIdentity: identity,
                    detectedKind: mount.kind, isConfiguredRoot: true))
            } else {
                mount = nil
            }
            result.locations[index] = location
            result.statuses.append(.init(id: location.id, rootID: location.id, path: location.path,
                kind: location.kind, isAvailable: mount != nil, keepIndexWhenUnavailable: location.keepIndexWhenUnavailable,
                isConfiguredRoot: true))
            result.access.append(.init(path: location.path, device: mount?.device, isAvailable: mount != nil,
                                       identity: mount?.validationIdentity ?? mount?.identity))
        }
        currentConfig.roots = result.locations.map(\.path)
        let selected = IndexedVolume.select(config: currentConfig, mounts: mounts, deviceForPath: deviceForPath)
        var claimed = Set<UUID>()
        for volume in selected {
            guard let mount = mounts.first(where: { $0.path == volume.path && $0.device == volume.device }),
                  let identity = mount.identity else { continue }
            for path in volume.roots {
                guard let owner = result.locations.filter({ IndexedVolume.contains($0.path, path) })
                    .max(by: { $0.path.count < $1.path.count }), path != owner.path,
                      result.statuses.first(where: { $0.id == owner.id })?.isAvailable == true,
                      let relative = mount.relativePath(for: Walk.canonicalPath(path)) else { continue }
                let candidates = bindings.filter {
                    !$0.isConfiguredRoot && $0.rootID == owner.id && $0.volumeIdentity == identity && $0.relativePath == relative
                }
                let uniqueIdentity = mounts.filter { $0.identity == identity }.count == 1
                let old = candidates.first(where: { $0.path == path }) ?? (uniqueIdentity && candidates.count == 1 ? candidates.first : nil)
                if !candidates.isEmpty && old == nil {
                    result.access.append(.init(path: path, device: nil, isAvailable: false))
                    continue
                }
                let occupied = bindings.first {
                    !$0.isConfiguredRoot && $0.rootID == owner.id && $0.path == path && $0.volumeIdentity != identity
                }
                if occupied != nil && old == nil { continue }
                var binding = old ?? IndexLocationBinding(id: UUID(), rootID: owner.id, path: path,
                    mountPath: mount.path, relativePath: relative, volumeIdentity: identity,
                    detectedKind: mount.kind, isConfiguredRoot: false)
                if binding.path != path {
                    result.relocations.append(.init(from: binding.path, to: path))
                }
                binding.path = path
                binding.mountPath = mount.path
                binding.detectedKind = mount.kind
                result.bindings.append(binding)
                claimed.insert(binding.id)
                let available = isDirectory(path) && deviceForPath(path) == mount.device
                result.statuses.append(.init(id: binding.id, rootID: owner.id, path: path,
                    kind: owner.kindOverride ?? mount.kind, isAvailable: available,
                    keepIndexWhenUnavailable: owner.keepIndexWhenUnavailable, isConfiguredRoot: false))
                result.access.append(.init(path: path, device: mount.device, isAvailable: available,
                                           identity: mount.validationIdentity ?? mount.identity))
            }
        }
        for old in bindings where !old.isConfiguredRoot && !claimed.contains(old.id) {
            guard let owner = result.locations.first(where: { $0.id == old.rootID }) else { continue }
            var binding = old
            if let relocation = result.relocations.first(where: { IndexedVolume.contains($0.from, old.path) }) {
                binding.path = relocation.to + String(old.path.dropFirst(relocation.from.count))
            }
            guard !currentConfig.ignores(path: binding.path),
                  result.locations.filter({ IndexedVolume.contains($0.path, binding.path) })
                    .max(by: { $0.path.count < $1.path.count })?.id == owner.id else { continue }
            result.bindings.append(binding)
            result.statuses.append(.init(id: binding.id, rootID: owner.id, path: binding.path,
                kind: owner.kindOverride ?? binding.detectedKind, isAvailable: false,
                keepIndexWhenUnavailable: owner.keepIndexWhenUnavailable, isConfiguredRoot: false))
            result.access.append(.init(path: binding.path, device: nil, isAvailable: false))
        }
        for relocation in result.relocations {
            result.access.append(.init(path: relocation.from, device: nil, isAvailable: false))
        }
        result.statuses.sort { $0.path.count > $1.path.count }
        result.access.sort { $0.path.count > $1.path.count }
        return result
    }

    private static func containing(_ path: String, mounts: [IndexedVolume.Mount], isDirectory: (String) -> Bool,
                                   deviceForPath: (String) -> Int32?) -> IndexedVolume.Mount? {
        guard isDirectory(path), let device = deviceForPath(path) else { return nil }
        let canonical = Walk.canonicalPath(path)
        return mounts.filter { $0.device == device && $0.relativePath(for: canonical) != nil }
            .max { $0.path.count < $1.path.count }
    }

    private static func matching(_ binding: IndexLocationBinding, mounts: [IndexedVolume.Mount]) -> IndexedVolume.Mount? {
        let matches = mounts.filter { $0.identity == binding.volumeIdentity }
        return matches.count == 1 ? matches.first : nil
    }
}
