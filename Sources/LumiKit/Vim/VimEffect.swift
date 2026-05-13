import Foundation

/// A side-effect requested by the vim engine that must be carried out by the
/// host application — typically issued by ex commands like `:w`, `:wq`, `:q`.
///
/// The engine is otherwise pure: it can't open files, write to disk, or close
/// windows. When an ex command resolves, the engine sets `VimEngine.Result.effect`
/// and the host's `VimController.onEffect` callback fires.
public enum VimEffect: Sendable, Hashable {
    /// `:w` — save current buffer to disk.
    case save
    /// `:wq` — save then close.
    case saveAndClose
    /// `:q` — close without saving (host may choose to refuse if dirty).
    case close
}
