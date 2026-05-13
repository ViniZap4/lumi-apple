import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Maps platform-specific key events into the engine's `VimInput` enum.
///
/// `mode` lets the mapper translate arrow keys differently depending on what
/// the engine is currently doing. Outside command-line mode, up/down arrows
/// stand in for `k`/`j` motions; inside command-line mode they step through
/// search/ex history. Left/right remain `h`/`l` everywhere (vim doesn't move
/// the cursor within the command-line buffer in our subset — typing or
/// backspacing is the only mutation).
enum VimKeyMapper {
    #if canImport(AppKit)
    static func map(event: NSEvent, mode: VimMode) -> VimInput? {
        let inCommandLine = mode.commandLinePrefix != nil
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .return
        case 51: return .backspace
        case 48: return .tab
        case 126: return inCommandLine ? .historyPrev : .character("k") // up arrow
        case 125: return inCommandLine ? .historyNext : .character("j") // down arrow
        case 123: return .character("h") // left arrow
        case 124: return .character("l") // right arrow
        default: break
        }
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "r": return .controlR
            case "d": return .controlD
            case "u": return .controlU
            default: break
            }
        }
        guard let chars = event.charactersIgnoringModifiers,
              let first = chars.first,
              !chars.isEmpty
        else { return nil }
        return .character(first)
    }
    #endif

    #if canImport(UIKit)
    static func map(key: UIKey, mode: VimMode) -> VimInput? {
        let inCommandLine = mode.commandLinePrefix != nil
        switch key.keyCode {
        case .keyboardEscape: return .escape
        case .keyboardReturnOrEnter, .keypadEnter: return .return
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardTab: return .tab
        case .keyboardUpArrow: return inCommandLine ? .historyPrev : .character("k")
        case .keyboardDownArrow: return inCommandLine ? .historyNext : .character("j")
        case .keyboardLeftArrow: return .character("h")
        case .keyboardRightArrow: return .character("l")
        default: break
        }
        if key.modifierFlags.contains(.control) {
            switch key.characters {
            case "r": return .controlR
            case "d": return .controlD
            case "u": return .controlU
            default: break
            }
        }
        guard let first = key.characters.first else { return nil }
        return .character(first)
    }
    #endif
}
