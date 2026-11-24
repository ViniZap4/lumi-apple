import Foundation

// Following links (SPEC-PARTE2 §3 "Following links") — one routing table
// for every surface (reader, split preview, Live Preview, the editor's
// normal mode, the hover card). Port of the web's `link-open.ts`; pure.
//
//   - `gf` / Enter / a plain click         → the current pane
//   - `⌃w f` / `⌃w Enter`, ⌘-click          → a vertical split
//   - `⌃w F`, ⇧⌘-click                      → a horizontal split
//
// External links never navigate the app: they open in the browser, and
// only through an explicit action (a click or Enter), never on hover.

/// Where a followed link opens.
public enum LinkOpenWhere: String, Sendable, Hashable, Codable {
    case current, vsplit, hsplit

    /// The split axis a non-current target opens along.
    public var axis: SplitAxis? {
        switch self {
        case .current: return nil
        case .vsplit: return .vertical
        case .hsplit: return .horizontal
        }
    }

    /// Where a click on a note link opens. ⌘ (the platform modifier on a
    /// Mac; ⌃-click is the context menu there) → split; ⇧ picks the
    /// horizontal one. nil = not ours (⌥-click, a non-primary button).
    public static func fromClick(command: Bool, shift: Bool, option: Bool = false, button: Int = 0) -> LinkOpenWhere? {
        if button != 0 || option { return nil }
        if !command { return shift ? nil : .current }
        return shift ? .hsplit : .vsplit
    }
}

/// What a link points at.
public enum LinkTarget: Sendable, Hashable {
    case note(ExplorerNote)
    /// A note link whose target does not exist (yet): its resolved path.
    case missing(String)
    case external(String)
    case anchor(String)
    /// `javascript:`, `data:`, `//host`, unknown schemes — never followed.
    case unsafe
}

/// A link found in source text (editor cursor).
public struct LinkAt: Sendable, Hashable {
    public var href: String
    /// The `[[…]]` form.
    public var wiki: Bool
    /// Character offsets of the whole link in the text.
    public var from: Int
    public var to: Int

    public init(href: String, wiki: Bool, from: Int, to: Int) {
        self.href = href
        self.wiki = wiki
        self.from = from
        self.to = to
    }
}

public enum LinkRouting {
    // MARK: Resolution

    private static func comparable(_ n: ExplorerNote) -> String {
        var p = NoteTree.normalizePath(n.path.isEmpty ? n.id + ".md" : n.path).lowercased()
        if p.hasSuffix(".md") { p.removeLast(3) }
        return p
    }

    /// `[[Name]]`, `[[folder/Name|alias]]`, `[[Name#Heading]]` → note:
    /// the book path first, then the title, then the file name (web
    /// `findNoteByWiki`).
    public static func findNoteByWiki(_ notes: [ExplorerNote], _ raw: String) -> ExplorerNote? {
        let name = String(raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { return nil }
        var lower = name.lowercased()
        if lower.hasSuffix(".md") { lower.removeLast(3) }
        lower = NoteTree.normalizePath(lower)
        return notes.first { comparable($0) == lower }
            ?? notes.first { $0.title.trimmingCharacters(in: .whitespaces).lowercased() == lower }
            ?? notes.first { NoteTree.baseName(comparable($0)) == lower }
    }

    /// Book-relative target of a relative note href written in note
    /// `fromPath` (`../a/b.md`, `/x`, `other`). `.md` is added when the
    /// href has no `.md` / `.canvas` extension. nil when it is not a note
    /// href or climbs above the book root (web `resolveNoteHref`).
    public static func resolveNoteHref(_ href: String, from fromPath: String) -> String? {
        guard let path = LivePreview.resolveNoteLink(href, from: fromPath) else { return nil }
        let lower = path.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".canvas") { return path }
        return path + ".md"
    }

    /// The note an href points at: exact path, then case-insensitive.
    public static func findNoteByHref(_ notes: [ExplorerNote], from fromPath: String, _ href: String) -> ExplorerNote? {
        guard let target = resolveNoteHref(href, from: fromPath) else { return nil }
        let norm: (ExplorerNote) -> String = { NoteTree.normalizePath($0.path.isEmpty ? $0.id + ".md" : $0.path) }
        return notes.first { norm($0) == target } ?? notes.first { norm($0).lowercased() == target.lowercased() }
    }

    /// Classify an href found in note `fromPath`. `wiki` = the `[[…]]`
    /// form. A relative link that names no existing note falls back to
    /// the wiki rules (the reader turns `[[x]]` into `[x](x.md)`).
    public static func classify(_ notes: [ExplorerNote], from fromPath: String, href raw: String, wiki: Bool = false) -> LinkTarget {
        let h = raw.trimmingCharacters(in: .whitespaces)
        if wiki {
            if let n = findNoteByWiki(notes, h) { return .note(n) }
            let name = String(h.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            return .missing(name)
        }
        if h.hasPrefix("#") { return .anchor(String(h.dropFirst())) }
        if h.hasPrefix("//") { return .unsafe }
        if h.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            if let safe = LivePreview.safeHref(h) { return .external(safe) }
            return .unsafe
        }
        if let n = findNoteByHref(notes, from: fromPath, h) { return .note(n) }
        guard let p = resolveNoteHref(h, from: fromPath) else { return .unsafe }
        return .missing(p)
    }

    /// Wiki targets written in `text` (`[[a]]`, `[[b|B]]` → `a`, `b`),
    /// for telling the reader's rewritten `[x](x.md)` links apart.
    public static func wikiTargets(in text: String) -> Set<String> {
        var out = Set<String>()
        var rest = text[...]
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            let inner = after[..<close.lowerBound]
            if !inner.contains("\n") {
                let target = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let name = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let t = name.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.insert(t.lowercased()) }
            }
            rest = after[close.upperBound...]
        }
        return out
    }

    // MARK: Links in source text

    /// The link under `pos` (character offset) in `text`: `[label](href)`
    /// (images skipped), `<https://…>` autolinks, `[[wiki]]` and bare
    /// http(s) URLs. Only the line holding `pos` is scanned (web `linkAt`).
    public static func linkAt(_ text: String, _ pos: Int) -> LinkAt? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        let p = max(0, min(pos, chars.count))
        var start = p
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = p
        while end < chars.count, chars[end] != "\n" { end += 1 }
        let line = String(chars[start..<end])
        let col = p - start
        let ns = line as NSString
        // NSString offsets are UTF-16; map them back to character columns.
        func charCol(_ utf16: Int) -> Int {
            let idx = String.Index(utf16Offset: utf16, in: line)
            return line.distance(from: line.startIndex, to: idx)
        }
        let patterns: [(String, (NSTextCheckingResult) -> (String, Bool)?)] = [
            (#"\[\[([^\]\n]+)\]\]"#, { m in (ns.substring(with: m.range(at: 1)), true) }),
            (#"(!?)\[(?:[^\]\\\n]|\\.)*\]\(\s*(<[^>\n]*>|[^\s)]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*\)"#, { m in
                guard m.range(at: 1).length == 0 else { return nil }
                var href = ns.substring(with: m.range(at: 2))
                if href.hasPrefix("<"), href.hasSuffix(">") { href = String(href.dropFirst().dropLast()) }
                return (href, false)
            }),
            (#"<((?:https?|mailto):[^>\s]+)>"#, { m in (ns.substring(with: m.range(at: 1)), false) }),
            (#"\bhttps?://[^\s<>()\]]+[^\s<>()\].,;:!?'"]"#, { m in (ns.substring(with: m.range), false) }),
        ]
        for (pattern, get) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let from = charCol(m.range.location)
                let to = charCol(m.range.location + m.range.length)
                guard col >= from, col <= to - 1 else { continue }
                if let (href, wiki) = get(m) {
                    return LinkAt(href: href, wiki: wiki, from: start + from, to: start + to)
                }
                break
            }
        }
        return nil
    }

    // MARK: External URL card

    public struct URLCard: Sendable, Hashable {
        public var host: String
        public var path: String
        public var secure: Bool
        public var mail: Bool
    }

    /// Short display parts of an external URL (hover card). Never fetches.
    public static func urlCard(_ raw: String) -> URLCard? {
        guard let safe = LivePreview.safeHref(raw), let comps = URLComponents(string: safe),
              let scheme = comps.scheme?.lowercased() else { return nil }
        if scheme == "mailto" {
            return URLCard(host: comps.path.removingPercentEncoding ?? comps.path, path: "", secure: false, mail: true)
        }
        guard scheme == "http" || scheme == "https", let host = comps.host else { return nil }
        let port = comps.port.map { ":\($0)" } ?? ""
        var path = (comps.percentEncodedPath.removingPercentEncoding ?? comps.path)
            + (comps.percentEncodedQuery.map { "?" + ($0.removingPercentEncoding ?? $0) } ?? "")
        if path.hasSuffix("/") { path.removeLast() }
        if path.count > 80 { path = String(path.prefix(79)) + "…" }
        return URLCard(host: host + port, path: path, secure: scheme == "https", mail: false)
    }
}
