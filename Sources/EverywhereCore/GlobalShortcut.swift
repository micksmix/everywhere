import Foundation
import Carbon.HIToolbox

public struct GlobalShortcut: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let standard = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    public static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    public var validationError: String? {
        guard Self.keyNames[keyCode] != nil else {
            return "This key cannot be used as a global shortcut. Choose another key."
        }
        guard modifiers & ~Self.modifierMask == 0 else {
            return "Use Control, Option, Shift, and Command as shortcut modifiers."
        }
        guard isFunctionKey || modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "Include Control, Option, or Command, or choose a function key."
        }
        return nil
    }

    public var isValid: Bool { validationError == nil }
    public var isFunctionKey: Bool { Self.functionKeyCodes.contains(keyCode) }
    public var usesKeyboardLayout: Bool { Self.layoutKeyCodes.contains(keyCode) }
    public var keyName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }
    public var displayName: String { displayName(keyName: keyName) }

    public func displayName(keyName: String) -> String {
        let symbols = Self.modifierSymbols(for: modifiers)
        return symbols.isEmpty ? keyName : symbols + " " + keyName
    }

    public static func modifierSymbols(for modifiers: UInt32) -> String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
         (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }

    public static func capture(keyCode: UInt32, modifiers: UInt32, isRepeat: Bool = false) -> ShortcutCaptureResult {
        guard !isRepeat else { return .ignored }
        if keyCode == UInt32(kVK_Escape) { return .cancelled }
        if modifierKeyCodes.contains(keyCode) { return .ignored }
        let shortcut = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
        if let error = shortcut.validationError { return .invalid(error) }
        return .shortcut(shortcut)
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_CapsLock,
        kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl, kVK_Function
    ].mapSet()

    private static let functionKeyCodes: Set<UInt32> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
        kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
        kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].mapSet()

    private static let layoutKeys: [(Int, String)] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
        (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
        (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
        (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"),
        (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"),
        (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-"), (kVK_ANSI_LeftBracket, "["),
        (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Semicolon, ";"),
        (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Slash, "/"),
        (kVK_ANSI_Period, "."), (kVK_ANSI_Grave, "`"), (kVK_ISO_Section, "§"),
        (kVK_JIS_Yen, "¥"), (kVK_JIS_Underscore, "_")
    ]

    private static let layoutKeyCodes = Set(layoutKeys.map { UInt32($0.0) })

    private static let keyNames: [UInt32: String] = {
        let specialKeys: [(Int, String)] = [
            (kVK_Space, "Space"), (kVK_Return, "Return"), (kVK_Tab, "Tab"),
            (kVK_Delete, "Delete"), (kVK_ForwardDelete, "Forward Delete"), (kVK_Escape, "Escape"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_DownArrow, "↓"), (kVK_UpArrow, "↑"),
            (kVK_Home, "Home"), (kVK_End, "End"), (kVK_PageUp, "Page Up"), (kVK_PageDown, "Page Down"),
            (kVK_Help, "Help"), (kVK_ContextualMenu, "Menu"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
            (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
            (kVK_ANSI_Keypad0, "Keypad 0"), (kVK_ANSI_Keypad1, "Keypad 1"),
            (kVK_ANSI_Keypad2, "Keypad 2"), (kVK_ANSI_Keypad3, "Keypad 3"),
            (kVK_ANSI_Keypad4, "Keypad 4"), (kVK_ANSI_Keypad5, "Keypad 5"),
            (kVK_ANSI_Keypad6, "Keypad 6"), (kVK_ANSI_Keypad7, "Keypad 7"),
            (kVK_ANSI_Keypad8, "Keypad 8"), (kVK_ANSI_Keypad9, "Keypad 9"),
            (kVK_ANSI_KeypadDecimal, "Keypad ."), (kVK_ANSI_KeypadMultiply, "Keypad *"),
            (kVK_ANSI_KeypadPlus, "Keypad +"), (kVK_ANSI_KeypadClear, "Keypad Clear"),
            (kVK_ANSI_KeypadDivide, "Keypad /"), (kVK_ANSI_KeypadEnter, "Keypad Enter"),
            (kVK_ANSI_KeypadMinus, "Keypad -"), (kVK_ANSI_KeypadEquals, "Keypad ="),
            (kVK_JIS_KeypadComma, "Keypad ,"), (kVK_JIS_Eisu, "Eisu"), (kVK_JIS_Kana, "Kana")
        ]
        return Dictionary(uniqueKeysWithValues: (layoutKeys + specialKeys).map { (UInt32($0.0), $0.1) })
    }()
}

public enum ShortcutCaptureResult: Equatable {
    case ignored
    case cancelled
    case invalid(String)
    case shortcut(GlobalShortcut)
}

private extension Array where Element == Int {
    func mapSet() -> Set<UInt32> { Set(map(UInt32.init)) }
}
