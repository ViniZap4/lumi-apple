import SwiftUI
import WebKit
import LumiKit

/// Renders a Mermaid diagram via WKWebView. Detection is driven from
/// `BlockView` when a fenced code block has language "mermaid". The view
/// loads a minimal HTML page that pulls mermaid.min.js from jsdelivr and
/// auto-renders the embedded diagram source.
///
/// Cross-platform: AppKit + UIKit Representables share the same HTML
/// template. Network access is required (CDN script load). The sandbox
/// is disabled in the Apple client so the request goes through; on iOS
/// the app's standard network entitlement covers it.
///
/// Theme: passes `dark` / `default` to mermaid.initialize based on the
/// active LumiTheme's `isDark` flag so node fills + edges match the
/// surrounding read pane.
///
/// Sizing: starts at a 360 pt fixed height to avoid a layout flash while
/// the script loads; once mermaid has rendered, a small JS bridge posts
/// the rendered SVG height back over a `WKScriptMessageHandler` and the
/// SwiftUI host snaps to that height. Diagrams wider than the column
/// scroll horizontally inside the WebView.
public struct MermaidView: View {
    public let code: String
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite
    @State private var measuredHeight: CGFloat = 360

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        if lite {
            HStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                Text("mermaid diagram")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(theme.overlayBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            renderedBody
        }
    }

    @ViewBuilder
    private var renderedBody: some View {
        MermaidWebRepresentable(
            code: code,
            isDark: theme.isDark,
            onHeight: { h in
                if h > 1 { measuredHeight = min(max(h, 80), 2000) }
            }
        )
        .frame(height: measuredHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.overlayBackground.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border.opacity(0.5), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            Text("mermaid")
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.background.opacity(0.7)))
                .padding(8)
        }
    }
}

// MARK: - HTML template

private func mermaidHTML(code: String, isDark: Bool, backgroundHex: String) -> String {
    // Mermaid's source must land inside the HTML untouched. The user can
    // legitimately type any character — including `<`, `>`, `&` — so the
    // template uses a `<pre>` block (whitespace-preserving) and we escape
    // the three HTML-significant chars only. JS handles the rest.
    let escaped = code
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let mermaidTheme = isDark ? "dark" : "default"
    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
      html, body { margin: 0; padding: 0; background: \(backgroundHex); }
      body { padding: 14px; font-family: -apple-system, system-ui, sans-serif; color: #ddd; }
      pre.mermaid { margin: 0; background: transparent; }
      svg { max-width: 100%; height: auto; }
    </style>
    <script src="mermaid.min.js"></script>
    </head>
    <body>
    <pre class="mermaid">\(escaped)</pre>
    <script>
      try {
        mermaid.initialize({ startOnLoad: true, theme: '\(mermaidTheme)', securityLevel: 'loose' });
      } catch (e) {}
      // Wait for mermaid to render, then post the body's full content
      // height back to Swift so the SwiftUI host can match the diagram's
      // actual size. mermaid renders asynchronously; poll briefly until
      // the SVG appears.
      function reportHeight() {
        try {
          const h = document.body.scrollHeight + 8;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mermaidHeight) {
            window.webkit.messageHandlers.mermaidHeight.postMessage(h);
          }
        } catch (e) {}
      }
      let attempts = 0;
      const t = setInterval(() => {
        attempts += 1;
        if (document.querySelector('pre.mermaid svg')) {
          reportHeight();
          clearInterval(t);
        } else if (attempts > 40) {
          // Stop polling after ~4 s; whatever's there is what we get.
          reportHeight();
          clearInterval(t);
        }
      }, 100);
    </script>
    </body>
    </html>
    """
}

// MARK: - WebView representable

#if canImport(UIKit)
import UIKit

private struct MermaidWebRepresentable: UIViewRepresentable {
    let code: String
    let isDark: Bool
    let onHeight: (CGFloat) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "mermaidHeight")
        let view = ScrollForwardingWKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        loadHTML(into: view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastKey != renderKey {
            context.coordinator.lastKey = renderKey
            loadHTML(into: uiView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    private var renderKey: String { "\(isDark ? "d" : "l")|\(code.hashValue)" }

    private func loadHTML(into view: WKWebView) {
        // See `KaTeXView.load(into:)` for the loadFileURL rationale —
        // same sandbox dance to grant the WebView read access to the
        // bundled `mermaid.min.js` (and the inline HTML's parent dir).
        let html = mermaidHTML(code: code, isDark: isDark, backgroundHex: "transparent")
        if let webDir = BundledWebAssets.writableWebDir,
           let renderFile = BundledWebAssets.writeRenderHTML(html) {
            view.loadFileURL(renderFile, allowingReadAccessTo: webDir)
        } else {
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastKey: String = ""
        let onHeight: (CGFloat) -> Void
        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidHeight" else { return }
            if let n = message.body as? CGFloat {
                onHeight(n)
            } else if let n = message.body as? Double {
                onHeight(CGFloat(n))
            } else if let n = message.body as? Int {
                onHeight(CGFloat(n))
            }
        }
    }
}
#elseif canImport(AppKit)
import AppKit

private struct MermaidWebRepresentable: NSViewRepresentable {
    let code: String
    let isDark: Bool
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "mermaidHeight")
        let view = ScrollForwardingWKWebView(frame: .zero, configuration: cfg)
        view.setValue(false, forKey: "drawsBackground")
        loadHTML(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastKey != renderKey {
            context.coordinator.lastKey = renderKey
            loadHTML(into: nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    private var renderKey: String { "\(isDark ? "d" : "l")|\(code.hashValue)" }

    private func loadHTML(into view: WKWebView) {
        // See `KaTeXView.load(into:)` for the loadFileURL rationale —
        // same sandbox dance to grant the WebView read access to the
        // bundled `mermaid.min.js` (and the inline HTML's parent dir).
        let html = mermaidHTML(code: code, isDark: isDark, backgroundHex: "transparent")
        if let webDir = BundledWebAssets.writableWebDir,
           let renderFile = BundledWebAssets.writeRenderHTML(html) {
            view.loadFileURL(renderFile, allowingReadAccessTo: webDir)
        } else {
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastKey: String = ""
        let onHeight: (CGFloat) -> Void
        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidHeight" else { return }
            if let n = message.body as? CGFloat {
                onHeight(n)
            } else if let n = message.body as? Double {
                onHeight(CGFloat(n))
            } else if let n = message.body as? Int {
                onHeight(CGFloat(n))
            }
        }
    }
}
#endif
