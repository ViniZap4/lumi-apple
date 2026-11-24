import CoreGraphics
import Foundation
import ImageIO
import Network
import WebKit

/// Offscreen Mermaid renderer: source → sanitised SVG + rasterised bitmap.
///
/// **Isolation.** Each worker is a hidden `WKWebView` that is never put
/// in a view tree and is locked down so the only code that runs is the
/// bundled, pinned `mermaid.min.js`:
///
///   - non-persistent website data store (no cookies, storage, cache)
///     whose proxy is a dead loopback port, so even WebKit's speculative
///     preconnects cannot leave the machine;
///   - `allowsContentJavaScript = false` — page content cannot run
///     script at all; mermaid is injected as a `WKUserScript` into a
///     private `WKContentWorld`, so even a `<script>` or `onerror` that
///     slipped through mermaid's DOMPurify would be inert;
///   - a compiled content-rule list that blocks every load except
///     `about:` and inline `data:` (the SVG → canvas hop), so there is
///     no network and no file access, plus a CSP meta as a second layer;
///   - a navigation delegate that allows only the initial `about:blank`
///     document and cancels every other navigation; no new windows;
///   - mermaid initialised with `securityLevel: 'strict'`, HTML labels
///     off (pure SVG text, no `foreignObject`), and the security keys
///     (`securityLevel`, `htmlLabels`, `dompurifyConfig`, limits) marked
///     `secure` so `%%{init}%%` directives in a note cannot loosen them.
///
/// **Output.** The page rasterises the SVG on a canvas and returns PNG;
/// the app displays that bitmap (an `Image`), never live SVG. The SVG is
/// kept, scrubbed again by `MermaidSVGSanitizer`, for "Copy SVG".
///
/// **Scheduling.** Requests are coalesced by key, served from an LRU
/// (`MermaidRenderCache`), and otherwise queued FIFO across at most
/// `maxConcurrent` workers (spawned lazily; extras are reaped when
/// idle). Each render has a timeout; a timed-out worker is torn down so
/// a pathological diagram cannot wedge the queue. PNG decoding and SVG
/// scrubbing run off the main actor.
@MainActor
public final class MermaidRenderer {
    /// The pinned mermaid build in `App/Resources/Web/mermaid.min.js`.
    public nonisolated static let bundledVersion = "12.3.0"

    public static let shared = MermaidRenderer(
        scriptURL: Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Web")
    )

    public let scriptURL: URL?
    public let maxConcurrent: Int
    public let timeout: Duration
    /// Longest bitmap side in pixels; scale is reduced to fit.
    public let maxPixelDimension: CGFloat

    private var cache = MermaidRenderCache()
    private var waiters: [MermaidRenderKey: [CheckedContinuation<MermaidRenderResult, Never>]] = [:]
    private var queue: [Job] = []
    private var workers: [MermaidWorker] = []
    private var environment: Task<WorkerEnvironment?, Never>?
    private var reapGeneration = 0

    struct Job {
        let key: MermaidRenderKey
        let theme: MermaidTheme
    }

    public init(
        scriptURL: URL?,
        maxConcurrent: Int = 2,
        timeout: Duration = .seconds(12),
        maxPixelDimension: CGFloat = 4096
    ) {
        self.scriptURL = scriptURL
        self.maxConcurrent = max(1, maxConcurrent)
        self.timeout = timeout
        self.maxPixelDimension = maxPixelDimension
    }

    // MARK: - Public API

    /// Synchronous cache probe, so a remounting view can show the
    /// diagram on its first frame instead of flashing the placeholder.
    public func cached(source: String, theme: MermaidTheme, scale: CGFloat) -> MermaidRenderResult? {
        cache.value(for: MermaidRenderKey(source: source, themeFingerprint: theme.fingerprint, scale: scale))
    }

    /// Render (or return the cached render of) `source`.
    public func render(source: String, theme: MermaidTheme, scale: CGFloat) async -> MermaidRenderResult {
        let key = MermaidRenderKey(source: source, themeFingerprint: theme.fingerprint, scale: scale)
        if let hit = cache.value(for: key) { return hit }
        if source.count > MermaidSource.maxSourceLength {
            let failure = MermaidRenderResult.failure(.tooLarge(length: source.count))
            cache.insert(failure, for: key)
            return failure
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.syntax("The diagram is empty."))
        }
        return await withCheckedContinuation { cont in
            if waiters[key] != nil {
                waiters[key]!.append(cont)
                return
            }
            waiters[key] = [cont]
            queue.append(Job(key: key, theme: theme))
            pump()
        }
    }

    /// Start loading the first worker now (e.g. when a note with a
    /// diagram opens) so the first render doesn't pay mermaid's parse.
    public func prewarm() {
        guard workers.isEmpty else { return }
        let worker = spawnWorker()
        Task { _ = await worker.ensureLoaded() }
    }

    /// Drop every cached render (memory warning, tests).
    public func purge() { cache.removeAll() }

    var cacheCount: Int { cache.count }
    var workerCount: Int { workers.count }

    /// Test hook: run `js` (an async function body) in the mermaid
    /// content world of a loaded worker. Used to prove the sandbox
    /// (network / page script blocked); not used by the app.
    func probeForTesting(_ js: String) async -> Any? {
        let worker = workers.first(where: { !$0.dead }) ?? spawnWorker()
        guard await worker.ensureLoaded() else { return nil }
        return await worker.evaluate(js)
    }

    // MARK: - Scheduling

    private func pump() {
        while !queue.isEmpty {
            let worker: MermaidWorker
            if let idle = workers.first(where: { !$0.busy && !$0.dead }) {
                worker = idle
            } else if workers.count < maxConcurrent {
                worker = spawnWorker()
            } else {
                return
            }
            let job = queue.removeFirst()
            worker.busy = true
            Task { [weak self] in
                guard let self else { return }
                let result = await self.run(job, on: worker)
                worker.busy = false
                if worker.dead { self.workers.removeAll { $0 === worker } }
                self.finish(job.key, result)
                self.pump()
                self.scheduleReap()
            }
        }
    }

    private func finish(_ key: MermaidRenderKey, _ result: MermaidRenderResult) {
        switch result {
        case .success, .failure(.syntax), .failure(.tooLarge):
            cache.insert(result, for: key)
        case .failure(.timedOut), .failure(.unavailable):
            break // transient — let the next mount retry
        }
        for w in waiters.removeValue(forKey: key) ?? [] { w.resume(returning: result) }
    }

    private func spawnWorker() -> MermaidWorker {
        let worker = MermaidWorker(environment: workerEnvironment())
        workers.append(worker)
        return worker
    }

    /// Keep one warm worker; tear the rest down after a quiet spell.
    private func scheduleReap() {
        guard queue.isEmpty, workers.count > 1 else { return }
        reapGeneration += 1
        let generation = reapGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, generation == self.reapGeneration, self.queue.isEmpty else { return }
            for w in self.workers.dropFirst() where !w.busy { w.tearDown() }
            self.workers.removeAll { $0.dead }
        }
    }

    // MARK: - Render

    private func run(_ job: Job, on worker: MermaidWorker) async -> MermaidRenderResult {
        guard await worker.ensureLoaded() else {
            worker.tearDown()
            return .failure(.unavailable("The diagram engine failed to load."))
        }
        let raw = await worker.render(
            source: job.key.source,
            config: Self.mermaidConfig(theme: job.theme),
            scale: job.key.scale,
            maxPixelDimension: maxPixelDimension,
            timeout: timeout
        )
        switch raw {
        case let .failure(error):
            return .failure(error)
        case let .success(payload):
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(payload)
            }.value
            return decoded
        }
    }

    /// Off-main: base64 → CGImage, SVG scrub.
    nonisolated static func decode(_ payload: MermaidWorker.Payload) -> MermaidRenderResult {
        guard let data = Data(base64Encoded: payload.pngBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .failure(.unavailable("The diagram could not be rasterised.")) }
        return .success(MermaidDiagram(
            svg: MermaidSVGSanitizer.sanitize(payload.svg),
            bitmap: MermaidBitmap(image),
            size: payload.size,
            scale: payload.scale
        ))
    }

    // MARK: - Config

    nonisolated static let secureKeys = [
        "secure", "securityLevel", "startOnLoad", "maxTextSize", "maxEdges",
        "htmlLabels", "dompurifyConfig", "suppressErrorRendering", "deterministicIds",
    ]

    static func mermaidConfig(theme: MermaidTheme) -> [String: Any] {
        var vars: [String: Any] = theme.variables
        vars["darkMode"] = theme.isDark
        return [
            "startOnLoad": false,
            "securityLevel": "strict",
            "secure": secureKeys,
            "theme": "base",
            "themeVariables": vars,
            "fontFamily": MermaidTheme.fontFamily,
            "htmlLabels": false,
            "flowchart": ["htmlLabels": false],
            // Mermaid's default `%Y-%m-%d` ticks collide at daily spacing.
            "gantt": ["axisFormat": "%b %d"],
            "maxTextSize": MermaidSource.maxSourceLength,
            "maxEdges": 2000,
            "suppressErrorRendering": true,
            "deterministicIds": true,
        ]
    }

    // MARK: - Shared worker environment (script + compiled rules)

    struct WorkerEnvironment {
        let script: String
        let rules: WKContentRuleList
    }

    private func workerEnvironment() -> Task<WorkerEnvironment?, Never> {
        if let environment { return environment }
        let url = scriptURL
        let task = Task<WorkerEnvironment?, Never> { @MainActor in
            guard let url else { return nil }
            let script = await Task.detached(priority: .userInitiated) {
                try? String(contentsOf: url, encoding: .utf8)
            }.value
            guard let script, script.contains("mermaid") else { return nil }
            guard let rules = await Self.compileRules() else { return nil }
            return WorkerEnvironment(
                script: MermaidWorker.preludeJS + "\n" + script + "\n" + MermaidWorker.bootstrapJS,
                rules: rules
            )
        }
        environment = task
        return task
    }

    /// Block every subresource / navigation load; re-allow only the
    /// blank document and inline `data:` (SVG → <img> → canvas).
    nonisolated static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    private static func compileRules() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        return await withCheckedContinuation { cont in
            store.compileContentRuleList(
                forIdentifier: "lumi.mermaid.block-all.v1",
                encodedContentRuleList: contentRules
            ) { list, _ in
                nonisolated(unsafe) let list = list
                cont.resume(returning: list)
            }
        }
    }
}

// MARK: - Worker

/// One locked-down hidden web view with mermaid loaded.
@MainActor
final class MermaidWorker: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Payload: Sendable {
        let svg: String
        let pngBase64: String
        let size: CGSize
        let scale: CGFloat
    }

    static let world = WKContentWorld.world(name: "lumi.mermaid")

    var busy = false
    private(set) var dead = false
    private let environment: Task<MermaidRenderer.WorkerEnvironment?, Never>
    private var webView: WKWebView?
    private var loadState: LoadState = .idle
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var allowedInitialNavigation = false

    private enum LoadState { case idle, loading, ready, failed }

    init(environment: Task<MermaidRenderer.WorkerEnvironment?, Never>) {
        self.environment = environment
        super.init()
    }

    nonisolated static let pageHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
    <style>html,body{margin:0;padding:0;background:transparent}#stage{position:absolute;left:0;top:0;width:800px}</style>
    </head><body><div id="stage"></div></body></html>
    """

    /// Runs in the private content world before mermaid: removes the
    /// script-driven ways to start a navigation (a navigation can open a
    /// speculative TCP preconnect before the policy delegate cancels it).
    /// Prototypes are per-world, so this only affects mermaid and us.
    nonisolated static let preludeJS = """
    ;(() => {
      const noop = () => {};
      try { HTMLElement.prototype.click = noop; } catch (e) {}
      try { SVGElement.prototype.click = noop; } catch (e) {}
      try { HTMLFormElement.prototype.submit = noop; HTMLFormElement.prototype.requestSubmit = noop; } catch (e) {}
      try { window.open = () => null; } catch (e) {}
    })();
    """

    /// Runs in the private content world after mermaid. Renders,
    /// measures, scrubs the live DOM, rasterises via canvas and returns
    /// `{ok, svg, png, width, height, scale}` or `{ok:false, error}`.
    nonisolated static let bootstrapJS = #"""
    ;(() => {
      let seq = 0;
      const BLOCKED = ['script', 'foreignObject', 'iframe', 'object', 'embed', 'audio', 'video',
                       'animate', 'animateMotion', 'animateTransform', 'set', 'handler', 'listener'];
      function scrub(root) {
        for (const tag of BLOCKED) root.querySelectorAll(tag).forEach(n => n.remove());
        for (const el of [root, ...root.querySelectorAll('*')]) {
          for (const a of [...el.attributes]) {
            const n = a.name.toLowerCase();
            const v = (a.value || '').replace(/[\s\u0000-\u001f]/g, '').toLowerCase();
            if (n.startsWith('on')) { el.removeAttribute(a.name); continue; }
            if ((n === 'href' || n === 'xlink:href' || n === 'src') && v && !v.startsWith('#')
                && !/^(https?:|mailto:|data:image\/(png|jpeg|gif|webp))/.test(v)) el.removeAttribute(a.name);
          }
        }
      }
      globalThis.lumiMermaidRender = async (source, config, scale, maxDim) => {
        const stage = document.getElementById('stage');
        const id = 'lumi-mmd-' + (++seq);
        try {
          mermaid.initialize(config);
          await mermaid.parse(source);
          const { svg } = await mermaid.render(id, source, stage);
          const host = document.createElement('div');
          host.innerHTML = svg;
          const el = host.querySelector('svg');
          if (!el) return { ok: false, error: 'Mermaid produced no SVG.' };
          scrub(el);
          stage.appendChild(host);
          let w = 0, h = 0;
          const vb = el.viewBox && el.viewBox.baseVal;
          if (vb && vb.width > 0 && vb.height > 0) { w = vb.width; h = vb.height; }
          else { const r = el.getBoundingClientRect(); w = r.width; h = r.height; }
          stage.removeChild(host);
          if (!(w > 0 && h > 0)) return { ok: false, error: 'The diagram is empty.' };
          w = Math.ceil(w); h = Math.ceil(h);
          el.setAttribute('width', String(w));
          el.setAttribute('height', String(h));
          el.style.maxWidth = '';
          if (!el.getAttribute('xmlns')) el.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
          const xml = new XMLSerializer().serializeToString(el);
          const s = Math.max(0.25, Math.min(scale, maxDim / Math.max(w, h)));
          const img = new Image();
          img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml);
          await img.decode();
          const canvas = document.createElement('canvas');
          canvas.width = Math.round(w * s); canvas.height = Math.round(h * s);
          const ctx = canvas.getContext('2d');
          ctx.scale(s, s);
          ctx.drawImage(img, 0, 0, w, h);
          const url = canvas.toDataURL('image/png');
          return { ok: true, svg: xml, png: url.slice(url.indexOf(',') + 1), width: w, height: h, scale: s };
        } catch (e) {
          const msg = (e && (e.message || e.str)) ? String(e.message || e.str) : String(e);
          return { ok: false, error: msg };
        } finally {
          const stray = document.getElementById(id) || document.getElementById('d' + id);
          if (stray) stray.remove();
          stage.textContent = '';
        }
      };
    })();
    """#

    // MARK: Load

    func ensureLoaded() async -> Bool {
        switch loadState {
        case .ready: return true
        case .failed: return false
        case .loading:
            return await withCheckedContinuation { loadWaiters.append($0) }
        case .idle:
            loadState = .loading
            guard let env = await environment.value, !dead else {
                finishLoad(false)
                return false
            }
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = Self.isolatedDataStore()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = false
            cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
            cfg.preferences.isElementFullscreenEnabled = false
            cfg.mediaTypesRequiringUserActionForPlayback = .all
            cfg.suppressesIncrementalRendering = true
            cfg.userContentController.add(env.rules)
            cfg.userContentController.addUserScript(WKUserScript(
                source: env.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
            ))
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
            wv.navigationDelegate = self
            wv.uiDelegate = self
            #if os(macOS)
            wv.setValue(false, forKey: "drawsBackground")
            #endif
            webView = wv
            return await withCheckedContinuation { cont in
                loadWaiters.append(cont)
                wv.loadHTMLString(Self.pageHTML, baseURL: nil)
            }
        }
    }

    /// Ephemeral store whose only route out is a dead loopback proxy.
    /// Content rules stop subresource loads, but WebKit can still open a
    /// speculative TCP preconnect for a main-frame navigation before the
    /// policy delegate cancels it; with every connection forced through
    /// `127.0.0.1:9` (discard, closed) nothing ever leaves the machine.
    /// Port of the dead proxy (tests point it at a listener to prove
    /// egress is pinned to it).
    static var proxySinkPort: UInt16 = 9

    static func isolatedDataStore() -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        let sink = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxySinkPort) ?? 9)
        store.proxyConfigurations = [
            ProxyConfiguration(httpCONNECTProxy: sink),
            ProxyConfiguration(socksv5Proxy: sink),
        ]
        return store
    }

    private func finishLoad(_ ok: Bool) {
        guard loadState == .loading else { return }
        loadState = ok ? .ready : .failed
        if !ok { dead = true }
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for w in waiters { w.resume(returning: ok) }
    }

    // MARK: Render

    func render(
        source: String,
        config: [String: Any],
        scale: CGFloat,
        maxPixelDimension: CGFloat,
        timeout: Duration
    ) async -> Result<Payload, MermaidRenderError> {
        guard let webView, loadState == .ready else { return .failure(.unavailable("The diagram engine is not loaded.")) }
        return await withCheckedContinuation { cont in
            var done = false
            func complete(_ r: Result<Payload, MermaidRenderError>) {
                guard !done else { return }
                done = true
                cont.resume(returning: r)
            }
            webView.callAsyncJavaScript(
                "return await globalThis.lumiMermaidRender(source, config, scale, maxDim);",
                arguments: ["source": source, "config": config, "scale": Double(scale), "maxDim": Double(maxPixelDimension)],
                in: nil,
                in: Self.world
            ) { result in
                switch result {
                case let .success(value): complete(Self.payload(from: value))
                case let .failure(error): complete(.failure(.unavailable(error.localizedDescription)))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !done else { return }
                self?.tearDown()
                complete(.failure(.timedOut))
            }
        }
    }

    func evaluate(_ js: String) async -> Any? {
        guard let webView else { return nil }
        let result = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: Self.world)
        return result.map { $0 as Any }
    }

    nonisolated static func payload(from value: Any) -> Result<Payload, MermaidRenderError> {
        guard let dict = value as? [String: Any] else {
            return .failure(.unavailable("Unexpected renderer response."))
        }
        guard dict["ok"] as? Bool == true else {
            return .failure(.syntax(cleanError(dict["error"] as? String ?? "Unknown error")))
        }
        guard let svg = dict["svg"] as? String, let png = dict["png"] as? String, !png.isEmpty,
              let w = (dict["width"] as? NSNumber)?.doubleValue, let h = (dict["height"] as? NSNumber)?.doubleValue,
              let s = (dict["scale"] as? NSNumber)?.doubleValue
        else { return .failure(.unavailable("The diagram could not be rasterised.")) }
        return .success(Payload(svg: svg, pngBase64: png, size: CGSize(width: w, height: h), scale: s))
    }

    /// Trim mermaid's error text to something a card can show.
    nonisolated static func cleanError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { line -> String in
            // Parser token lists run to dozens of entries; a few say enough.
            guard line.hasPrefix("Expecting "), let got = line.range(of: ", got ") else { return String(line) }
            let tokens = line[line.index(line.startIndex, offsetBy: 10)..<got.lowerBound]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let shown = tokens.prefix(4).joined(separator: ", ")
            return "Expecting \(shown)\(tokens.count > 4 ? ", …" : "")\(line[got.lowerBound...])"
        }
        let joined = lines.joined(separator: "\n")
        return joined.count > 600 ? String(joined.prefix(600)) + "…" : joined
    }

    func tearDown() {
        dead = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeAllContentRuleLists()
        webView = nil
        finishLoad(false)
    }

    // MARK: WKNavigationDelegate — only the initial blank document

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        if !allowedInitialNavigation, url == "about:blank" || url.isEmpty {
            allowedInitialNavigation = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // User scripts at document end have run; confirm mermaid landed.
        webView.callAsyncJavaScript(
            "return typeof mermaid === 'object' && typeof globalThis.lumiMermaidRender === 'function';",
            arguments: [:], in: nil, in: Self.world
        ) { [weak self] result in
            if case let .success(v) = result, (v as? Bool) == true { self?.finishLoad(true) } else { self?.finishLoad(false) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { tearDown() }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }
}
