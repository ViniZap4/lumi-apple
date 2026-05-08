import SwiftUI

/// All 12 themes shared with the TUI, web client, and site. Order matches
/// `themeOrder` in `web-client/src/lib/themes.ts`. Single source of truth for
/// the Apple client; if upstream themes change, regenerate this file.
public enum LumiTheme: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    case tokyoNight = "tokyo-night"
    case tokyoDay = "tokyo-day"
    case catppuccinMocha = "catppuccin-mocha"
    case catppuccinLatte = "catppuccin-latte"
    case dracula
    case lgbtDark = "lgbt-dark"
    case lgbtLight = "lgbt-light"
    case transDark = "trans-dark"
    case transLight = "trans-light"
    case transfem
    case transmasc
    case obsidian

    public var id: String { rawValue }

    public static var darkThemes: [LumiTheme] { allCases.filter { $0.tokens.isDark } }
    public static var lightThemes: [LumiTheme] { allCases.filter { !$0.tokens.isDark } }

    public static let defaultDark: LumiTheme = .tokyoNight
    public static let defaultLight: LumiTheme = .tokyoDay
}

public extension LumiTheme {
    var tokens: ThemeTokens {
        switch self {
        case .tokyoNight: return .tokyoNight
        case .tokyoDay: return .tokyoDay
        case .catppuccinMocha: return .catppuccinMocha
        case .catppuccinLatte: return .catppuccinLatte
        case .dracula: return .dracula
        case .lgbtDark: return .lgbtDark
        case .lgbtLight: return .lgbtLight
        case .transDark: return .transDark
        case .transLight: return .transLight
        case .transfem: return .transfem
        case .transmasc: return .transmasc
        case .obsidian: return .obsidian
        }
    }
}

extension ThemeTokens {
    static let tokyoNight = ThemeTokens(
        name: "tokyo-night",
        isDark: true,
        primary: Color(hex: "#7aa2f7"),
        secondary: Color(hex: "#bb9af7"),
        accent: Color(hex: "#7dcfff"),
        muted: Color(hex: "#565f89"),
        background: Color(hex: "#1a1b26"),
        selectedBackground: Color(hex: "#292e42"),
        overlayBackground: Color(hex: "#16161e"),
        text: Color(hex: "#c0caf5"),
        textDim: Color(hex: "#565f89"),
        border: Color(hex: "#3b4261"),
        separator: Color(hex: "#292e42"),
        error: Color(hex: "#f7768e"),
        warning: Color(hex: "#e0af68"),
        info: Color(hex: "#7dcfff"),
        logoColors: ["#7aa2f7", "#7dcfff", "#bb9af7", "#7aa2f7", "#7dcfff", "#bb9af7"].map(Color.init(hex:))
    )

    static let tokyoDay = ThemeTokens(
        name: "tokyo-day",
        isDark: false,
        primary: Color(hex: "#2e7de9"),
        secondary: Color(hex: "#9854f1"),
        accent: Color(hex: "#007197"),
        muted: Color(hex: "#8990b3"),
        background: Color(hex: "#d5d6db"),
        selectedBackground: Color(hex: "#c4c8da"),
        overlayBackground: Color(hex: "#e9e9ec"),
        text: Color(hex: "#3760bf"),
        textDim: Color(hex: "#8990b3"),
        border: Color(hex: "#a8aecb"),
        separator: Color(hex: "#c4c8da"),
        error: Color(hex: "#f52a65"),
        warning: Color(hex: "#8c6c3e"),
        info: Color(hex: "#007197"),
        logoColors: ["#2e7de9", "#007197", "#9854f1", "#2e7de9", "#007197", "#9854f1"].map(Color.init(hex:))
    )

    static let catppuccinMocha = ThemeTokens(
        name: "catppuccin-mocha",
        isDark: true,
        primary: Color(hex: "#cba6f7"),
        secondary: Color(hex: "#89b4fa"),
        accent: Color(hex: "#f5c2e7"),
        muted: Color(hex: "#6c7086"),
        background: Color(hex: "#1e1e2e"),
        selectedBackground: Color(hex: "#313244"),
        overlayBackground: Color(hex: "#181825"),
        text: Color(hex: "#cdd6f4"),
        textDim: Color(hex: "#6c7086"),
        border: Color(hex: "#45475a"),
        separator: Color(hex: "#313244"),
        error: Color(hex: "#f38ba8"),
        warning: Color(hex: "#f9e2af"),
        info: Color(hex: "#89dceb"),
        logoColors: ["#cba6f7", "#f5c2e7", "#89b4fa", "#cba6f7", "#f5c2e7", "#89b4fa"].map(Color.init(hex:))
    )

    static let catppuccinLatte = ThemeTokens(
        name: "catppuccin-latte",
        isDark: false,
        primary: Color(hex: "#8839ef"),
        secondary: Color(hex: "#1e66f5"),
        accent: Color(hex: "#ea76cb"),
        muted: Color(hex: "#9ca0b0"),
        background: Color(hex: "#ccd0da"),
        selectedBackground: Color(hex: "#bcc0cc"),
        overlayBackground: Color(hex: "#e6e9ef"),
        text: Color(hex: "#4c4f69"),
        textDim: Color(hex: "#9ca0b0"),
        border: Color(hex: "#acb0be"),
        separator: Color(hex: "#bcc0cc"),
        error: Color(hex: "#d20f39"),
        warning: Color(hex: "#df8e1d"),
        info: Color(hex: "#04a5e5"),
        logoColors: ["#8839ef", "#ea76cb", "#1e66f5", "#8839ef", "#ea76cb", "#1e66f5"].map(Color.init(hex:))
    )

    static let dracula = ThemeTokens(
        name: "dracula",
        isDark: true,
        primary: Color(hex: "#bd93f9"),
        secondary: Color(hex: "#8be9fd"),
        accent: Color(hex: "#ff79c6"),
        muted: Color(hex: "#6272a4"),
        background: Color(hex: "#282a36"),
        selectedBackground: Color(hex: "#44475a"),
        overlayBackground: Color(hex: "#21222c"),
        text: Color(hex: "#f8f8f2"),
        textDim: Color(hex: "#6272a4"),
        border: Color(hex: "#44475a"),
        separator: Color(hex: "#44475a"),
        error: Color(hex: "#ff5555"),
        warning: Color(hex: "#f1fa8c"),
        info: Color(hex: "#8be9fd"),
        logoColors: ["#bd93f9", "#ff79c6", "#8be9fd", "#bd93f9", "#ff79c6", "#8be9fd"].map(Color.init(hex:))
    )

    static let lgbtDark = ThemeTokens(
        name: "lgbt-dark",
        isDark: true,
        primary: Color(hex: "#ff6b6b"),
        secondary: Color(hex: "#ffd93d"),
        accent: Color(hex: "#6bcb77"),
        muted: Color(hex: "#7f8c8d"),
        background: Color(hex: "#1a1a2e"),
        selectedBackground: Color(hex: "#2d2d44"),
        overlayBackground: Color(hex: "#141425"),
        text: Color(hex: "#ecf0f1"),
        textDim: Color(hex: "#7f8c8d"),
        border: Color(hex: "#3d3d5c"),
        separator: Color(hex: "#2d2d44"),
        error: Color(hex: "#ff6b6b"),
        warning: Color(hex: "#ffd93d"),
        info: Color(hex: "#4ecdc4"),
        logoColors: ["#ff6b6b", "#ff8e53", "#ffd93d", "#6bcb77", "#4ecdc4", "#9b59b6"].map(Color.init(hex:))
    )

    static let lgbtLight = ThemeTokens(
        name: "lgbt-light",
        isDark: false,
        primary: Color(hex: "#e63946"),
        secondary: Color(hex: "#f4a261"),
        accent: Color(hex: "#2a9d8f"),
        muted: Color(hex: "#8d99ae"),
        background: Color(hex: "#d6d6d6"),
        selectedBackground: Color(hex: "#c8c8c8"),
        overlayBackground: Color(hex: "#edf2f4"),
        text: Color(hex: "#264653"),
        textDim: Color(hex: "#8d99ae"),
        border: Color(hex: "#a8b2c1"),
        separator: Color(hex: "#c8c8c8"),
        error: Color(hex: "#e63946"),
        warning: Color(hex: "#e76f51"),
        info: Color(hex: "#2a9d8f"),
        logoColors: ["#e63946", "#e76f51", "#f4a261", "#2a9d8f", "#264653", "#6a4c93"].map(Color.init(hex:))
    )

    static let transDark = ThemeTokens(
        name: "trans-dark",
        isDark: true,
        primary: Color(hex: "#5bcefa"),
        secondary: Color(hex: "#f5a9b8"),
        accent: Color(hex: "#ffffff"),
        muted: Color(hex: "#7f8c8d"),
        background: Color(hex: "#1a1a2e"),
        selectedBackground: Color(hex: "#2d2d44"),
        overlayBackground: Color(hex: "#141425"),
        text: Color(hex: "#ecf0f1"),
        textDim: Color(hex: "#7f8c8d"),
        border: Color(hex: "#3d3d5c"),
        separator: Color(hex: "#2d2d44"),
        error: Color(hex: "#ff6b6b"),
        warning: Color(hex: "#ffd93d"),
        info: Color(hex: "#5bcefa"),
        logoColors: ["#5bcefa", "#f5a9b8", "#ffffff", "#f5a9b8", "#5bcefa", "#ffffff"].map(Color.init(hex:))
    )

    static let transLight = ThemeTokens(
        name: "trans-light",
        isDark: false,
        primary: Color(hex: "#5bcefa"),
        secondary: Color(hex: "#f5a9b8"),
        accent: Color(hex: "#333333"),
        muted: Color(hex: "#8d99ae"),
        background: Color(hex: "#d6d6d6"),
        selectedBackground: Color(hex: "#c8c8c8"),
        overlayBackground: Color(hex: "#edf2f4"),
        text: Color(hex: "#2b2d42"),
        textDim: Color(hex: "#8d99ae"),
        border: Color(hex: "#a8b2c1"),
        separator: Color(hex: "#c8c8c8"),
        error: Color(hex: "#e63946"),
        warning: Color(hex: "#e76f51"),
        info: Color(hex: "#5bcefa"),
        logoColors: ["#5bcefa", "#f5a9b8", "#333333", "#f5a9b8", "#5bcefa", "#333333"].map(Color.init(hex:))
    )

    static let transfem = ThemeTokens(
        name: "transfem",
        isDark: true,
        primary: Color(hex: "#f4a7b9"),
        secondary: Color(hex: "#c9b1e8"),
        accent: Color(hex: "#87ceeb"),
        muted: Color(hex: "#7a6e7e"),
        background: Color(hex: "#1a1520"),
        selectedBackground: Color(hex: "#2e2238"),
        overlayBackground: Color(hex: "#130f1a"),
        text: Color(hex: "#f0e6f6"),
        textDim: Color(hex: "#7a6e7e"),
        border: Color(hex: "#3d2e4a"),
        separator: Color(hex: "#2e2238"),
        error: Color(hex: "#ff6b8a"),
        warning: Color(hex: "#ffd6a5"),
        info: Color(hex: "#87ceeb"),
        logoColors: ["#87ceeb", "#f4a7b9", "#f0e6f6", "#f4a7b9", "#87ceeb", "#c9b1e8"].map(Color.init(hex:))
    )

    static let transmasc = ThemeTokens(
        name: "transmasc",
        isDark: true,
        primary: Color(hex: "#5ba3d9"),
        secondary: Color(hex: "#f4a7b9"),
        accent: Color(hex: "#d8eaf8"),
        muted: Color(hex: "#6e7a8a"),
        background: Color(hex: "#0f1820"),
        selectedBackground: Color(hex: "#1c2e3f"),
        overlayBackground: Color(hex: "#0a1018"),
        text: Color(hex: "#ddeeff"),
        textDim: Color(hex: "#6e7a8a"),
        border: Color(hex: "#2a4060"),
        separator: Color(hex: "#1c2e3f"),
        error: Color(hex: "#ff7096"),
        warning: Color(hex: "#ffd6a5"),
        info: Color(hex: "#5ba3d9"),
        logoColors: ["#5ba3d9", "#d8eaf8", "#f4a7b9", "#5ba3d9", "#d8eaf8", "#f4a7b9"].map(Color.init(hex:))
    )

    static let obsidian = ThemeTokens(
        name: "obsidian",
        isDark: true,
        primary: Color(hex: "#a882ff"),
        secondary: Color(hex: "#7c6f9e"),
        accent: Color(hex: "#c792ea"),
        muted: Color(hex: "#5c5c5c"),
        background: Color(hex: "#1e1e1e"),
        selectedBackground: Color(hex: "#2d2d2d"),
        overlayBackground: Color(hex: "#161616"),
        text: Color(hex: "#dcddde"),
        textDim: Color(hex: "#5c5c5c"),
        border: Color(hex: "#3c3c3c"),
        separator: Color(hex: "#2d2d2d"),
        error: Color(hex: "#e05561"),
        warning: Color(hex: "#d19a66"),
        info: Color(hex: "#56b6c2"),
        logoColors: ["#a882ff", "#c792ea", "#7c6f9e", "#a882ff", "#c792ea", "#7c6f9e"].map(Color.init(hex:))
    )
}
