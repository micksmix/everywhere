import Foundation
import Combine

public final class IndexSettings: ObservableObject {
    private static let rootsKey = "IndexRoots"
    private static let exclusionsKey = "IndexExclusions"
    private static let liveKey = "IndexLiveUpdates"
    private static let builtInFoldersKey = "IndexBuiltInExcludedFolders"
    private static let builtInDirNamesKey = "IndexBuiltInExcludedDirectoryNames"
    private static let builtInVersionKey = "IndexBuiltInExcludedFoldersVersion"
    private static let builtInDefaultsVersion = 2

    private static func loadBuiltInExclusions(defaults: UserDefaults) -> (folders: [String], dirNames: [String]) {
        let storedFolders = defaults.stringArray(forKey: builtInFoldersKey)
        let storedDirNames = defaults.stringArray(forKey: builtInDirNamesKey)
        let storedVersion = defaults.object(forKey: builtInVersionKey) == nil ? 0 : defaults.integer(forKey: builtInVersionKey)
        var folders = storedFolders ?? FilesystemIndexer.defaultSkipPathPrefixes
        var dirNames = storedDirNames ?? FilesystemIndexer.defaultSkipDirNames
        if storedVersion < builtInDefaultsVersion {
            for prefix in FilesystemIndexer.defaultSkipPathPrefixes where !folders.contains(prefix) { folders.append(prefix) }
            for name in FilesystemIndexer.defaultSkipDirNames where !dirNames.contains(name) { dirNames.append(name) }
            defaults.set(folders, forKey: builtInFoldersKey)
            defaults.set(dirNames, forKey: builtInDirNamesKey)
            defaults.set(builtInDefaultsVersion, forKey: builtInVersionKey)
        }
        return (folders, dirNames)
    }

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

    @Published public var builtInExcludedFolders: [String] {
        didSet { defaults.set(builtInExcludedFolders, forKey: "IndexBuiltInExcludedFolders") }
    }

    @Published public var builtInExcludedDirectoryNames: [String] {
        didSet { defaults.set(builtInExcludedDirectoryNames, forKey: "IndexBuiltInExcludedDirectoryNames") }
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

    private static let lastRebuildKey = "LastFullRebuildDate"

    @Published public private(set) var lastFullRebuildDate: Date?

    public func noteFullRebuild(_ date: Date = Date()) {
        lastFullRebuildDate = date
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastRebuildKey)
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
        if defaults.object(forKey: Self.lastRebuildKey) != nil {
            lastFullRebuildDate = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastRebuildKey))
        }
        let builtIn = Self.loadBuiltInExclusions(defaults: defaults)
        builtInExcludedFolders = builtIn.folders
        builtInExcludedDirectoryNames = builtIn.dirNames
        excludedFolders = defaults.stringArray(forKey: "IndexExcludedFolders") ?? []
        excludedNamePatterns = defaults.stringArray(forKey: "IndexExcludedNamePatterns") ?? []
        if defaults.object(forKey: Self.liveKey) == nil {
            liveUpdates = true
        } else {
            liveUpdates = defaults.bool(forKey: Self.liveKey)
        }
    }
}
