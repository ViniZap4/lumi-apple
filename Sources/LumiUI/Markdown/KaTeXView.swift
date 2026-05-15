import SwiftUI
import LumiKit

/// Display-style math (`$$ … $$`). Asks `MathRenderService` for the
/// rendered HTML (once per `(latex, theme)`-keyed cache entry, served
/// from a single persistent KaTeX-loaded WebView) and shows the result
/// in a script-less `StaticContentWebView`. The first render of a
/// brand-new expression goes ~5–10 ms in the service; subsequent
/// mounts of the same expression hit the in-memory LRU and skip the
/// WebView entirely.
public struct KaTeXBlockView: View {
    public let latex: String
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite
    @State private var rendered: MathRenderService.Rendered?
    @State private var failed: Bool = false

    public init(latex: String) {
        self.latex = latex
    }

    public var body: some View {
        Group {
            if lite {
                litePlaceholder
            } else if let rendered {
                StaticContentWebView(
                    payload: rendered.payload,
                    role: .mathBlock,
                    intrinsicHeight: clampHeight(rendered.intrinsicHeight)
                )
                .frame(maxWidth: .infinity)
            } else if failed {
                rawFallback
            } else {
                // Pre-render placeholder. Use a one-line-ish height so
                // the layout doesn't jump when the rendered content
                // lands an instant later.
                Color.clear.frame(height: 32)
            }
        }
        .task(id: latex) {
            await renderIfNeeded()
        }
    }

    private func renderIfNeeded() async {
        guard !lite else { return }
        if let result = await MathRenderService.shared.render(.mathBlock(latex: latex)) {
            rendered = result
            failed = false
        } else {
            failed = true
        }
    }

    private func clampHeight(_ h: CGFloat) -> CGFloat {
        max(24, min(h, 1600))
    }

    @ViewBuilder
    private var litePlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "sum")
                .font(.system(.caption))
                .foregroundStyle(theme.accent)
            Text(latex)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(theme.overlayBackground.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rawFallback: some View {
        Text(latex)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(theme.warning)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.overlayBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Paragraph that mixes prose with inline math. The input
/// `[InlineNode]` tree gets HTML-encoded once at view-init time
/// (`paragraphHTML(from:)`), then handed to the render service.
/// Repeated mounts of the same paragraph share a cache entry; the
/// display WebView never runs scripts.
public struct KaTeXParagraphView: View {
    public let inline: [InlineNode]
    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownLite) private var lite
    @State private var rendered: MathRenderService.Rendered?
    @State private var failed: Bool = false

    public init(inline: [InlineNode]) {
        self.inline = inline
    }

    /// HTML for this paragraph's inline tree. Recomputed per body
    /// evaluation; cheap, and lets us avoid stashing a derived value in
    /// `@State`.
    private var html: String {
        paragraphHTML(from: inline)
    }

    public var body: some View {
        Group {
            if lite {
                litePlaceholder
            } else if let rendered {
                StaticContentWebView(
                    payload: rendered.payload,
                    role: .mathParagraph,
                    intrinsicHeight: clampHeight(rendered.intrinsicHeight)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                rawFallback
            } else {
                Color.clear.frame(height: 32)
            }
        }
        .task(id: renderTaskID) {
            await renderIfNeeded()
        }
    }

    private var renderTaskID: String {
        // Re-fire the .task when either the paragraph content or the
        // typography scale changes — both are cache-key inputs.
        "\(html)|\(scale)"
    }

    private func renderIfNeeded() async {
        guard !lite else { return }
        let fontSize = 15 * scale
        if let result = await MathRenderService.shared.render(
            .mathParagraph(html: html, fontSize: fontSize)
        ) {
            rendered = result
            failed = false
        } else {
            failed = true
        }
    }

    private func clampHeight(_ h: CGFloat) -> CGFloat {
        max(16, min(h, 4000))
    }

    @ViewBuilder
    private var litePlaceholder: some View {
        // Fast preview-mode fallback — render natively with raw LaTeX
        // shown in code styling. Cheap, no WebView spawn.
        Text(InlineRenderer.render(inline, theme: theme))
            .font(.system(size: 15 * scale, weight: .regular))
            .foregroundStyle(theme.text)
            .lineSpacing(3 * scale)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rawFallback: some View {
        // Render fell over (bad LaTeX / dead WebView). Fall back to the
        // native inline renderer so the user still sees their content,
        // just without rendered math glyphs.
        Text(InlineRenderer.render(inline, theme: theme))
            .font(.system(size: 15 * scale, weight: .regular))
            .foregroundStyle(theme.text)
            .lineSpacing(3 * scale)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Heading row (h1…h6) whose inline content contains math. Same shape
/// as `KaTeXParagraphView` but with heading typography (level-derived
/// font size + semibold weight + tighter line-height).
public struct KaTeXHeadingView: View {
    public let inline: [InlineNode]
    public let level: Int
    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownLite) private var lite
    @State private var rendered: MathRenderService.Rendered?
    @State private var failed: Bool = false

    public init(inline: [InlineNode], level: Int) {
        self.inline = inline
        self.level = level
    }

    private var html: String {
        paragraphHTML(from: inline)
    }

    /// Heading font size — kept in sync with `BlockView.headingFont`
    /// so a heading-with-math and a heading-without line up side by
    /// side.
    private var headingFontSize: CGFloat {
        switch level {
        case 1: return 30
        case 2: return 24
        case 3: return 19
        case 4: return 17
        case 5: return 15
        default: return 14
        }
    }

    public var body: some View {
        Group {
            if lite {
                litePlaceholder
            } else if let rendered {
                StaticContentWebView(
                    payload: rendered.payload,
                    role: .mathHeading,
                    intrinsicHeight: clampHeight(rendered.intrinsicHeight)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                rawFallback
            } else {
                Color.clear.frame(height: headingFontSize * scale + 4)
            }
        }
        .task(id: renderTaskID) {
            await renderIfNeeded()
        }
    }

    private var renderTaskID: String {
        "\(html)|\(level)|\(scale)"
    }

    private func renderIfNeeded() async {
        guard !lite else { return }
        let fontSize = headingFontSize * scale
        if let result = await MathRenderService.shared.render(
            .mathHeading(html: html, fontSize: fontSize, fontWeight: 600)
        ) {
            rendered = result
            failed = false
        } else {
            failed = true
        }
    }

    private func clampHeight(_ h: CGFloat) -> CGFloat {
        max(16, min(h, 2000))
    }

    @ViewBuilder
    private var litePlaceholder: some View {
        Text(InlineRenderer.render(inline, theme: theme))
            .font(.system(size: headingFontSize * scale, weight: .semibold))
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rawFallback: some View {
        Text(InlineRenderer.render(inline, theme: theme))
            .font(.system(size: headingFontSize * scale, weight: .semibold))
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Inline HTML emission (shared with the render service)

/// Convert a paragraph's inline tree into HTML for the math render
/// service. Bold / italic / strike map to the matching HTML elements;
/// inline math becomes a `<span class="math math-inline">` carrying
/// the LaTeX source as a `data-latex` attribute; block math (rare
/// inside a paragraph but possible) becomes `<span class="math math-display">`.
///
/// The service's JS walks every `span.math` in the input HTML and
/// calls `katex.render` on it in place — see
/// `MathRenderService.rendererPageHTML`.
public func paragraphHTML(from nodes: [InlineNode]) -> String {
    var out = String()
    for node in nodes {
        renderInlineHTML(node, into: &out)
    }
    return out
}

private func renderInlineHTML(_ node: InlineNode, into out: inout String) {
    switch node {
    case let .text(s):
        out.append(escapeHTML(s))
    case let .strong(children):
        out.append("<strong>")
        for c in children { renderInlineHTML(c, into: &out) }
        out.append("</strong>")
    case let .emphasis(children):
        out.append("<em>")
        for c in children { renderInlineHTML(c, into: &out) }
        out.append("</em>")
    case let .strikethrough(children):
        out.append("<s>")
        for c in children { renderInlineHTML(c, into: &out) }
        out.append("</s>")
    case let .code(s):
        out.append("<code>")
        out.append(escapeHTML(s))
        out.append("</code>")
    case let .link(destination, children):
        out.append("<a href=\"")
        out.append(escapeHTML(destination))
        out.append("\">")
        for c in children { renderInlineHTML(c, into: &out) }
        out.append("</a>")
    case let .image(_, alt):
        out.append("<span class=\"img-alt\">")
        out.append(escapeHTML(alt.isEmpty ? "[image]" : alt))
        out.append("</span>")
    case let .math(latex, display):
        let cls = display == .block ? "math math-display" : "math math-inline"
        out.append("<span class=\"")
        out.append(cls)
        out.append("\" data-latex=\"")
        out.append(escapeHTML(latex))
        out.append("\"></span>")
    case .lineBreak:
        out.append("<br>")
    case .softBreak:
        out.append(" ")
    }
}

private func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
