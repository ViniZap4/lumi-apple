import SwiftUI
import LumiKit

/// Scale factor applied to all markdown typography. The read pane injects
/// this from `preferences.readingScale` so users can resize on the fly. The
/// default 1.0 matches the prior hard-coded sizes.
public struct MarkdownScaleKey: EnvironmentKey {
    public static let defaultValue: Double = 1.0
}

/// Controls the per-block staggered fade when a markdown document
/// mounts. Off → all blocks land instantly (no animation transactions
/// kicked off). On → each block fades + slides up with a small delay
/// based on its index, capped so very long notes don't take seconds to
/// settle.
public struct MarkdownStaggerKey: EnvironmentKey {
    public static let defaultValue: Bool = false
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
    var markdownStagger: Bool {
        get { self[MarkdownStaggerKey.self] }
        set { self[MarkdownStaggerKey.self] = newValue }
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
    /// Where this document's block indices sit in the surrounding
    /// stagger cascade. Lets a host (e.g. a reader with its own header
    /// items) reserve the first N indices and have the body continue
    /// the cascade smoothly.
    public let indexOffset: Int
    @Environment(\.markdownScale) private var scale

    public init(_ document: MarkdownDocument, indexOffset: Int = 0) {
        self.document = document
        self.indexOffset = indexOffset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                StaggeredBlock(index: index + indexOffset) {
                    BlockView(block: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cascade pacing for `StaggeredBlock`. 14 blocks fade in within ~0.5s;
/// anything past the cap lands at the same time so long documents don't
/// take seconds to settle.
private enum StaggerCascade {
    static let stepDelay: Double = 0.035
    static let delayCap: Double = 0.45

    static func delay(for index: Int) -> Double {
        min(Double(index) * stepDelay, delayCap)
    }
}

/// Per-block wrapper that fades + slides into place when the markdown
/// document mounts. Cascade pacing comes from `StaggerCascade`. When
/// `markdownStagger` is off we short-circuit to the bare content view
/// — no @State, no .onAppear, no animation transactions — so a
/// 500-block preview doesn't fire 500 closures.
public struct StaggeredBlock<Content: View>: View {
    let index: Int
    @ViewBuilder let content: () -> Content

    @Environment(\.markdownStagger) private var stagger

    public init(index: Int, @ViewBuilder content: @escaping () -> Content) {
        self.index = index
        self.content = content
    }

    public var body: some View {
        if stagger {
            AnimatedBlock(index: index, content: content)
        } else {
            content()
        }
    }
}

private struct AnimatedBlock<Content: View>: View {
    let index: Int
    @ViewBuilder let content: () -> Content
    @State private var visible = false

    var body: some View {
        content()
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .onAppear {
                let delay = StaggerCascade.delay(for: index)
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.30).delay(delay)) {
                        visible = true
                    }
                }
            }
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
    @Environment(\.markdownScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 13 * scale, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.overlayBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border.opacity(0.4), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 10, design: .monospaced).weight(.medium))
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(theme.background.opacity(0.7))
                    )
                    .padding(8)
            }
        }
    }
}

struct BlockQuoteView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.accent.opacity(0.6))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                        .opacity(0.82)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.leading, 4)
        .background(
            theme.accent.opacity(0.04)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        )
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
