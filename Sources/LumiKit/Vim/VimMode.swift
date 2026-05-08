import Foundation

/// The vim mode the engine is currently in. Visual modes are reserved for a
/// follow-up phase but listed here so the public API doesn't need to break
/// when they land.
public enum VimMode: Sendable, Hashable {
    case normal
    case insert
    case visual(VisualKind)

    public enum VisualKind: Sendable, Hashable {
        case characterwise
        case linewise
    }
}

/// Operators consume a motion (or are doubled with themselves like `dd`) to
/// produce a range edit.
public enum VimOperator: Sendable, Hashable {
    case delete
    case change
    case yank
}
