import SwiftUI
import LumiUI

/// One type system for the shell chrome: monospace for UI (yazi
/// aesthetic), proportional/configurable for prose (the reader).
enum ShellFont {
    static let row = Font.system(size: 12.5, design: .monospaced)
    static let rowBold = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let chrome = Font.system(size: 11.5, design: .monospaced)
    static let chromeBold = Font.system(size: 11.5, weight: .semibold, design: .monospaced)
    static let small = Font.system(size: 10.5, design: .monospaced)
    static let mode = Font.system(size: 10.5, weight: .bold, design: .monospaced)
    static let prompt = Font.system(size: 13, design: .monospaced)
    static let palette = Font.system(size: 15, design: .monospaced)
}

enum ShellMetrics {
    static let rowHeight: CGFloat = 26
    static let topLineHeight: CGFloat = 34
    static let statusLineHeight: CGFloat = 24
    static let legendHeight: CGFloat = 22
    static let noteBarHeight: CGFloat = 40
    #if os(macOS)
    /// Room for the traffic lights when the sidebar is hidden.
    static let trafficLightInset: CGFloat = 78
    #else
    static let trafficLightInset: CGFloat = 0
    #endif
}

/// Raised surface for floating chrome (palette, help, cards): the theme
/// background lifted toward white — more in light themes, a touch in
/// dark ones — so it separates from the scrim without a new colour.
struct ElevatedSurface: View {
    var radius: CGFloat = 14
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(theme.background)
            .overlay(shape.fill(Color.white.opacity(theme.isDark ? 0.035 : 0.42)))
            .overlay(shape.stroke(theme.border.opacity(theme.isDark ? 0.9 : 0.55), lineWidth: 0.5))
            .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 34, y: 14)
            .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: 3, y: 1)
    }
}

/// Hairline in the theme's border colour.
struct Hairline: View {
    var vertical = false
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.border.opacity(0.7))
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

/// `⌘K` style key cap, flat (no pill).
struct KeyCap: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellFont.small)
            .foregroundStyle(theme.textDim)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).stroke(theme.border, lineWidth: 0.5))
            .fixedSize()
    }
}

extension View {
    /// Editor column capped to a readable measure, centred (web
    /// `readableWidth`).
    func readableEditorWidth(_ capped: Bool = true) -> some View {
        frame(maxWidth: capped ? 880 : .infinity).frame(maxWidth: .infinity)
    }
}
