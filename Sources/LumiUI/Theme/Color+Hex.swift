import SwiftUI

public extension Color {
    /// Construct a Color from a `#rrggbb` or `rrggbb` hex string. Falls back to
    /// black on malformed input rather than failing — themes are static and
    /// validated by tests, so a bad string is a programmer error worth seeing.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var raw: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&raw)
        let r = Double((raw >> 16) & 0xFF) / 255.0
        let g = Double((raw >> 8) & 0xFF) / 255.0
        let b = Double(raw & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
