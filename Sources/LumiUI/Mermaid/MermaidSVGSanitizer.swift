import Foundation

/// Defence-in-depth scrub for SVG that leaves the renderer. The diagram
/// is *displayed* as a bitmap, so no SVG is ever interpreted in-app; this
/// pass protects the "Copy SVG" export (pasted into browsers, other
/// apps) and the rasterisation step.
///
/// Mermaid already runs with `securityLevel: 'strict'` (DOMPurify on
/// labels, no click callbacks) inside a JavaScript-disabled, network-
/// blocked page; this scrub assumes that layer can fail and removes:
///
///   - active elements: `script`, `foreignObject` (HTML islands carry
///     their own handlers), `iframe`, `object`, `embed`, `audio`,
///     `video`, `handler`, `listener`, `animate*`/`set` that could
///     rewrite `href`;
///   - every `on*=` event-handler attribute;
///   - `href` / `xlink:href` / `src` pointing anywhere but a fragment
///     (`#id`), `http(s):`, `mailto:` or an inline raster `data:image/…`
///     (never `data:image/svg+xml` — nested SVG documents are scripts
///     in disguise);
///   - CSS `@import` and `url(…)` that leaves the document, and
///     `javascript:` anywhere in a style.
///
/// It loops until a pass removes nothing, so split-token tricks like
/// `<scr<script>ipt>` collapse instead of reassembling.
public enum MermaidSVGSanitizer {
    public static func sanitize(_ svg: String) -> String {
        var out = svg
        for _ in 0..<8 {
            let next = pass(out)
            if next == out { break }
            out = next
        }
        return out
    }

    /// Whether an SVG still contains anything the sanitiser removes.
    /// Used by the tests and as a debug assertion on render output.
    public static func isClean(_ svg: String) -> Bool { pass(svg) == svg }

    // MARK: - Pass

    private static let blockedElements = [
        "script", "foreignObject", "iframe", "object", "embed", "audio", "video",
        "handler", "listener", "animate", "animateMotion", "animateTransform", "set",
    ]

    private static func pass(_ input: String) -> String {
        var s = input
        for name in blockedElements {
            // Paired element with body, then any orphan / self-closing tag.
            s = replace(s, #"<\s*\#(name)\b[^>]*>[\s\S]*?<\s*/\s*\#(name)\s*>"#, with: "")
            s = replace(s, #"<\s*/?\s*\#(name)\b[^>]*>"#, with: "")
        }
        // Event-handler attributes, quoted or bare.
        s = replace(s, #"\s+on[a-z0-9_:-]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "")
        // Link-ish attributes: keep only safe targets.
        s = scrubURLAttributes(s)
        // Styles: no external fetches, no script URLs.
        s = replace(s, #"@import[^;]*;?"#, with: "")
        s = replace(s, #"url\(\s*(?!['"]?\s*#)[^)]*\)"#, with: "none")
        s = replace(s, #"javascript\s*:"#, with: "")
        return s
    }

    private static func scrubURLAttributes(_ s: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"\s+((?:xlink:)?href|src|action|formaction)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#,
            options: [.caseInsensitive]
        ) else { return s }
        let ns = s as NSString
        var result = ""
        var cursor = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let value = [3, 4, 5].lazy
                .map { m.range(at: $0) }
                .first { $0.location != NSNotFound }
                .map { ns.substring(with: $0) } ?? ""
            if isSafeURL(value) { result += ns.substring(with: m.range) }
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    static func isSafeURL(_ raw: String) -> Bool {
        // Strip whitespace / control characters browsers ignore inside schemes.
        let v = String(raw.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })
            .replacingOccurrences(of: "&#", with: "")
            .lowercased()
        if v.isEmpty || v.hasPrefix("#") { return true }
        if v.hasPrefix("https:") || v.hasPrefix("http:") || v.hasPrefix("mailto:") { return true }
        if v.hasPrefix("data:image/png") || v.hasPrefix("data:image/jpeg") || v.hasPrefix("data:image/gif")
            || v.hasPrefix("data:image/webp") { return true }
        return false
    }

    private static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template
        )
    }
}
