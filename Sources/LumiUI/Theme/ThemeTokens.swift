import SwiftUI

/// Resolved theme as colors. Mirrors the `Theme` shape in
/// `web-client/src/lib/themes.ts` and `tui-client/theme/builtin.go`.
public struct ThemeTokens: Sendable, Hashable {
    public let name: String
    public let isDark: Bool
    public let primary: Color
    public let secondary: Color
    public let accent: Color
    public let muted: Color
    public let background: Color
    public let selectedBackground: Color
    public let overlayBackground: Color
    public let text: Color
    public let textDim: Color
    public let border: Color
    public let separator: Color
    public let error: Color
    public let warning: Color
    public let info: Color
    public let logoColors: [Color]

    public init(
        name: String,
        isDark: Bool,
        primary: Color,
        secondary: Color,
        accent: Color,
        muted: Color,
        background: Color,
        selectedBackground: Color,
        overlayBackground: Color,
        text: Color,
        textDim: Color,
        border: Color,
        separator: Color,
        error: Color,
        warning: Color,
        info: Color,
        logoColors: [Color]
    ) {
        self.name = name
        self.isDark = isDark
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.muted = muted
        self.background = background
        self.selectedBackground = selectedBackground
        self.overlayBackground = overlayBackground
        self.text = text
        self.textDim = textDim
        self.border = border
        self.separator = separator
        self.error = error
        self.warning = warning
        self.info = info
        self.logoColors = logoColors
    }
}
