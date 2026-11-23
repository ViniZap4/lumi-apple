import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit

/// One NSEvent monitor for every shell key (explorer + reader).
///
/// Installed at App init, before SwiftUI builds its own monitors (List
/// typeahead etc.), so it sees keys first and the sidebar never beeps on
/// `j`. It only acts on the main window when no text input owns the
/// keyboard: an editable `NSText` first responder (the vim editor, the
/// palette / prompt fields, sign-in forms) and every sheet or popover get
/// their keys untouched. What a key does is decided by `ShellKeymap` via
/// `AppState.handleShellKey`.
@MainActor
final class KeyRouter {
    private weak var appState: AppState?
    nonisolated(unsafe) private var token: Any?

    init(appState: AppState) {
        self.appState = appState
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let appState else { return event }
        guard let window = event.window, window.isKeyWindow, window.sheetParent == nil,
              window.attachedSheet == nil, !(window is NSPanel),
              window.className.contains("Popover") == false
        else { return event }
        if let text = window.firstResponder as? NSText, text.isEditable { return event }

        // ⌘C in the reader also flashes the yank highlight; the copy
        // itself still runs through the responder chain.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "c", appState.surface == .reader {
                appState.yankFlashAt = Date()
            }
            return event
        }

        guard let stroke = KeyStroke(event: event) else { return event }
        return appState.handleShellKey(stroke) ? nil : event
    }
}

extension KeyStroke {
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = mods.contains(.control)
        let command = mods.contains(.command)
        let option = mods.contains(.option)
        let special: Special?
        switch event.keyCode {
        case 125: special = .down
        case 126: special = .up
        case 123: special = .left
        case 124: special = .right
        case 36, 76: special = .enter
        case 53: special = .escape
        case 51: special = .backspace
        case 48: special = .tab
        case 116: special = .pageUp
        case 121: special = .pageDown
        case 115: special = .home
        case 119: special = .end
        default: special = nil
        }
        if let special {
            self.init(nil, special: special, control: control, command: command, option: option)
            return
        }
        var chars: String?
        if control {
            // ⌃letter: charactersIgnoringModifiers can be empty or a
            // control code depending on the layout; map 0x01…0x1A back.
            if let s = event.charactersIgnoringModifiers?.lowercased(), s.count == 1, s.unicodeScalars.first.map({ $0.value >= 0x20 }) == true {
                chars = s
            } else if let v = event.characters?.unicodeScalars.first?.value, v >= 0x01, v <= 0x1A,
                      let scalar = Unicode.Scalar(v + 0x60) {
                chars = String(scalar)
            }
        } else {
            chars = event.characters
        }
        guard let chars, !chars.isEmpty else { return nil }
        self.init(chars, control: control, command: command, option: option)
    }
}
#endif

extension KeyStroke {
    /// SwiftUI hardware-keyboard press (iOS / iPadOS / visionOS).
    init?(press: KeyPress) {
        let special: Special?
        switch press.key {
        case .downArrow: special = .down
        case .upArrow: special = .up
        case .leftArrow: special = .left
        case .rightArrow: special = .right
        case .return: special = .enter
        case .escape: special = .escape
        case .delete: special = .backspace
        case .tab: special = .tab
        case .pageUp: special = .pageUp
        case .pageDown: special = .pageDown
        case .home: special = .home
        case .end: special = .end
        default: special = nil
        }
        let control = press.modifiers.contains(.control)
        let command = press.modifiers.contains(.command)
        let option = press.modifiers.contains(.option)
        if let special {
            self.init(nil, special: special, control: control, command: command, option: option)
            return
        }
        guard !press.characters.isEmpty else { return nil }
        self.init(control ? press.characters.lowercased() : press.characters, control: control, command: command, option: option)
    }
}
