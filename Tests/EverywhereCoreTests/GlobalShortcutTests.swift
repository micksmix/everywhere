import XCTest
import Carbon.HIToolbox
@testable import EverywhereCore

final class GlobalShortcutTests: XCTestCase {
    func testDefaultRemainsOptionSpace() {
        XCTAssertEqual(GlobalShortcut.standard.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(GlobalShortcut.standard.modifiers, UInt32(optionKey))
        XCTAssertEqual(GlobalShortcut.standard.displayName, "⌥ Space")
        XCTAssertTrue(GlobalShortcut.standard.isValid)
    }

    func testLegacyJSONPreservesPhysicalKeyAndModifiers() throws {
        let data = Data("{\"keyCode\":49,\"modifiers\":2048}".utf8)
        let shortcut = try JSONDecoder().decode(GlobalShortcut.self, from: data)
        XCTAssertEqual(shortcut, .standard)
        let roundTrip = try JSONDecoder().decode(GlobalShortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(roundTrip, shortcut)
    }

    func testPunctuationSupportsAllModifierCombinations() {
        let keys = [kVK_ANSI_Semicolon, kVK_ANSI_Slash, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
                    kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Quote, kVK_ANSI_Backslash,
                    kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_Grave]
        for key in keys {
            let shortcut = GlobalShortcut(keyCode: UInt32(key), modifiers: GlobalShortcut.modifierMask)
            XCTAssertTrue(shortcut.isValid)
            XCTAssertEqual(GlobalShortcut.capture(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers), .shortcut(shortcut))
            XCTAssertTrue(shortcut.displayName.hasPrefix("⌃⌥⇧⌘ "))
        }
    }

    func testSpecialAndInternationalKeysAreValid() {
        let keys = [kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
                    kVK_DownArrow, kVK_UpArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
                    kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadEnter, kVK_ANSI_Keypad0, kVK_JIS_KeypadComma,
                    kVK_ISO_Section, kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_Eisu, kVK_JIS_Kana]
        for key in keys {
            let shortcut = GlobalShortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey))
            XCTAssertTrue(shortcut.isValid, shortcut.keyName)
            XCTAssertFalse(shortcut.keyName.hasPrefix("Key "))
        }
    }

    func testFunctionKeysCanBeRecordedWithoutModifiers() {
        let keys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                    kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                    kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, key) in keys.enumerated() {
            let shortcut = GlobalShortcut(keyCode: UInt32(key), modifiers: 0)
            XCTAssertTrue(shortcut.isValid)
            XCTAssertEqual(shortcut.displayName, "F\(index + 1)")
            XCTAssertEqual(GlobalShortcut.capture(keyCode: shortcut.keyCode, modifiers: 0), .shortcut(shortcut))
        }
    }

    func testTypingAndShiftOnlyRequirePrimaryModifier() {
        for key in [kVK_ANSI_A, kVK_ANSI_Semicolon, kVK_Space, kVK_Tab, kVK_LeftArrow] {
            for modifiers in [UInt32(0), UInt32(shiftKey)] {
                let shortcut = GlobalShortcut(keyCode: UInt32(key), modifiers: modifiers)
                XCTAssertFalse(shortcut.isValid)
                guard case .invalid = GlobalShortcut.capture(keyCode: shortcut.keyCode, modifiers: modifiers) else {
                    return XCTFail("Expected a validation error")
                }
            }
        }
    }

    func testUnknownKeysAndUnsupportedModifiersAreRejected() {
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32.max, modifiers: UInt32(optionKey)).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | alphaLock)).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(optionKey)).isValid)
    }

    func testEscapeCancelsWithOrWithoutModifiers() {
        XCTAssertEqual(GlobalShortcut.capture(keyCode: UInt32(kVK_Escape), modifiers: 0), .cancelled)
        XCTAssertEqual(GlobalShortcut.capture(keyCode: UInt32(kVK_Escape), modifiers: GlobalShortcut.modifierMask), .cancelled)
    }

    func testModifierOnlyAndRepeatedEventsAreIgnored() {
        for key in [kVK_Command, kVK_RightCommand, kVK_Control, kVK_RightControl, kVK_Shift,
                    kVK_RightShift, kVK_Option, kVK_RightOption, kVK_CapsLock, kVK_Function] {
            XCTAssertEqual(GlobalShortcut.capture(keyCode: UInt32(key), modifiers: GlobalShortcut.modifierMask), .ignored)
        }
        XCTAssertEqual(GlobalShortcut.capture(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey), isRepeat: true), .ignored)
    }

    func testDisplayDistinguishesKeypadAndUsesUnshiftedPunctuation() {
        XCTAssertEqual(GlobalShortcut(keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(cmdKey | shiftKey)).displayName, "⇧⌘ /")
        XCTAssertEqual(GlobalShortcut(keyCode: UInt32(kVK_ANSI_KeypadDivide), modifiers: UInt32(cmdKey)).displayName, "⌘ Keypad /")
        XCTAssertEqual(GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey)).displayName, "⌃ ←")
    }
}
