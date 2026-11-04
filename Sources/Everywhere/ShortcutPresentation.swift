import AppKit
import Carbon.HIToolbox
import EverywhereCore

extension GlobalShortcut {
    var localizedDisplayName: String {
        displayName(keyName: usesKeyboardLayout ? ShortcutKeyLabels.character(for: keyCode)?.uppercased() ?? keyName : keyName)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    var acceptsFunctionFlag: Bool {
        isFunctionKey || [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                          kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
                          kVK_Help].contains(Int(keyCode))
    }

    fileprivate var menuKeyEquivalents: [String] {
        switch keyCode {
        case UInt32(kVK_Space): return [" "]
        case UInt32(kVK_Return): return ["\r"]
        case UInt32(kVK_ANSI_KeypadEnter): return ["\u{3}"]
        case UInt32(kVK_Tab): return ["\t", "\u{19}"]
        case UInt32(kVK_Delete): return ["\u{8}", "\u{7f}"]
        case UInt32(kVK_Escape): return ["\u{1b}"]
        case UInt32(kVK_ForwardDelete): return [Self.functionCharacter(NSDeleteFunctionKey)]
        case UInt32(kVK_LeftArrow): return [Self.functionCharacter(NSLeftArrowFunctionKey)]
        case UInt32(kVK_RightArrow): return [Self.functionCharacter(NSRightArrowFunctionKey)]
        case UInt32(kVK_UpArrow): return [Self.functionCharacter(NSUpArrowFunctionKey)]
        case UInt32(kVK_DownArrow): return [Self.functionCharacter(NSDownArrowFunctionKey)]
        case UInt32(kVK_Home): return [Self.functionCharacter(NSHomeFunctionKey)]
        case UInt32(kVK_End): return [Self.functionCharacter(NSEndFunctionKey)]
        case UInt32(kVK_PageUp): return [Self.functionCharacter(NSPageUpFunctionKey)]
        case UInt32(kVK_PageDown): return [Self.functionCharacter(NSPageDownFunctionKey)]
        case UInt32(kVK_Help): return [Self.functionCharacter(NSHelpFunctionKey)]
        default:
            if isFunctionKey, let number = Int(keyName.dropFirst()) {
                return [Self.functionCharacter(NSF1FunctionKey + number - 1)]
            }
            guard usesKeyboardLayout, let character = ShortcutKeyLabels.character(for: keyCode) else { return [] }
            return [character]
        }
    }

    private static func functionCharacter(_ value: Int) -> String {
        UnicodeScalar(value).map(String.init) ?? ""
    }
}

private enum ShortcutKeyLabels {
    static func character(for keyCode: UInt32, shifted: Bool = false) -> String? {
        guard keyCode <= UInt16.max else { return nil }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay),
                                    shifted ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                    characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? nil : text
    }
}

enum ShortcutConflicts {
    static func message(for shortcut: GlobalShortcut) -> String? {
        if isSystemShortcut(shortcut) {
            return "\(shortcut.localizedDisplayName) is enabled in macOS Keyboard Shortcuts. Choose another shortcut, or change it in System Settings → Keyboard → Keyboard Shortcuts."
        }
        if let menu = NSApp?.mainMenu, let title = conflictingMenuItem(in: menu, shortcut: shortcut) {
            return "\(shortcut.localizedDisplayName) is used by “\(title)” in Everywhere. Record a different shortcut."
        }
        return nil
    }

    private static func isSystemShortcut(_ shortcut: GlobalShortcut) -> Bool {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr,
              let shortcuts = values?.takeRetainedValue() as? [[String: Any]] else { return false }
        return shortcuts.contains { value in
            (value[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true
                && (value[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode
                && (value[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == shortcut.modifiers
        }
    }

    private static func conflictingMenuItem(in menu: NSMenu, shortcut: GlobalShortcut) -> String? {
        for item in menu.items {
            if let submenu = item.submenu, let title = conflictingMenuItem(in: submenu, shortcut: shortcut) {
                return title
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            var itemModifiers = GlobalShortcut.carbonModifiers(from: item.keyEquivalentModifierMask)
            let equivalent = item.keyEquivalent.lowercased()
            if item.keyEquivalent != equivalent { itemModifiers |= UInt32(shiftKey) }
            let baseMatches = shortcut.menuKeyEquivalents.contains { $0.lowercased() == equivalent }
            let shiftedMatches = shortcut.usesKeyboardLayout
                && ShortcutKeyLabels.character(for: shortcut.keyCode, shifted: true)?.lowercased() == equivalent
            if itemModifiers == shortcut.modifiers,
               baseMatches || shortcut.modifiers & UInt32(shiftKey) != 0 && shiftedMatches {
                return item.title
            }
            if shortcut.modifiers & UInt32(shiftKey) != 0,
               itemModifiers == shortcut.modifiers & ~UInt32(shiftKey), shiftedMatches, !baseMatches {
                return item.title
            }
        }
        return nil
    }
}
