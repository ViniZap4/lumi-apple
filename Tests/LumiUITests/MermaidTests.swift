import CoreGraphics
import Foundation
import Testing
import LumiKit
@testable import LumiUI

@Suite("Mermaid detection")
struct MermaidDetectionTests {
    @Test func fenceInfoStrings() {
        for yes in ["mermaid", "Mermaid", " mermaid ", "mermaid title=\"x\"", "{mermaid}", ".mermaid", "MERMAID\tfoo"] {
            #expect(MermaidSource.isMermaidFence(yes), "\(yes)")
        }
        for no in [nil, "", "swift", "mermaidjs", "mer maid", "math", "`mermaid`"] as [String?] {
            #expect(!MermaidSource.isMermaidFence(no), "\(no ?? "nil")")
        }
    }

    @Test func diagramKinds() {
        let cases: [(String, MermaidSource.DiagramKind)] = [
            ("graph TD\nA-->B", .flowchart),
            ("flowchart LR\nA-->B", .flowchart),
            ("sequenceDiagram\nA->>B: hi", .sequence),
            ("classDiagram\nclass A", .classDiagram),
            ("stateDiagram-v2\n[*] --> A", .state),
            ("erDiagram\nA ||--o{ B : has", .entityRelationship),
            ("gantt\ntitle x", .gantt),
            ("pie title Pets\n\"Dogs\" : 3", .pie),
            ("gitGraph\ncommit", .gitGraph),
            ("mindmap\n  root", .mindmap),
            ("xychart-beta\n x-axis [a]", .xyChart),
            ("C4Context\ntitle x", .c4),
            ("nonsense here", .unknown),
            ("", .unknown),
        ]
        for (src, kind) in cases { #expect(MermaidSource.diagramKind(of: src) == kind, "\(src)") }
    }

    @Test func kindSkipsFrontMatterCommentsAndDirectives() {
        let src = """

        ---
        title: Hello
        config:
          theme: forest
        ---
        %% a comment
        %%{init: {"theme": "dark"}}%%
        sequenceDiagram
          A->>B: hi
        """
        #expect(MermaidSource.diagramKind(of: src) == .sequence)
        #expect(MermaidSource.accessibilityLabel(for: src).hasPrefix("Sequence diagram"))
    }

    @MainActor
    @Test func readerBuilderRoutesMermaidFencesToTheDiagramAttachment() {
        let doc = MarkdownParser.parse("# T\n\n```mermaid\ngraph TD\nA-->B\n```\n\n```swift\nlet x = 1\n```\n")
        var payloads: [MarkdownBlockAttachment.Payload] = []
        let builder = MarkdownAttributedBuilder(style: MarkdownRenderStyle(theme: LumiTheme.tokyoNight.tokens))
        let built = NSMutableAttributedString()
        for block in doc.blocks { built.append(builder.fragment(for: block)) }
        built.enumerateAttribute(.attachment, in: NSRange(location: 0, length: built.length)) { value, _, _ in
            if let a = value as? MarkdownBlockAttachment { payloads.append(a.payload) }
        }
        #expect(payloads.contains(.mermaid(code: "graph TD\nA-->B\n")))
        #expect(payloads.contains { if case .code("swift", _) = $0 { return true } else { return false } })
    }
}

@Suite("Mermaid SVG sanitiser")
struct MermaidSanitizerTests {
    @Test func stripsScriptsAndActiveElements() {
        let dirty = """
        <svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><SCRIPT type="x">x</SCRIPT>\
        <g><foreignObject width="10"><div xmlns="http://www.w3.org/1999/xhtml" onclick="x()">hi</div></foreignObject>\
        <iframe src="https://evil"></iframe><embed src="x"/><animate attributeName="href" to="javascript:alert(1)"/>\
        <set attributeName="onmouseover" to="alert(1)"/><text x="1">keep me</text></g></svg>
        """
        let clean = MermaidSVGSanitizer.sanitize(dirty)
        let lower = clean.lowercased()
        for bad in ["<script", "foreignobject", "<iframe", "<embed", "<animate", "<set", "onclick", "javascript:"] {
            #expect(!lower.contains(bad), "\(bad) survived: \(clean)")
        }
        #expect(clean.contains("<text x=\"1\">keep me</text>"))
        #expect(MermaidSVGSanitizer.isClean(clean))
    }

    @Test func stripsEventHandlersInAllQuotings() {
        let dirty = #"<svg><rect onload="a()" ONERROR='b()' onmouseover=c() width="4"/><g on-x="1"></g></svg>"#
        let clean = MermaidSVGSanitizer.sanitize(dirty)
        #expect(!clean.lowercased().contains("onload"))
        #expect(!clean.lowercased().contains("onerror"))
        #expect(!clean.lowercased().contains("onmouseover"))
        #expect(clean.contains(#"width="4""#))
    }

    @Test func scrubsDangerousURLsButKeepsFragmentsAndWebLinks() {
        let dirty = """
        <svg><a href="javascript:alert(1)"><text>x</text></a><a xlink:href=" jav&#x09;ascript:alert(1)">y</a>\
        <a href="https://example.com/ok">ok</a><use href="#arrow"/><image href="data:image/svg+xml;base64,PHN2Zz4="/>\
        <image href="data:image/png;base64,iVBOR"/><image href="file:///etc/passwd"/>\
        <path marker-end="url(#arrowhead)"/><style>@import url(https://evil/x.css); .a{background:url(https://evil/p.png)}</style></svg>
        """
        let clean = MermaidSVGSanitizer.sanitize(dirty)
        #expect(!clean.lowercased().contains("javascript"))
        #expect(!clean.contains("jav&#x09;ascript"))
        #expect(clean.contains(#"href="https://example.com/ok""#))
        #expect(clean.contains(##"href="#arrow""##))
        #expect(!clean.contains("data:image/svg+xml"))
        #expect(clean.contains("data:image/png"))
        #expect(!clean.contains("file:///"))
        #expect(clean.contains("url(#arrowhead)"))
        #expect(!clean.contains("@import"))
        #expect(!clean.contains("https://evil"))
    }

    @Test func nestedTokenTricksDoNotReassemble() {
        let dirty = "<svg><scr<script>x</script>ipt>alert(1)</scr<script></script>ipt></svg>"
        let clean = MermaidSVGSanitizer.sanitize(dirty)
        #expect(!clean.lowercased().contains("<script"))
    }

    @Test func safeURLPolicy() {
        #expect(MermaidSVGSanitizer.isSafeURL("#a"))
        #expect(MermaidSVGSanitizer.isSafeURL("https://x"))
        #expect(MermaidSVGSanitizer.isSafeURL("mailto:a@b"))
        #expect(!MermaidSVGSanitizer.isSafeURL("JaVaScRiPt:alert(1)"))
        #expect(!MermaidSVGSanitizer.isSafeURL("java\nscript:alert(1)"))
        #expect(!MermaidSVGSanitizer.isSafeURL("data:text/html,<script>"))
        #expect(!MermaidSVGSanitizer.isSafeURL("data:image/svg+xml,<svg>"))
        #expect(!MermaidSVGSanitizer.isSafeURL("file:///etc/passwd"))
        #expect(!MermaidSVGSanitizer.isSafeURL("lumi://note"))
    }
}

@Suite("Mermaid cache + theme + config")
struct MermaidCacheTests {
    static func bitmap(_ w: Int, _ h: Int) -> MermaidBitmap {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return MermaidBitmap(ctx.makeImage()!)
    }

    static func diagram(_ w: Int = 10, _ h: Int = 10) -> MermaidRenderResult {
        .success(MermaidDiagram(svg: "<svg/>", bitmap: bitmap(w, h), size: CGSize(width: w, height: h), scale: 1))
    }

    @Test func keyIncludesSourceThemeAndQuantisedScale() {
        let a = MermaidRenderKey(source: "graph TD", themeFingerprint: "d", scale: 2)
        #expect(a == MermaidRenderKey(source: "graph TD", themeFingerprint: "d", scale: 2.0000001))
        #expect(a != MermaidRenderKey(source: "graph TD", themeFingerprint: "l", scale: 2))
        #expect(a != MermaidRenderKey(source: "graph LR", themeFingerprint: "d", scale: 2))
        #expect(a != MermaidRenderKey(source: "graph TD", themeFingerprint: "d", scale: 3))
    }

    @Test func lruEvictsOldestByCount() {
        var cache = MermaidRenderCache(maxEntries: 2, maxBytes: .max)
        let k = (0..<3).map { MermaidRenderKey(source: "s\($0)", themeFingerprint: "t", scale: 1) }
        cache.insert(Self.diagram(), for: k[0])
        cache.insert(Self.diagram(), for: k[1])
        _ = cache.value(for: k[0]) // touch → k1 is now oldest
        cache.insert(Self.diagram(), for: k[2])
        #expect(cache.contains(k[0]))
        #expect(!cache.contains(k[1]))
        #expect(cache.contains(k[2]))
        #expect(cache.count == 2)
    }

    @Test func lruEvictsByBytesAndTracksTotals() {
        var cache = MermaidRenderCache(maxEntries: 100, maxBytes: 100 * 100 * 4 * 2 + 4096)
        let k = (0..<3).map { MermaidRenderKey(source: "s\($0)", themeFingerprint: "t", scale: 1) }
        for key in k { cache.insert(Self.diagram(100, 100), for: key) }
        #expect(cache.count == 2)
        #expect(!cache.contains(k[0]))
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalBytes == 0)
    }

    @Test func failuresAreCachedCheaply() {
        var cache = MermaidRenderCache()
        let key = MermaidRenderKey(source: "bad", themeFingerprint: "t", scale: 1)
        cache.insert(.failure(.syntax("Parse error on line 1")), for: key)
        guard case .failure(.syntax)? = cache.value(for: key) else {
            Issue.record("expected cached syntax failure")
            return
        }
        #expect(MermaidRenderCache.cost(.failure(.timedOut)) < 4096)
    }

    @Test func themeVariablesFollowTokensAndFingerprintDiffers() {
        let night = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        let day = MermaidTheme(tokens: LumiTheme.tokyoDay.tokens)
        #expect(night.isDark && !day.isDark)
        #expect(night.variables["background"] == "#1a1b26")
        #expect(night.variables["primaryBorderColor"] == "#7aa2f7")
        #expect(night.variables["primaryTextColor"] == "#c0caf5")
        #expect(night.fingerprint != day.fingerprint)
        #expect(night.fingerprint == MermaidTheme(tokens: LumiTheme.tokyoNight.tokens).fingerprint)
        for theme in LumiTheme.allCases {
            let v = MermaidTheme(tokens: theme.tokens).variables
            for (key, value) in v where key != "fontFamily" && key != "fontSize" && key != "darkMode" {
                #expect(value.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil, "\(theme) \(key)=\(value)")
            }
            #expect(v["pie12"] != nil && v["git7"] != nil && v["cScale11"] != nil)
        }
    }

    @MainActor
    @Test func configIsStrictAndLocksSecurityKeys() {
        let cfg = MermaidRenderer.mermaidConfig(theme: MermaidTheme(tokens: LumiTheme.dracula.tokens))
        #expect(cfg["securityLevel"] as? String == "strict")
        #expect(cfg["htmlLabels"] as? Bool == false)
        #expect(cfg["startOnLoad"] as? Bool == false)
        let secure = cfg["secure"] as? [String] ?? []
        for key in ["securityLevel", "htmlLabels", "dompurifyConfig", "maxTextSize", "secure"] {
            #expect(secure.contains(key), "\(key) must not be overridable by %%{init}%%")
        }
        #expect((cfg["themeVariables"] as? [String: Any])?["darkMode"] as? Bool == true)
    }

    @Test func contentRulesBlockEverythingButBlankAndData() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(MermaidRenderer.contentRules.utf8)) as? [[String: Any]]
        let first = try #require(rules?.first)
        #expect((first["trigger"] as? [String: Any])?["url-filter"] as? String == ".*")
        #expect((first["action"] as? [String: Any])?["type"] as? String == "block")
        #expect(rules?.count == 3)
    }

    @Test func workerPayloadParsing() {
        guard case let .failure(.syntax(msg)) = MermaidWorker.payload(from: ["ok": false, "error": "Parse error on line 2:\n...\nExpecting 'X'"]) else {
            Issue.record("expected syntax failure")
            return
        }
        #expect(msg.hasPrefix("Parse error on line 2"))
        guard case .failure(.unavailable) = MermaidWorker.payload(from: "nonsense") else {
            Issue.record("expected unavailable")
            return
        }
        guard case .failure(.unavailable) = MermaidWorker.payload(from: ["ok": true, "svg": "<svg/>"]) else {
            Issue.record("missing png must not succeed")
            return
        }
        let noisy = MermaidWorker.cleanError("Parse error on line 3:\n...\nExpecting 'A', 'B', 'C', 'D', 'E', 'F', got 'G'")
        #expect(noisy.hasSuffix("Expecting 'A', 'B', 'C', 'D', …, got 'G'"))
        #expect(MermaidRenderError.syntax(noisy).blamedLine == 3)
        #expect(MermaidRenderError.timedOut.blamedLine == nil)
        #expect(MermaidDiagramCard.maxWidth(for: CGSize(width: 400, height: 800), maxHeight: 200) == 100)
        #expect(MermaidDiagramCard.maxWidth(for: CGSize(width: 400, height: 100), maxHeight: 200) == 400)
        let long = String(repeating: "x", count: 2000)
        #expect(MermaidWorker.cleanError(long).count <= 601)
    }

    @MainActor
    @Test func oversizedAndEmptySourcesFailWithoutAWebView() async {
        let renderer = MermaidRenderer(scriptURL: nil)
        let theme = MermaidTheme(tokens: LumiTheme.tokyoNight.tokens)
        let big = "graph TD\n" + String(repeating: "A-->B\n", count: MermaidSource.maxSourceLength / 5)
        guard case .failure(.tooLarge) = await renderer.render(source: big, theme: theme, scale: 2) else {
            Issue.record("expected tooLarge")
            return
        }
        guard case .failure(.syntax) = await renderer.render(source: "  \n", theme: theme, scale: 2) else {
            Issue.record("expected empty → syntax")
            return
        }
        #expect(renderer.workerCount == 0)
        // Missing bundle asset: unavailable, not a hang, and not cached.
        guard case .failure(.unavailable) = await renderer.render(source: "graph TD\nA-->B", theme: theme, scale: 2) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(renderer.cached(source: "graph TD\nA-->B", theme: theme, scale: 2) == nil)
    }

    @Test func errorCopyIsFriendly() {
        #expect(MermaidRenderError.syntax("Parse error").title.contains("syntax error"))
        #expect(MermaidRenderError.tooLarge(length: 60_000).detail.contains("60000"))
    }

    @Test func bundledScriptIsThePinnedVersion() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Web/mermaid.min.js")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        #expect(text.contains("version:\"\(MermaidRenderer.bundledVersion)\""))
        #expect(!text.contains("cdn.jsdelivr.net/npm/mermaid@"), "bundle must not lazy-load chunks from a CDN")
    }
}
