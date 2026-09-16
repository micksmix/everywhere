import Foundation
import Combine

public final class IndexSettings: ObservableObject {
    private static let rootsKey = "IndexRoots"
    private static let exclusionsKey = "IndexExclusions"
    private static let liveKey = "IndexLiveUpdates"

    @Published public private(set) var indexPath: String

    public func setIndexPath(_ path: String) throws {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !(expanded as NSString).lastPathComponent.isEmpty else {
            throw DatabaseError.open("Choose an absolute path to an index file.")
        }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        try Database.validateIndexLocation(normalized)
        indexPath = normalized
        defaults.set(normalized, forKey: "IndexDatabasePath")
    }

    public enum DelayUnit: String, CaseIterable {
        case seconds, minutes, hours

        public var seconds: Double {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            }
        }
    }

    @Published public var indexingEnabled: Bool {
        didSet { defaults.set(indexingEnabled, forKey: "IndexingEnabled") }
    }

    @Published public var startupDelay: Double {
        didSet { defaults.set(startupDelay, forKey: "IndexStartupDelay") }
    }

    @Published public var startupDelayUnit: DelayUnit {
        didSet { defaults.set(startupDelayUnit.rawValue, forKey: "IndexStartupDelayUnit") }
    }

    public var startupDelaySeconds: TimeInterval {
        let seconds = startupDelay * startupDelayUnit.seconds
        return seconds.isFinite ? min(max(0, seconds), 31_536_000) : 120
    }

    private let defaults: UserDefaults

    @Published public private(set) var needsLocationSetup: Bool

    @Published public var roots: [String] {
        didSet {
            defaults.set(roots, forKey: Self.rootsKey)
            needsLocationSetup = false
            defaults.set(false, forKey: "IndexLocationSetupPending")
        }
    }

    @Published public var exclusions: [String] {
        didSet { defaults.set(exclusions, forKey: Self.exclusionsKey) }
    }

    @Published public var excludedFolders: [String] {
        didSet { defaults.set(excludedFolders, forKey: "IndexExcludedFolders") }
    }

    @Published public var excludedNamePatterns: [String] {
        didSet { defaults.set(excludedNamePatterns, forKey: "IndexExcludedNamePatterns") }
    }

    @Published public var liveUpdates: Bool {
        didSet { defaults.set(liveUpdates, forKey: Self.liveKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialIndexPath = defaults.string(forKey: "IndexDatabasePath") ?? Database.defaultPath()
        indexPath = initialIndexPath
        indexingEnabled = defaults.object(forKey: "IndexingEnabled") == nil || defaults.bool(forKey: "IndexingEnabled")
        startupDelay = defaults.object(forKey: "IndexStartupDelay") == nil ? 120 : defaults.double(forKey: "IndexStartupDelay")
        startupDelayUnit = DelayUnit(rawValue: defaults.string(forKey: "IndexStartupDelayUnit") ?? "") ?? .seconds
        let storedRoots = defaults.stringArray(forKey: Self.rootsKey)
        let hasExistingIndex = FileManager.default.fileExists(atPath: initialIndexPath)
        let pendingSetup = storedRoots == nil && (defaults.bool(forKey: "IndexLocationSetupPending") || !hasExistingIndex)
        needsLocationSetup = pendingSetup
        defaults.set(pendingSetup, forKey: "IndexLocationSetupPending")
        roots = storedRoots ?? (pendingSetup ? [FileManager.default.homeDirectoryForCurrentUser.path] : ["/"])
        if storedRoots == nil && !pendingSetup {
            defaults.set(["/"], forKey: Self.rootsKey)
        }
        exclusions = defaults.stringArray(forKey: Self.exclusionsKey) ?? []
        excludedFolders = defaults.stringArray(forKey: "IndexExcludedFolders") ?? []
        excludedNamePatterns = defaults.stringArray(forKey: "IndexExcludedNamePatterns") ?? []
        if defaults.object(forKey: Self.liveKey) == nil {
            liveUpdates = true
        } else {
            liveUpdates = defaults.bool(forKey: Self.liveKey)
        }
    }
}
