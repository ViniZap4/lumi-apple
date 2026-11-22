import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Maps platform key input into `VimInput`.
///
/// Printable text is **not** mapped here any more: it travels through the
/// platform text-input system (`interpretKeyEvents` → `insertText` /
/// `setMarkedText` on macOS, `UITextInput` on iOS), so dead keys (ABNT2
/// `´` + `a` → `á`), IMEs and the press-and-hold accent menu work. This
/// type only handles keys the input system would otherwise consume —
/// Escape, Ctrl chords, arrows — and the command selectors the input
/// system emits (`insertNewline:`, `deleteBackward:`, `moveUp:` …).
enum VimKeyMapper {
    /// Input for an AppKit/UIKit text-input command selector, or nil to
    /// swallow it silently (no beep, no native editing behind the
    /// engine's back).
    static func input(forCommand selector: String) -> VimInput? {
        switch selector {
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": return .return
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": return .backspace
        case "insertTab:", "insertTabIgnoringFieldEditor:": return .tab
        case "cancelOperation:": return .escape
        case "moveLeft:": return .arrow(.left)
        case "moveRight:": return .arrow(.right)
        case "moveUp:": return .arrow(.up)
        case "moveDown:": return .arrow(.down)
        default: return nil
        }
    }

    /// Ctrl chords the engine understands, by their base character.
    static func controlInput(for base: String) -> VimInput? {
        switch base.lowercased() {
        case "r": return .controlR
        case "d": return .controlD
        case "u": return .controlU
        case "[": return .escape
        default: return nil
        }
    }

    #if canImport(AppKit)
    /// Keys handled before the input system sees the event.
    static func directInput(for event: NSEvent) -> VimInput? {
        switch event.keyCode {
        case 53: return .escape
        case 123: return .arrow(.left)
        case 124: return .arrow(.right)
        case 125: return .arrow(.down)
        case 126: return .arrow(.up)
        default: break
        }
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers {
            return controlInput(for: chars)
        }
        return nil
    }
    #endif

    #if canImport(UIKit)
    /// Hardware keys handled before UIKit's text input (`pressesBegan`).
    @MainActor
    static func directInput(for key: UIKey) -> VimInput? {
        switch key.keyCode {
        case .keyboardEscape: return .escape
        case .keyboardUpArrow: return .arrow(.up)
        case .keyboardDownArrow: return .arrow(.down)
        case .keyboardLeftArrow: return .arrow(.left)
        case .keyboardRightArrow: return .arrow(.right)
        default: break
        }
        if key.modifierFlags.contains(.control) {
            return controlInput(for: key.charactersIgnoringModifiers)
        }
        return nil
    }
    #endif
}
