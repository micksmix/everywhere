import AppKit
import SwiftUI
import EverywhereCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var mainWindow: NSWindow?
    private let closingWindows = NSHashTable<NSWindow>.weakObjects()
    private var openMainWindow: (() -> Void)?
    private var viewModel: ContentViewModel?
    private var indexService: IndexService?
    private var hotKeyManager: HotKeyManager?
    private let statusController = StatusItemController()
    private var isConfirmingQuit = false

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
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.canBecomeMain, window.isVisible, NSApp.windows.contains(window) else { return }
        closingWindows.remove(window)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.canBecomeMain else { return }
        closingWindows.add(window)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hasOpenWindow = NSApp.windows.contains {
                !self.closingWindows.contains($0) && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
            }
            if !hasOpenWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func activateWindowMode() {
        let changed = NSApp.activationPolicy() != .regular
        if changed { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if changed {
            DispatchQueue.main.async {
                if NSApp.activationPolicy() == .regular { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }

    func registerSettingsAction(_ action: @escaping () -> Void) {
        statusController.onSettings = action
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyAppearance()
        statusController.install()
        AppUpdater.shared.start()
        hotKeyManager?.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isConfirmingQuit { return .terminateCancel }
        guard !AppPreferences.shared.quitWithoutPrompt else { return .terminateNow }
        isConfirmingQuit = true
        let alert = NSAlert()
        alert.messageText = "Quit Everywhere?"
        alert.informativeText = "Everywhere stops keeping the index up to date and leaves the menu bar until reopened. Choose Minimize to keep it running."
        alert.addButton(withTitle: "Minimize")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isConfirmingQuit = false
            switch response {
            case .alertSecondButtonReturn:
                NSApp.reply(toApplicationShouldTerminate: true)
            case .alertFirstButtonReturn:
                NSApp.reply(toApplicationShouldTerminate: false)
                DispatchQueue.main.async { self?.minimizeMainWindow() }
            default:
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        if let window = mainWindow, NSApp.windows.contains(window), window.isVisible, !window.isMiniaturized {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            DispatchQueue.main.async { respond(alert.runModal()) }
        }
        return .terminateLater
    }

    private func minimizeMainWindow() {
        if let window = mainWindow, NSApp.windows.contains(window) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func registerMainWindow(_ window: NSWindow) {
        window.level = .normal
        window.identifier = NSUserInterfaceItemIdentifier("EverywhereMainWindow")
        installTitlebarIdentity(in: window)
        mainWindow = window
        if window.isVisible && NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func installTitlebarIdentity(in window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier?.rawValue == "ApplicationIcon" }) else { return }
        window.titleVisibility = .hidden
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = NSUserInterfaceItemIdentifier("ApplicationIcon")
        accessory.layoutAttribute = .left
        accessory.view = TitleBarIdentityView(title: "Everywhere")
        window.addTitlebarAccessoryViewController(accessory)
    }

    func showMainWindow() {
        activateWindowMode()
        if let window = mainWindow, NSApp.windows.contains(window) {
            closingWindows.remove(window)
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

private final class TitleBarIdentityView: NSView {
    private let stack = NSStackView()
    private var centering: NSLayoutConstraint?
    private var resizeObservation: NSObjectProtocol?

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        stack.setAccessibilityLabel(title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let constraint = stack.centerXAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            constraint,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        centering = constraint
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let token = resizeObservation { NotificationCenter.default.removeObserver(token) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token = resizeObservation { NotificationCenter.default.removeObserver(token) }
        resizeObservation = nil
        guard window != nil else { return }
        alignContent()
        resizeObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.alignContent() }
    }

    private func alignContent() {
        guard let window, let centering else { return }
        let width = window.frame.width
        if frame.width != width { frame.size.width = width }
        let windowFrame = convert(bounds, to: nil)
        centering.constant = width / 2 - windowFrame.minX
        needsLayout = true
    }
}
