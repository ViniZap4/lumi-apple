import Foundation

/// The vim mode the engine is currently in. Visual modes carry the offset of
/// the selection's anchor — the position where visual mode was entered. The
/// "active end" of the selection is the buffer's regular cursor. Command-line
/// mode carries its prefix (`/`, `?`, or `:` later) and the in-progress
/// pattern buffer.
public enum VimMode: Sendable, Hashable {
    case normal
    case insert
    case visual(VisualKind, anchor: Int)
    case commandLine(prefix: Character, buffer: String)

    public enum VisualKind: Sendable, Hashable {
        case characterwise
        case linewise
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
}

/// Operators consume a motion (or are doubled with themselves like `dd`) to
/// produce a range edit.
public enum VimOperator: Sendable, Hashable {
    case delete
    case change
    case yank
}
