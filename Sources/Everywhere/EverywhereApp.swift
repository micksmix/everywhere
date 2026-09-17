import SwiftUI
import AppKit
import EverywhereCore

@main
struct EverywhereApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var settings: IndexSettings
    @StateObject private var indexService: IndexService
    @StateObject private var viewModel: ContentViewModel
    @StateObject private var hotKeyManager: HotKeyManager
    @State private var showsStartupNotice = false
    private let startupNotice: String

    init() {
        let settings = IndexSettings()
        let database: Database
        var notice = ""
        do {
            database = try Database(path: settings.indexPath)
        } catch {
            let originalError = error.localizedDescription
            let temporaryPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("Everywhere-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("index.sqlite").path
            do {
                database = try Database(path: temporaryPath)
                notice = "Your saved index could not be opened: \(originalError)\n\nEverywhere is using a temporary index for this session. Your saved index location has not changed. Choose a writable index location in Settings before restarting."
            } catch {
                let alert = NSAlert()
                alert.messageText = "Everywhere could not open an index"
                alert.informativeText = "\(originalError)\n\nA temporary index could not be created either: \(error.localizedDescription)"
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                exit(EXIT_FAILURE)
            }
        }
        startupNotice = notice
        _showsStartupNotice = State(initialValue: !notice.isEmpty)
        let service = IndexService(settings: settings, database: database, accessCheck: { FullDiskAccess.check() })
        let hotKeyManager = HotKeyManager()
        let viewModel = ContentViewModel(database: database, indexService: service)

        _settings = StateObject(wrappedValue: settings)
        _indexService = StateObject(wrappedValue: service)
        _viewModel = StateObject(wrappedValue: viewModel)
        _hotKeyManager = StateObject(wrappedValue: hotKeyManager)

    }

    var body: some Scene {
        Window("Everywhere", id: "main") {
            ContentView()
                .alert("Using a temporary index", isPresented: $showsStartupNotice) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(startupNotice)
                }
                .environmentObject(viewModel)
                .environmentObject(indexService)
                .environmentObject(settings)
                .environmentObject(hotKeyManager)
                .frame(minWidth: 760, minHeight: 440)
                .background(MainWindowRegistration(delegate: appDelegate, viewModel: viewModel,
                                                   indexService: indexService, hotKeyManager: hotKeyManager))
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Everywhere Help") {
                    AppHelp.showGuide()
                }
                .keyboardShortcut("?", modifiers: .command)
                Button("Search Syntax") {
                    AppHelp.showSearchSyntax()
                }
            }
            UpdateCommands()
            SearchCommands(viewModel: viewModel, indexService: indexService, settings: settings)
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(indexService)
                .environmentObject(settings)
                .environmentObject(hotKeyManager)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 700)
    }
}

struct SearchCommands: Commands {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var indexService: IndexService
    @ObservedObject var settings: IndexSettings

    var body: some Commands {
        CommandMenu("Search") {
            Button("Focus Search Field") {
                viewModel.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Clear Search") {
                viewModel.clearSearch()
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Toggle("Match Path", isOn: $viewModel.matchPath)
                .keyboardShortcut("p", modifiers: [.command, .option])

            Toggle("Use Regex", isOn: $viewModel.useRegex)
                .keyboardShortcut("x", modifiers: [.command, .option])

            Toggle("Match Case", isOn: $viewModel.matchCase)
                .keyboardShortcut("c", modifiers: [.command, .option])

            Toggle("Match Whole Words", isOn: $viewModel.wholeWord)
                .keyboardShortcut("w", modifiers: [.command, .option])

            Toggle("Show Hidden Files", isOn: $viewModel.showHidden)
                .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("Open") {
                viewModel.openSelection()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Quick Look") {
                viewModel.previewSelection?()
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(viewModel.selectedEntries.isEmpty)

            Button("Clear Search History") {
                viewModel.clearHistory()
            }

            Button("Get Info") {
                viewModel.showInfo(viewModel.selectedEntries)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(viewModel.selectedEntries.isEmpty)

            Button("Open in Terminal") {
                viewModel.openInTerminal(viewModel.selectedEntries)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])

            Button("Show in Finder") {
                viewModel.revealSelection()
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button(indexService.isPaused ? "Resume Indexing" : "Pause Indexing") {
                indexService.togglePause()
            }
            .disabled(!indexService.canPause)

            Button("Rebuild Index") {
                indexService.rebuild()
            }
            .disabled(!settings.indexingEnabled || (indexService.isBusy && indexService.phase != .waiting))
        }
    }
}

struct UpdateCommands: Commands {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
