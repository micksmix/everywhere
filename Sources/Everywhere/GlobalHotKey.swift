import Foundation
import Combine
import Carbon.HIToolbox
import EverywhereCore

final class GlobalHotKey {
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registeredID: UInt32?
    private var nextID: UInt32 = 0
    private static let signature = OSType(0x4556_5752)

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &eventType,
                                             Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
            guard status == noErr else { return status }
            guard eventHandlerRef != nil else { return OSStatus(eventInternalErr) }
        }
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyRef = nil
            return status
        }
        guard hotKeyRef != nil else { return OSStatus(eventInternalErr) }
        registeredID = nextID
        return noErr
    }

    func unregister() {
        registeredID = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    deinit {
        unregister()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    fileprivate func handle(_ id: EventHotKeyID) -> OSStatus {
        guard hotKeyRef != nil, id.signature == Self.signature, id.id == registeredID else {
            return OSStatus(eventNotHandledErr)
        }
        handler?()
        return noErr
    }
}

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    var size = MemoryLayout<EventHotKeyID>.size
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil, size, &size, &hotKeyID)
    guard status == noErr else { return status }
    return Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handle(hotKeyID)
}

final class HotKeyManager: ObservableObject {
    @Published private(set) var registrationError: String?
    @Published private(set) var isRecording = false
    @Published private(set) var shortcut: GlobalShortcut?
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "HotKeyEnabled")
            if isRecording { cancelRecording() }
            else if activated { apply() }
        }
    }

    var onActivate: (() -> Void)?
    private let defaults: UserDefaults
    private let hotKey = GlobalHotKey()
    private var activated = false
    private var activationGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "HotKeyEnabled") == nil
            || defaults.bool(forKey: "HotKeyEnabled")
        if defaults.bool(forKey: "GlobalShortcutCleared") {
            shortcut = nil
        } else if let data = defaults.data(forKey: "GlobalShortcut"),
                  let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    func activate() {
        guard !activated else { return }
        hotKey.handler = { [weak self] in
            guard let self, !self.isRecording, self.enabled else { return }
            let generation = self.activationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRecording, self.enabled,
                      self.shortcut != nil, self.activationGeneration == generation else { return }
                self.onActivate?()
            }
        }
        activated = true
        apply()
    }

    func beginRecording() {
        guard !isRecording else { return }
        activationGeneration &+= 1
        isRecording = true
        registrationError = nil
        hotKey.unregister()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        apply()
    }

    func reportRecordingError(_ message: String) {
        registrationError = message
    }

    @discardableResult
    func finishRecording(with candidate: GlobalShortcut) -> Bool {
        guard isRecording else { return false }
        if let error = candidate.validationError {
            registrationError = error
            return false
        }
        if let conflict = ShortcutConflicts.message(for: candidate) {
            registrationError = conflict
            return false
        }
        let status = hotKey.register(keyCode: candidate.keyCode, modifiers: candidate.modifiers)
        guard status == noErr else {
            registrationError = registrationFailure(for: candidate, status: status)
            return false
        }
        saveShortcut(candidate)
        activationGeneration &+= 1
        isRecording = false
        registrationError = nil
        if !enabled || !activated { hotKey.unregister() }
        return true
    }

    func clearShortcut() {
        saveShortcut(nil)
        if isRecording { cancelRecording() }
        else { apply() }
    }

    func resetShortcut() {
        saveShortcut(.standard)
        if isRecording { cancelRecording() }
        else { apply() }
    }

    func retryRegistration() {
        guard !isRecording else { return }
        apply()
    }

    private func saveShortcut(_ shortcut: GlobalShortcut?) {
        self.shortcut = shortcut
        defaults.set(shortcut == nil, forKey: "GlobalShortcutCleared")
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: "GlobalShortcut")
        }
    }

    private func apply() {
        activationGeneration &+= 1
        registrationError = nil
        hotKey.unregister()
        guard activated, !isRecording, enabled, let shortcut else { return }
        if let error = shortcut.validationError {
            registrationError = error
            return
        }
        if let conflict = ShortcutConflicts.message(for: shortcut) {
            registrationError = conflict
            return
        }
        let status = hotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
        if status != noErr {
            registrationError = registrationFailure(for: shortcut, status: status)
        }
    }

    private func registrationFailure(for shortcut: GlobalShortcut, status: OSStatus) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "\(shortcut.localizedDisplayName) is already in use by another app. Record a different shortcut, or free it in the other app and retry."
        }
        return "Could not register \(shortcut.localizedDisplayName) (error \(status)). macOS or another app may be using it. Record a different shortcut or retry."
    }
}
