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

    public init(theme: ThemeTokens, scale: Double = 1.0, fontFamily: MarkdownFontFamily = .system) {
        self.theme = theme
        self.scale = scale
        self.fontFamily = fontFamily
    }

    var s: CGFloat { CGFloat(scale) }

    // MARK: Metrics (kept identical to the prior SwiftUI renderer)

    var bodySize: CGFloat { 15 * s }
    var codeSize: CGFloat { 13 * s }
    var bodyLineSpacing: CGFloat { 3 * s }
    /// Gap between top-level blocks (was the LazyVStack spacing).
    var blockGap: CGFloat { 14 * s }
    var listItemGap: CGFloat { 6 * s }
    var quoteGap: CGFloat { 8 * s }
    var listMarkerColumn: CGFloat { 28 * s }
    var listMarkerWidth: CGFloat { 18 * s }
    var quoteIndent: CGFloat { 16 * s }
    var quotePadding: CGFloat { 6 * s }
    var codePaddingH: CGFloat { 14 * s }
    var codePaddingV: CGFloat { 12 * s }
    var titleSize: CGFloat { 34 * s }

    static func headingBaseSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 30
        case 2: return 24
        case 3: return 19
        case 4: return 17
        case 5: return 15
        default: return 14
        }
    }

    func headingSize(_ level: Int) -> CGFloat { Self.headingBaseSize(level) * s }
    func headingSpacingBefore(_ level: Int) -> CGFloat { (level <= 2 ? 8 : 4) * s }
}

/// Theme colours resolved once per style into platform colours. Bridging
/// `Color` → `NSColor`/`UIColor` is not free; doing it per text run on a
/// 5k-line note showed up in profiles.
struct MarkdownPalette {
    let text: MarkdownPlatformColor
    let textDim: MarkdownPlatformColor
    let primary: MarkdownPlatformColor
    let accent: MarkdownPlatformColor
    let border: MarkdownPlatformColor
    let separator: MarkdownPlatformColor
    let overlayBackground: MarkdownPlatformColor
    let background: MarkdownPlatformColor

    init(_ theme: ThemeTokens) {
        text = Self.concrete(theme.text)
        textDim = Self.concrete(theme.textDim)
        primary = Self.concrete(theme.primary)
        accent = Self.concrete(theme.accent)
        border = Self.concrete(theme.border)
        separator = Self.concrete(theme.separator)
        overlayBackground = Self.concrete(theme.overlayBackground)
        background = Self.concrete(theme.background)
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
        if serif, !monospaced, let d = font.fontDescriptor.withDesign(.serif) {
            font = Self.font(from: d, size: size) ?? font
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

    private static func font(from descriptor: MarkdownPlatformFontDescriptor, size: CGFloat) -> MarkdownPlatformFont? {
        #if canImport(AppKit)
        return NSFont(descriptor: descriptor, size: size)
        #else
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }
}
