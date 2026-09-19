import SwiftUI
import AppKit
import EverywhereCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @EnvironmentObject var settings: IndexSettings
    @EnvironmentObject var indexService: IndexService
    @EnvironmentObject var hotKeyManager: HotKeyManager
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var preferences = AppPreferences.shared
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @State private var terminalMessage: String?
    @State private var indexPathDraft = ""
    @State private var indexPathError: String?
    @State private var newRoot = ""
    @State private var newExclusion = ""
    @State private var newNamePattern = ""

    @State private var selectedCategory: SettingsCategory? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedCategory) {
                Section("Everywhere") {
                    categoryRows([.general, .shortcuts, .terminal, .updates])
                }
                Section("Search & Index") {
                    categoryRows([.performance, .indexing, .locations, .exclusions, .builtInExclusions, .storage, .fileAccess])
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            .accessibilityLabel("Settings categories")

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(category.rawValue)
                    .font(.title2.bold())
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                Form {
                    detailSections
                }
                .formStyle(.grouped)
                .id(category)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, idealWidth: 900, maxWidth: .infinity,
               minHeight: 580, idealHeight: 700, maxHeight: .infinity)
        .background(SettingsWindowConfiguration())
        .onAppear {
            indexPathDraft = settings.indexPath
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var category: SettingsCategory { selectedCategory ?? .general }

    private func categoryRows(_ categories: [SettingsCategory]) -> some View {
        ForEach(categories, id: \.self) { category in
            Label(category.rawValue, systemImage: category.symbol)
                .padding(.vertical, 4)
                .tag(category)
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        switch category {
        case .general:
            appearanceSection
            quitSection
            startupSection
        case .shortcuts: shortcutSection
        case .terminal: terminalSection
        case .updates: updatesSection
        case .performance: performanceSection
        case .indexing:
            indexingSection
            liveUpdatesSection
            maintenanceSection
        case .locations: rootsSection
        case .exclusions:
            excludedFoldersSection
            namePatternsSection
            nameSubstringsSection
        case .builtInExclusions: builtInExclusionsSection
        case .storage:
            storageSection
            protectedStorageSection
        case .fileAccess: fileAccessSection
        }
    }

    private var startupSection: some View {
        Section {
            Toggle("Launch on Startup", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .disabled(!launchAtLogin.isAppBundle)
            if launchAtLogin.requiresApproval {
                Text("Allow Everywhere in macOS Login Items to finish enabling Launch on Startup.")
                    .foregroundStyle(.secondary)
                Button("Open Login Items…", action: launchAtLogin.openLoginItems)
            }
            if let error = launchAtLogin.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Startup")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch Everywhere automatically when you log in to your Mac. Everywhere stays in the menu bar when its windows are closed.")
                if !launchAtLogin.isAppBundle {
                    Text("Open the Everywhere app from Applications to change this setting.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var updatesSection: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: updater.setAutomaticChecks
            ))
            .disabled(updater.unavailableReason != nil)
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: updater.setAutomaticDownloads
            ))
            .disabled(!updater.automaticallyChecksForUpdates || updater.unavailableReason != nil)
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
            if let reason = updater.unavailableReason {
                Text(reason).foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Checks GitHub releases at startup and daily while Everywhere is running. Choose Install Update to download, replace the app, and relaunch. Automatic installation is optional; when enabled, updates can install when you quit.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var performanceSection: some View {
        Section {
            Toggle("Keep filename index in memory", isOn: $preferences.keepSearchIndexInMemory)
            if preferences.keepSearchIndexInMemory {
                LabeledContent("Filename cache", value: viewModel.cacheStatistics.itemCount == 0 ? "Not loaded" :
                    "\(viewModel.cacheStatistics.itemCount.formatted()) items · \(ByteCountFormatter.string(fromByteCount: Int64(viewModel.cacheStatistics.storageBytes), countStyle: .memory))")
                LabeledContent("Fast sorting", value: "\(viewModel.cacheStatistics.sortCount) cached orders · \(ByteCountFormatter.string(fromByteCount: Int64(viewModel.cacheStatistics.sortBytes), countStyle: .memory))")
            }
        } header: {
            Text("Search Performance")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speeds up repeated filename searches by keeping names and metadata in memory. Turn off to query the disk database with lower active memory use, which can be slower. The cache loads on the next filename search. Small index changes update it incrementally. Broad searches cache up to three sort orders. Memory figures estimate allocated array storage, not total app memory.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(AppPreferences.Appearance.allCases, id: \.self) { appearance in
                    Text(appearance.rawValue).tag(appearance)
                }
            }
        }
    }

    private var quitSection: some View {
        Section {
            Toggle("Always quit without asking", isOn: $preferences.quitWithoutPrompt)
        } header: {
            Text("Quitting")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("When off, quitting asks whether to quit or minimize instead. Minimizing closes the window and keeps Everywhere in the menu bar, still updating the index.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var terminalSection: some View {
        Section {
            LabeledContent("Application") {
                Text(preferences.terminalPath.isEmpty ? "Terminal (default)" :
                     FileManager.default.displayName(atPath: preferences.terminalPath))
                    .help(preferences.terminalPath)
            }
            if !preferences.terminalPath.isEmpty {
                Text(preferences.terminalPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))], spacing: 8) {
                ForEach(AppPreferences.terminalApplications) { application in
                    Button(application.name) {
                        if let url = application.installedURL() {
                            preferences.terminalPath = url.path
                            terminalMessage = nil
                        } else {
                            terminalMessage = "\(application.name) wasn’t found. Install it or use Choose Application… to locate it."
                        }
                    }
                }
            }
            if let terminalMessage {
                Text(terminalMessage).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose Application…", action: chooseTerminal)
                Button("Use Default") {
                    preferences.terminalPath = ""
                    terminalMessage = nil
                }
                    .disabled(preferences.terminalPath.isEmpty)
            }
        } header: {
            Text("Terminal")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open in Terminal sends the selected folder, or a file’s containing folder, to this application. Choose a terminal that supports opening folders.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var shortcutSection: some View {
        Section {
            Toggle("Enable global shortcut", isOn: Binding(
                get: { hotKeyManager.enabled },
                set: { hotKeyManager.enabled = $0 }
            ))
            Picker("Key", selection: $hotKeyManager.shortcut.keyCode) {
                ForEach(GlobalShortcut.keys, id: \.code) { key in
                    Text(key.name).tag(key.code)
                }
            }
            HStack {
                ForEach(GlobalShortcut.modifierOptions, id: \.flag) { modifier in
                    Toggle(modifier.name, isOn: Binding(
                        get: { hotKeyManager.shortcut.modifiers & modifier.flag != 0 },
                        set: { selected in
                            if selected {
                                hotKeyManager.shortcut.modifiers |= modifier.flag
                            } else {
                                hotKeyManager.shortcut.modifiers &= ~modifier.flag
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Text("Shortcut: \(hotKeyManager.shortcut.displayName)")
                Spacer()
                Button("Reset to ⌥ Space") { hotKeyManager.shortcut = .standard }
            }
        } header: {
            Text("Global Shortcut")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a key and at least Control, Option, or Command. Changes are saved and take effect immediately. The menu bar icon also opens the search window.")
                if let error = hotKeyManager.registrationError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var indexingSection: some View {
        Section {
            Toggle("Enable indexing", isOn: Binding(
                get: { settings.indexingEnabled },
                set: { indexService.setIndexingEnabled($0) }
            ))
            HStack {
                Text("Startup delay")
                TextField("Delay", value: $settings.startupDelay, format: .number)
                    .frame(width: 80)
                Picker("Unit", selection: $settings.startupDelayUnit) {
                    ForEach(IndexSettings.DelayUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue.capitalized).tag(unit)
                    }
                }
                .labelsHidden()
            }
            .disabled(!settings.indexingEnabled)
            .onChange(of: settings.startupDelay) { _ in indexService.restartStartupDelay() }
            .onChange(of: settings.startupDelayUnit) { _ in indexService.restartStartupDelay() }
        } header: {
            Text("Indexing")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Empty indexes build immediately. Search the saved index immediately. Delay checks after launch or re-enabling indexing (default: 120 seconds; 0 starts immediately; maximum: 365 days). Resume starts indexing immediately after a pause. Disabling indexing stops scans and live updates; saved results remain searchable.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var liveUpdatesSection: some View {
        Section {
            Toggle("Watch the file system for changes", isOn: Binding(
                get: { indexService.live },
                set: { indexService.setLive($0) }
            ))
            .disabled(!settings.indexingEnabled)
        } header: {
            Text("Live Updates")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keeps the index in sync in real time using file system events.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var maintenanceSection: some View {
        Section {
            HStack {
                Text(indexService.indexCountError ?? (indexService.hasLoadedIndexCount ? "\(indexService.indexedRows.formatted()) items in index" : "Loading saved index…"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rebuild Index") {
                    indexService.rebuild()
                }
                .disabled(!settings.indexingEnabled || (indexService.isBusy && indexService.phase != .waiting))
            }
            if indexService.isBusy {
                IndexingProgressView()
            }
            if indexService.isCompacting {
                Text("Compacting index…").foregroundStyle(.secondary)
            }
        } header: {
            Text("Maintenance")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unused database space is reclaimed automatically when indexing is idle and enough space can be recovered.")
                if let error = indexService.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var storageSection: some View {
        Section {
            TextField("Index file path", text: $indexPathDraft)
                .onSubmit(saveIndexPath)
            HStack {
                Button("Choose Existing…", action: chooseIndexFile)
                Button("New File…", action: chooseNewIndexFile)
                Spacer()
                Button("Use Default") {
                    indexPathDraft = Database.defaultPath()
                    saveIndexPath()
                }
                Button("Apply", action: saveIndexPath)
                    .disabled(indexPathDraft == settings.indexPath)
            }
            LabeledContent("Active index") {
                Text(indexService.database.path)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: indexService.database.path)])
            }
            HStack {
                Button("Compact Index Now") {
                    indexService.compactIndexNow()
                }
                .disabled(!indexService.canCompactIndex)
                if indexService.isCompacting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Compacting index…")
                        .foregroundStyle(.secondary)
                }
            }
            if let message = indexService.compactionMessage {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Index Storage")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Changes take effect after quitting and reopening Everywhere. Choose an existing index to use its saved results, or a new file to build a fresh index. The current index is not moved or copied.")
                Text("Compact Index Now reclaims unused space in the active index without rebuilding it. Available when no scan is running, including when indexing is disabled.")
                if settings.indexPath != indexService.database.path {
                    Text("Restart Everywhere to use the selected index.")
                        .foregroundStyle(.orange)
                }
                if let indexPathError { Text(indexPathError).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var fileAccessSection: some View {
        Section("File Access") {
            FullDiskAccessView()
            Button("Reindex Accessible Files") { indexService.rebuild() }
                .disabled(settings.needsLocationSetup || !settings.indexingEnabled || indexService.isBusy)
        }
    }

    private var rootsSection: some View {
        Section {
            ForEach(settings.roots, id: \.self) { root in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(root)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        settings.roots.removeAll { $0 == root }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel("Remove location or exclusion")
                }
            }
            HStack {
                TextField("Add a folder to index…", text: $newRoot)
                    .onSubmit(addRoot)
                Button("Browse…", action: browseForRoot)
                Button("Add", action: addRoot)
                    .disabled(newRoot.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Index Locations")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("These folders are indexed subject to the configured exclusions. Location changes take effect when the index is rebuilt.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var builtInExclusionsSection: some View {
        Section {
            ForEach(settings.builtInExcludedFolders, id: \.self) { folder in
                HStack {
                    Text(folder).lineLimit(1).truncationMode(.middle).help(folder)
                    Spacer()
                    Button {
                        settings.builtInExcludedFolders.removeAll { $0 == folder }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove built-in folder exclusion")
                        .accessibilityLabel("Remove built-in folder exclusion: \(folder)")
                }
            }
            ForEach(settings.builtInExcludedDirectoryNames, id: \.self) { name in
                HStack {
                    VStack(alignment: .leading) {
                        Text(name)
                        Text("File or folder name, anywhere").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        settings.builtInExcludedDirectoryNames.removeAll { $0 == name }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove built-in name exclusion")
                        .accessibilityLabel("Remove built-in name exclusion: \(name)")
                }
            }
            Button("Restore Built-in Exclusions") {
                settings.builtInExcludedFolders = FilesystemIndexer.defaultSkipPathPrefixes
                settings.builtInExcludedDirectoryNames = FilesystemIndexer.defaultSkipDirNames
            }
        } header: {
            Text("Built-in Exclusions")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("These defaults skip system volumes, temporary folders, and system metadata. Remove any rule to include those locations. Name rules apply anywhere; an overlapping rule can still exclude a folder. An explicitly added index location overrides a built-in path exclusion. Rebuild the index to apply changes.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var protectedStorageSection: some View {
        Section {
            Label((indexService.database.path as NSString).deletingLastPathComponent, systemImage: "lock")
                .textSelection(.enabled)
        } header: {
            Text("Protected Index Folder")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The folder containing Everywhere’s own index is always excluded to prevent indexing its own writes. This exclusion cannot be removed.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var excludedFoldersSection: some View {
        Section {
            ForEach(settings.excludedFolders, id: \.self) { folder in
                HStack {
                    Text(folder).lineLimit(1).truncationMode(.middle).help(folder)
                    Spacer()
                    Button {
                        settings.excludedFolders.removeAll { $0 == folder }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove excluded folder")
                }
            }
            Button("Exclude Folder…", action: chooseExcludedFolders)
        } header: {
            Text("Excluded Folders")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Exclude a specific folder and everything inside it. Other folders with the same name remain indexed. Rebuild the index to apply changes.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var namePatternsSection: some View {
        Section {
            ForEach(settings.excludedNamePatterns, id: \.self) { pattern in
                HStack {
                    Text(pattern)
                    Spacer()
                    Button {
                        settings.excludedNamePatterns.removeAll { $0 == pattern }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove excluded name pattern")
                }
            }
            HStack {
                TextField("*.tmp; *.log; cache-?", text: $newNamePattern).onSubmit(addNamePatterns)
                Button("Add", action: addNamePatterns)
                    .disabled(newNamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Excluded Name Patterns")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Matches complete file or folder names, ignoring case. Use * for any text and ? for one character; separate patterns with semicolons. Matching folders and their contents are excluded. Rebuild the index to apply changes.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private var nameSubstringsSection: some View {
        Section {
            ForEach(settings.exclusions, id: \.self) { exclusion in
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text(exclusion)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        settings.exclusions.removeAll { $0 == exclusion }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel("Remove location or exclusion")
                }
            }
            HStack {
                TextField("Exclude names containing…", text: $newExclusion)
                    .onSubmit(addExclusion)
                Button("Add", action: addExclusion)
                    .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Names Containing")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Folders and files whose name contains any of these terms are left out of the index. Rebuild the index to apply changes.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }

    private func chooseExcludedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to exclude from the index"
        guard panel.runModal() == .OK else { return }
        settings.excludedFolders = Array(Set(settings.excludedFolders + panel.urls.map { $0.standardizedFileURL.path })).sorted()
    }

    private func addNamePatterns() {
        let patterns = newNamePattern.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        settings.excludedNamePatterns = Array(Set(settings.excludedNamePatterns + patterns)).sorted()
        newNamePattern = ""
    }

    private func chooseTerminal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose a terminal application"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.terminalPath = url.path
        terminalMessage = nil
    }

    private func saveIndexPath() {
        do {
            try settings.setIndexPath(indexPathDraft)
            indexPathDraft = settings.indexPath
            indexPathError = nil
        } catch {
            indexPathError = error.localizedDescription
        }
    }

    private func chooseIndexFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an existing Everywhere index"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        indexPathDraft = url.path
        saveIndexPath()
    }

    private func chooseNewIndexFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "index.sqlite"
        panel.message = "Choose where to create a new Everywhere index"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        indexPathDraft = url.path
        saveIndexPath()
    }

    private func addRoot() {
        let trimmed = newRoot.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if !settings.roots.contains(expanded) {
            settings.roots.append(expanded)
            settings.roots.sort()
        }
        newRoot = ""
    }

    private func browseForRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to index"
        guard panel.runModal() == .OK else { return }
        let chosen = panel.urls.map(\.path)
        settings.roots = Array(Set(settings.roots + chosen)).sorted()
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return }
        if !settings.exclusions.contains(trimmed) {
            settings.exclusions.append(trimmed)
            settings.exclusions.sort()
        }
        newExclusion = ""
    }
}

private enum SettingsCategory: String, Hashable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case terminal = "Terminal"
    case updates = "Updates"
    case performance = "Search Performance"
    case indexing = "Indexing"
    case locations = "Index Locations"
    case exclusions = "Custom Exclusions"
    case builtInExclusions = "Built-in Exclusions"
    case storage = "Index Storage"
    case fileAccess = "File Access"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .terminal: return "terminal"
        case .updates: return "arrow.down.circle"
        case .performance: return "speedometer"
        case .indexing: return "arrow.triangle.2.circlepath"
        case .locations: return "folder"
        case .exclusions: return "line.3.horizontal.decrease.circle"
        case .builtInExclusions: return "eye.slash"
        case .storage: return "externaldrive"
        case .fileAccess: return "lock.shield"
        }
    }
}

private struct SettingsWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SettingsWindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                window.styleMask.insert(.resizable)
            }
        }
    }
}
