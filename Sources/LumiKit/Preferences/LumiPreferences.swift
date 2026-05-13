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

    /// What mode a freshly-opened note lands in.
    public var defaultOpenMode: DefaultOpenMode {
        didSet { defaults.set(defaultOpenMode.rawValue, forKey: Keys.defaultOpenMode) }
    }
    public enum DefaultOpenMode: String, CaseIterable, Identifiable, Sendable {
        case view, edit
        public var id: String { rawValue }
        public var label: String { self == .view ? "Read mode" : "Edit mode" }
    }

    /// Show gutter line numbers in the vim editor.
    public var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: Keys.showLineNumbers) }
    }

    /// Show relative line numbers (vim's `relativenumber`) instead of absolute.
    public var relativeLineNumbers: Bool {
        didSet { defaults.set(relativeLineNumbers, forKey: Keys.relativeLineNumbers) }
    }

    /// Font size for the editor and read pane, in points. Clamped 11…22.
    public var editorFontSize: Double {
        didSet {
            let clamped = max(11, min(22, editorFontSize))
            if clamped != editorFontSize {
                editorFontSize = clamped
                return
            }
            defaults.set(editorFontSize, forKey: Keys.editorFontSize)
        }
    }

    /// Hard cap on how many body lines the three-column browser's preview
    /// pane renders.
    public var previewLines: Int {
        didSet {
            let clamped = max(5, min(80, previewLines))
            if clamped != previewLines {
                previewLines = clamped
                return
            }
            defaults.set(previewLines, forKey: Keys.previewLines)
        }
    }

    /// Render the vim normal-mode cursor as a tinted block (default).
    /// Disable to keep just the slim caret like a regular text field.
    public var vimBlockCursor: Bool {
        didSet { defaults.set(vimBlockCursor, forKey: Keys.vimBlockCursor) }
    }

    /// Apply markdown syntax color in the editor.
    public var editorSyntaxColor: Bool {
        didSet { defaults.set(editorSyntaxColor, forKey: Keys.editorSyntaxColor) }
    }

    /// Display the contextual keybinds bar at the bottom of the window.
    /// Off matches a chrome-light reading mode; on mirrors what TUI / web
    /// show by default.
    public var showKeybindsBar: Bool {
        didSet { defaults.set(showKeybindsBar, forKey: Keys.showKeybindsBar) }
    }

    /// How the active theme is chosen: explicit dark, explicit light, or
    /// auto-follow the system. Auto uses `defaultLight` for light system
    /// appearance and `defaultDark` otherwise.
    public var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }
    public enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
        case auto, dark, light
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .auto: return "Follow system"
            case .dark: return "Always dark"
            case .light: return "Always light"
            }
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.vimNavigationInList = defaults.object(forKey: Keys.vimNavInList) as? Bool ?? true
        self.jjEscapeMapping = defaults.object(forKey: Keys.jjEscape) as? Bool ?? true
        self.jkScrollInView = defaults.object(forKey: Keys.jkScroll) as? Bool ?? true
        let raw = defaults.string(forKey: Keys.defaultOpenMode) ?? DefaultOpenMode.view.rawValue
        self.defaultOpenMode = DefaultOpenMode(rawValue: raw) ?? .view
        self.showLineNumbers = defaults.object(forKey: Keys.showLineNumbers) as? Bool ?? false
        self.relativeLineNumbers = defaults.object(forKey: Keys.relativeLineNumbers) as? Bool ?? false
        self.editorFontSize = defaults.object(forKey: Keys.editorFontSize) as? Double ?? 14
        self.previewLines = defaults.object(forKey: Keys.previewLines) as? Int ?? 20
        self.vimBlockCursor = defaults.object(forKey: Keys.vimBlockCursor) as? Bool ?? true
        self.editorSyntaxColor = defaults.object(forKey: Keys.editorSyntaxColor) as? Bool ?? true
        self.showKeybindsBar = defaults.object(forKey: Keys.showKeybindsBar) as? Bool ?? true
        let rawTheme = defaults.string(forKey: Keys.themeMode) ?? ThemeMode.auto.rawValue
        self.themeMode = ThemeMode(rawValue: rawTheme) ?? .auto
    }

    private enum Keys {
        static let vimNavInList = "lumi.pref.vimNavInList.v1"
        static let jjEscape = "lumi.pref.jjEscape.v1"
        static let jkScroll = "lumi.pref.jkScroll.v1"
        static let defaultOpenMode = "lumi.pref.defaultOpenMode.v1"
        static let showLineNumbers = "lumi.pref.showLineNumbers.v1"
        static let relativeLineNumbers = "lumi.pref.relativeLineNumbers.v1"
        static let editorFontSize = "lumi.pref.editorFontSize.v1"
        static let previewLines = "lumi.pref.previewLines.v1"
        static let vimBlockCursor = "lumi.pref.vimBlockCursor.v1"
        static let editorSyntaxColor = "lumi.pref.editorSyntaxColor.v1"
        static let showKeybindsBar = "lumi.pref.showKeybindsBar.v1"
        static let themeMode = "lumi.pref.themeMode.v1"
    }
}
