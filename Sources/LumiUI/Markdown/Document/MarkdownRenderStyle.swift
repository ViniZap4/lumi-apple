import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit
public typealias MarkdownPlatformFont = NSFont
public typealias MarkdownPlatformColor = NSColor
typealias MarkdownPlatformFontDescriptor = NSFontDescriptor
#else
import UIKit
public typealias MarkdownPlatformFont = UIFont
public typealias MarkdownPlatformColor = UIColor
typealias MarkdownPlatformFontDescriptor = UIFontDescriptor
#endif

/// Everything that changes how a block *looks* without changing what it
/// *is*. Part of every fragment-cache key: flip the theme, the reading
/// scale or the font family and every cached fragment misses, so a
/// theme switch can never leave stale colours behind.
public struct MarkdownRenderStyle: Hashable, Sendable {
    public var theme: ThemeTokens
    public var scale: Double
    public var fontFamily: MarkdownFontFamily
    /// Task checkboxes are clickable (the host can write the note).
    public var tasksInteractive: Bool

    public init(theme: ThemeTokens, scale: Double = 1.0, fontFamily: MarkdownFontFamily = .system, tasksInteractive: Bool = false) {
        self.theme = theme
        self.scale = scale
        self.fontFamily = fontFamily
        self.tasksInteractive = tasksInteractive
    }

    var s: CGFloat { CGFloat(scale) }

    // MARK: Prose metrics — the web's `.lumi-prose` / `.md-body` system
    // (app.css): one size, everything else in em, so the reading scale
    // scales the whole rhythm.

    /// Body size: sans 17 pt (the web's 16 px reads a touch smaller on
    /// a Mac display), serif 18.5, mono 15.5.
    var em: CGFloat {
        switch fontFamily {
        case .system: return 17 * s
        case .serif: return 18.5 * s
        case .monospace: return 15.5 * s
        }
    }

    /// Line height as a multiple of the size (`--prose-leading`).
    var leading: CGFloat {
        switch fontFamily {
        case .system: return 1.65
        case .serif: return 1.6
        case .monospace: return 1.7
        }
    }

    var bodySize: CGFloat { em }
    /// Vertical rhythm between blocks (`--md-rhythm: 0.95em`).
    var rhythm: CGFloat { 0.95 * em }
    var blockGap: CGFloat { rhythm }
    /// Code block text (`pre code` 0.84em).
    var codeSize: CGFloat { 0.84 * em }
    /// Inline code (0.86em).
    var inlineCodeSize: CGFloat { 0.86 * em }
    var listItemGap: CGFloat { 0.3 * em }
    var quoteGap: CGFloat { rhythm }
    /// Lists: `padding-left: 1.55em` + `li { padding-left: .25em }`.
    var listMarkerColumn: CGFloat { 1.8 * em }
    /// Marker's right edge, measured from the list's indent.
    var listMarkerWidth: CGFloat { 1.25 * em }
    var quoteIndent: CGFloat { 1.1 * em + 3 }
    var quotePadding: CGFloat { 0.3 * em }
    var calloutPaddingH: CGFloat { 1.05 * em }
    var calloutPaddingV: CGFloat { 0.78 * em }
    var codePaddingH: CGFloat { 1.1 * em }
    var codePaddingV: CGFloat { 0.85 * em }
    var titleSize: CGFloat { 2.05 * em }

    /// Heading size ratio (`h1 1.875em` … `h6 .8em`).
    static func headingRatio(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.875
        case 2: return 1.45
        case 3: return 1.2
        case 4: return 1.02
        case 5: return 0.86
        default: return 0.8
        }
    }

    /// Legacy absolute sizes (attachment estimates, KaTeX headings).
    static func headingBaseSize(_ level: Int) -> CGFloat { 17 * headingRatio(level) }

    func headingSize(_ level: Int) -> CGFloat { Self.headingRatio(level) * em }

    /// Space above a heading, in its own em (`h1 1.5em` …), minus the
    /// rhythm the previous block already leaves (TextKit adds spacing,
    /// CSS collapses margins).
    func headingSpacingBefore(_ level: Int) -> CGFloat {
        let ratio: CGFloat
        switch level {
        case 1: ratio = 1.5
        case 2: ratio = 1.75
        case 3: ratio = 1.65
        case 4: ratio = 1.55
        default: ratio = 1.5
        }
        return max(0, ratio * headingSize(level) - rhythm)
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        let ratio: CGFloat
        switch level {
        case 1: ratio = 0.55
        case 2: ratio = 0.6
        case 3: ratio = 0.45
        case 4: ratio = 0.4
        default: ratio = 0.35
        }
        return ratio * headingSize(level)
    }

    /// Heading line height (`1.18` … `1.3`).
    static func headingLeading(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.18
        case 2: return 1.22
        case 3: return 1.3
        default: return 1.25
        }
    }

    /// Letter spacing in em (`-0.022em` … `0.07em`).
    static func headingTracking(_ level: Int) -> CGFloat {
        switch level {
        case 1: return -0.022
        case 2: return -0.016
        case 5: return 0.06
        case 6: return 0.07
        default: return -0.012
        }
    }
}

/// Theme colours resolved once per style into platform colours. Bridging
/// `Color` → `NSColor`/`UIColor` is not free; doing it per text run on a
/// 5k-line note showed up in profiles.
///
/// The `md*` tokens are the web's prose tokens (app.css): theme colours
/// and sRGB mixes of them only, so every theme applies.
struct MarkdownPalette {
    let text: MarkdownPlatformColor
    let textDim: MarkdownPlatformColor
    let primary: MarkdownPlatformColor
    let secondary: MarkdownPlatformColor
    let accent: MarkdownPlatformColor
    let border: MarkdownPlatformColor
    let separator: MarkdownPlatformColor
    let overlayBackground: MarkdownPlatformColor
    let background: MarkdownPlatformColor
    let warning: MarkdownPlatformColor
    let error: MarkdownPlatformColor
    let info: MarkdownPlatformColor

    /// Quotes, captions, done tasks (`--md-dim`: text 82% over bg).
    let dim: MarkdownPlatformColor
    /// List markers, code labels (`--md-marker`: text 48%).
    let marker: MarkdownPlatformColor
    /// Hairlines (`--md-rule`: text 13%).
    let rule: MarkdownPlatformColor
    /// Code block fill / border (text 4% / 10%).
    let codeBackground: MarkdownPlatformColor
    let codeBorder: MarkdownPlatformColor
    /// Inline code pill (text at 7% alpha).
    let inlineBackground: MarkdownPlatformColor
    /// Link underline (link ink at 45% alpha).
    let linkLine: MarkdownPlatformColor
    /// `==mark==` (warning at 24–30% alpha).
    let markBackground: MarkdownPlatformColor
    /// Quote bar (secondary, readable) and its faint tint.
    let quoteBar: MarkdownPlatformColor
    let quoteFill: MarkdownPlatformColor

    // MARK: Prose colour system (shared mapping with the web's
    // `--md-*` tokens; DESIGN-LANGUAGE §4 "prose in colour").
    // Every ink is pushed towards `text` in OKLab only as far as needed
    // to reach its contrast floor on the background, so all 12 themes,
    // light and dark, keep the hue *and* pass.

    /// Heading ink per level 1…6: h1 primary, h2 secondary, h3 accent,
    /// h4 primary/text, h5 secondary/text, h6 muted ink.
    let headings: [MarkdownPlatformColor]
    /// Links and wikilinks (theme accent) + their underline.
    let link: MarkdownPlatformColor
    /// `**bold**`: warm ink (error⊕warning, 40% into text).
    let strong: MarkdownPlatformColor
    /// `_italic_`: secondary, 50% into text.
    let emphasis: MarkdownPlatformColor
    /// `~~strike~~`: dim text with an error-tinted line.
    let strikeText: MarkdownPlatformColor
    let strikeLine: MarkdownPlatformColor
    /// `==mark==` ink (the fill is `markBackground`).
    let markText: MarkdownPlatformColor
    /// Inline `code`: primary-tinted pill.
    let inlineCodeText: MarkdownPlatformColor
    let inlineCodeStroke: MarkdownPlatformColor
    /// Bullets, ordered numbers, checkbox ring.
    let listMarker: MarkdownPlatformColor
    let checkBorder: MarkdownPlatformColor
    /// `#tag` chips.
    let tagText: MarkdownPlatformColor
    let tagFill: MarkdownPlatformColor
    /// Table header tint and zebra rows.
    let tableHeader: MarkdownPlatformColor
    let tableZebra: MarkdownPlatformColor
    /// `---`: primary → secondary gradient.
    let hrStart: MarkdownPlatformColor
    let hrEnd: MarkdownPlatformColor
    /// Footnote references and back links.
    let footnote: MarkdownPlatformColor

    init(_ theme: ThemeTokens) {
        text = Self.concrete(theme.text)
        textDim = Self.concrete(theme.textDim)
        primary = Self.concrete(theme.primary)
        secondary = Self.concrete(theme.secondary)
        accent = Self.concrete(theme.accent)
        border = Self.concrete(theme.border)
        separator = Self.concrete(theme.separator)
        overlayBackground = Self.concrete(theme.overlayBackground)
        background = Self.concrete(theme.background)
        warning = Self.concrete(theme.warning)
        error = Self.concrete(theme.error)
        info = Self.concrete(theme.info)
        dim = Self.mix(text, background, 0.82)
        marker = Self.mix(text, background, 0.48)
        rule = Self.mix(text, background, 0.13)
        codeBackground = Self.mix(text, background, 0.04)
        codeBorder = Self.mix(text, background, 0.10)
        let t = Self.rgbv(text), bg = Self.rgbv(background)
        func ink(_ c: RGB, _ min: Double = 4.5) -> MarkdownPlatformColor {
            Self.platform(OKLab.readable(c, ink: t, on: bg, minimum: min))
        }
        let p = Self.rgbv(primary), s2 = Self.rgbv(secondary), a = Self.rgbv(accent)
        let w = Self.rgbv(warning), e = Self.rgbv(error), inf = Self.rgbv(info)
        func pick(_ c: [RGB], _ min: Double = 4.5) -> MarkdownPlatformColor {
            Self.platform(OKLab.pick(c, ink: t, on: bg, minimum: min))
        }
        // A heading must not read as body text: when the theme's text is
        // itself tinted like primary (tokyo-day), fall to the next hue.
        func distinct(_ c: [RGB]) -> MarkdownPlatformColor {
            let made = c.map { OKLab.pick([$0], ink: t, on: bg, minimum: 4.5) }
            let tl = OKLab.lab(t)
            let far = made.first {
                let l = OKLab.lab($0)
                return hypot(hypot(l.l - tl.l, l.a - tl.a), l.b - tl.b) > 0.06
            }
            return Self.platform(far ?? made[0])
        }
        headings = [
            distinct([p, s2, a]),
            distinct([s2, p, a]),
            pick([a, inf, s2]),
            ink(OKLab.mix(p, t, 0.55)),
            ink(OKLab.mix(s2, t, 0.45)),
            ink(OKLab.mix(t, bg, 0.62), 3),
        ]
        link = pick([a, inf, p, s2])
        linkLine = link.withAlphaComponent(0.45)
        strong = ink(OKLab.mix(OKLab.mix(e, w, 0.5), t, 0.4))
        emphasis = ink(OKLab.mix(s2, t, 0.5))
        strikeText = ink(OKLab.mix(t, bg, 0.62), 3)
        strikeLine = error.withAlphaComponent(0.7)
        // Inks that sit on a tinted pill are checked against the pill.
        func inkOn(_ c: RGB, fill: RGB, alpha: Double) -> MarkdownPlatformColor {
            Self.platform(OKLab.readable(c, ink: t, on: OKLab.over(fill, alpha: alpha, on: bg), minimum: 4.5))
        }
        let markAlpha = theme.isDark ? 0.24 : 0.30
        markText = inkOn(OKLab.mix(w, t, 0.28), fill: w, alpha: markAlpha)
        markBackground = warning.withAlphaComponent(markAlpha)
        let codeAlpha = theme.isDark ? 0.13 : 0.10
        inlineCodeText = inkOn(OKLab.mix(p, t, 0.6), fill: p, alpha: codeAlpha)
        inlineBackground = primary.withAlphaComponent(codeAlpha)
        inlineCodeStroke = primary.withAlphaComponent(0.22)
        listMarker = ink(p, 3)
        checkBorder = Self.platform(OKLab.readable(p, ink: t, on: bg, minimum: 3)).withAlphaComponent(0.75)
        let tagAlpha = theme.isDark ? 0.14 : 0.12
        tagText = inkOn(OKLab.pick([a, inf, s2], ink: t, on: bg, minimum: 3), fill: a, alpha: tagAlpha)
        tagFill = accent.withAlphaComponent(tagAlpha)
        tableHeader = primary.withAlphaComponent(theme.isDark ? 0.12 : 0.10)
        tableZebra = text.withAlphaComponent(theme.isDark ? 0.035 : 0.04)
        hrStart = Self.platform(OKLab.mix(p, bg, 0.7))
        hrEnd = Self.platform(OKLab.mix(s2, bg, 0.7))
        footnote = ink(p)
        quoteBar = Self.platform(OKLab.readable(s2, ink: t, on: bg, minimum: 3))
        quoteFill = secondary.withAlphaComponent(theme.isDark ? 0.07 : 0.06)
    }

    /// One palette per theme, shared (the contrast search is not free).
    static func shared(_ theme: ThemeTokens) -> MarkdownPalette {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[theme] { return hit }
        let made = MarkdownPalette(theme)
        cache[theme] = made
        return made
    }

    private nonisolated(unsafe) static var cache: [ThemeTokens: MarkdownPalette] = [:]
    private static let cacheLock = NSLock()

    func heading(_ level: Int) -> MarkdownPlatformColor { headings[max(1, min(6, level)) - 1] }

    static func rgbv(_ c: MarkdownPlatformColor) -> RGB {
        let v = rgb(c)
        return RGB(Double(v.r), Double(v.g), Double(v.b))
    }

    static func platform(_ c: RGB) -> MarkdownPlatformColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        #else
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        #endif
    }

    /// Callout colour per kind (web `.md-callout[data-callout]`).
    func callout(_ kind: String) -> MarkdownPlatformColor {
        switch Self.calloutFamily(kind) {
        case .info: return info
        case .tip: return accent
        case .question: return secondary
        case .warning: return warning
        case .danger: return error
        case .quote: return textDim
        case .note: return primary
        }
    }

    /// Callout title ink: the kind's colour, made readable on the page.
    func calloutTitle(_ kind: String) -> MarkdownPlatformColor {
        let c = Self.rgbv(MarkdownPalette.mix(callout(kind), text, 0.85))
        return Self.platform(OKLab.readable(c, ink: Self.rgbv(text), on: Self.rgbv(background), minimum: 4.5))
    }

    enum CalloutFamily { case note, info, tip, question, warning, danger, quote }

    /// Obsidian's callout aliases folded into the seven colour families
    /// (same table as the web's `.md-callout[data-callout]`).
    static func calloutFamily(_ kind: String) -> CalloutFamily {
        switch kind.lowercased() {
        case "info", "todo", "abstract", "summary", "tldr": return .info
        case "tip", "hint", "important", "success", "check", "done": return .tip
        case "question", "help", "faq", "example": return .question
        case "warning", "caution", "attention": return .warning
        case "danger", "error", "failure", "fail", "missing", "bug": return .danger
        case "quote", "cite": return .quote
        default: return .note
        }
    }

    /// A plain component colour. A colour bridged straight from SwiftUI
    /// `Color` is a lazy wrapper: every `isEqual` (which attributed-string
    /// run coalescing does constantly) and every `withAlphaComponent`
    /// re-resolves it. Resolving once made fragment building ~10x faster.
    static func concrete(_ color: Color) -> MarkdownPlatformColor {
        #if canImport(AppKit)
        let bridged = NSColor(color)
        return bridged.usingColorSpace(.sRGB) ?? bridged
        #else
        return UIColor(cgColor: UIColor(color).cgColor)
        #endif
    }

    /// sRGB components (0…1) of an opaque colour.
    static func rgb(_ c: MarkdownPlatformColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if canImport(AppKit)
        let srgb = c.usingColorSpace(.sRGB) ?? c
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return (r, g, b, a)
    }

    /// CSS `color-mix(in srgb, a p, b)`.
    static func mix(_ a: MarkdownPlatformColor, _ b: MarkdownPlatformColor, _ p: CGFloat) -> MarkdownPlatformColor {
        let x = rgb(a), y = rgb(b)
        #if canImport(AppKit)
        return NSColor(srgbRed: x.r * p + y.r * (1 - p), green: x.g * p + y.g * (1 - p), blue: x.b * p + y.b * (1 - p), alpha: 1)
        #else
        return UIColor(red: x.r * p + y.r * (1 - p), green: x.g * p + y.g * (1 - p), blue: x.b * p + y.b * (1 - p), alpha: 1)
        #endif
    }

    /// WCAG relative luminance.
    static func luminance(_ c: MarkdownPlatformColor) -> CGFloat {
        let v = rgb(c)
        func lin(_ u: CGFloat) -> CGFloat { u <= 0.03928 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(v.r) + 0.7152 * lin(v.g) + 0.0722 * lin(v.b)
    }

    /// WCAG contrast ratio.
    static func contrast(_ a: MarkdownPlatformColor, _ b: MarkdownPlatformColor) -> CGFloat {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// Memoised font factory. Keyed by every input that changes the glyphs.
final class MarkdownFontBook {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let monospaced: Bool
    }

    let family: MarkdownFontFamily
    private var cache: [Key: MarkdownPlatformFont] = [:]

    init(family: MarkdownFontFamily) {
        self.family = family
    }

    func font(
        size: CGFloat,
        weight: MarkdownPlatformFont.Weight = .regular,
        italic: Bool = false,
        monospaced: Bool = false
    ) -> MarkdownPlatformFont {
        let key = Key(size: size, weight: weight.rawValue, italic: italic, monospaced: monospaced)
        if let hit = cache[key] { return hit }
        let made = Self.make(size: size, weight: weight, italic: italic, monospaced: monospaced || family == .monospace, serif: family == .serif)
        cache[key] = made
        return made
    }

    private static func make(
        size: CGFloat,
        weight: MarkdownPlatformFont.Weight,
        italic: Bool,
        monospaced: Bool,
        serif: Bool
    ) -> MarkdownPlatformFont {
        var font: MarkdownPlatformFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        if serif, !monospaced {
            // The web's serif stack starts with Iowan Old Style; fall
            // back to the system serif design (New York).
            if let iowan = Self.iowan(size: size, weight: weight) {
                font = iowan
            } else if let d = font.fontDescriptor.withDesign(.serif) {
                font = Self.font(from: d, size: size) ?? font
            }
        }
        if italic {
            #if canImport(AppKit)
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = Self.font(from: d, size: size) ?? font
            #else
            if let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = Self.font(from: d, size: size) ?? font
            }
            #endif
        }
        return font
    }

    private static func iowan(size: CGFloat, weight: MarkdownPlatformFont.Weight) -> MarkdownPlatformFont? {
        let name = weight.rawValue >= MarkdownPlatformFont.Weight.semibold.rawValue ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman"
        return MarkdownPlatformFont(name: name, size: size)
    }

    private static func font(from descriptor: MarkdownPlatformFontDescriptor, size: CGFloat) -> MarkdownPlatformFont? {
        #if canImport(AppKit)
        return NSFont(descriptor: descriptor, size: size)
        #else
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }
}
