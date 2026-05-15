import SwiftUI
import WebKit
import LumiKit

/// Display-style math (`$$ … $$`) rendered via KaTeX. Mirrors `MermaidView`'s
/// auto-height approach: KaTeX renders inside a WKWebView, JS posts the
/// final body height back, the SwiftUI host snaps to that height.
public struct KaTeXBlockView: View {
    public let latex: String
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite
    @State private var measuredHeight: CGFloat = 64

    public init(latex: String) {
        self.latex = latex
    }

    public var body: some View {
        if lite {
            // Preview-pane fallback — single Text glyph + truncated
            // LaTeX so the user can still tell the block contains math
            // without paying the cost of a fresh WKWebView + KaTeX CDN
            // fetch on every j/k cursor sweep.
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
        } else {
            KaTeXWebRepresentable(
                mode: .block(latex: latex),
                isDark: theme.isDark,
                textHex: theme.textHex,
                mutedHex: theme.textDimHex,
                primaryHex: theme.primaryHex,
                onHeight: { h in
                    if h > 1 { measuredHeight = min(max(h, 24), 1600) }
                }
            )
            .frame(height: measuredHeight)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Paragraph that mixes prose with inline math. Rendered as a single
/// KaTeX-aware WebView so the math expressions sit on the same baseline as
/// their surrounding text — something a SwiftUI Text view can't do natively
/// (it has no way to embed a per-glyph rendered span from an external
/// engine). Pure-text paragraphs keep going through native SwiftUI; this
/// view is only invoked when the parser detected at least one inline math
/// node in the paragraph.
public struct KaTeXParagraphView: View {
    public let inline: [InlineNode]
    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownLite) private var lite
    @State private var measuredHeight: CGFloat = 36

    public init(inline: [InlineNode]) {
        self.inline = inline
    }

    public var body: some View {
        if lite {
            // Preview-pane fallback — render the paragraph natively with
            // raw LaTeX shown in code styling (via InlineRenderer's
            // `.math` fallback). Much cheaper than spawning a WKWebView
            // per paragraph while the user is just glancing at notes.
            Text(InlineRenderer.render(inline, theme: theme))
                .font(.system(size: 15 * scale, weight: .regular))
                .foregroundStyle(theme.text)
                .lineSpacing(3 * scale)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            KaTeXWebRepresentable(
                mode: .paragraph(
                    html: paragraphHTML(from: inline),
                    fontSize: 15 * scale
                ),
                isDark: theme.isDark,
                textHex: theme.textHex,
                mutedHex: theme.textDimHex,
                primaryHex: theme.primaryHex,
                onHeight: { h in
                    if h > 1 { measuredHeight = min(max(h, 16), 4000) }
                }
            )
            .frame(height: measuredHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Heading (h1…h6) row whose inline content contains math. Renders the
/// heading text + math expressions through the same KaTeX WebView the
/// paragraph view uses, but with heading typography (level-dependent
/// font size + semibold weight + tighter line-height) so `## $\Sigma_1$
/// form of HALT` reads like a real heading rather than raw LaTeX next
/// to prose. `level` is the markdown heading depth (1…6); the renderer
/// picks the matching font size from the same scale `BlockView.heading`
/// uses for non-math headings so the two look identical to the eye.
public struct KaTeXHeadingView: View {
    public let inline: [InlineNode]
    public let level: Int
    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownLite) private var lite
    @State private var measuredHeight: CGFloat = 36

    public init(inline: [InlineNode], level: Int) {
        self.inline = inline
        self.level = level
    }

    public var body: some View {
        // Heading font sizes — kept in sync with `BlockView.headingFont`
        // in MarkdownView so a heading-with-math and a heading-without
        // line up next to each other on the page.
        let size: CGFloat = {
            switch level {
            case 1: return 30
            case 2: return 24
            case 3: return 19
            case 4: return 17
            case 5: return 15
            default: return 14
            }
        }()
        if lite {
            // Preview pane fallback. Render natively with
            // `InlineRenderer` (math falls back to italic-code styling)
            // so the preview stays cheap.
            Text(InlineRenderer.render(inline, theme: theme))
                .font(.system(size: size * scale, weight: .semibold))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            KaTeXWebRepresentable(
                mode: .heading(
                    html: paragraphHTML(from: inline),
                    fontSize: size * scale,
                    fontWeight: 600
                ),
                isDark: theme.isDark,
                textHex: theme.textHex,
                mutedHex: theme.textDimHex,
                primaryHex: theme.primaryHex,
                onHeight: { h in
                    if h > 1 { measuredHeight = min(max(h, 16), 2000) }
                }
            )
            .frame(height: measuredHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - HTML emission

/// Render-mode discriminator. Block mode renders a single `katex.render`
/// call with displayMode=true. Paragraph mode emits arbitrary HTML
/// surrounded by `<span class="math-inline">…</span>` / `<span class="math-block">…</span>`
/// and lets `renderMathInElement` auto-find and render every math node.
fileprivate enum KaTeXRenderMode {
    case block(latex: String)
    case paragraph(html: String, fontSize: CGFloat)
    /// A heading row with inline math (e.g. `## $\Sigma_1$ form of HALT`).
    /// Rendered as a `<p>` element with the heading's typography (size +
    /// weight + tighter line-height) so the math glyphs sit on the same
    /// baseline as the surrounding heading text.
    case heading(html: String, fontSize: CGFloat, fontWeight: Int)
}

/// Shared JS that walks every `<span class="math">` in the rendered body
/// and asks KaTeX to render each one in-place. Used by both paragraph
/// and heading modes — they only differ in the wrapping `<p>` styling,
/// not in the math-rendering step.
fileprivate let spanWalkingMathKickoff = """
  try {
    document.querySelectorAll('span.math').forEach(function(el) {
      const latex = el.getAttribute('data-latex') || '';
      const isBlock = el.classList.contains('math-display');
      katex.render(latex, el, { displayMode: isBlock, throwOnError: false, output: 'html' });
    });
  } catch (e) {
    // Leave the spans empty if KaTeX failed; raw LaTeX falls back to
    // nothing rather than breaking the paragraph / heading render.
  }
"""

/// HTML-escape so plain text doesn't break the surrounding template.
private func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// JSON-string-escape so a LaTeX source can be safely inlined into a JS
/// string literal. KaTeX expects raw LaTeX (no HTML escapes inside the
/// string).
private func jsString(_ s: String) -> String {
    var out = "\""
    for ch in s {
        switch ch {
        case "\\": out.append("\\\\")
        case "\"": out.append("\\\"")
        case "\n": out.append("\\n")
        case "\r": out.append("\\r")
        case "\t": out.append("\\t")
        default:
            let scalar = ch.unicodeScalars.first!.value
            if scalar < 0x20 {
                out.append(String(format: "\\u%04x", scalar))
            } else {
                out.append(ch)
            }
        }
    }
    out.append("\"")
    return out
}

/// Convert a paragraph's `[InlineNode]` into HTML for KaTeX paragraph
/// rendering. Bold / italic / strike map to the matching HTML elements.
/// Code spans stay monospaced. Inline math becomes a `<span class="math">`
/// span carrying its LaTeX source; block math (rare inside a paragraph
/// but possible) becomes a `<span class="math math-display">`.
fileprivate func paragraphHTML(from nodes: [InlineNode]) -> String {
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

/// KaTeX-loading HTML. Pulls katex.css + katex.js + the auto-render
/// extension from jsdelivr. Reports body height back via
/// `webkit.messageHandlers.katexHeight` once rendering settles.
fileprivate func katexHTML(
    mode: KaTeXRenderMode,
    isDark: Bool,
    textHex: String,
    mutedHex: String,
    primaryHex: String
) -> String {
    let bg = "transparent"
    // KaTeX picks colors from CSS; we set color/background on body so
    // any non-math text in paragraph mode picks up the lumi theme.
    // Links pick `primary` rather than the body text color so the math
    // paragraphs match the native SwiftUI Text link styling everywhere
    // else (under .link in InlineRenderer the foreground is theme.primary).
    let cssVars = """
      html, body { margin: 0; padding: 0; background: \(bg); color: \(textHex);
                   font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                   -webkit-font-smoothing: antialiased; }
      a { color: \(primaryHex); text-decoration: underline;
          text-decoration-color: \(primaryHex); text-underline-offset: 2px; }
      a:hover { cursor: pointer; }
      code { background: rgba(127,127,127,0.16); padding: 1px 4px; border-radius: 4px;
             font-family: ui-monospace, SF Mono, Menlo, monospace; font-size: 0.9em; }
      .img-alt { color: \(mutedHex); }
      .katex { font-size: 1.05em; }
      .katex-display { margin: 0; }
      """

    // Bundled assets: resolve against `BundledWebAssets.baseURL` passed
    // as `loadHTMLString(_:baseURL:)`'s baseURL. KaTeX's CSS in turn
    // references its `fonts/KaTeX_*.woff2` via relative `url(...)`, so
    // colocating CSS + fonts in the same bundle dir is essential.
    let scripts = """
      <link rel="stylesheet" href="katex.min.css">
      <script defer src="katex.min.js"></script>
      <script defer src="auto-render.min.js"></script>
      """

    let body: String
    let kickoff: String
    switch mode {
    case let .block(latex):
        body = """
        <div id="block"></div>
        <div id="raw" style="display:none;">\(escapeHTML(latex))</div>
        """
        kickoff = """
          try {
            katex.render(\(jsString(latex)), document.getElementById('block'),
              { displayMode: true, throwOnError: false, output: 'html' });
          } catch (e) {
            document.getElementById('block').innerText = document.getElementById('raw').innerText;
          }
        """

    case let .paragraph(html, fontSize):
        body = """
        <p id="para" style="font-size: \(fontSize)px; line-height: 1.55; margin: 0; padding: 0;">
        \(html)
        </p>
        """
        kickoff = spanWalkingMathKickoff
    case let .heading(html, fontSize, fontWeight):
        // Headings sit tighter (line-height 1.25) and use a higher
        // font-weight so the math glyphs match the surrounding bold
        // prose. Same span-walking kickoff as paragraph mode.
        body = """
        <p id="heading" style="font-size: \(fontSize)px; font-weight: \(fontWeight); line-height: 1.25; margin: 0; padding: 0;">
        \(html)
        </p>
        """
        kickoff = spanWalkingMathKickoff
    }

    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      \(scripts)
      <style>\(cssVars)</style>
    </head>
    <body>
      \(body)
      <script>
        function report() {
          try {
            const h = document.body.scrollHeight + 4;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.katexHeight) {
              window.webkit.messageHandlers.katexHeight.postMessage(h);
            }
          } catch (e) {}
        }
        function go() {
          if (typeof katex === 'undefined') { return setTimeout(go, 40); }
          \(kickoff)
          // Two reports: first after layout settles, second slightly
          // later in case KaTeX's font-load reflows the math glyphs.
          requestAnimationFrame(report);
          setTimeout(report, 220);
        }
        go();
      </script>
    </body>
    </html>
    """
}

// MARK: - WebView representable

fileprivate struct KaTeXWebRepresentable {
    let mode: KaTeXRenderMode
    let isDark: Bool
    let textHex: String
    let mutedHex: String
    let primaryHex: String
    let onHeight: (CGFloat) -> Void

    fileprivate func makeContentKey() -> String {
        switch mode {
        case let .block(latex):
            return "b|\(isDark ? "d" : "l")|\(primaryHex)|\(latex.hashValue)"
        case let .paragraph(html, fontSize):
            return "p|\(isDark ? "d" : "l")|\(primaryHex)|\(fontSize)|\(html.hashValue)"
        case let .heading(html, fontSize, fontWeight):
            return "h|\(isDark ? "d" : "l")|\(primaryHex)|\(fontSize)|\(fontWeight)|\(html.hashValue)"
        }
    }

    fileprivate func makeHTML() -> String {
        katexHTML(
            mode: mode,
            isDark: isDark,
            textHex: textHex,
            mutedHex: mutedHex,
            primaryHex: primaryHex
        )
    }
}

#if canImport(UIKit)
import UIKit

extension KaTeXWebRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "katexHeight")
        let view = ScrollForwardingWKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        load(into: view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let key = makeContentKey()
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            load(into: uiView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    private func load(into view: WKWebView) {
        // WKWebView on macOS is sandboxed: `loadHTMLString` with a
        // file:// baseURL cannot read sibling files from disk. Bundled
        // KaTeX assets only load when we go through `loadFileURL` with
        // an explicit `allowingReadAccessTo:` ACL — see
        // `BundledWebAssets` for the writable-mirror plumbing.
        let html = makeHTML()
        if let webDir = BundledWebAssets.writableWebDir,
           let renderFile = BundledWebAssets.writeRenderHTML(html) {
            view.loadFileURL(renderFile, allowingReadAccessTo: webDir)
        } else {
            // Bundle layout drifted or temp dir unwritable — fall back
            // to in-memory load. Math will fail to render but the page
            // won't crash; we'd rather degrade than abort.
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastKey: String = ""
        let onHeight: (CGFloat) -> Void
        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "katexHeight" else { return }
            if let n = message.body as? Double { onHeight(CGFloat(n)) }
            else if let n = message.body as? Int { onHeight(CGFloat(n)) }
            else if let n = message.body as? CGFloat { onHeight(n) }
        }
    }
}
#elseif canImport(AppKit)
import AppKit

extension KaTeXWebRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "katexHeight")
        let view = ScrollForwardingWKWebView(frame: .zero, configuration: cfg)
        view.setValue(false, forKey: "drawsBackground")
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let key = makeContentKey()
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            load(into: nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    private func load(into view: WKWebView) {
        // WKWebView on macOS is sandboxed: `loadHTMLString` with a
        // file:// baseURL cannot read sibling files from disk. Bundled
        // KaTeX assets only load when we go through `loadFileURL` with
        // an explicit `allowingReadAccessTo:` ACL — see
        // `BundledWebAssets` for the writable-mirror plumbing.
        let html = makeHTML()
        if let webDir = BundledWebAssets.writableWebDir,
           let renderFile = BundledWebAssets.writeRenderHTML(html) {
            view.loadFileURL(renderFile, allowingReadAccessTo: webDir)
        } else {
            // Bundle layout drifted or temp dir unwritable — fall back
            // to in-memory load. Math will fail to render but the page
            // won't crash; we'd rather degrade than abort.
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastKey: String = ""
        let onHeight: (CGFloat) -> Void
        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "katexHeight" else { return }
            if let n = message.body as? Double { onHeight(CGFloat(n)) }
            else if let n = message.body as? Int { onHeight(CGFloat(n)) }
            else if let n = message.body as? CGFloat { onHeight(n) }
        }
    }
}
#endif

// MARK: - Theme bridge

private extension ThemeTokens {
    /// `#rrggbb` for KaTeX's CSS color attribute. Falls back to a neutral
    /// light grey when SwiftUI's bridge can't resolve a Color to RGB
    /// components — that path is theoretical (system / dynamic colors
    /// resolve fine on the platforms we ship to) but the fallback keeps
    /// the template valid.
    var textHex: String { text.hexString ?? "#dddddd" }
    var textDimHex: String { textDim.hexString ?? "#888888" }
    var primaryHex: String { primary.hexString ?? "#88c0d0" }
}

private extension Color {
    /// Best-effort hex serialisation of a SwiftUI Color via the platform-
    /// native color types. KaTeX's CSS doesn't accept .sRGB(r,g,b) values
    /// directly so the HTML template needs a real `#rrggbb`.
    var hexString: String? {
        #if canImport(AppKit)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
        #elseif canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int(round(max(0, min(1, r)) * 255)),
                      Int(round(max(0, min(1, g)) * 255)),
                      Int(round(max(0, min(1, b)) * 255)))
        #else
        return nil
        #endif
    }
}
