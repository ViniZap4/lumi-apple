import Foundation

/// A side-effect requested by the vim engine that must be carried out by the
/// host application — ex commands like `:w`, `:wq`, `:q`, and view-only
/// requests (scrolling, display-line motion) the pure engine can't perform.
///
/// The save/close cases carry a `force` flag (the vim `!` modifier). The
/// host translates that into the relevant escape hatch: `force == true` save
/// bypasses the disk-conflict check; `force == true` close discards unsaved
/// changes; `force == false` close should refuse when dirty.
public enum VimEffect: Sendable, Hashable {
    /// `:w` / `:w!` — save current buffer to disk.
    case save(force: Bool)
    /// `:wq` / `:wq!` / `:x` / `ZZ` — save then close.
    case saveAndClose(force: Bool)
    /// `:q` / `:q!` / `ZQ` — close without saving.
    case close(force: Bool)
    /// `zz` / `zt` / `zb`: scroll so the cursor line sits at that spot.
    case scrollCursor(VimScrollPosition)
    /// `Ctrl-e` / `Ctrl-y` / half- and full-page keys: scroll the view by
    /// this many lines (negative = up) without the engine knowing the
    /// viewport geometry.
    case scrollLines(Int)
    /// `gj` / `gk`: move by display (wrapped) lines. The engine has already
    /// moved by logical lines; the host recomputes the target from `from`
    /// (character offset) using its layout and overrides the cursor.
    case displayLines(from: Int, count: Int)
}

public enum VimScrollPosition: Sendable, Hashable {
    case center, top, bottom
}

/// A message shown in the command-line area (`E486: Pattern not found`,
/// `3 substitutions on 3 lines`, the `:registers` listing).
public struct VimMessage: Sendable, Hashable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    /// More than one line: shown as a panel until the next key.
    public var isMultiline: Bool { text.contains("\n") }
}
