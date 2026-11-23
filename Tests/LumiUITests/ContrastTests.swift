import Testing
import SwiftUI
@testable import LumiUI

/// Port of the web's `contrast.test.ts`: body text and prose tokens stay
/// legible in every theme, plus the editor's visual selection is
/// actually visible (the web shipped an invisible one once).
@Suite("Theme contrast (web parity)")
@MainActor
struct ContrastTests {
    @Test("body text ≥ 4.5:1, links ≥ 3:1", arguments: LumiTheme.allCases)
    func body(theme: LumiTheme) {
        let p = MarkdownPalette(theme.tokens)
        #expect(MarkdownPalette.contrast(p.text, p.background) >= 4.5)
        #expect(MarkdownPalette.contrast(p.primary, p.background) >= 3)
    }

    @Test("quotes, inline code and code blocks stay legible", arguments: LumiTheme.allCases)
    func prose(theme: LumiTheme) {
        let p = MarkdownPalette(theme.tokens)
        let body = MarkdownPalette.contrast(p.text, p.background)
        let dim = MarkdownPalette.contrast(p.dim, p.background)
        #expect(dim >= 3)
        #expect(dim / body >= 0.6)
        let pill = MarkdownPalette.contrast(p.text, MarkdownPalette.mix(p.text, p.background, 0.07))
        #expect(pill >= min(7, body * 0.85))
        let code = MarkdownPalette.contrast(p.text, p.codeBackground)
        #expect(code >= min(7, body * 0.88))
    }

    @Test("visual selection is visible and keeps text readable", arguments: LumiTheme.allCases)
    func selection(theme: LumiTheme) {
        let t = theme.tokens
        let p = MarkdownPalette(t)
        let alpha: CGFloat = t.isDark ? 0.32 : 0.26
        let band = MarkdownPalette.mix(p.primary, p.background, alpha)
        // The band must stand out from the page…
        #expect(MarkdownPalette.contrast(band, p.background) >= 1.25, "\(theme.rawValue): selection too faint")
        // …without drowning the text on it.
        #expect(MarkdownPalette.contrast(p.text, band) >= 3, "\(theme.rawValue): text unreadable on selection")
    }
}
