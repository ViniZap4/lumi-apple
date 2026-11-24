import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LumiUI

/// Offscreen renders through the real, locked-down WKWebView pipeline.
/// WebKit needs a GUI session (window server) even for hidden web views,
/// so these run only when `LUMI_MERMAID_RENDER=1` (or `LUMI_RENDER_DIR`
/// is set, which also writes the PNGs there).
enum MermaidFixtures {
    static let flowchart = """
    flowchart LR
      A[Write note] --> B{Has diagram?}
      B -- yes --> C[Render offscreen]
      B -- no --> D[Plain prose]
      C --> E((Cache))
      E --> F[Show bitmap]
    """

    static let sequence = """
    sequenceDiagram
      participant W as Web
      participant S as Server
      participant A as Apple
      W->>S: Yjs update
      S-->>A: broadcast
      Note over S: fan-out to subscribers
      A->>S: awareness
      loop every 30s
        S->>S: snapshot
      end
    """

    static let gantt = """
    gantt
      title Mermaid rollout
      dateFormat YYYY-MM-DD
      section Apple
      Renderer      :done, a1, 2026-11-01, 5d
      Live Preview  :active, a2, after a1, 4d
      section Web
      Parity        :crit, w1, 2026-11-08, 6d
    """

    static let classDiagram = """
    classDiagram
      class Vault { +String slug +notes() }
      class Note { +String id +String title }
      Vault "1" --> "*" Note
    """

    static let pie = """
    pie title Notes by kind
      "Prose" : 62
      "Kanban" : 21
      "Canvas" : 17
    """

    static let broken = """
    flowchart LR
      A --> B -->
      ((( nope
    """

    /// One small source per remaining family, for the gallery test.
    static let gallery: [(String, String)] = [
        ("state", "stateDiagram-v2\n  [*] --> Draft\n  Draft --> Synced: save\n  Synced --> [*]"),
        ("er", "erDiagram\n  VAULT ||--o{ NOTE : contains\n  NOTE { string id string title }"),
        ("journey", "journey\n  title Capture\n  section Morning\n    Open app: 5: Me\n    Write: 3: Me"),
        ("gitgraph", "gitGraph\n  commit\n  branch feat\n  commit\n  checkout main\n  merge feat"),
        ("mindmap", "mindmap\n  root((lumi))\n    Web\n    Apple\n      macOS\n      iOS\n    TUI"),
        ("timeline", "timeline\n  title Releases\n  2025 : v1\n  2026 : v2 : v2.1"),
        ("quadrant", "quadrantChart\n  title Effort vs value\n  x-axis Low --> High\n  y-axis Low --> High\n  Mermaid: [0.3, 0.8]"),
        ("xychart", "xychart-beta\n  title Notes\n  x-axis [jan, feb, mar]\n  y-axis 0 --> 50\n  bar [10, 30, 45]"),
        ("sankey", "sankey-beta\nWeb,Server,10\nApple,Server,6\nServer,Disk,16"),
        ("block", "block-beta\n  columns 2\n  a[\"Client\"] b[\"Server\"]"),
        ("requirement", "requirementDiagram\n  requirement sync {\n    id: 1\n    text: live\n    risk: low\n    verifymethod: test\n  }"),
        ("c4", "C4Context\n  Person(u, \"User\")\n  System(l, \"lumi\")\n  Rel(u, l, \"writes\")"),
        ("kanban", "kanban\n  Todo\n    [Write spec]\n  Done\n    [Ship]"),
        ("architecture", "architecture-beta\n  service web(server)[Web]\n  service db(database)[DB]\n  web:R --> L:db"),
    ]

    static let all: [(String, String)] = [
        ("flowchart", flowchart), ("sequence", sequence), ("gantt", gantt),
        ("class", classDiagram), ("pie", pie),
    ]
}

let mermaidRenderEnabled: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["LUMI_MERMAID_RENDER"] == "1" || env["LUMI_RENDER_DIR"] != nil
}()

@Suite("Mermaid offscreen renders", .serialized, .enabled(if: mermaidRenderEnabled))
@MainActor
struct MermaidRenderTests {
    static var outDir: URL? {
        ProcessInfo.processInfo.environment["LUMI_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Web/mermaid.min.js")

    static let renderer = MermaidRenderer(scriptURL: scriptURL, maxConcurrent: 2, timeout: .seconds(30))

    @Test("flowchart / sequence / gantt / class / pie render to non-empty bitmaps (dark + light)")
    func rendersDiagrams() async throws {
        for (themeName, theme) in [("dark", LumiTheme.tokyoNight), ("light", LumiTheme.tokyoDay)] {
            let mt = MermaidTheme(tokens: theme.tokens)
            for (name, source) in MermaidFixtures.all {
                let result = await Self.renderer.render(source: source, theme: mt, scale: 2)
                let diagram = try result.get()
                #expect(diagram.size.width > 40 && diagram.size.height > 20, "\(name) size \(diagram.size)")
                #expect(diagram.bitmap.cgImage.width >= Int(diagram.size.width))
                #expect(Self.hasInk(diagram.bitmap.cgImage), "\(name) bitmap is blank")
                #expect(MermaidSVGSanitizer.isClean(diagram.svg), "\(name) svg not clean")
                #expect(!diagram.svg.contains("<foreignObject"))
                #expect(!diagram.svg.lowercased().contains("<script"))
                try Self.write(diagram, name: "\(name)-\(themeName)", background: theme.tokens.background)
            }
        }
    }

    @Test("every other diagram family renders with visible text (no foreignObject labels lost)")
    func gallery() async throws {
        let mt = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        var failures: [String] = []
        for (name, source) in MermaidFixtures.gallery {
            switch await Self.renderer.render(source: source, theme: mt, scale: 2) {
            case let .success(d):
                if !Self.hasInk(d.bitmap.cgImage) { failures.append("\(name): blank") }
                if !d.svg.contains("<text") && !d.svg.contains("<tspan") { failures.append("\(name): no SVG text") }
                try Self.write(d, name: "gallery-\(name)-dark", background: LumiTheme.tokyoNight.tokens.background)
            case let .failure(e):
                failures.append("\(name): \(e)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("syntax errors come back as .syntax with mermaid's message, and are cached")
    func syntaxError() async throws {
        let mt = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        let result = await Self.renderer.render(source: MermaidFixtures.broken, theme: mt, scale: 2)
        guard case let .failure(.syntax(message)) = result else {
            Issue.record("expected syntax error, got \(result)")
            return
        }
        #expect(!message.isEmpty)
        #expect(Self.renderer.cached(source: MermaidFixtures.broken, theme: mt, scale: 2) != nil)
    }

    @Test("cache hit returns the same bitmap; theme change re-renders")
    func cacheAndTheme() async throws {
        let dark = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        let light = MermaidTheme(tokens: LumiTheme.tokyoDay.tokens)
        let a = try await Self.renderer.render(source: MermaidFixtures.pie, theme: dark, scale: 2).get()
        let b = try await Self.renderer.render(source: MermaidFixtures.pie, theme: dark, scale: 2).get()
        #expect(a.bitmap === b.bitmap)
        let c = try await Self.renderer.render(source: MermaidFixtures.pie, theme: light, scale: 2).get()
        #expect(a.bitmap !== c.bitmap)
    }

    @Test("concurrent identical requests coalesce; distinct ones all finish")
    func concurrency() async throws {
        let r = MermaidRenderer(scriptURL: Self.scriptURL, maxConcurrent: 2, timeout: .seconds(30))
        let mt = MermaidTheme(tokens: LumiTheme.catppuccinMocha.tokens)
        async let one = r.render(source: MermaidFixtures.flowchart, theme: mt, scale: 1)
        async let two = r.render(source: MermaidFixtures.flowchart, theme: mt, scale: 1)
        async let three = r.render(source: MermaidFixtures.sequence, theme: mt, scale: 1)
        async let four = r.render(source: MermaidFixtures.gantt, theme: mt, scale: 1)
        let results = await [one, two, three, four]
        let bitmaps = try results.map { try $0.get().bitmap }
        #expect(bitmaps[0] === bitmaps[1])
        #expect(r.workerCount <= 2)
    }

    @Test("a script-injection attempt renders inert and leaves no active content")
    func injectionIsInert() async throws {
        let mt = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        let source = """
        %%{init: {"securityLevel": "loose", "htmlLabels": true, "dompurifyConfig": {"ADD_TAGS": ["script"]}}}%%
        flowchart LR
          A["<img src=x onerror=alert(1)>"] --> B["<script>alert(2)</script>"]
          click A "javascript:alert(3)"
        """
        let result = await Self.renderer.render(source: source, theme: mt, scale: 1)
        if case let .success(d) = result {
            let svg = d.svg.lowercased()
            #expect(!svg.contains("<script"))
            #expect(!svg.contains("onerror"))
            #expect(!svg.contains("javascript:"))
            #expect(!svg.contains("<foreignobject"))
        }
    }

    // MARK: helpers

    static func hasInk(_ image: CGImage) -> Bool {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: px.count, by: 4).contains { px[$0] > 16 }
    }

    static func write(_ d: MermaidDiagram, name: String, background: Color) throws {
        guard let dir = outDir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = d.bitmap.cgImage
        let pad = 24 * Int(d.scale.rounded())
        let w = img.width + pad * 2, h = img.height + pad * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let bg = RGB(background)
        ctx.setFillColor(CGColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: pad, y: pad, width: img.width, height: img.height))
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                dir.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        try d.svg.write(to: dir.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    }
}

@Suite("Mermaid sandbox", .serialized, .enabled(if: mermaidRenderEnabled))
@MainActor
struct MermaidSandboxTests {
    @Test("all egress is pinned to the dead sink proxy (even navigation preconnects)")
    func egressGoesToSinkProxy() async throws {
        // Point the sink at a local listener: a navigation / fetch to a
        // non-loopback address must arrive here as a proxy handshake
        // (in the app the sink is the closed port 9, so it just fails).
        let listener = try LocalListener()
        defer { listener.close() }
        MermaidWorker.proxySinkPort = listener.port
        defer { MermaidWorker.proxySinkPort = 9 }
        let renderer = MermaidRenderer(scriptURL: MermaidRenderTests.scriptURL, maxConcurrent: 1, timeout: .seconds(30))
        _ = await renderer.probeForTesting("""
        const a = document.createElement('a'); a.href = 'http://198.51.100.7/x'; document.body.appendChild(a);
        HTMLAnchorElement.prototype.dispatchEvent.call(a, new MouseEvent('click'));
        location.href = 'http://198.51.100.7/nav';
        await new Promise(r => setTimeout(r, 800)); return 1;
        """)
        try await Task.sleep(for: .milliseconds(500))
        let lines = listener.requestLines
        #expect(!lines.isEmpty, "expected the preconnect to hit the sink proxy")
        #expect(lines.allSatisfy { $0.hasPrefix("CONNECT 198.51.100.7") || $0.hasPrefix("\u{05}") || $0 == "(no request)" },
                "\(lines)")
    }

    @Test("network, page script and navigation are blocked in the render web view")
    func sandbox() async throws {
        let listener = try LocalListener()
        defer { listener.close() }
        let port = listener.port
        let renderer = MermaidRenderer(scriptURL: MermaidRenderTests.scriptURL, maxConcurrent: 1, timeout: .seconds(30))
        let js = """
        const r = {};
        try { await fetch('http://127.0.0.1:\(port)/fetch'); r.fetch = 'ok'; } catch (e) { r.fetch = 'blocked'; }
        try { const i = new Image(); i.src = 'http://127.0.0.1:\(port)/img.png'; await i.decode(); r.img = 'ok'; }
        catch (e) { r.img = 'blocked'; }
        // Page-world handlers must be inert (allowsContentJavaScript = false).
        document.title = 'clean';
        const host = document.createElement('div');
        host.innerHTML = '<img src="data:," onerror="document.title=\\'pwned\\'"><svg onload="document.title=\\'pwned\\'"></svg>';
        document.body.appendChild(host);
        await new Promise(res => setTimeout(res, 300));
        r.title = document.title;
        const link = document.createElement('a');
        link.href = 'http://127.0.0.1:\(port)/nav';
        document.body.appendChild(link);
        link.click();
        try { window.open('http://127.0.0.1:\(port)/popup'); } catch (e) {}
        await new Promise(res => setTimeout(res, 300));
        r.still = !!document.getElementById('stage');
        return r;
        """
        let result = await renderer.probeForTesting(js) as? [String: Any]
        let r = try #require(result)
        #expect(r["fetch"] as? String == "blocked")
        #expect(r["img"] as? String == "blocked")
        #expect(r["title"] as? String == "clean", "content-world JS must not run page handlers")
        #expect(r["still"] as? Bool == true, "navigation must be cancelled")
        // Also through a real render with a CSS url() directive.
        let theme = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        _ = await renderer.render(source: """
        %%{init: {"themeCSS": ".node rect { fill: url(http://127.0.0.1:\(port)/css.svg#x); }"}}%%
        flowchart LR
          A --> B
        """, theme: theme, scale: 1)
        try await Task.sleep(for: .milliseconds(500))
        #expect(listener.connections == 0, "the render web view reached the network: \(listener.requestLines)")
    }
}

/// Minimal loopback TCP listener that just counts accepted connections.
final class LocalListener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var count = 0
    private var requests: [String] = []
    var requestLines: [String] { lock.withLock { requests } }
    private var source: DispatchSourceRead?

    var connections: Int { lock.withLock { count } }

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .global())
        src.setEventHandler { [weak self] in
            let c = accept(sock, nil, nil)
            var line = "(no request)"
            if c >= 0 {
                var tv = timeval(tv_sec: 0, tv_usec: 300_000)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var buf = [UInt8](repeating: 0, count: 512)
                let n = read(c, &buf, buf.count)
                if n > 0 { line = String(decoding: buf[0..<n], as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? "" }
                Darwin.close(c)
            }
            self?.lock.withLock { self?.count += 1; self?.requests.append(line) }
        }
        src.resume()
        source = src
    }

    func close() {
        source?.cancel()
        Darwin.close(fd)
    }
}

#if canImport(AppKit)
import AppKit

/// The SwiftUI surfaces (card, error card, skeleton, compact) hosted in
/// an `NSHostingView` and cached to PNG — no window, no app launch.
@Suite("Mermaid card renders", .serialized, .enabled(if: mermaidRenderEnabled))
@MainActor
struct MermaidCardRenderTests {
    @Test func cards() async throws {
        for (themeName, theme) in [("dark", LumiTheme.tokyoNight), ("light", LumiTheme.tokyoDay)] {
            let tokens = theme.tokens
            let diagram = try await MermaidRenderTests.renderer.render(
                source: MermaidFixtures.flowchart, theme: MermaidTheme(tokens: tokens), scale: 2
            ).get()
            let broken = await MermaidRenderTests.renderer.render(
                source: MermaidFixtures.broken, theme: MermaidTheme(tokens: tokens), scale: 2
            )
            guard case let .failure(error) = broken else {
                Issue.record("expected failure")
                return
            }
            let page = VStack(alignment: .leading, spacing: 18) {
                Text("Reader / Live Preview card").font(.caption).foregroundStyle(tokens.textDim)
                MermaidDiagramCard(source: MermaidFixtures.flowchart, diagram: diagram, compact: false)
                Text("Error card").font(.caption).foregroundStyle(tokens.textDim)
                MermaidErrorCard(source: MermaidFixtures.broken, error: error, compact: false)
                Text("Skeleton (rendering)").font(.caption).foregroundStyle(tokens.textDim)
                MermaidSkeleton(height: 120)
                Text("Compact (kanban / canvas card)").font(.caption).foregroundStyle(tokens.textDim)
                MermaidDiagramCard(source: MermaidFixtures.flowchart, diagram: diagram, compact: true)
                    .frame(width: 260)
            }
            .padding(24)
            .frame(width: 760)
            .background(tokens.background)
            .environment(\.theme, tokens)

            let host = NSHostingView(rootView: page)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 300)
            guard let dir = MermaidRenderTests.outDir,
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("cards-\(themeName).png"))
        }
    }
}
#endif
