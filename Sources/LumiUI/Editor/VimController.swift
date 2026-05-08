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
        let chars = buffer.text.prefix(buffer.cursor)
        return chars.utf16.count
    }

    /// Human-readable mode label for status lines (`NORMAL`, `INSERT`, …).
    public var modeLabel: String {
        switch state.mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case let .visual(kind):
            switch kind {
            case .characterwise: return "VISUAL"
            case .linewise: return "V-LINE"
            }
        }
    }
}
