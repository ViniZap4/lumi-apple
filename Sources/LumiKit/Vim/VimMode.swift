import Foundation

/// The vim mode the engine is currently in. Visual modes carry the offset of
/// the selection's anchor — the position where visual mode was entered. The
/// "active end" (head) of the selection is the buffer's regular cursor.
/// Command-line mode carries its prefix (`/`, `?`, `:`) and the in-progress
/// text. Operator-pending is not a separate case: it is normal mode with an
/// operator in `VimState.pendingKeys` (see `VimEngine.pendingInfo`).
public enum VimMode: Sendable, Hashable {
    case normal
    case insert
    /// `R`: typed characters overwrite the text under the cursor.
    case replace
    case visual(VisualKind, anchor: Int)
    case commandLine(prefix: Character, buffer: String)

    public enum VisualKind: Sendable, Hashable {
        case characterwise
        case linewise
        /// `Ctrl-v`: a rectangle of columns.
        case block
    }

    public var visualKind: VisualKind? {
        if case let .visual(kind, _) = self { return kind }
        return nil
    }

    public var visualAnchor: Int? {
        if case let .visual(_, anchor) = self { return anchor }
        return nil
    }

    public var commandLinePrefix: Character? {
        if case let .commandLine(prefix, _) = self { return prefix }
        return nil
    }

    public var commandLineBuffer: String? {
        if case let .commandLine(_, buffer) = self { return buffer }
        return nil
    }

    /// Insert or replace: modes where printable keys type text.
    public var isTyping: Bool { self == .insert || self == .replace }

    public var isVisual: Bool { visualKind != nil }
}

/// Operators consume a motion / text object (or are doubled like `dd`) to
/// produce a range edit.
public enum VimOperator: Sendable, Hashable {
    case delete       // d
    case change       // c
    case yank         // y
    case shiftRight   // >
    case shiftLeft    // <
    case reindent     // =  (no-op re-indent: markdown has no indent rules)
    case swapCase     // g~
    case lowercase    // gu
    case uppercase    // gU
    case rot13        // g?

    /// Keys that type this operator (`d`, `g~`).
    public var keys: String {
        switch self {
        case .delete: return "d"
        case .change: return "c"
        case .yank: return "y"
        case .shiftRight: return ">"
        case .shiftLeft: return "<"
        case .reindent: return "="
        case .swapCase: return "g~"
        case .lowercase: return "gu"
        case .uppercase: return "gU"
        case .rot13: return "g?"
        }
    }

    /// True when the operator changes the text (dot-repeatable).
    public var modifiesText: Bool { self != .yank }
}
