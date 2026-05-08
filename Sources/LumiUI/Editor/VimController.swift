import Foundation
import Observation
import LumiKit

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
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer
    }

    /// Cursor offset in UTF-16 code units, matching what UIKit/AppKit text
    /// views use for `NSRange.location`.
    public var cursorUTF16Offset: Int {
        utf16Offset(of: buffer.cursor)
    }

    /// Selection to render in the platform text view. Collapsed range when
    /// not in visual mode, the full visual selection otherwise.
    public var selectionUTF16Range: NSRange {
        guard case let .visual(kind, anchor) = state.mode else {
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
