import Testing
import SwiftUI
@testable import LumiUI

/// "Prose in colour": every coloured ink keeps its contrast floor on
/// every theme, and the heading ramp really is a ramp (not one colour).
@Suite("Prose colour system")
@MainActor
struct ProseColorTests {
    static func over(_ fill: MarkdownPlatformColor, _ bg: MarkdownPlatformColor) -> MarkdownPlatformColor {
        MarkdownPalette.mix(fill.withAlphaComponent(1), bg, MarkdownPalette.rgb(fill).a)
    }

    @Test("inks pass their floors", arguments: LumiTheme.allCases)
    func floors(theme: LumiTheme) {
        let p = MarkdownPalette(theme.tokens)
        let bg = p.background
        func c(_ x: MarkdownPlatformColor, _ on: MarkdownPlatformColor? = nil) -> CGFloat { MarkdownPalette.contrast(x, on ?? bg) }
        for level in 1...5 { #expect(c(p.heading(level)) >= 4.45, "\(theme.rawValue) h\(level)") }
        #expect(c(p.heading(6)) >= 2.95)
        #expect(c(p.link) >= 4.45, "\(theme.rawValue) link")
        #expect(c(p.strong) >= 4.45, "\(theme.rawValue) bold")
        #expect(c(p.emphasis) >= 4.45, "\(theme.rawValue) italic")
        #expect(c(p.footnote) >= 4.45)
        #expect(c(p.listMarker) >= 2.95)
        #expect(c(p.strikeText) >= 2.95)
        // Inks on their own tinted pills.
        #expect(c(p.inlineCodeText, Self.over(p.inlineBackground, bg)) >= 4.0, "\(theme.rawValue) code pill")
        #expect(c(p.tagText, Self.over(p.tagFill, bg)) >= 4.0, "\(theme.rawValue) tag chip")
        #expect(c(p.markText, Self.over(p.markBackground, bg)) >= 4.0, "\(theme.rawValue) mark")
        #expect(c(p.text, Self.over(p.tableHeader, bg)) >= 3.5)
        #expect(c(p.dim, Self.over(p.quoteFill, bg)) >= 3)
    }

    @Test("the heading ramp has at least three distinct hues", arguments: LumiTheme.allCases)
    func ramp(theme: LumiTheme) {
        let p = MarkdownPalette(theme.tokens)
        let labs = (1...5).map { OKLab.lab(MarkdownPalette.rgbv(p.heading($0))) }
        var distinct: [OKLab.Lab] = []
        for l in labs where !distinct.contains(where: { hypot(hypot($0.l - l.l, $0.a - l.a), $0.b - l.b) < 0.04 }) {
            distinct.append(l)
        }
        #expect(distinct.count >= 3, "\(theme.rawValue): \(distinct.count) distinct heading colours")
        // Body ink differs from h1 (the owner: "só com uma cor").
        let body = OKLab.lab(MarkdownPalette.rgbv(p.text))
        #expect(hypot(hypot(labs[0].l - body.l, labs[0].a - body.a), labs[0].b - body.b) > 0.04)
    }

    @Test("callout aliases fold into the shared colour families")
    func calloutFamilies() {
        #expect(MarkdownPalette.calloutFamily("caution") == .warning)
        #expect(MarkdownPalette.calloutFamily("BUG") == .danger)
        #expect(MarkdownPalette.calloutFamily("hint") == .tip)
        #expect(MarkdownPalette.calloutFamily("faq") == .question)
        #expect(MarkdownPalette.calloutFamily("tldr") == .info)
        #expect(MarkdownPalette.calloutFamily("cite") == .quote)
        #expect(MarkdownPalette.calloutFamily("whatever") == .note)
    }

    @Test("OKLab round-trips and mixes perceptually")
    func oklab() {
        let c = RGB(hex: "#7aa2f7")
        let back = OKLab.rgb(OKLab.lab(c))
        #expect(abs(back.r - c.r) < 1e-4 && abs(back.g - c.g) < 1e-4 && abs(back.b - c.b) < 1e-4)
        let white = RGB(1, 1, 1), black = RGB(0, 0, 0)
        #expect(abs(OKLab.lab(OKLab.mix(white, black, 0.5)).l - 0.5) < 1e-6)
        let fixed = OKLab.readable(RGB(hex: "#ea76cb"), ink: RGB(hex: "#4c4f69"), on: RGB(hex: "#ccd0da"), minimum: 4.5)
        #expect(OKLab.contrast(fixed, RGB(hex: "#ccd0da")) >= 4.49)
    }

    @Test("inline #tags become chips, headings and URLs do not")
    func tags() {
        let r = MarkdownAttributedBuilder.tagRegex!
        func tags(_ s: String) -> [String] {
            r.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { (s as NSString).substring(with: $0.range(at: 1)) }
        }
        #expect(tags("Tagged #design #prose/sub.") == ["#design", "#prose/sub"])
        #expect(tags("issue #123 and a#b") == [])
        #expect(tags("#start of line") == ["#start"])
    }
}
