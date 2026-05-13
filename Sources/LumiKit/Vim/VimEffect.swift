import Foundation

/// A side-effect requested by the vim engine that must be carried out by the
/// host application — typically issued by ex commands like `:w`, `:wq`, `:q`.
///
/// Each case carries a `force` flag (the vim `!` modifier). The host
/// translates that into the relevant escape hatch: `force == true` save
/// bypasses the disk-conflict check; `force == true` close discards unsaved
/// changes; `force == false` close should refuse when dirty.
///
/// The engine is otherwise pure: it can't open files, write to disk, or close
/// windows. When an ex command resolves, the engine sets `VimEngine.Result.effect`
/// and the host's `VimController.onEffect` callback fires.
public enum VimEffect: Sendable, Hashable {
    /// `:w` / `:w!` — save current buffer to disk.
    case save(force: Bool)
    /// `:wq` / `:wq!` / `:x` — save then close.
    case saveAndClose(force: Bool)
    /// `:q` / `:q!` — close without saving. `force: true` discards dirty
    /// edits; `force: false` should be refused by the host when dirty.
    case close(force: Bool)
}
