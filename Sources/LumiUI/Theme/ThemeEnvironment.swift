import SwiftUI

public extension EnvironmentValues {
    /// Resolved theme tokens for the current view tree. Inject at the root via
    /// `.environment(\.theme, theme.tokens)`.
    @Entry var theme: ThemeTokens = LumiTheme.defaultDark.tokens
}
