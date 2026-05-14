import Foundation
import Observation

/// User-tunable behavior preferences. Persisted to `~/.config/lumi/apple.yaml`
/// via `PreferencesStore` so the file is human-readable and lives alongside
/// the TUI's `config.yaml` (separate file, shared directory — see
/// `ConfigPaths`). UI binds to the shared instance via
/// `@Environment(\.lumiPreferences)` or by stashing one inside an
/// `@Observable` AppState.
///
/// Defaults aim at "smart and unobtrusive": vim-mode features default ON for
/// users who installed lumi (the product's identity is vim-friendly), but
/// every toggle is reachable from the Settings sheet so the choice is
/// reversible.
///
/// Migration: on first construction the store auto-migrates pre-existing
/// `UserDefaults` values (older lumi-apple builds wrote there) into the new
/// yaml file. The migration is one-way and idempotent.
@Observable
@MainActor
public final class LumiPreferences {
    /// j/k move selection, h/l collapse/expand or open, Enter opens. Applies
    /// to the note list when the list (or its enclosing column) has focus.
    public var vimNavigationInList: Bool {
        didSet { store.set(Keys.vimNavInList, vimNavigationInList) }
    }

    /// While typing in insert mode, a `j` followed immediately by another `j`
    /// exits insert mode (deleting the buffered `j`). Common vim plugin.
    public var jjEscapeMapping: Bool {
        didSet { store.set(Keys.jjEscape, jjEscapeMapping) }
    }

    /// In read (view) mode, `j` scrolls down a line and `k` scrolls up.
    /// Mirrors the vim feel without making the read pane an actual editor.
    public var jkScrollInView: Bool {
        didSet { store.set(Keys.jkScroll, jkScrollInView) }
    }

    /// What mode a freshly-opened note lands in.
    public var defaultOpenMode: DefaultOpenMode {
        didSet { store.set(Keys.defaultOpenMode, defaultOpenMode.rawValue) }
    }
    public enum DefaultOpenMode: String, CaseIterable, Identifiable, Sendable {
        case view, edit
        public var id: String { rawValue }
        public var label: String { self == .view ? "Read mode" : "Edit mode" }
    }

    /// Show gutter line numbers in the vim editor.
    public var showLineNumbers: Bool {
        didSet { store.set(Keys.showLineNumbers, showLineNumbers) }
    }

    /// Show relative line numbers (vim's `relativenumber`) instead of absolute.
    public var relativeLineNumbers: Bool {
        didSet { store.set(Keys.relativeLineNumbers, relativeLineNumbers) }
    }

    /// Font size for the editor and read pane, in points. Clamped 11…22.
    public var editorFontSize: Double {
        didSet {
            let clamped = max(11, min(22, editorFontSize))
            if clamped != editorFontSize {
                editorFontSize = clamped
                return
            }
            store.set(Keys.editorFontSize, editorFontSize)
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
            store.set(Keys.previewLines, previewLines)
        }
    }

    /// Render the vim normal-mode cursor as a tinted block (default).
    /// Disable to keep just the slim caret like a regular text field.
    public var vimBlockCursor: Bool {
        didSet { store.set(Keys.vimBlockCursor, vimBlockCursor) }
    }

    /// Apply markdown syntax color in the editor.
    public var editorSyntaxColor: Bool {
        didSet { store.set(Keys.editorSyntaxColor, editorSyntaxColor) }
    }

    /// Display the contextual keybinds bar at the bottom of the window.
    /// Off matches a chrome-light reading mode; on mirrors what TUI / web
    /// show by default.
    public var showKeybindsBar: Bool {
        didSet { store.set(Keys.showKeybindsBar, showKeybindsBar) }
    }

    /// Master switch for vim mode in the edit pane. When off the editor
    /// behaves like a regular text field (system shortcuts, no modal
    /// states, Writing Tools enabled). When on the vim engine drives
    /// every keystroke as before.
    public var vimEnabled: Bool {
        didSet { store.set(Keys.vimEnabled, vimEnabled) }
    }

    /// Animate note-content transitions (open / switch / scroll mode
    /// toggle). Off matches a "snappy IDE" feel; on adds a brief opacity
    /// fade so context shifts are visually obvious.
    public var contentAnimations: Bool {
        didSet { store.set(Keys.contentAnimations, contentAnimations) }
    }

    /// Body font for the read pane. Editor stays monospace.
    public var readingFontFamily: ReadingFontFamily {
        didSet { store.set(Keys.readingFontFamily, readingFontFamily.rawValue) }
    }
    public enum ReadingFontFamily: String, CaseIterable, Identifiable, Sendable {
        case system, serif, monospace
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .system: return "Sans (default)"
            case .serif: return "Serif"
            case .monospace: return "Monospaced"
            }
        }
    }

    /// Scale factor applied to read-mode typography. 1.0 = default; the UI
    /// exposes presets via the toolbar (Small / Default / Large / X-Large).
    /// Clamped to a sane range so it never breaks layout.
    public var readingScale: Double {
        didSet {
            let clamped = max(0.85, min(1.6, readingScale))
            if clamped != readingScale {
                readingScale = clamped
                return
            }
            store.set(Keys.readingScale, readingScale)
        }
    }

    /// Maximum body width (in pt) for the read pane. Lets users pick a
    /// narrow newspaper-column measure or a wider editor-style layout.
    /// Clamped 520…1100.
    public var readingWidth: Double {
        didSet {
            let clamped = max(520, min(1100, readingWidth))
            if clamped != readingWidth {
                readingWidth = clamped
                return
            }
            store.set(Keys.readingWidth, readingWidth)
        }
    }

    /// How the active theme is chosen: explicit dark, explicit light, or
    /// auto-follow the system. Auto uses `defaultLight` for light system
    /// appearance and `defaultDark` otherwise.
    public var themeMode: ThemeMode {
        didSet { store.set(Keys.themeMode, themeMode.rawValue) }
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

    private let store: PreferencesStore

    public init(store: PreferencesStore = .shared) {
        self.store = store
        Self.migrateFromUserDefaultsIfNeeded(into: store)
        self.vimNavigationInList = store.bool(Keys.vimNavInList) ?? true
        self.jjEscapeMapping = store.bool(Keys.jjEscape) ?? true
        self.jkScrollInView = store.bool(Keys.jkScroll) ?? true
        let raw = store.string(Keys.defaultOpenMode) ?? DefaultOpenMode.view.rawValue
        self.defaultOpenMode = DefaultOpenMode(rawValue: raw) ?? .view
        self.showLineNumbers = store.bool(Keys.showLineNumbers) ?? false
        self.relativeLineNumbers = store.bool(Keys.relativeLineNumbers) ?? false
        self.editorFontSize = store.double(Keys.editorFontSize) ?? 14
        self.previewLines = store.int(Keys.previewLines) ?? 20
        self.vimBlockCursor = store.bool(Keys.vimBlockCursor) ?? true
        self.editorSyntaxColor = store.bool(Keys.editorSyntaxColor) ?? true
        self.showKeybindsBar = store.bool(Keys.showKeybindsBar) ?? true
        self.vimEnabled = store.bool(Keys.vimEnabled) ?? true
        self.contentAnimations = store.bool(Keys.contentAnimations) ?? true
        let rawFamily = store.string(Keys.readingFontFamily) ?? ReadingFontFamily.system.rawValue
        self.readingFontFamily = ReadingFontFamily(rawValue: rawFamily) ?? .system
        self.readingScale = store.double(Keys.readingScale) ?? 1.0
        self.readingWidth = store.double(Keys.readingWidth) ?? 760
        let rawTheme = store.string(Keys.themeMode) ?? ThemeMode.auto.rawValue
        self.themeMode = ThemeMode(rawValue: rawTheme) ?? .auto
    }

    /// One-shot migration of legacy `UserDefaults` values into the yaml
    /// store. Runs at most once per process; subsequent calls no-op via the
    /// store's "already-loaded" guard. Old defaults are left intact so a
    /// downgrade to a pre-yaml build doesn't lose user settings.
    private static func migrateFromUserDefaultsIfNeeded(into store: PreferencesStore) {
        let defaults = UserDefaults.standard
        var migrated: [String: String] = [:]
        func copy(_ legacyKey: String, _ targetKey: String, transform: (Any) -> String? = { "\($0)" }) {
            guard let any = defaults.object(forKey: legacyKey), let v = transform(any) else { return }
            migrated[targetKey] = v
        }
        copy(LegacyKeys.vimNavInList, Keys.vimNavInList)
        copy(LegacyKeys.jjEscape, Keys.jjEscape)
        copy(LegacyKeys.jkScroll, Keys.jkScroll)
        copy(LegacyKeys.defaultOpenMode, Keys.defaultOpenMode)
        copy(LegacyKeys.showLineNumbers, Keys.showLineNumbers)
        copy(LegacyKeys.relativeLineNumbers, Keys.relativeLineNumbers)
        copy(LegacyKeys.editorFontSize, Keys.editorFontSize)
        copy(LegacyKeys.previewLines, Keys.previewLines)
        copy(LegacyKeys.vimBlockCursor, Keys.vimBlockCursor)
        copy(LegacyKeys.editorSyntaxColor, Keys.editorSyntaxColor)
        copy(LegacyKeys.showKeybindsBar, Keys.showKeybindsBar)
        copy(LegacyKeys.themeMode, Keys.themeMode)
        copy(LegacyKeys.readingScale, Keys.readingScale)
        copy(LegacyKeys.readingWidth, Keys.readingWidth)
        copy(LegacyKeys.vimEnabled, Keys.vimEnabled)
        copy(LegacyKeys.contentAnimations, Keys.contentAnimations)
        copy(LegacyKeys.readingFontFamily, Keys.readingFontFamily)
        store.bootstrap(migrated)
    }

    private enum Keys {
        static let vimNavInList = "vim_navigation_in_list"
        static let jjEscape = "jj_escape_mapping"
        static let jkScroll = "jk_scroll_in_view"
        static let defaultOpenMode = "default_open_mode"
        static let showLineNumbers = "show_line_numbers"
        static let relativeLineNumbers = "relative_line_numbers"
        static let editorFontSize = "editor_font_size"
        static let previewLines = "preview_lines"
        static let vimBlockCursor = "vim_block_cursor"
        static let editorSyntaxColor = "editor_syntax_color"
        static let showKeybindsBar = "show_keybinds_bar"
        static let themeMode = "theme_mode"
        static let readingScale = "reading_scale"
        static let readingWidth = "reading_width"
        static let vimEnabled = "vim_enabled"
        static let contentAnimations = "content_animations"
        static let readingFontFamily = "reading_font_family"
    }

    /// UserDefaults keys used by builds <= F.36. Kept here only for the
    /// one-shot migration in `init`. Do not write to these.
    private enum LegacyKeys {
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
        static let readingScale = "lumi.pref.readingScale.v1"
        static let readingWidth = "lumi.pref.readingWidth.v1"
        static let vimEnabled = "lumi.pref.vimEnabled.v1"
        static let contentAnimations = "lumi.pref.contentAnimations.v1"
        static let readingFontFamily = "lumi.pref.readingFontFamily.v1"
    }
}
