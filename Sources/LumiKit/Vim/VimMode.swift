import Foundation

/// The vim mode the engine is currently in. Visual modes carry the offset of
/// the selection's anchor — the position where visual mode was entered. The
/// "active end" of the selection is the buffer's regular cursor.
public enum VimMode: Sendable, Hashable {
    case normal
    case insert
    case visual(VisualKind, anchor: Int)

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
}

/// Operators consume a motion (or are doubled with themselves like `dd`) to
/// produce a range edit.
public enum VimOperator: Sendable, Hashable {
    case delete
    case change
    case yank
}
