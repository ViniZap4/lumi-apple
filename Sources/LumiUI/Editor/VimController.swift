import Foundation
import Observation
import LumiKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Thin observable wrapper that owns a `TextBuffer` + `VimState` and dispatches
/// input events through the pure `VimEngine` reducer. The UI bridge holds one
/// of these per editor instance.
@Observable
@MainActor
public final class VimController {
    public var buffer: TextBuffer
    public var state: VimState

    public init(initialText: String = "") {
        self.buffer = TextBuffer(text: initialText, cursor: 0)
        self.state = .initial
    }

    /// Replace the buffer text wholesale (e.g. when the user switches notes).
    /// Resets the engine state to normal mode and clears history.
    public func replace(text: String) {
        let cursor = min(buffer.cursor, text.count)
        buffer = TextBuffer(text: text, cursor: cursor)
        state = .initial
    }

    public func send(_ input: VimInput) {
        let previousRegister = state.defaultRegister
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer

        // Mirror yank/delete output to the system pasteboard so vim's `y` and
        // `d` interoperate with Cmd+V outside the editor.
        if state.defaultRegister != previousRegister, !state.defaultRegister.text.isEmpty {
            writeToSystemPasteboard(state.defaultRegister.text)
        }
    }

    private func writeToSystemPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// Cursor offset in UTF-16 code units, matching what UIKit/AppKit text
    /// views use for `NSRange.location`.
    public var cursorUTF16Offset: Int {
        utf16Offset(of: buffer.cursor)
    }

    /// Selection to render in the platform text view. Drives both the visual
    /// highlight (in visual mode) and a single-character "block cursor" in
    /// normal mode — UIKit/AppKit render the 1-char selection as a tinted
    /// rectangle, which is exactly the vim block-cursor look without needing
    /// custom drawing.
    public var selectionUTF16Range: NSRange {
        guard case let .visual(kind, anchor) = state.mode else {
            // Normal mode: 1-char "block" if cursor is on a character.
            // Insert mode (or empty buffer / past-end): collapsed caret.
            if state.mode == .normal,
               buffer.cursor < buffer.text.count,
               !buffer.text.isEmpty
            {
                let cursorChar = buffer.text[buffer.cursorIndex]
                if cursorChar != "\n" {
                    let from = cursorUTF16Offset
                    let to = utf16Offset(of: buffer.cursor + 1)
                    return NSRange(location: from, length: to - from)
                }
            }
            return NSRange(location: cursorUTF16Offset, length: 0)
        }
        let cursor = buffer.cursor
        switch kind {
        case .characterwise:
            let from = min(anchor, cursor)
            let to = min(buffer.text.count, max(anchor, cursor) + 1)
            let utf16From = utf16Offset(of: from)
            let utf16To = utf16Offset(of: to)
            return NSRange(location: utf16From, length: utf16To - utf16From)
        case .linewise:
            let anchorLine = lineForOffset(anchor)
            let cursorLine = lineForOffset(cursor)
            let firstLine = min(anchorLine, cursorLine)
            let lastLine = max(anchorLine, cursorLine)
            let from = buffer.lineStart(of: firstLine)
            var to = buffer.lineEnd(of: lastLine)
            if to < buffer.text.count { to += 1 }
            let utf16From = utf16Offset(of: from)
            let utf16To = utf16Offset(of: to)
            return NSRange(location: utf16From, length: utf16To - utf16From)
        }
    }

    private func utf16Offset(of charOffset: Int) -> Int {
        let safe = max(0, min(charOffset, buffer.text.count))
        return buffer.text.prefix(safe).utf16.count
    }

    private func lineForOffset(_ offset: Int) -> Int {
        var b = buffer
        b.cursor = max(0, min(offset, b.text.count))
        return b.cursorLine
    }

    /// Human-readable mode label for status lines (`NORMAL`, `INSERT`, …).
    public var modeLabel: String {
        switch state.mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case let .visual(kind, _):
            switch kind {
            case .characterwise: return "VISUAL"
            case .linewise: return "V-LINE"
            }
        }
    }
}
