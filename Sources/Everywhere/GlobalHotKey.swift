import Foundation
import Combine
import Carbon.HIToolbox

final class GlobalHotKey {
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static let signature = OSType(0x4556_5752)

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &eventType,
                                             Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
            guard status == noErr else { return status }
        }
        guard hotKeyRef == nil else { return noErr }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    deinit {
        unregister()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    fileprivate func handle(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
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

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let standard = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let keys: [(name: String, code: UInt32)] = [
        ("Space", UInt32(kVK_Space)),
        ("A", UInt32(kVK_ANSI_A)),
        ("B", UInt32(kVK_ANSI_B)),
        ("C", UInt32(kVK_ANSI_C)),
        ("D", UInt32(kVK_ANSI_D)),
        ("E", UInt32(kVK_ANSI_E)),
        ("F", UInt32(kVK_ANSI_F)),
        ("G", UInt32(kVK_ANSI_G)),
        ("H", UInt32(kVK_ANSI_H)),
        ("I", UInt32(kVK_ANSI_I)),
        ("J", UInt32(kVK_ANSI_J)),
        ("K", UInt32(kVK_ANSI_K)),
        ("L", UInt32(kVK_ANSI_L)),
        ("M", UInt32(kVK_ANSI_M)),
        ("N", UInt32(kVK_ANSI_N)),
        ("O", UInt32(kVK_ANSI_O)),
        ("P", UInt32(kVK_ANSI_P)),
        ("Q", UInt32(kVK_ANSI_Q)),
        ("R", UInt32(kVK_ANSI_R)),
        ("S", UInt32(kVK_ANSI_S)),
        ("T", UInt32(kVK_ANSI_T)),
        ("U", UInt32(kVK_ANSI_U)),
        ("V", UInt32(kVK_ANSI_V)),
        ("W", UInt32(kVK_ANSI_W)),
        ("X", UInt32(kVK_ANSI_X)),
        ("Y", UInt32(kVK_ANSI_Y)),
        ("Z", UInt32(kVK_ANSI_Z)),
        ("0", UInt32(kVK_ANSI_0)),
        ("1", UInt32(kVK_ANSI_1)),
        ("2", UInt32(kVK_ANSI_2)),
        ("3", UInt32(kVK_ANSI_3)),
        ("4", UInt32(kVK_ANSI_4)),
        ("5", UInt32(kVK_ANSI_5)),
        ("6", UInt32(kVK_ANSI_6)),
        ("7", UInt32(kVK_ANSI_7)),
        ("8", UInt32(kVK_ANSI_8)),
        ("9", UInt32(kVK_ANSI_9)),
    ]
    static let modifierOptions: [(name: String, flag: UInt32)] = [
        ("⌃ Control", UInt32(controlKey)), ("⌥ Option", UInt32(optionKey)),
        ("⇧ Shift", UInt32(shiftKey)), ("⌘ Command", UInt32(cmdKey))
    ]

    var isValid: Bool {
        Self.keys.contains { $0.code == keyCode }
            && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
            && modifiers & ~UInt32(controlKey | optionKey | cmdKey | shiftKey) == 0
    }

    var displayName: String {
        let symbols = Self.modifierOptions.filter { modifiers & $0.flag != 0 }
            .map { String($0.name.prefix(1)) }.joined()
        return symbols + " " + (Self.keys.first { $0.code == keyCode }?.name ?? "Unknown")
    }
}

final class HotKeyManager: ObservableObject {
    @Published private(set) var registrationError: String?
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "HotKeyEnabled")
            if activated { apply() }
        }
    }

    @Published var shortcut: GlobalShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: "GlobalShortcut")
            }
            if activated { apply() }
        }
    }

    var onActivate: (() -> Void)?
    private let defaults: UserDefaults
    private let hotKey = GlobalHotKey()
    private var activated = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "HotKeyEnabled") == nil
            || defaults.bool(forKey: "HotKeyEnabled")
        if let data = defaults.data(forKey: "GlobalShortcut"),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    func activate() {
        hotKey.handler = { [weak self] in
            DispatchQueue.main.async { self?.onActivate?() }
        }
        activated = true
        apply()
    }

    private func apply() {
        registrationError = nil
        hotKey.unregister()
        if enabled {
            guard shortcut.isValid else {
                registrationError = "Choose a key with at least Control, Option, or Command."
                return
            }
            let status = hotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
            if status != noErr {
                registrationError = "Could not register \(shortcut.displayName) (error \(status)). Another app may be using it. Choose another shortcut, or switch this option off and on to retry."
            }
        } else {
            hotKey.unregister()
        }
    }
}
