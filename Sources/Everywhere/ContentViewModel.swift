import AppKit
import Combine
import EverywhereCore
import UniformTypeIdentifiers

final class ContentViewModel: ObservableObject, @unchecked Sendable {
    @Published var searchText: String = "" {
        didSet {
            if searchText != oldValue { scheduleSearch() }
        }
    }
    @Published private(set) var results: [Entry] = []
    @Published var selection: Set<Int64> = []
    @Published private(set) var totalMatches = 0
    @Published private(set) var cacheStatistics = SearchCacheStatistics()
    @Published private(set) var elapsedMS: Double = 0
    @Published var kindFilter: KindFilter = .all {
        didSet {
            if kindFilter != oldValue { scheduleSearch() }
        }
    }
    @Published var showHidden: Bool = true {
        didSet {
            if showHidden != oldValue { scheduleSearch() }
        }
    }
    @Published var matchPath: Bool = false {
        didSet {
            if matchPath != oldValue { scheduleSearch() }
        }
    }
    @Published var useRegex: Bool = false {
        didSet {
            if useRegex != oldValue { scheduleSearch() }
        }
    }
    @Published var matchCase: Bool = false {
        didSet {
            if matchCase != oldValue { scheduleSearch() }
        }
    }
    @Published var wholeWord: Bool = false {
        didSet {
            if wholeWord != oldValue { scheduleSearch() }
        }
    }
    @Published private(set) var searchError: String?
    @Published private(set) var sortKey: SortKey = .name
    @Published private(set) var sortAscending = true
    @Published var focusToken = 0

    private let defaults: UserDefaults
    private let database: Database
    private let indexService: IndexService
    private var searchTask: Task<Void, Never>?
    private var searchCancellation = SearchCancellation()
    private var searchGeneration: UInt64 = 0
    private var searchInFlight = false
    private var pendingIndexRefresh = false
    private var memorySubscription: AnyCancellable?
    private var changeSubscription: AnyCancellable?
    private var indexSubscription: AnyCancellable?

    init(database: Database, indexService: IndexService, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sortKey = SortKey(rawValue: defaults.string(forKey: "ResultsSortKey") ?? "") ?? .name
        sortAscending = defaults.object(forKey: "ResultsSortAscending") == nil || defaults.bool(forKey: "ResultsSortAscending")
        self.database = database
        self.indexService = indexService
        scheduleSearch()
        memorySubscription = AppPreferences.shared.$keepSearchIndexInMemory
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSearch() }
        changeSubscription = indexService.$indexRevision
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refreshIndexResults() }
        indexSubscription = indexService.$phase
            .removeDuplicates()
            .dropFirst()
            .filter { $0 == .idle }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIndexResults() }
    }

    deinit {
        searchTask?.cancel()
        searchCancellation.cancel()
    }

    var sortDescriptors: [NSSortDescriptor] {
        let selector: Selector? = (sortKey == .name || sortKey == .path) ? #selector(NSString.compare(_:)) : nil
        return [NSSortDescriptor(key: sortKey.rawValue, ascending: sortAscending, selector: selector)]
    }

    func apply(sortDescriptors: [NSSortDescriptor]) {
        guard let first = sortDescriptors.first,
              let key = first.key.flatMap(SortKey.init(rawValue:)) else { return }
        let changed = key != sortKey || first.ascending != sortAscending
        sortKey = key
        sortAscending = first.ascending
        defaults.set(key.rawValue, forKey: "ResultsSortKey")
        defaults.set(first.ascending, forKey: "ResultsSortAscending")
        if changed { scheduleSearch() }
    }

    func focusSearch() {
        focusToken += 1
    }

    func clearSearch() {
        searchText = ""
        selection = []
        focusSearch()
    }

    private func currentRequest() -> SearchRequest {
        SearchRequest(
            text: searchText,
            kind: kindFilter,
            includeHidden: showHidden,
            matchPath: matchPath,
            useRegex: useRegex,
            matchCase: matchCase,
            wholeWord: wholeWord,
            sortKey: sortKey,
            ascending: sortAscending,
            limit: 10_000
        )
    }

    private func refreshIndexResults() {
        if searchInFlight {
            pendingIndexRefresh = true
        } else {
            scheduleSearch()
        }
    }

    private func finishSearch() {
        searchInFlight = false
        if pendingIndexRefresh { scheduleSearch() }
    }

    private func scheduleSearch() {
        searchInFlight = true
        pendingIndexRefresh = false
        searchTask?.cancel()
        searchCancellation.cancel()
        let cancellation = SearchCancellation()
        searchCancellation = cancellation
        searchGeneration &+= 1
        let generation = searchGeneration
        let useMemory = AppPreferences.shared.keepSearchIndexInMemory
        let request = currentRequest()
        let db = database
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try db.search(request, useMemory: useMemory, cancellation: cancellation)
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self, generation == self.searchGeneration else { return }
                    self.apply(result)
                    self.finishSearch()
                }
            } catch {
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self, generation == self.searchGeneration else { return }
                    self.results = []
                    self.totalMatches = 0
                    self.searchError = Self.errorText(error)
                    self.finishSearch()
                }
            }
        }
    }

    private static func errorText(_ error: Error) -> String {
        (error as? DatabaseError)?.errorDescription ?? String(describing: error)
    }

    private func apply(_ result: SearchResult) {
        selection.formIntersection(Set(result.entries.map(\.id)))
        results = result.entries
        totalMatches = result.total
        elapsedMS = result.elapsedMS
        cacheStatistics = result.cacheStatistics
        searchError = nil
    }

    var selectedEntries: [Entry] {
        if !selection.isEmpty {
            return results.filter { selection.contains($0.id) }
        }
        return results.first.map { [$0] } ?? []
    }

    func openSelection() {
        for entry in selectedEntries.prefix(10) {
            Self.open(entry)
        }
    }

    static func open(_ entry: Entry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    func revealSelection() {
        let urls = selectedEntries.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openInTerminal(_ entries: [Entry]) {
        let workspace = NSWorkspace.shared
        let selectedPath = AppPreferences.shared.terminalPath
        guard let terminal = selectedPath.isEmpty
            ? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            : URL(fileURLWithPath: selectedPath) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        for entry in entries.prefix(5) {
            let directory = entry.isDirectory
                ? URL(fileURLWithPath: entry.path)
                : URL(fileURLWithPath: entry.path).deletingLastPathComponent()
            workspace.open([directory], withApplicationAt: terminal, configuration: configuration) { _, error in
                guard let error else { return }
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    func copyPath(_ entries: [Entry]) {
        let paths = entries.map(\.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    func copyName(_ entries: [Entry]) {
        let names = entries.map(\.name).joined(separator: "\n")
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names, forType: .string)
    }
}
