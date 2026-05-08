import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Maps platform-specific key events into the engine's `VimInput` enum.
enum VimKeyMapper {
    #if canImport(AppKit)
    static func map(event: NSEvent) -> VimInput? {
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .return
        case 51: return .backspace
        case 48: return .tab
        case 126: return .character("k") // up arrow → motion
        case 125: return .character("j") // down arrow
        case 123: return .character("h") // left arrow
        case 124: return .character("l") // right arrow
        default: break
        }
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           chars == "r" {
            return .controlR
        }
        guard let chars = event.charactersIgnoringModifiers,
              let first = chars.first,
              !chars.isEmpty
        else { return nil }
        return .character(first)
    }
    #endif

    #if canImport(UIKit)
    static func map(key: UIKey) -> VimInput? {
        switch key.keyCode {
        case .keyboardEscape: return .escape
        case .keyboardReturnOrEnter, .keypadEnter: return .return
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardTab: return .tab
        case .keyboardUpArrow: return .character("k")
        case .keyboardDownArrow: return .character("j")
        case .keyboardLeftArrow: return .character("h")
        case .keyboardRightArrow: return .character("l")
        default: break
        }
        if key.modifierFlags.contains(.control), key.characters == "r" {
            return .controlR
        }
        guard let first = key.characters.first else { return nil }
        return .character(first)
    }
    #endif
}
