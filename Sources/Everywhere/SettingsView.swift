import SwiftUI
import AppKit
import EverywhereCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @EnvironmentObject var settings: IndexSettings
    @EnvironmentObject var indexService: IndexService
    @EnvironmentObject var hotKeyManager: HotKeyManager
    @ObservedObject private var preferences = AppPreferences.shared
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @State private var terminalMessage: String?
    @State private var indexPathDraft = ""
    @State private var indexPathError: String?
    @State private var newRoot = ""
    @State private var newExclusion = ""
    @State private var newNamePattern = ""

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            indexingSettings
                .tabItem { Label("Indexing", systemImage: "externaldrive") }
            locationSettings
                .tabItem { Label("Locations", systemImage: "folder") }
        }
        .padding(12)
        .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity,
               minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .background(SettingsWindowConfiguration())
        .onAppear {
            indexPathDraft = settings.indexPath
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var generalSettings: some View {
        Form {
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
                Text("Launch Everywhere automatically when you log in to your Mac. Everywhere stays in the menu bar when its windows are closed.")
                if !launchAtLogin.isAppBundle {
                    Text("Open the Everywhere app from Applications to change this setting.")
                }
            }
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
                Text("Speeds up repeated filename searches by keeping names and metadata in memory. Turn off to query the disk database with lower active memory use, which can be slower. The cache loads on the next filename search. Small index changes update it incrementally. Broad searches cache up to three sort orders. Memory figures estimate allocated array storage, not total app memory.")
            }
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppPreferences.Appearance.allCases, id: \.self) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
            }
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
                Text("Open in Terminal sends the selected folder, or a file’s containing folder, to this application. Choose a terminal that supports opening folders.")
            }
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
                Text("General")
            } footer: {
                Text("Choose a key and at least Control, Option, or Command. Changes are saved and take effect immediately. The menu bar icon also opens the search window.")
                if let error = hotKeyManager.registrationError {
                    Text(error).foregroundStyle(.red)
                }
            }

        }
        .formStyle(.grouped)
    }

    private var indexingSettings: some View {
        Form {
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
                Text("Empty indexes build immediately. Search the saved index immediately. Delay checks after launch or re-enabling indexing (default: 120 seconds; 0 starts immediately; maximum: 365 days). Resume starts indexing immediately after a pause. Disabling indexing stops scans and live updates; saved results remain searchable.")
            }

            Section {
                Toggle("Watch the file system for changes", isOn: Binding(
                    get: { settings.liveUpdates },
                    set: { newValue in
                        settings.liveUpdates = newValue
                        indexService.setLive(newValue)
                    }
                ))
                .disabled(!settings.indexingEnabled)
            } header: {
                Text("Live Updates")
            } footer: {
                Text("Keeps the index in sync in real time using file system events.")
            }

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
                Text("Unused database space is reclaimed automatically when indexing is idle and enough space can be recovered.")
                if let error = indexService.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var locationSettings: some View {
        Form {
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
                Text("Changes take effect after quitting and reopening Everywhere. Choose an existing index to use its saved results, or a new file to build a fresh index. The current index is not moved or copied.")
                Text("Compact Index Now reclaims unused space in the active index without rebuilding it. Available when no scan is running, including when indexing is disabled.")
                if settings.indexPath != indexService.database.path {
                    Text("Restart Everywhere to use the selected index.")
                        .foregroundStyle(.orange)
                }
                if let indexPathError { Text(indexPathError).foregroundStyle(.red) }
            }

            Section("File Access") {
                FullDiskAccessView()
                Button("Reindex Accessible Files") { indexService.rebuild() }
                    .disabled(settings.needsLocationSetup || !settings.indexingEnabled || indexService.isBusy)
            }

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
                Text("Everything under these folders is indexed. Location changes take effect when the index is rebuilt.")
            }

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
                Text("Exclude a specific folder and everything inside it. Other folders with the same name remain indexed. Rebuild the index to apply changes.")
            }

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
                Text("Matches complete file or folder names, ignoring case. Use * for any text and ? for one character; separate patterns with semicolons. Matching folders and their contents are excluded. Rebuild the index to apply changes.")
            }

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
                Text("Exclusions")
            } footer: {
                Text("Folders and files whose name contains any of these terms are left out of the index. Rebuild the index to apply changes.")
            }

        }
        .formStyle(.grouped)
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
