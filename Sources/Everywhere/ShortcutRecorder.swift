import AppKit
import SwiftUI
import EverywhereCore
import Carbon.HIToolbox

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var manager: HotKeyManager

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.manager = manager
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.manager = manager
        button.synchronize()
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.cancelRecording()
    }
}

final class ShortcutRecorderButton: NSButton {
    weak var manager: HotKeyManager?
    private(set) var recording = false
    private var pendingShortcut: GlobalShortcut?
    private var eventMonitor: Any?
    private var observations: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        title = "Record Shortcut"
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self
        action = #selector(toggleRecording)
        setAccessibilityLabel("Record global shortcut")
        toolTip = "Record a key combination. Press Escape or click elsewhere to cancel."
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    deinit {
        removeMonitoring()
        if recording { manager?.cancelRecording() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { cancelRecording() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { cancelRecording() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelRecording()
    }

    override func keyDown(with event: NSEvent) {
        if recording { _ = handleRecordingEvent(event) }
        else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if recording { _ = handleRecordingEvent(event) }
        else { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if recording { _ = handleRecordingEvent(event) }
        else { super.flagsChanged(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { return handleRecordingEvent(event) == nil }
        return super.performKeyEquivalent(with: event)
    }

    func synchronize() {
        if recording, manager?.isRecording != true { stopRecording() }
    }

    @objc private func toggleRecording() {
        if recording { cancelRecording() }
        else { startRecording() }
    }

    func startRecording() {
        guard !recording, let manager, !manager.isRecording, let window,
              window.isKeyWindow, window.makeFirstResponder(self) else { return }
        recording = true
        pendingShortcut = nil
        manager.beginRecording()
        updateTitle(modifiers: 0)
        observe(NSWindow.didResignKeyNotification, object: window)
        observe(NSWindow.willCloseNotification, object: window)
        observe(NSApplication.didResignActiveNotification, object: nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    func cancelRecording() {
        let wasRecording = recording
        stopRecording()
        if wasRecording { manager?.cancelRecording() }
    }

    func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard recording, let manager else { return event }
        guard let window, window.isKeyWindow, window.firstResponder === self else {
            cancelRecording()
            return event
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                cancelRecording()
            }
            return event
        case .flagsChanged:
            if pendingShortcut == nil { updateTitle(modifiers: GlobalShortcut.carbonModifiers(from: event.modifierFlags)) }
            return nil
        case .keyDown:
            let result = GlobalShortcut.capture(keyCode: UInt32(event.keyCode),
                                                modifiers: GlobalShortcut.carbonModifiers(from: event.modifierFlags),
                                                isRepeat: event.isARepeat)
            switch result {
            case .cancelled:
                cancelRecording()
            case .ignored:
                break
            case .invalid(let error):
                if pendingShortcut == nil { manager.reportRecordingError(error) }
            case .shortcut(let shortcut):
                guard pendingShortcut == nil else { return nil }
                if event.modifierFlags.contains(.function), !shortcut.acceptsFunctionFlag {
                    manager.reportRecordingError("Fn/Globe cannot be used as a global shortcut modifier. Use Control, Option, or Command.")
                } else {
                    pendingShortcut = shortcut
                    title = shortcut.localizedDisplayName
                    setAccessibilityValue("Captured \(title). Release the key to save.")
                }
            }
            return nil
        case .keyUp:
            if let pendingShortcut, event.keyCode == pendingShortcut.keyCode {
                if manager.finishRecording(with: pendingShortcut) {
                    stopRecording()
                } else {
                    self.pendingShortcut = nil
                    updateTitle(modifiers: GlobalShortcut.carbonModifiers(from: event.modifierFlags))
                }
            }
            return nil
        default:
            return event
        }
    }

    private func updateTitle(modifiers: UInt32) {
        let symbols = GlobalShortcut.modifierSymbols(for: modifiers)
        title = symbols.isEmpty ? "Type Shortcut…" : symbols + " …"
        setAccessibilityValue("Recording. Press a shortcut, or Escape to cancel.")
    }

    private func stopRecording() {
        recording = false
        pendingShortcut = nil
        removeMonitoring()
        title = "Record Shortcut"
        setAccessibilityValue(nil)
    }

    private func observe(_ name: Notification.Name, object: Any?) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            self?.cancelRecording()
        })
    }

    private func removeMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations.removeAll()
    }
}
