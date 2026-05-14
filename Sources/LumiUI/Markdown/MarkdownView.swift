import SwiftUI
import LumiKit

/// Scale factor applied to all markdown typography. The read pane injects
/// this from `preferences.readingScale` so users can resize on the fly. The
/// default 1.0 matches the prior hard-coded sizes.
public struct MarkdownScaleKey: EnvironmentKey {
    public static let defaultValue: Double = 1.0
}

/// Body-font choice for markdown rendering. Default = system sans; the
/// read pane injects this from `preferences.readingFontFamily`.
public enum MarkdownFontFamily: Sendable {
    case system, serif, monospace
}

public struct MarkdownFontFamilyKey: EnvironmentKey {
    public static let defaultValue: MarkdownFontFamily = .system
}

public extension EnvironmentValues {
    var markdownScale: Double {
        get { self[MarkdownScaleKey.self] }
        set { self[MarkdownScaleKey.self] = newValue }
    }
    var markdownFontFamily: MarkdownFontFamily {
        get { self[MarkdownFontFamilyKey.self] }
        set { self[MarkdownFontFamilyKey.self] = newValue }
    }
}

/// Resolves a Font for the active family + size. Headings stay on the
/// chosen family too — keeps reading visually coherent.
func markdownBodyFont(size: CGFloat, weight: Font.Weight, family: MarkdownFontFamily) -> Font {
    switch family {
    case .system: return .system(size: size, weight: weight)
    case .serif: return .system(size: size, weight: weight, design: .serif)
    case .monospace: return .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Top-level markdown renderer. Consumes a `MarkdownDocument` and lays out
/// blocks vertically. Links open via the system handler; media gets dispatched
/// to dedicated views (video player, PDF viewer, embed).
public struct MarkdownView: View {
    public let document: MarkdownDocument
    @Environment(\.markdownScale) private var scale

    public init(_ document: MarkdownDocument) {
        self.document = document
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BlockView: View {
    let block: MarkdownBlock
    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownFontFamily) private var fontFamily

    var body: some View {
        switch block {
        case let .heading(level, inline):
            Text(InlineRenderer.render(inline, theme: theme))
                .font(headingFont(level))
                .foregroundStyle(theme.text)
                .padding(.top, (level <= 2 ? 8 : 4) * scale)

        case let .paragraph(inline):
            Text(InlineRenderer.render(inline, theme: theme))
                .font(markdownBodyFont(size: 15 * scale, weight: .regular, family: fontFamily))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .lineSpacing(3 * scale)

        case let .codeBlock(language, code):
            CodeBlockView(language: language, code: code)

        case let .blockQuote(blocks):
            BlockQuoteView(blocks: blocks)

        case let .unorderedList(items):
            ListBlockView(items: items, ordered: false, start: 1)

        case let .orderedList(start, items):
            ListBlockView(items: items, ordered: true, start: start)

        case .thematicBreak:
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .padding(.vertical, 8)

        case let .media(ref):
            MediaView(reference: ref)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let base: CGFloat
        switch level {
        case 1: base = 30
        case 2: base = 24
        case 3: base = 19
        case 4: base = 17
        case 5: base = 15
        default: base = 14
        }
        return markdownBodyFont(size: base * scale, weight: .semibold, family: fontFamily)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.overlayBackground)
        )
        .overlay(alignment: .topTrailing) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }
}

struct BlockQuoteView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                        .opacity(0.85)
                }
            }
        }
        .padding(.leading, 4)
    }
}

struct ListBlockView: View {
    let items: [[MarkdownBlock]]
    let ordered: Bool
    let start: Int
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(marker(for: index))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(theme.textDim)
                        .frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            BlockView(block: block)
                        }
                    }
                }
            }
        }
    }

    private func marker(for index: Int) -> String {
        ordered ? "\(start + index)." : "•"
    }
}
