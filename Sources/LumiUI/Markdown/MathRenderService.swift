import Foundation
import WebKit
import LumiKit

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Persistent WKWebView-backed renderer for math (KaTeX) and diagram
/// (Mermaid) content. A single hidden WKWebView preloads katex.js +
/// auto-render.js + mermaid.js *once* at app start; every subsequent
/// render reuses it instead of spawning a fresh WebView per markdown
/// block.
///
/// Wins over the prior per-block spawn:
///
///   1. **Script load + JIT happens once, not per block.** A note with
///      20 math expressions previously did 20× full KaTeX init
///      (~50–200 ms each); now it's 1× init + 20× `katex.renderToString`
///      (~5–10 ms each).
///   2. **Render results are content-hashed and cached.** Repeated
///      mounts of the same expression skip the WebView entirely.
///      Switching back to a previously-viewed note is instant.
///   3. **WebView is created in a single sandbox process,** not N. Big
///      memory + GPU surface savings on math-heavy notes.
///
/// The display side (`KaTeXBlockView`, etc.) hands the service the
/// source, awaits a pre-rendered HTML/SVG snippet, and embeds it in a
/// trivial WebView (no scripts, no layout JIT). For mermaid the result
/// is raw SVG and could ultimately become a native `Image` (deferred).
///
/// The service is `@MainActor` because WKWebView is. JS execution is
/// inherently serialised by WebKit, so concurrent callers safely
/// dispatch in parallel — the per-request UUID embedded in each
/// message handler post routes responses back to the right
/// `CheckedContinuation`.
@MainActor
public final class MathRenderService {
    public static let shared = MathRenderService()

    /// What kind of content to render. Each case carries everything the
    /// renderer needs to produce a layout-correct output — `fontSize`
    /// and `fontWeight` for paragraph/heading math because the spans
    /// need to size to their host typography, `isDark` for mermaid
    /// because mermaid bakes theme colours into the SVG itself.
    public enum Kind: Hashable, Sendable {
        case mathBlock(latex: String)
        case mathParagraph(html: String, fontSize: CGFloat)
        case mathHeading(html: String, fontSize: CGFloat, fontWeight: Int)
        case mermaid(source: String, isDark: Bool)
    }

    /// Output of a render. `payload` is the HTML (math) or SVG
    /// (mermaid) ready to embed in a display WebView (or, for mermaid,
    /// to feed to an `NSImage`/`UIImage`). `intrinsicHeight` is the
    /// measured layout height in points so the display side can size
    /// itself without waiting for a second measurement round-trip.
    public struct Rendered: Hashable, Sendable {
        public let payload: String
        public let intrinsicHeight: CGFloat

        public init(payload: String, intrinsicHeight: CGFloat) {
            self.payload = payload
            self.intrinsicHeight = intrinsicHeight
        }
    }

    // MARK: - Public API

    /// Fire-and-forget warmup. Triggers the persistent WebView setup
    /// + KaTeX/Mermaid script load *now* so the user's first math
    /// render doesn't pay that latency. Safe to call multiple times —
    /// `ensureReady` is idempotent.
    public func prewarm() {
        Task { await ensureReady() }
    }

    /// Render `kind` and return the result. Cache lookup runs first; on
    /// miss the service ensures the WebView is loaded then dispatches a
    /// JS render. Returns `nil` if the render failed (bad LaTeX, dead
    /// WebView, missing bundle assets). Callers should display raw
    /// source as a fallback in that case.
    public func render(_ kind: Kind) async -> Rendered? {
        let key = cacheKey(for: kind)
        if let hit = memoryCache[key] {
            // LRU touch
            lru.removeAll(where: { $0 == key })
            lru.append(key)
            return hit
        }

        await ensureReady()
        guard webView != nil else { return nil }

        let result = await runRender(kind)
        if let result {
            memoryCache[key] = result
            lru.append(key)
            evictIfNeeded()
        }
        return result
    }

    // MARK: - Private state

    private var webView: WKWebView?
    private var messageProxy: MessageProxy?
    private var isLoaded: Bool = false
    /// Continuations parked by `ensureReady` while the WebView's
    /// renderer page finishes loading. All resumed in order when the
    /// page posts `{kind: "ready"}`.
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    /// In-flight render continuations keyed by request id. The JS posts
    /// the id back in its response, native resumes the matching
    /// continuation.
    private var inFlight: [UUID: CheckedContinuation<Rendered?, Never>] = [:]
    /// Insertion-order LRU. Front = oldest, back = most recently
    /// touched. Bounded at `memoryCacheCap`.
    private var lru: [String] = []
    private var memoryCache: [String: Rendered] = [:]
    private let memoryCacheCap: Int = 256

    private init() {}

    // MARK: - WebView setup

    private func ensureReady() async {
        if isLoaded { return }
        if webView == nil { setupWebView() }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if isLoaded {
                cont.resume()
            } else {
                readyWaiters.append(cont)
            }
        }
    }

    private func setupWebView() {
        guard let webDir = BundledWebAssets.writableWebDir else {
            return
        }
        // One hidden WKWebView, never attached to a view tree. JS
        // executes regardless of attachment; the messageHandler
        // delivers results to native asynchronously.
        let cfg = WKWebViewConfiguration()
        let proxy = MessageProxy(target: self)
        cfg.userContentController.add(proxy, name: "lumi")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        #if canImport(AppKit)
        wv.setValue(false, forKey: "drawsBackground")
        #endif
        webView = wv
        messageProxy = proxy

        // Persist a stable renderer.html in the writable mirror so it
        // can sit alongside katex/mermaid assets. Re-written each
        // launch because the JS template may change with builds.
        let rendererFile = webDir.appendingPathComponent("renderer.html")
        try? rendererPageHTML().write(to: rendererFile, atomically: true, encoding: .utf8)
        wv.loadFileURL(rendererFile, allowingReadAccessTo: webDir)
    }

    // MARK: - Render dispatch

    private func runRender(_ kind: Kind) async -> Rendered? {
        guard let webView else { return nil }
        let id = UUID()
        let js = jsCall(for: kind, id: id)
        return await withCheckedContinuation { (cont: CheckedContinuation<Rendered?, Never>) in
            inFlight[id] = cont
            webView.evaluateJavaScript(js) { [weak self] _, error in
                // `evaluateJavaScript` errors fire synchronously before
                // the messageHandler ever runs — bail out and resume
                // with nil so the caller doesn't hang.
                if error != nil {
                    Task { @MainActor in
                        guard let self else { return }
                        self.inFlight.removeValue(forKey: id)?.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func jsCall(for kind: Kind, id: UUID) -> String {
        let idJS = jsString(id.uuidString)
        switch kind {
        case let .mathBlock(latex):
            return "window.lumiRenderMathBlock({id:\(idJS), latex:\(jsString(latex))});"
        case let .mathParagraph(html, fontSize):
            return "window.lumiRenderMathParagraph({id:\(idJS), html:\(jsString(html)), fontSize:\(fontSize)});"
        case let .mathHeading(html, fontSize, fontWeight):
            return "window.lumiRenderMathHeading({id:\(idJS), html:\(jsString(html)), fontSize:\(fontSize), fontWeight:\(fontWeight)});"
        case let .mermaid(source, isDark):
            let theme = isDark ? "dark" : "default"
            return "window.lumiRenderMermaid({id:\(idJS), source:\(jsString(source)), theme:\(jsString(theme))});"
        }
    }

    // MARK: - Cache management

    private func cacheKey(for kind: Kind) -> String {
        var hasher = Hasher()
        switch kind {
        case let .mathBlock(latex):
            hasher.combine(0)
            hasher.combine(latex)
        case let .mathParagraph(html, fontSize):
            hasher.combine(1)
            hasher.combine(html)
            hasher.combine(fontSize)
        case let .mathHeading(html, fontSize, fontWeight):
            hasher.combine(2)
            hasher.combine(html)
            hasher.combine(fontSize)
            hasher.combine(fontWeight)
        case let .mermaid(source, isDark):
            hasher.combine(3)
            hasher.combine(source)
            hasher.combine(isDark)
        }
        return String(hasher.finalize())
    }

    private func evictIfNeeded() {
        while lru.count > memoryCacheCap {
            let key = lru.removeFirst()
            memoryCache.removeValue(forKey: key)
        }
    }

    // MARK: - JS bridge

    fileprivate func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }

        // Readiness handshake — page posts this once katex + mermaid
        // are both defined globally.
        if let kind = dict["kind"] as? String, kind == "ready" {
            guard !isLoaded else { return }
            isLoaded = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for w in waiters { w.resume() }
            return
        }

        // Render response. Resume the matching continuation.
        guard let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        let cont = inFlight.removeValue(forKey: id)
        let success = dict["success"] as? Bool ?? false
        guard success else {
            cont?.resume(returning: nil)
            return
        }
        let payload = dict["payload"] as? String ?? ""
        let heightAny = dict["height"]
        let height: CGFloat
        if let n = heightAny as? Double { height = CGFloat(n) }
        else if let n = heightAny as? Int { height = CGFloat(n) }
        else { height = 0 }
        cont?.resume(returning: Rendered(payload: payload, intrinsicHeight: height))
    }

    // MARK: - HTML template

    private func rendererPageHTML() -> String {
        // Hidden offscreen page. Loads katex + mermaid scripts once.
        // Exposes four global render functions; each one accepts a
        // request object, does the render synchronously (math) or
        // awaits the SVG (mermaid), and posts the result back via
        // `webkit.messageHandlers.lumi`.
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <link rel="stylesheet" href="katex.min.css">
        <script src="katex.min.js"></script>
        <script src="mermaid.min.js"></script>
        <style>
          html, body { margin: 0; padding: 0; }
          .stage { display: inline-block; }
        </style>
        </head>
        <body>
        <script>
          (function () {
            function post(msg) {
              try {
                window.webkit.messageHandlers.lumi.postMessage(msg);
              } catch (e) { /* host gone */ }
            }

            function measure(node) {
              const r = node.getBoundingClientRect();
              return r.height;
            }

            // Math block: katex.renderToString gives us the HTML
            // directly. We append to a hidden stage to measure, then
            // detach. Each call uses a fresh stage so concurrent calls
            // (JS is single-threaded so this is mostly defensive) can't
            // step on each other.
            window.lumiRenderMathBlock = function (req) {
              try {
                const html = katex.renderToString(req.latex, {
                  displayMode: true, throwOnError: false, output: 'html'
                });
                const stage = document.createElement('div');
                stage.className = 'stage';
                stage.innerHTML = html;
                document.body.appendChild(stage);
                const h = measure(stage);
                document.body.removeChild(stage);
                post({ id: req.id, success: true, payload: html, height: h });
              } catch (e) {
                post({ id: req.id, success: false, error: String(e) });
              }
            };

            // Paragraph math: input is HTML with embedded
            // <span class="math" data-latex="..."> placeholders. We
            // render each placeholder in place, then return the
            // resulting innerHTML.
            window.lumiRenderMathParagraph = function (req) {
              try {
                const stage = document.createElement('div');
                stage.className = 'stage';
                stage.style.fontFamily = '-apple-system, BlinkMacSystemFont, system-ui, sans-serif';
                stage.innerHTML = '<p style="font-size:' + req.fontSize + 'px; line-height:1.55; margin:0; padding:0;">' + req.html + '</p>';
                document.body.appendChild(stage);
                stage.querySelectorAll('span.math').forEach(function (el) {
                  const latex = el.getAttribute('data-latex') || '';
                  const isBlock = el.classList.contains('math-display');
                  katex.render(latex, el, { displayMode: isBlock, throwOnError: false, output: 'html' });
                });
                const h = measure(stage.firstChild);
                const out = stage.innerHTML;
                document.body.removeChild(stage);
                post({ id: req.id, success: true, payload: out, height: h });
              } catch (e) {
                post({ id: req.id, success: false, error: String(e) });
              }
            };

            // Heading math: same shape as paragraph but with tighter
            // line-height + heading font weight on the host <p>.
            window.lumiRenderMathHeading = function (req) {
              try {
                const stage = document.createElement('div');
                stage.className = 'stage';
                stage.style.fontFamily = '-apple-system, BlinkMacSystemFont, system-ui, sans-serif';
                stage.innerHTML = '<p style="font-size:' + req.fontSize + 'px; font-weight:' + req.fontWeight + '; line-height:1.25; margin:0; padding:0;">' + req.html + '</p>';
                document.body.appendChild(stage);
                stage.querySelectorAll('span.math').forEach(function (el) {
                  const latex = el.getAttribute('data-latex') || '';
                  const isBlock = el.classList.contains('math-display');
                  katex.render(latex, el, { displayMode: isBlock, throwOnError: false, output: 'html' });
                });
                const h = measure(stage.firstChild);
                const out = stage.innerHTML;
                document.body.removeChild(stage);
                post({ id: req.id, success: true, payload: out, height: h });
              } catch (e) {
                post({ id: req.id, success: false, error: String(e) });
              }
            };

            // Mermaid is async: mermaid.render() returns a promise.
            // re-initialize with the requested theme each call so
            // dark/light flips correctly invalidate.
            window.lumiRenderMermaid = async function (req) {
              try {
                mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', theme: req.theme });
                const idAttr = 'm' + req.id.replace(/-/g, '');
                const { svg } = await mermaid.render(idAttr, req.source);
                const stage = document.createElement('div');
                stage.className = 'stage';
                stage.innerHTML = svg;
                document.body.appendChild(stage);
                const h = measure(stage.firstChild || stage);
                document.body.removeChild(stage);
                post({ id: req.id, success: true, payload: svg, height: h });
              } catch (e) {
                post({ id: req.id, success: false, error: String(e) });
              }
            };

            // Wait for both libs to land, then post `ready`.
            function pollReady() {
              if (typeof katex === 'undefined' || typeof mermaid === 'undefined') {
                setTimeout(pollReady, 30);
                return;
              }
              post({ kind: 'ready' });
            }
            pollReady();
          })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - String escaping helpers

    /// JSON-string encode for inlining a Swift string into a JS source
    /// literal. Round-trips through JSONEncoder so all the standard
    /// escapes (\\, \", control chars) are handled.
    private func jsString(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
    }
}

/// Trampoline so the WKScriptMessageHandler protocol's @objc
/// requirements don't pollute `MathRenderService`'s Swift surface.
/// Captures the service weakly; messages no-op after the service has
/// been deallocated (which only happens if the singleton's release is
/// somehow forced — not in practice).
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: MathRenderService?
    init(target: MathRenderService) { self.target = target }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        Task { @MainActor [weak target] in
            target?.handleMessage(body)
        }
    }
}
