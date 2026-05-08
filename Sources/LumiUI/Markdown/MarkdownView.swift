import SwiftUI
import LumiKit

/// Top-level markdown renderer. Consumes a `MarkdownDocument` and lays out
/// blocks vertically. Links open via the system handler; media gets dispatched
/// to dedicated views (video player, PDF viewer, embed).
public struct MarkdownView: View {
    public let document: MarkdownDocument

    public init(_ document: MarkdownDocument) {
        self.document = document
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

    var body: some View {
        switch block {
        case let .heading(level, inline):
            Text(InlineRenderer.render(inline, theme: theme))
                .font(headingFont(level))
                .foregroundStyle(theme.text)
                .padding(.top, level <= 2 ? 8 : 4)

        case let .paragraph(inline):
            Text(InlineRenderer.render(inline, theme: theme))
                .font(.body)
                .foregroundStyle(theme.text)
                .textSelection(.enabled)

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
        switch level {
        case 1: return .system(size: 28, weight: .semibold)
        case 2: return .system(size: 22, weight: .semibold)
        case 3: return .system(size: 18, weight: .semibold)
        case 4: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
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
