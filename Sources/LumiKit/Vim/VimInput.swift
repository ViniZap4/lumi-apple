import Foundation

/// One discrete input event into the vim engine. Higher-level inputs (key
/// chords, modifier-only events) are decomposed into a stream of these by the
/// UI bridge.
public enum VimInput: Sendable, Hashable {
    /// A printable character. The engine routes it through the active mode.
    case character(Character)

    /// Escape key — exits insert/visual mode, cancels pending operator/count.
    case escape

    /// Return / Enter key — newline in insert mode, line down in normal.
    case `return`

    /// Backspace / Delete — character delete in insert, motion in normal.
    case backspace

    /// Tab — inserts a tab in insert mode (or several spaces, depending on
    /// future settings); ignored in normal for now.
    case tab

    /// Ctrl-R — redo in normal mode.
    case controlR

    /// Ctrl-D — half-page down (vim's scroll-cursor-down). Engine treats
    /// it as a multi-line down motion (no concept of viewport).
    case controlD

    /// Ctrl-U — half-page up.
    case controlU

    /// Up arrow while in command-line mode — recall older history entry.
    /// Outside command-line, the UI bridge translates up/down arrows into
    /// `h`/`j`/`k`/`l` motions before reaching the engine, so these cases
    /// are only produced while typing a `/`, `?`, or `:` pattern.
    case historyPrev

    /// Down arrow while in command-line mode — step toward newer entries
    /// (eventually restoring the user's typed draft).
    case historyNext
}
