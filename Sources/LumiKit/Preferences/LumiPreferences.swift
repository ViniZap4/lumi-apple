import Foundation
import Observation

/// User-tunable behavior preferences. Persisted to UserDefaults so they
/// survive launches without us needing per-feature wiring. UI binds to the
/// shared instance via `@Environment(\.lumiPreferences)` or by stashing one
/// inside an `@Observable` AppState.
///
/// Defaults aim at "smart and unobtrusive": vim-mode features default ON for
/// users who installed lumi (the product's identity is vim-friendly), but
/// every toggle is reachable from the Settings sheet so the choice is
/// reversible.
@Observable
@MainActor
public final class LumiPreferences {
    /// j/k move selection, h/l collapse/expand or open, Enter opens. Applies
    /// to the note list when the list (or its enclosing column) has focus.
    public var vimNavigationInList: Bool {
        didSet { defaults.set(vimNavigationInList, forKey: Keys.vimNavInList) }
    }

    /// While typing in insert mode, a `j` followed immediately by another `j`
    /// exits insert mode (deleting the buffered `j`). Common vim plugin.
    public var jjEscapeMapping: Bool {
        didSet { defaults.set(jjEscapeMapping, forKey: Keys.jjEscape) }
    }

    /// In read (view) mode, `j` scrolls down a line and `k` scrolls up.
    /// Mirrors the vim feel without making the read pane an actual editor.
    public var jkScrollInView: Bool {
        didSet { defaults.set(jkScrollInView, forKey: Keys.jkScroll) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.vimNavigationInList = defaults.object(forKey: Keys.vimNavInList) as? Bool ?? true
        self.jjEscapeMapping = defaults.object(forKey: Keys.jjEscape) as? Bool ?? true
        self.jkScrollInView = defaults.object(forKey: Keys.jkScroll) as? Bool ?? true
    }

    private enum Keys {
        static let vimNavInList = "lumi.pref.vimNavInList.v1"
        static let jjEscape = "lumi.pref.jjEscape.v1"
        static let jkScroll = "lumi.pref.jkScroll.v1"
    }
}
