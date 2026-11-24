import SwiftUI

/// Mermaid `base`-theme variables derived from lumi's theme tokens, so a
/// diagram reads as part of the note in every one of the 12 themes
/// instead of mermaid's stock light/dark palettes.
///
/// Mermaid's base theme derives most of its ~150 colours from a handful
/// of seeds via khroma, which wants opaque hex — so tints are blended
/// against the background here rather than passed as rgba.
public struct MermaidTheme: Hashable, Sendable {
    public let isDark: Bool
    /// `themeVariables` for `mermaid.initialize`, hex strings only.
    public let variables: [String: String]

    /// Stable cache-key component: same tokens → same fingerprint.
    public var fingerprint: String {
        (isDark ? "d|" : "l|") + variables.keys.sorted().map { "\($0)=\(variables[$0]!)" }.joined(separator: ";")
    }

    public init(tokens t: ThemeTokens) {
        let bg = RGB(t.background), text = RGB(t.text), dim = RGB(t.textDim)
        let primary = RGB(t.primary), secondary = RGB(t.secondary), accent = RGB(t.accent)
        let warning = RGB(t.warning), error = RGB(t.error), info = RGB(t.info), border = RGB(t.border)
        let tint: Double = t.isDark ? 0.22 : 0.16
        var v: [String: String] = [
            "darkMode": t.isDark ? "true" : "false",
            "background": bg.hex,
            "fontFamily": Self.fontFamily,
            "fontSize": "14px",
            "primaryColor": bg.mix(primary, tint).hex,
            "primaryBorderColor": primary.hex,
            "primaryTextColor": text.hex,
            "secondaryColor": bg.mix(secondary, tint).hex,
            "secondaryBorderColor": secondary.hex,
            "secondaryTextColor": text.hex,
            "tertiaryColor": bg.mix(accent, tint * 0.6).hex,
            "tertiaryBorderColor": accent.hex,
            "tertiaryTextColor": text.hex,
            "lineColor": text.mix(bg, 0.35).hex,
            "textColor": text.hex,
            "titleColor": text.hex,
            "mainBkg": bg.mix(primary, tint).hex,
            "nodeBorder": primary.hex,
            "clusterBkg": bg.mix(border, 0.35).hex,
            "clusterBorder": border.hex,
            "edgeLabelBackground": bg.hex,
            "noteBkgColor": bg.mix(warning, tint).hex,
            "noteTextColor": text.hex,
            "noteBorderColor": warning.hex,
            "actorBkg": bg.mix(primary, tint).hex,
            "actorBorder": primary.hex,
            "actorTextColor": text.hex,
            "actorLineColor": dim.hex,
            "signalColor": text.hex,
            "signalTextColor": text.hex,
            "labelBoxBkgColor": bg.mix(secondary, tint).hex,
            "labelBoxBorderColor": secondary.hex,
            "labelTextColor": text.hex,
            "loopTextColor": text.hex,
            "activationBkgColor": bg.mix(accent, tint).hex,
            "activationBorderColor": accent.hex,
            "sequenceNumberColor": bg.hex,
            "sectionBkgColor": bg.mix(primary, tint * 0.7).hex,
            "altSectionBkgColor": bg.hex,
            "sectionBkgColor2": bg.mix(secondary, tint * 0.7).hex,
            "taskBkgColor": bg.mix(primary, tint * 1.8).hex,
            "taskBorderColor": primary.hex,
            "taskTextColor": text.hex,
            "taskTextOutsideColor": text.hex,
            "taskTextLightColor": text.hex,
            "taskTextDarkColor": text.hex,
            "activeTaskBkgColor": bg.mix(accent, tint * 1.8).hex,
            "activeTaskBorderColor": accent.hex,
            "doneTaskBkgColor": bg.mix(dim, 0.35).hex,
            "doneTaskBorderColor": dim.hex,
            "critBkgColor": bg.mix(error, tint * 1.8).hex,
            "critBorderColor": error.hex,
            "todayLineColor": error.hex,
            "gridColor": border.hex,
            "errorBkgColor": bg.mix(error, tint).hex,
            "errorTextColor": error.hex,
            "pieTitleTextColor": text.hex,
            "pieSectionTextColor": t.isDark ? bg.hex : text.hex,
            "pieLegendTextColor": text.hex,
            "pieStrokeColor": bg.hex,
            "pieOuterStrokeColor": border.hex,
        ]
        // Categorical series (pie slices, git branches, journey actors,
        // mindmap / timeline sections) cycle the theme's accents.
        let series = [primary, secondary, accent, warning, info, error]
            + t.logoColors.map(RGB.init)
        for i in 0..<12 {
            let c = series[i % series.count]
            let shade = i < series.count ? 0.0 : 0.25
            v["pie\(i + 1)"] = c.mix(bg, shade).hex
            v["cScale\(i)"] = bg.mix(c, t.isDark ? 0.55 : 0.4).hex
            v["cScaleLabel\(i)"] = text.hex
            v["cScaleInv\(i)"] = c.hex
            v["cScalePeer\(i)"] = c.mix(bg, 0.3).hex
            if i < 8 {
                v["git\(i)"] = c.hex
                v["gitBranchLabel\(i)"] = bg.hex
            }
        }
        self.isDark = t.isDark
        self.variables = v
    }

    static let fontFamily =
        "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
}

/// sRGB triple resolved from a SwiftUI `Color` (themes are built from
/// sRGB hex, so this round-trips exactly).
struct RGB: Hashable, Sendable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        r = Double(resolved.red); g = Double(resolved.green); b = Double(resolved.blue)
    }

    /// Linear blend toward `other` by `t` (0 = self, 1 = other).
    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var hex: String {
        func c(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}
