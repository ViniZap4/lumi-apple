import SwiftUI
import WebKit
import LumiKit

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Trivial WKWebView host that displays pre-rendered HTML/SVG content
/// — the output of `MathRenderService`. No `<script>` tags load here,
/// no KaTeX/Mermaid init: just `katex.min.css` (for the math glyph
/// styles) plus a theme-derived `<style>` block, and the rendered
/// payload inlined in `<body>`. Each spawn is essentially a CSS+font
/// load, which WebKit caches across sibling WebViews — so the second
/// block of a math-heavy note is cheap.
///
/// The display height is fixed up-front from `MathRenderService.Rendered.intrinsicHeight`;
/// no measurement round-trip needed. Scroll-wheel events forward to
/// the host scroll view (see `ScrollForwardingWKWebView`).
///
/// This view replaces the per-block KaTeX/Mermaid WebView which loaded
/// the full script bundle on every mount.
struct StaticContentWebView: View {
    /// Inline HTML or SVG. For math this is `katex.renderToString`'s
    /// output; for mermaid it's the SVG returned by `mermaid.render`.
    let payload: String
    /// Wraps the payload with extra CSS — paragraph/heading math want
    /// theme-coloured text + link styling, block math + mermaid don't.
    let role: Role
    /// Already-measured intrinsic height from the render service.
    let intrinsicHeight: CGFloat
    @Environment(\.theme) private var theme

    enum Role {
        /// Block math: rendered output is the only content. No
        /// surrounding text styling needed.
        case mathBlock
        /// Paragraph math: rendered HTML includes a host `<p>` that
        /// already has font-size + line-height inline. We layer
        /// theme-derived `color` + link styling.
        case mathParagraph
        /// Heading math: same as paragraph but heading typography.
        case mathHeading
        /// Mermaid SVG: bg transparent, SVG already carries theme
        /// colors baked in.
        case mermaid
    }

    var body: some View {
        StaticContentRepresentable(
            html: makeHTML(),
            intrinsicHeight: intrinsicHeight
        )
        .frame(height: intrinsicHeight)
    }

    private func makeHTML() -> String {
        let bg = "transparent"
        let textHex = theme.text.hexString ?? "#dddddd"
        let mutedHex = theme.textDim.hexString ?? "#888888"
        let primaryHex = theme.primary.hexString ?? "#88c0d0"

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
          svg { max-width: 100%; height: auto; }
          """

        let needsKatexCSS: Bool
        switch role {
        case .mathBlock, .mathParagraph, .mathHeading: needsKatexCSS = true
        case .mermaid: needsKatexCSS = false
        }

        let katexLink = needsKatexCSS
            ? "<link rel=\"stylesheet\" href=\"katex.min.css\">"
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(katexLink)
        <style>\(cssVars)</style>
        </head>
        <body>\(payload)</body>
        </html>
        """
    }
}

// MARK: - Platform representable

#if canImport(AppKit)
private struct StaticContentRepresentable: NSViewRepresentable {
    let html: String
    let intrinsicHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let view = ScrollForwardingWKWebView(frame: .zero)
        view.setValue(false, forKey: "drawsBackground")
        load(into: view)
        context.coordinator.lastHTML = html
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            load(into: nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String = ""
    }

    private func load(into view: WKWebView) {
        if let webDir = BundledWebAssets.writableWebDir,
           let renderFile = BundledWebAssets.writeRenderHTML(html) {
            view.loadFileURL(renderFile, allowingReadAccessTo: webDir)
        } else {
            view.loadHTMLString(html, baseURL: nil)
        }
    }
}
#endif

#if canImport(UIKit)
private struct StaticContentRepresentable: UIViewRepresentable {
    let html: String
    let intrinsicHeight: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let view = ScrollForwardingWKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        load(into: view)
        context.coordinator.lastHTML = html
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            load(into: uiView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String = ""
    }

    private func load(into view: WKWebView) {
        if let webDir = BundledWebAssets.writableWebDir,
           let renderFile = BundledWebAssets.writeRenderHTML(html) {
            view.loadFileURL(renderFile, allowingReadAccessTo: webDir)
        } else {
            view.loadHTMLString(html, baseURL: nil)
        }
    }
}
#endif

// MARK: - Color hex bridge (used by `makeHTML`)

private extension Color {
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
