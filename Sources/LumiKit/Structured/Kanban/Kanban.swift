import Foundation

// Obsidian Kanban board format: parser + serializer (SPEC-PARTE2 §5).
// Port of web-client `lib/kanban/kanban.ts` — same fixtures, same
// offsets (UTF-16 code units).
//
// The parse is lossless: every byte of the input belongs to exactly one
// segment (preamble, lane heading, card, gap, footer), so serializing
// the segments reproduces the input byte for byte. Edits are never made
// by re-serializing a model; `KanbanEdits` plans ranged text edits from
// the offsets recorded here.
//
// The text may be a full file (with frontmatter) or a note body as the
// server's CRDT holds it (frontmatter stripped); both parse the same.

public enum KanbanFormat: String, Sendable, Equatable {
    case board, basic
}

public struct KanbanCard: Sendable, Equatable {
    /// Index in its lane.
    public var index: Int
    public var lane: Int
    /// [start, end) of the card's lines, trailing line break included.
    public var start: Int
    public var end: Int
    public var raw: String
    /// List marker: `-`, `*` or `+`.
    public var marker: String
    public var hasCheckbox: Bool
    /// Absolute offset of the checkbox character, or -1.
    public var checkOffset: Int
    public var checkChar: String
    public var checked: Bool
    /// [textStart, textEnd): the card content (no marker, no trailing EOL).
    public var textStart: Int
    public var textEnd: Int
    /// Content with continuation indentation removed, lines joined by `\n`.
    public var text: String
    /// Indentation of continuation lines (common prefix), "" if single line.
    public var indent: String
}

public struct KanbanLane: Sendable, Equatable {
    public var index: Int
    public var title: String
    /// [start, end): heading line through the line before the next lane/footer.
    public var start: Int
    public var end: Int
    public var headingEnd: Int
    public var titleStart: Int
    public var titleEnd: Int
    /// Lane carries the plugin's `**Complete**` flag.
    public var complete: Bool
    public var cards: [KanbanCard]
}

public struct KanbanSegment: Sendable, Equatable {
    public enum Kind: String, Sendable { case preamble, heading, card, gap, footer }
    public var kind: Kind
    public var start: Int
    public var end: Int
}

public struct KanbanBoard: Sendable, Equatable {
    public var text: String
    /// From frontmatter (or the settings block) when present.
    public var format: KanbanFormat?
    public var eol: String
    public var frontmatter: Range<Int>?
    /// Text before the first lane (frontmatter included).
    public var preambleEnd: Int
    public var lanes: [KanbanLane]
    /// [footerStart, length): archive + settings block.
    public var footerStart: Int
    public var settings: (start: Int, end: Int, json: JSONValue?)?
    /// Dominant list marker (for new cards).
    public var marker: String
    /// Continuation indent used by existing multi-line cards ('\t' by default).
    public var indent: String
    public var segments: [KanbanSegment]

    public static func == (l: KanbanBoard, r: KanbanBoard) -> Bool {
        l.text == r.text && l.segments == r.segments && l.lanes == r.lanes
    }

    /// UTF-16 view of `text` for offset slicing.
    var ns: NSString { text as NSString }

    public func slice(_ from: Int, _ to: Int) -> String { (text as NSString).substring(with: NSRange(location: from, length: to - from)) }
}

// MARK: - Small regex helper (ICU on line strings; offsets are UTF-16)

struct Rx: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }
    func match(_ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }
    func test(_ s: String) -> Bool { match(s) != nil }
    func replace(_ s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
}

extension NSTextCheckingResult {
    func group(_ i: Int, in s: String) -> String? {
        let r = range(at: i)
        guard r.location != NSNotFound else { return nil }
        return (s as NSString).substring(with: r)
    }
}

public enum Kanban {
    struct Line {
        var start: Int
        /// Content end (before `\r\n` / `\n`).
        var cEnd: Int
        /// After the line break.
        var end: Int
        var s: String
    }

    static func splitLines(_ text: String) -> [Line] {
        let ns = text as NSString
        let n = ns.length
        var out: [Line] = []
        var i = 0
        while i < n {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: i, length: n - i))
            let nl = r.location == NSNotFound ? -1 : r.location
            let end = nl < 0 ? n : nl + 1
            var cEnd = nl < 0 ? n : nl
            if cEnd > i, ns.character(at: cEnd - 1) == 13 { cEnd -= 1 }
            out.append(Line(start: i, cEnd: cEnd, end: end, s: ns.substring(with: NSRange(location: i, length: cEnd - i))))
            i = end
        }
        return out
    }

    static let fmOpen = Rx("^---[ \\t]*$")
    static let fmClose = Rx("^(?:---|\\.\\.\\.)[ \\t]*$")
    static let lane = Rx("^##(?:[ \\t]+(.*?))?[ \\t]*$")
    static let item = Rx("^([-*+])[ \\t]+(?:\\[(.)\\](?=[ \\t]|$)[ \\t]?)?")
    static let itemNoBox = Rx("^([-*+])[ \\t]+")
    static let settingsRx = Rx("^%%[ \\t]*kanban:settings")
    static let archive = Rx("^\\*\\*\\*[ \\t]*$")
    static let complete = Rx("^\\*\\*Complete\\*\\*[ \\t]*$")
    static let blank = Rx("^[ \\t]*$")
    static let indented = Rx("^[ \\t]+\\S")
    static let formatLine = Rx("^kanban-plugin:[ \\t]*['\"]?(board|basic)['\"]?[ \\t]*$", [.anchorsMatchLines])
    static let settingsEnd = Rx("%%[ \\t]*$")
    static let braces = Rx("\\{[\\s\\S]*\\}")
    static let leadingWS = Rx("^[ \\t]*")

    /// `kanban-plugin: board|basic` in frontmatter text.
    public static func format(frontmatterText fm: String?) -> KanbanFormat? {
        guard let fm, !fm.isEmpty, let m = formatLine.match(fm), let v = m.group(1, in: fm) else { return nil }
        return KanbanFormat(rawValue: v)
    }

    /// `kanban-plugin` of a parsed frontmatter / settings object.
    public static func format(frontmatter fm: [String: Any]?) -> KanbanFormat? {
        guard let v = fm?["kanban-plugin"] as? String else { return nil }
        return KanbanFormat(rawValue: v)
    }

    static func format(json: JSONValue?) -> KanbanFormat? {
        guard let o = json?.objectValue, let v = o["kanban-plugin"]?.stringValue else { return nil }
        return KanbanFormat(rawValue: v)
    }

    /// Whether a full markdown file is a kanban board (frontmatter flag).
    public static func isKanbanText(_ text: String) -> Bool {
        let ls = splitLines(text)
        guard let first = ls.first, fmOpen.test(first.s) else { return false }
        for i in 1..<ls.count where fmClose.test(ls[i].s) {
            let start = ls[1].start
            let body = (text as NSString).substring(with: NSRange(location: start, length: ls[i].start - start))
            return format(frontmatterText: body) != nil
        }
        return false
    }

    /// A note *body* (frontmatter stripped, as server CRDT text holds it)
    /// that carries the plugin's `%% kanban:settings` block naming a
    /// format. Used where the frontmatter is not at hand (Apple: the
    /// server note list has no frontmatter).
    public static func hasSettingsBlock(_ text: String) -> Bool {
        guard text.contains("kanban:settings") else { return false }
        return parse(text).settings.flatMap { format(json: $0.json) } != nil
    }

    static func commonIndent(_ lines: [String]) -> String {
        var ind: [UInt16]?
        for l in lines {
            if blank.test(l) { continue }
            let m = Array(l.utf16.prefix { $0 == 0x20 || $0 == 0x09 })
            if let cur = ind {
                var k = 0
                while k < cur.count, k < m.count, cur[k] == m[k] { k += 1 }
                ind = Array(cur[0..<k])
            } else {
                ind = m
            }
        }
        return ind.map { String(decoding: $0, as: UTF16.self) } ?? ""
    }

    public static func parse(_ text: String) -> KanbanBoard {
        let ns = text as NSString
        let length = ns.length
        let lines = splitLines(text)
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var li = 0
        var frontmatter: Range<Int>?
        var fmt: KanbanFormat?

        if let first = lines.first, fmOpen.test(first.s) {
            for j in 1..<max(1, lines.count) where fmClose.test(lines[j].s) {
                frontmatter = 0..<lines[j].end
                fmt = format(frontmatterText: ns.substring(with: NSRange(location: lines[0].end, length: lines[j].start - lines[0].end)))
                li = j + 1
                break
            }
        }

        // Footer: first archive divider or settings block after the frontmatter.
        var footerLine = lines.count
        for j in li..<lines.count where settingsRx.test(lines[j].s) || archive.test(lines[j].s) {
            footerLine = j
            break
        }
        let footerStart = footerLine < lines.count ? lines[footerLine].start : length

        var settings: (start: Int, end: Int, json: JSONValue?)?
        if footerLine < lines.count {
            for j in footerLine..<lines.count where settingsRx.test(lines[j].s) {
                var k = j
                // The block ends at the first line that is (or ends with) `%%` after the opener.
                var m = j + 1
                while m < lines.count {
                    k = m
                    if settingsEnd.test(lines[m].s) { break }
                    m += 1
                }
                let inner = ns.substring(with: NSRange(location: lines[j].end, length: max(0, lines[k].start - lines[j].end)))
                var json: JSONValue?
                if let jm = braces.match(inner) {
                    json = try? JSONValue.parse((inner as NSString).substring(with: jm.range))
                }
                settings = (lines[j].start, lines[k].end, json)
                if fmt == nil { fmt = format(json: json) }
                break
            }
        }

        var segments: [KanbanSegment] = []
        var lanes: [KanbanLane] = []
        var markerCounts: [(String, Int)] = []
        var indent = ""

        // Preamble: up to the first lane heading.
        var firstLane = li
        while firstLane < footerLine, !lane.test(lines[firstLane].s) { firstLane += 1 }
        let preambleEnd = firstLane < footerLine ? lines[firstLane].start : footerStart
        if preambleEnd > 0 { segments.append(KanbanSegment(kind: .preamble, start: 0, end: preambleEnd)) }

        var j = firstLane
        while j < footerLine {
            let h = lines[j]
            let m = lane.match(h.s)!
            let title = m.group(1, in: h.s) ?? ""
            let titleStart: Int
            if title.isEmpty {
                titleStart = h.cEnd
            } else {
                let hs = h.s as NSString
                let r = hs.range(of: title, options: .literal, range: NSRange(location: 2, length: hs.length - 2))
                titleStart = h.start + r.location
            }
            var ln = KanbanLane(index: lanes.count, title: title, start: h.start, end: h.end, headingEnd: h.end,
                                titleStart: titleStart, titleEnd: titleStart + (title as NSString).length,
                                complete: false, cards: [])
            segments.append(KanbanSegment(kind: .heading, start: h.start, end: h.end))
            j += 1
            var gapStart = -1
            func flushGap(_ upTo: Int) {
                if gapStart >= 0, upTo > gapStart { segments.append(KanbanSegment(kind: .gap, start: gapStart, end: upTo)) }
                gapStart = -1
            }
            while j < footerLine, !lane.test(lines[j].s) {
                let l = lines[j]
                guard var im = item.match(l.s) else {
                    if complete.test(l.s) { ln.complete = true }
                    if gapStart < 0 { gapStart = l.start }
                    j += 1
                    continue
                }
                // JS `(.)` is one UTF-16 unit: a checkbox holding a
                // surrogate pair is not a checkbox there either.
                var boxChar = im.group(2, in: l.s)
                if let b = boxChar, (b as NSString).length != 1 {
                    im = itemNoBox.match(l.s)!
                    boxChar = nil
                }
                flushGap(l.start)
                // Card lines: the item line + indented continuation lines
                // (blank lines only when followed by more indented lines).
                var last = j
                var k = j + 1
                while k < footerLine {
                    if indented.test(lines[k].s) {
                        last = k
                        k += 1
                        continue
                    }
                    if blank.test(lines[k].s) {
                        var n = k
                        while n < footerLine, blank.test(lines[n].s) { n += 1 }
                        if n < footerLine, indented.test(lines[n].s), !lane.test(lines[n].s) {
                            k = n
                            continue
                        }
                    }
                    break
                }
                let cont = lines[(j + 1)..<(last + 1)].map(\.s)
                let ind = commonIndent(Array(cont))
                if !ind.isEmpty, indent.isEmpty { indent = ind }
                let ls = l.s as NSString
                let matchLen = im.range.length
                let firstText = ls.substring(from: matchLen)
                let textLines = [firstText] + cont.map { c in
                    c.hasPrefix(ind) ? (c as NSString).substring(from: (ind as NSString).length) : leadingWS.replace(c, with: "")
                }
                let hasCheckbox = boxChar != nil
                let checkOffset = hasCheckbox ? l.start + (ls.substring(to: matchLen) as NSString).range(of: "[").location + 1 : -1
                let marker = im.group(1, in: l.s) ?? "-"
                let card = KanbanCard(
                    index: ln.cards.count, lane: ln.index, start: l.start, end: lines[last].end,
                    raw: ns.substring(with: NSRange(location: l.start, length: lines[last].end - l.start)),
                    marker: marker, hasCheckbox: hasCheckbox, checkOffset: checkOffset,
                    checkChar: boxChar ?? " ", checked: hasCheckbox && boxChar != " ",
                    textStart: l.start + matchLen, textEnd: lines[last].cEnd,
                    text: textLines.joined(separator: "\n"), indent: ind
                )
                if let idx = markerCounts.firstIndex(where: { $0.0 == marker }) {
                    markerCounts[idx].1 += 1
                } else {
                    markerCounts.append((marker, 1))
                }
                ln.cards.append(card)
                segments.append(KanbanSegment(kind: .card, start: card.start, end: card.end))
                j = last + 1
            }
            ln.end = j < lines.count ? lines[j].start : length
            flushGap(ln.end)
            lanes.append(ln)
        }

        if footerStart < length { segments.append(KanbanSegment(kind: .footer, start: footerStart, end: length)) }

        var marker = "-"
        var best = 0
        for (mk, n) in markerCounts where n > best {
            marker = mk
            best = n
        }

        return KanbanBoard(text: text, format: fmt, eol: eol, frontmatter: frontmatter, preambleEnd: preambleEnd,
                           lanes: lanes, footerStart: footerStart, settings: settings, marker: marker,
                           indent: indent.isEmpty ? "\t" : indent, segments: segments)
    }

    /// Lossless serializer: concatenates the parsed segments.
    public static func serialize(_ board: KanbanBoard) -> String {
        board.segments.map { board.slice($0.start, $0.end) }.joined()
    }

    // MARK: - Building fresh boards

    public struct ModelCard: Sendable {
        public var text: String
        public var checked: Bool
        public init(_ text: String, checked: Bool = false) { self.text = text; self.checked = checked }
    }

    public struct ModelLane: Sendable {
        public var title: String
        public var complete: Bool
        public var cards: [ModelCard]
        public init(_ title: String, complete: Bool = false, cards: [ModelCard] = []) {
            self.title = title; self.complete = complete; self.cards = cards
        }
    }

    /// One card's lines, in plugin style (continuation lines indented).
    public static func cardLines(_ text: String, checked: Bool = false, marker: String = "-", indent: String = "\t", eol: String = "\n") -> String {
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = norm.components(separatedBy: "\n")
        let first = "\(marker) [\(checked ? "x" : " ")] \(parts[0])"
        return ([first] + parts.dropFirst().map { indent + $0 }).joined(separator: eol)
    }

    /// A new board file in the layout the obsidian-kanban plugin writes.
    /// `settings`: `.some(nil)` omits the block; nil writes the default.
    public static func build(lanes: [ModelLane], format: KanbanFormat = .board, settings: JSONValue?? = nil) -> String {
        var out = "---\n\nkanban-plugin: \(format.rawValue)\n\n---\n\n"
        for l in lanes {
            out += "## \(l.title)\n\n"
            if l.complete { out += "**Complete**\n" }
            for c in l.cards { out += cardLines(c.text, checked: c.checked) + "\n" }
            out += "\n\n"
        }
        let s: JSONValue? = settings ?? .object(JSONObject([("kanban-plugin", .string(format.rawValue))]))
        if let s { out += "\n\n%% kanban:settings\n```\n\(s.stringify())\n```\n%%" }
        return out
    }
}
