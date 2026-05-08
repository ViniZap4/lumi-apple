import Foundation

/// Engine-side state that lives across input events. The text buffer is owned
/// by the caller (UI bridge) and threaded through `VimEngine.handle`, which
/// keeps the engine pure and testable.
public struct VimState: Sendable, Hashable {
    public var mode: VimMode
    public var pendingCount: Int?
    public var pendingOperator: PendingOperator?
    /// After `i` or `a` in operator-pending or visual mode: which kind of text
    /// object the user is about to specify. Cleared once the object selector
    /// (`w`, `"`, `(`, …) arrives.
    public var pendingTextObjectKind: TextObjectKind?
    /// After `f F t T` (in any mode): which find variant we're awaiting a
    /// target character for.
    public var pendingFindKind: FindKind?
    /// Default ("unnamed") register — receives the most recent yank/delete.
    public var defaultRegister: Register
    public var history: VimHistory

    public init(
        mode: VimMode = .normal,
        pendingCount: Int? = nil,
        pendingOperator: PendingOperator? = nil,
        pendingTextObjectKind: TextObjectKind? = nil,
        pendingFindKind: FindKind? = nil,
        defaultRegister: Register = Register(),
        history: VimHistory = VimHistory()
    ) {
        self.mode = mode
        self.pendingCount = pendingCount
        self.pendingOperator = pendingOperator
        self.pendingTextObjectKind = pendingTextObjectKind
        self.pendingFindKind = pendingFindKind
        self.defaultRegister = defaultRegister
        self.history = history
    }

    public static let initial = VimState()

    /// Effective count for the next motion/operator: `pendingCount ?? 1`.
    public var effectiveCount: Int { pendingCount ?? 1 }
}

/// An operator captured while waiting for its motion (or its repeat key like
/// `dd`).
public struct PendingOperator: Sendable, Hashable {
    public let op: VimOperator
    public let count: Int

    public init(op: VimOperator, count: Int = 1) {
        self.op = op
        self.count = count
    }
}

/// A vim register holds yanked / deleted text plus a hint about its kind.
public struct Register: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case characterwise
        case linewise
    }

    public var text: String
    public var kind: Kind

    public init(text: String = "", kind: Kind = .characterwise) {
        self.text = text
        self.kind = kind
    }
}
