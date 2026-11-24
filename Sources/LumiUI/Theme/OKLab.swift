import Foundation

/// Perceptual colour maths shared by every derived token (DESIGN-LANGUAGE
/// §2.2: ramps are `color-mix(in oklch, …)` on the web). Plain sRGB
/// tuples, no platform colour types, so it is cheap and unit-testable.
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

public enum OKLab {
    public struct Lab: Hashable, Sendable {
        public var l: Double
        public var a: Double
        public var b: Double
    }

    static func lin(_ u: Double) -> Double { u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4) }
    static func gam(_ u: Double) -> Double {
        let v = max(0, min(1, u))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    public static func lab(_ c: RGB) -> Lab {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    public static func rgb(_ p: Lab) -> RGB {
        let l = pow(p.l + 0.3963377774 * p.a + 0.2158037573 * p.b, 3)
        let m = pow(p.l - 0.1055613458 * p.a - 0.0638541728 * p.b, 3)
        let s = pow(p.l - 0.0894841775 * p.a - 1.2914855480 * p.b, 3)
        return RGB(gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// CSS `color-mix(in oklab, a p, b)`: `p` of `a`.
    public static func mix(_ a: RGB, _ b: RGB, _ p: Double) -> RGB {
        let x = lab(a), y = lab(b)
        return rgb(Lab(l: x.l * p + y.l * (1 - p), a: x.a * p + y.a * (1 - p), b: x.b * p + y.b * (1 - p)))
    }

    /// WCAG relative luminance.
    public static func luminance(_ c: RGB) -> Double {
        0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The first candidate that is already close to legible (≥ 80% of
    /// the floor), else the most contrasting one, made readable. Keeps a
    /// hue family where a theme's preferred colour is too light (e.g. a
    /// pastel accent on a light theme).
    public static func pick(_ candidates: [RGB], ink: RGB, on background: RGB, minimum: Double) -> RGB {
        let chosen = candidates.first { contrast($0, background) >= 0.8 * minimum }
            ?? candidates.max { contrast($0, background) < contrast($1, background) }
            ?? ink
        return readable(chosen, ink: ink, on: background, minimum: minimum)
    }

    /// `c` with its OKLab lightness moved (darker on a light page,
    /// lighter on a dark one) just far enough to reach `minimum` contrast
    /// on `background`. Hue and chroma stay, so a ramp stays a ramp even
    /// when the theme's text is itself tinted. `ink` is the last resort
    /// when even the extreme lightness is not enough.
    public static func readable(_ c: RGB, ink: RGB, on background: RGB, minimum: Double) -> RGB {
        if contrast(c, background) >= minimum { return c }
        let lab = lab(c)
        let target = luminance(background) > 0.18 ? 0.0 : 1.0
        func at(_ t: Double) -> RGB {
            rgb(Lab(l: lab.l + (target - lab.l) * t, a: lab.a * (1 - 0.35 * t), b: lab.b * (1 - 0.35 * t)))
        }
        guard contrast(at(1), background) >= minimum else { return ink }
        var lo = 0.0, hi = 1.0
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            if contrast(at(mid), background) >= minimum { hi = mid } else { lo = mid }
        }
        return at(hi)
    }

    /// Alpha composite of `fill` at `alpha` over `background` (sRGB).
    public static func over(_ fill: RGB, alpha: Double, on background: RGB) -> RGB {
        RGB(fill.r * alpha + background.r * (1 - alpha), fill.g * alpha + background.g * (1 - alpha), fill.b * alpha + background.b * (1 - alpha))
    }
}
