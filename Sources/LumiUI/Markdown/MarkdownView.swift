import SwiftUI
import LumiKit
#if canImport(AppKit)
import AppKit
#endif

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

/// Lightweight-render flag for the three-column browser's preview pane.
/// When `true`, expensive WebView-based renderers (KaTeX block + paragraph,
/// Mermaid, YouTube/Vimeo embeds, inline video, PDF, embedded markdown)
/// collapse to a compact placeholder. Without this flag a fast `j/k` sweep
/// through a folder of math-heavy or media-heavy notes was spawning a
/// fresh WKWebView per matching block per selection — each one re-fetched
/// KaTeX / mermaid / etc. from the CDN. The opened-note view never sets
/// the flag, so full rendering still happens once the user commits to a
/// note. Off by default.
public struct MarkdownLiteKey: EnvironmentKey {
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
    /// See `MarkdownLiteKey`. Read by every heavy renderer (KaTeX block
    /// + paragraph, Mermaid, EmbedMedia, VideoMedia, PDFMedia,
    /// EmbeddedMarkdown) so they can opt out of WebView spawns inside a
    /// preview pass.
    var markdownLite: Bool {
        get { self[MarkdownLiteKey.self] }
        set { self[MarkdownLiteKey.self] = newValue }
    }
}

/// macOS cursor swap so paragraphs containing links visibly invite a
/// click. SwiftUI's Text + AttributedString `.link` doesn't trigger
/// `NSCursor.pointingHand` natively (the I-beam from
/// `.textSelection(.enabled)` wins). We attach the swap on the whole
/// paragraph: less precise than per-glyph hit-testing, but a single
/// `.onHover` is cheap and matches the typical lumi note shape (most
/// link-heavy paragraphs are bullets whose content is mostly the link).
/// iOS / iPadOS / visionOS keep the default cursor — touch UIs don't
/// have a hover state to react to.
extension View {
    @ViewBuilder
    func pointingHandIfContainsLink(_ inline: [InlineNode]) -> some View {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if InlineRenderer.containsLink(inline) {
            self.onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Unconditional pointing-hand on hover. Used for definitely-clickable
    /// affordances (task-list checkboxes, future toggle pills) where the
    /// element is always interactive, not "interactive only if it
    /// happens to contain a link".
    @ViewBuilder
    func pointingHandOnHover() -> some View {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        #else
        self
        #endif
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
            // Headings with inline math route through KaTeX so
            // expressions like `## $\Sigma_1$ form of HALT` actually
            // render the math glyph instead of falling back to raw
            // LaTeX in italic-code styling.
            if InlineRenderer.containsMath(inline) {
                KaTeXHeadingView(inline: inline, level: level)
                    .padding(.top, (level <= 2 ? 8 : 4) * scale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pointingHandIfContainsLink(inline)
            } else {
                Text(InlineRenderer.render(inline, theme: theme))
                    .font(headingFont(level))
                    .foregroundStyle(theme.text)
                    .padding(.top, (level <= 2 ? 8 : 4) * scale)
                    // Text inside an HStack (e.g. list items) negotiates its
                    // ideal one-line size with the parent, which truncates with
                    // ellipsis when the line overflows. fixedSize on the vertical
                    // axis forces wrapping; maxWidth makes the wrapped lines
                    // occupy the column instead of hugging their content.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .pointingHandIfContainsLink(inline)
            }

        case let .paragraph(inline):
            // Paragraphs that contain inline math route through the
            // KaTeX-aware WebView so the math glyphs sit on the same
            // baseline as the surrounding text. Pure-prose paragraphs
            // stay on the native Text path so most of the document
            // keeps its native selection / theme integration.
            if InlineRenderer.containsMath(inline) {
                KaTeXParagraphView(inline: inline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(InlineRenderer.render(inline, theme: theme))
                    .font(markdownBodyFont(size: 15 * scale, weight: .regular, family: fontFamily))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .lineSpacing(3 * scale)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pointingHandIfContainsLink(inline)
            }

        case let .codeBlock(language, code):
            // Fenced code blocks whose language label is `mermaid` get
            // rendered as a live diagram via WKWebView instead of as
            // syntax-highlighted source. Standard fences fall through
            // to CodeBlockView.
            if language?.lowercased() == "mermaid" {
                MermaidView(code: code)
            } else {
                CodeBlockView(language: language, code: code)
            }

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

        case let .mathBlock(latex):
            KaTeXBlockView(latex: latex)
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
        // Earlier version put the left accent bar in an HStack as a
        // RoundedRectangle(width: 3) with no explicit height. In an
        // HStack(.top), a Shape with one axis fixed and the other
        // unconstrained claims "fill" on the unconstrained axis — there
        // was no upper bound, so the bar (and the HStack) stretched
        // through the rest of the document, pushing every block after
        // the blockquote far off-screen. Switching to an overlay anchors
        // the bar's height to the content VStack instead.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
                    .opacity(0.82)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.accent.opacity(0.6))
                .frame(width: 3)
        }
        .background(
            theme.accent.opacity(0.04)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        )
    }
}

struct ListBlockView: View {
    let items: [ListItemContent]
    let ordered: Bool
    let start: Int
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    markerView(for: item, index: index)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            BlockView(block: block)
                        }
                    }
                }
            }
        }
    }

    /// Either a numeric/bullet marker (regular list) or a checkbox glyph
    /// (GitHub-style task list). Task-list markers carry pointing-hand
    /// cursor on macOS so the reader can tell they're interactive —
    /// even though click-to-toggle isn't wired yet, the affordance is
    /// in place for when it lands.
    @ViewBuilder
    private func markerView(for item: ListItemContent, index: Int) -> some View {
        if let cb = item.checkbox {
            Image(systemName: cb == .checked ? "checkmark.square.fill" : "square")
                .font(.body)
                .foregroundStyle(cb == .checked ? theme.accent : theme.textDim)
                .frame(minWidth: 18, alignment: .trailing)
                .pointingHandOnHover()
        } else {
            Text(textMarker(for: index))
                .font(.body.monospacedDigit())
                .foregroundStyle(theme.textDim)
                .frame(minWidth: 18, alignment: .trailing)
        }
    }

    private func textMarker(for index: Int) -> String {
        ordered ? "\(start + index)." : "•"
    }
}
