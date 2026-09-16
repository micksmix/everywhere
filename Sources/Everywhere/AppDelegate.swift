import AppKit
import SwiftUI
import EverywhereCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (() -> Void)?
    private var viewModel: ContentViewModel?
    private var indexService: IndexService?
    private var hotKeyManager: HotKeyManager?
    private let statusController = StatusItemController()

    func configure(viewModel: ContentViewModel, indexService: IndexService, hotKeyManager: HotKeyManager, openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
        self.viewModel = viewModel
        self.indexService = indexService
        self.hotKeyManager = hotKeyManager
        hotKeyManager.onActivate = { [weak self] in
            self?.showMainWindow()
        }
        statusController.onOpen = { [weak self] in
            self?.showMainWindow()
        }
        statusController.onRebuild = { [weak self] in
            self?.indexService?.rebuild()
        }
        hotKeyManager.activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func registerSettingsAction(_ action: @escaping () -> Void) {
        statusController.onSettings = action
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyAppearance()
        statusController.install()
        hotKeyManager?.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func registerMainWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("EverywhereMainWindow")
        if !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier?.rawValue == "ApplicationIcon" }) {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = NSUserInterfaceItemIdentifier("ApplicationIcon")
            accessory.layoutAttribute = .left
            let icon = NSImageView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
            icon.image = NSApp.applicationIconImage
            icon.imageScaling = .scaleProportionallyDown
            icon.setAccessibilityLabel("Everywhere")
            accessory.view = icon
            window.addTitlebarAccessoryViewController(accessory)
        }
        mainWindow = window
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow, NSApp.windows.contains(window) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        DispatchQueue.main.async { [weak self] in self?.viewModel?.focusSearch() }
    }
}

struct MainWindowRegistration: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate
    let viewModel: ContentViewModel
    let indexService: IndexService
    let hotKeyManager: HotKeyManager

    var body: some View {
        MainWindowReader { window in
            delegate.configure(viewModel: viewModel, indexService: indexService, hotKeyManager: hotKeyManager) {
                openWindow(id: "main")
            }
            delegate.registerMainWindow(window)
        }
        .background {
            if #available(macOS 14.0, *) {
                SettingsActionRegistration(delegate: delegate)
            }
        }
    }
}

@available(macOS 14.0, *)
private struct SettingsActionRegistration: View {
    @Environment(\.openSettings) private var openSettings
    let delegate: AppDelegate

    var body: some View {
        Color.clear.onAppear {
            delegate.registerSettingsAction { openSettings() }
        }
    }
}

struct MainWindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.onWindow = onWindow
    }

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }
                self?.onWindow?(window)
            }
        }
    }
}
