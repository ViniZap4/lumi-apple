import SwiftUI
import LumiKit

/// DESIGN-LANGUAGE §2–5 for the Mac: one token source. Ramps are OKLab
/// mixes of the 15 theme inputs (the web's `color-mix(in oklch, …)`), so
/// every theme, light or dark, gets the same structure.
public struct LumiRamp: Hashable, Sendable {
    public let surfaceSunk: Color
    public let surface0: Color
    public let surface1: Color
    public let surface2: Color
    public let surface3: Color
    public let ink1: Color
    public let ink2: Color
    public let ink3: Color
    public let ink4: Color
    public let accent: Color
    public let accentInk: Color
    public let accentWash: Color
    public let accentSoft: Color
    public let accentLine: Color
    public let accentGlow: Color
    public let hairlineSoft: Color
    public let hairline: Color
    public let hairlineStrong: Color
    /// Shadow ink (black on dark, ink-tinted on light).
    public let shadow: Color
    public let shadowStrength: Double
    /// The 1 px top edge light of raised surfaces.
    public let edgeLight: Color
    public let isDark: Bool

    public init(_ t: ThemeTokens) {
        let text = RGB.of(t.text), bg = RGB.of(t.background), overlay = RGB.of(t.overlayBackground)
        let primary = RGB.of(t.primary), border = RGB.of(t.border)
        func c(_ v: RGB) -> Color { Color(.sRGB, red: v.r, green: v.g, blue: v.b) }
        surfaceSunk = c(OKLab.mix(overlay, bg, 0.55))
        surface0 = c(bg)
        if t.isDark {
            surface1 = c(OKLab.mix(text, bg, 0.035))
            surface2 = c(OKLab.mix(text, bg, 0.06))
            surface3 = c(OKLab.mix(text, bg, 0.09))
        } else {
            // Light themes raise towards overlayBg (lighter), §2.4.
            surface1 = c(OKLab.mix(overlay, bg, 0.4))
            surface2 = c(OKLab.mix(overlay, bg, 0.7))
            surface3 = c(OKLab.mix(overlay, bg, 0.95))
        }
        ink1 = c(text)
        ink2 = c(OKLab.mix(text, bg, 0.78))
        ink3 = c(OKLab.mix(text, bg, t.isDark ? 0.58 : 0.66))
        ink4 = c(OKLab.mix(text, bg, 0.36))
        accent = t.primary
        accentInk = c(OKLab.mix(primary, text, 0.82))
        accentWash = t.primary.opacity(0.09)
        accentSoft = t.primary.opacity(0.16)
        accentLine = t.primary.opacity(0.45)
        accentGlow = t.primary.opacity(0.34)
        hairlineSoft = c(border).opacity(0.36)
        hairline = c(border).opacity(0.62)
        hairlineStrong = c(border).opacity(0.9)
        shadow = t.isDark ? .black : Color(.sRGB, red: 40 / 255, green: 48 / 255, blue: 80 / 255)
        shadowStrength = t.isDark ? 1 : 0.45
        edgeLight = t.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.7)
        isDark = t.isDark
    }

    /// Vim mode colour (§6.7): normal primary, insert accent, visual
    /// secondary, replace error.
    public static func modeColor(_ mode: String, theme t: ThemeTokens) -> Color {
        switch mode.lowercased() {
        case let m where m.hasPrefix("insert"): return t.accent
        case let m where m.hasPrefix("visual") || m.hasPrefix("v-"): return t.secondary
        case let m where m.hasPrefix("replace"): return t.error
        default: return t.primary
        }
    }
}

public extension ThemeTokens {
    /// Derived ramps, cached per theme.
    var ramp: LumiRamp { LumiRampCache.ramp(self) }
}

enum LumiRampCache {
    private nonisolated(unsafe) static var cache: [ThemeTokens: LumiRamp] = [:]
    private static let lock = NSLock()

    static func ramp(_ t: ThemeTokens) -> LumiRamp {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[t] { return hit }
        let r = LumiRamp(t)
        cache[t] = r
        return r
    }
}

extension RGB {
    /// sRGB components of a SwiftUI colour (resolved once).
    static func of(_ color: Color) -> RGB {
        let v = MarkdownPalette.rgb(MarkdownPalette.concrete(color))
        return RGB(Double(v.r), Double(v.g), Double(v.b))
    }
}

/// Elevation levels 0–4 (§3): a tight contact shadow, a wide ambient one,
/// a hairline ring and the lit top edge.
public enum LumiElevation: Int, CaseIterable, Sendable {
    case flat = 0, raised, hovered, menu, floating

    /// (contact radius, contact y, contact opacity, ambient radius, ambient y, ambient opacity)
    var layers: (Double, Double, Double, Double, Double, Double) {
        switch self {
        case .flat: return (0, 0, 0, 0, 0, 0)
        case .raised: return (1, 1, 0.22, 6, 3, 0.14)
        case .hovered: return (1.5, 1, 0.26, 12, 6, 0.20)
        case .menu: return (2, 1, 0.30, 22, 12, 0.30)
        case .floating: return (3, 2, 0.34, 40, 22, 0.42)
        }
    }
}

/// Radii grow with the surface (§5).
public enum LumiRadius {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 12
    public static let xl: CGFloat = 16
}

/// 4 pt grid (§5): sp1 … sp7 = 4 8 12 16 24 32 48.
public enum LumiSpace {
    public static let sp1: CGFloat = 4
    public static let sp2: CGFloat = 8
    public static let sp3: CGFloat = 12
    public static let sp4: CGFloat = 16
    public static let sp5: CGFloat = 24
    public static let sp6: CGFloat = 32
    public static let sp7: CGFloat = 48
}

/// UI type scale (§4), never scaled by the prose setting.
public enum LumiType {
    public static let xxs: CGFloat = 11
    public static let xs: CGFloat = 12
    public static let sm: CGFloat = 13
    public static let md: CGFloat = 14
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 28
    public static let xxxl: CGFloat = 40
    /// Tracking in em.
    public static let trackingUI: CGFloat = -0.006
    public static let trackingTight: CGFloat = -0.026
    public static let trackingCaps: CGFloat = 0.08

    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

public extension View {
    /// Raised surface: layered shadow + hairline ring + top edge light.
    func lumiElevation(_ level: LumiElevation, radius: CGFloat = LumiRadius.md, ramp: LumiRamp) -> some View {
        let l = level.layers
        let k = ramp.shadowStrength
        return self
            .overlay {
                if level != .flat {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(ramp.hairlineSoft, lineWidth: 1)
                    // The lit top edge: a 1 px highlight fading down.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [ramp.edgeLight, .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .shadow(color: ramp.shadow.opacity(l.2 * k), radius: l.0, y: l.1)
            .shadow(color: ramp.shadow.opacity(l.5 * k), radius: l.3, y: l.4)
    }

    /// Glass, only for surfaces that float over content (§3): material +
    /// theme tint (denser on light themes) + elevation 4 + edge light +
    /// a faint accent wash on the top edge.
    func lumiGlass(theme: ThemeTokens, radius: CGFloat = LumiRadius.xl, level: LumiElevation = .floating, accentEdge: Bool = true) -> some View {
        let ramp = theme.ramp
        return self
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.overlayBackground.opacity(theme.isDark ? 0.72 : 0.84))
                    if accentEdge {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [ramp.accentWash, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .lumiElevation(level, radius: radius, ramp: ramp)
    }
}
