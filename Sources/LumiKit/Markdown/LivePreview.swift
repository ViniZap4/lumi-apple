import Foundation

/// Obsidian-style **Live Preview** planning (web `live-preview.ts`).
///
/// Markdown syntax is hidden and the text styled in place; the raw syntax
/// comes back on every line that holds the cursor or the selection. This
/// file is the pure half: it reads the source and decides, per line, what
/// is hidden, how the line is styled and which block widgets (tables,
/// code, math, images) stand in for a run of lines. The platform text
/// view turns the plan into attributes and overlays.
///
/// Everything here is **purely visual**: nothing produces text. The one
/// edit Live Preview makes on its own — toggling a task — is the single
/// character `taskToggle(_:at:)` returns, a ranged op for the CRDT
/// (CRDT-CLIENT-PROTOCOL rule 3).
///
/// All offsets are UTF-16 (NSString / NSTextStorage / Y.Text). Ranges in
/// `LiveLine` and `LiveSpan` are **relative to the line start**, so a
/// line's plan does not change when text above it is edited — the view
/// only restyles lines whose plan really changed.
public enum LivePreview {}

// MARK: - Model

/// What a source line is, block-wise.
public enum LiveLineKind: Hashable, Sendable {
    case blank
    case text
    /// ATX heading. `marker`: length of `## ` (hashes + one space).
    case heading(level: Int, marker: Int)
    /// The text line of a setext heading.
    case setextText(level: Int)
    /// The `===` / `---` line under it.
    case setextUnderline(level: Int)
    /// A code fence line (```` ``` ```` / `~~~`). `info` is the language.
    case fence(open: Bool, info: String)
    /// A line inside a fenced code block.
    case code(info: String)
    /// `$$` on its own line, opening or closing a display-math block.
    case mathFence
    /// A line inside a `$$` block, or a whole-line `$$…$$`.
    case math
    case hr
    case tableHeader
    case tableDelimiter
    case tableRow
    case list(LiveListItem)
    /// YAML frontmatter (`---` … `---` at the top). `delimiter`: the
    /// `---` lines themselves.
    case frontmatter(delimiter: Bool)
    /// A line that is nothing but `![alt](src)`.
    case image
}

public struct LiveListItem: Hashable, Sendable {
    /// Leading whitespace (UTF-16 units, after any quote prefix).
    public var indent: Int
    /// Offset of the marker (`-`, `1.`) from the line start.
    public var markerOffset: Int
    public var markerLength: Int
    public var ordered: Bool
    /// Offset of `[` of a task marker, when the item is a task.
    public var taskOffset: Int?
    public var checked: Bool
    /// Nesting level from the indent (0 = top).
    public var level: Int
}

/// The `>` prefix of a line inside a blockquote or callout.
public struct LiveQuote: Hashable, Sendable {
    public var depth: Int
    /// Length of the whole prefix (`> > `), spaces included.
    public var prefixLength: Int
    public var callout: LiveCallout?
}

public struct LiveCallout: Hashable, Sendable {
    /// Canonical kind (`note`, `tip`, `warning`, …).
    public var kind: String
    /// Kind as written, lowercased (default title).
    public var rawKind: String
    /// The `> [!kind]` line.
    public var isTitle: Bool
    /// `+` / `-` after `]` — foldable.
    public var foldable: Bool
    /// Title-line only: offset (from the line start) where the title text
    /// starts and the length of `[!kind]±` + space before it.
    public var markerOffset: Int
    public var markerLength: Int
}

/// Line index range of a multi-line block.
public struct LiveGroup: Hashable, Sendable {
    public var first: Int
    public var last: Int
    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }
    public func contains(_ i: Int) -> Bool { i >= first && i <= last }
}

/// One source line with its block classification.
public struct LiveLine: Hashable, Sendable {
    /// UTF-16 offset of the first character.
    public var start: Int
    /// UTF-16 length without the terminator.
    public var length: Int
    public var kind: LiveLineKind
    public var quote: LiveQuote?
    /// The multi-line block the line belongs to (fence, math, table,
    /// frontmatter, quote/callout), if any.
    public var group: LiveGroup?

    public var range: NSRange { NSRange(location: start, length: length) }
}

/// Inline styling of a span of a line.
public enum LiveInline: Hashable, Sendable {
    /// Syntax hidden (the line is not being edited).
    case hide
    /// Syntax shown dimmed (the line is being edited).
    case marker
    case strong
    case emphasis
    case strike
    case code
    case mark
    case link(LiveLink)
    case footnote
    /// A bullet marker (`-`): kept for its width, drawn as `•`.
    case bullet
    /// A task marker `[ ]`: kept for its width, drawn as a checkbox.
    case taskBox(checked: Bool)
}

/// Where a link goes. Only `external` (http, https, mailto) and `note`
/// (book-relative path) are ever opened; everything else is styled but
/// inert.
public enum LiveLink: Hashable, Sendable {
    case external(String)
    case note(String)
    case inert
}

public struct LiveSpan: Hashable, Sendable {
    /// Relative to the line start.
    public var range: NSRange
    public var style: LiveInline
    public init(_ range: NSRange, _ style: LiveInline) {
        self.range = range
        self.style = style
    }
}

/// A block rendered as one piece (the reader's view) while the cursor
/// is outside it.
public enum LiveWidget: Hashable, Sendable {
    case table(source: String)
    case code(language: String?, code: String)
    case math(latex: String)
    case mermaid(code: String)
    case image(source: String)
}

/// How a whole line looks.
public enum LiveLineStyle: Hashable, Sendable {
    case body
    case heading(level: Int)
    /// Revealed code block line (fences included, dimmed).
    case code(fence: Bool, first: Bool, last: Bool)
    /// Revealed display math / table source: monospace, no panel.
    case source
    case frontmatter(first: Bool, last: Bool)
    /// Collapsed to (almost) nothing: inside a widget, a hidden fence.
    case collapsed
    /// First line of a widget: its text collapses, the widget is drawn
    /// in the space reserved after it.
    case widget(LiveWidget)
    /// `---` not being edited: text hidden, a rule drawn.
    case rule
    /// `---` / `***` being edited.
    case ruleSource
}

/// Everything the view needs to style one line.
public struct LiveLinePlan: Hashable, Sendable {
    public var style: LiveLineStyle
    public var quote: LiveQuote?
    public var list: LiveListItem?
    /// Draw the list marker / task box (the line is not being edited).
    public var drawsMarker: Bool
    public var spans: [LiveSpan]
    /// Done task: dimmed text.
    public var taskDone: Bool
    /// Callout box position (first/last line of the callout group).
    public var calloutFirst: Bool
    public var calloutLast: Bool
    /// Quote group position (for the bar's rounding).
    public var quoteFirst: Bool
    public var quoteLast: Bool
}

// MARK: - Block scan

public extension LivePreview {
    /// Classify every line of `text`. O(n); one pass plus a table
    /// look-ahead.
    static func scan(_ text: NSString) -> [LiveLine] {
        let n = text.length
        var buf = [unichar](repeating: 0, count: n)
        if n > 0 { text.getCharacters(&buf, range: NSRange(location: 0, length: n)) }
        // Line boundaries.
        var starts: [Int] = [0]
        var lens: [Int] = []
        var i = 0
        while i < n {
            if buf[i] == 10 {
                lens.append(i - starts[starts.count - 1])
                starts.append(i + 1)
            }
            i += 1
        }
        lens.append(n - starts[starts.count - 1])
        let count = starts.count
        var lines = [LiveLine](repeating: LiveLine(start: 0, length: 0, kind: .blank), count: count)
        for k in 0..<count { lines[k].start = starts[k]; lines[k].length = lens[k] }

        func chars(_ k: Int) -> ArraySlice<unichar> {
            let s = starts[k]
            var e = s + lens[k]
            if e > s, buf[e - 1] == 13 { e -= 1 }  // tolerate CRLF
            return buf[s..<e]
        }

        var k = 0
        // Frontmatter.
        if count > 1, isDashes(chars(0), exactly: 3) {
            var end = 1
            while end < count, !(isDashes(chars(end), exactly: 3) || String(utf16CodeUnits: Array(chars(end)), count: chars(end).count) == "...") { end += 1 }
            if end < count {
                let g = LiveGroup(first: 0, last: end)
                for j in 0...end { lines[j].kind = .frontmatter(delimiter: j == 0 || j == end); lines[j].group = g }
                k = end + 1
            }
        }

        var quoteStart: Int?
        var calloutOfGroup: LiveCallout?
        func closeQuote(at end: Int) {
            guard let qs = quoteStart else { return }
            let g = LiveGroup(first: qs, last: end)
            for j in qs...end { lines[j].group = g }
            quoteStart = nil
            calloutOfGroup = nil
        }

        while k < count {
            let line = chars(k)
            let base = line.startIndex
            // Fenced code.
            if let fence = openFence(line) {
                closeQuote(at: k - 1)
                var end = k + 1
                while end < count, !closesFence(chars(end), fence) { end += 1 }
                let last = min(end, count - 1)
                let g = LiveGroup(first: k, last: last)
                lines[k].kind = .fence(open: true, info: fence.info)
                lines[k].group = g
                if k + 1 <= last {
                    for j in (k + 1)...last {
                        lines[j].kind = (j == end) ? .fence(open: false, info: fence.info) : .code(info: fence.info)
                        lines[j].group = g
                    }
                }
                k = last + 1
                continue
            }
            // Display math.
            let trimmed = trim(line)
            if trimmed.count == 2, trimmed.first == 36, trimmed.last == 36 {
                var end = k + 1
                while end < count, !(trim(chars(end)).count == 2 && trim(chars(end)).allSatisfy { $0 == 36 }) { end += 1 }
                if end < count {
                    closeQuote(at: k - 1)
                    let g = LiveGroup(first: k, last: end)
                    for j in k...end { lines[j].kind = (j == k || j == end) ? .mathFence : .math; lines[j].group = g }
                    k = end + 1
                    continue
                }
            } else if trimmed.count > 4, trimmed.starts(with: [36, 36]), trimmed.reversed().starts(with: [36, 36]) {
                closeQuote(at: k - 1)
                lines[k].kind = .math
                lines[k].group = LiveGroup(first: k, last: k)
                k += 1
                continue
            }
            // Table (top level only).
            if quoteStart == nil, line.contains(124), k + 1 < count, isTableDelimiter(chars(k + 1)) {
                var end = k + 2
                while end < count, chars(end).contains(124), !trim(chars(end)).isEmpty { end += 1 }
                let g = LiveGroup(first: k, last: end - 1)
                lines[k].kind = .tableHeader
                lines[k + 1].kind = .tableDelimiter
                if end - 1 >= k + 2 { for j in (k + 2)...(end - 1) { lines[j].kind = .tableRow } }
                for j in k...(end - 1) { lines[j].group = g }
                k = end
                continue
            }

            // Quote prefix.
            var off = 0  // offset into line
            var depth = 0
            var p = 0
            while p < line.count, p < 4 + off, line[base + p] == 32 { p += 1 }
            while p < line.count, line[base + p] == 62 {  // '>'
                depth += 1
                p += 1
                if p < line.count, line[base + p] == 32 { p += 1 }
                let save = p
                while p < line.count, p - save < 3, line[base + p] == 32 { p += 1 }
                if p < line.count, line[base + p] == 62 { continue }
                p = save
                break
            }
            if depth > 0 {
                off = p
                if quoteStart == nil {
                    quoteStart = k
                    // Callout title?
                    calloutOfGroup = calloutHeader(line, from: off)
                }
                var q = LiveQuote(depth: depth, prefixLength: off, callout: nil)
                if var c = calloutOfGroup {
                    c.isTitle = (k == quoteStart)
                    if !c.isTitle { c.markerOffset = 0; c.markerLength = 0 }
                    q.callout = c
                }
                lines[k].quote = q
            } else {
                closeQuote(at: k - 1)
            }

            let content = line[(base + off)...]
            lines[k].kind = classify(content, contentOffset: off, previous: k > 0 ? lines[k - 1] : nil, depth: depth)
            if case let .setextUnderline(level) = lines[k].kind, k > 0 {
                lines[k - 1].kind = .setextText(level: level)
            }
            if lines[k].quote?.callout?.isTitle == true { lines[k].kind = .text }
            k += 1
        }
        closeQuote(at: count - 1)
        return lines
    }

    /// Line index holding UTF-16 `offset` (binary search).
    static func lineIndex(of offset: Int, in lines: [LiveLine]) -> Int {
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= offset { lo = mid } else { hi = mid - 1 }
        }
        return max(0, lo)
    }

    /// Lines touched by any of `ranges` (the cursor and the selection).
    static func activeLines(_ ranges: [NSRange], in lines: [LiveLine]) -> Set<Int> {
        var out = Set<Int>()
        guard !lines.isEmpty else { return out }
        for r in ranges where r.location != NSNotFound {
            let a = lineIndex(of: r.location, in: lines)
            let b = lineIndex(of: max(r.location, NSMaxRange(r)), in: lines)
            for i in a...max(a, b) { out.insert(i) }
        }
        return out
    }

    /// Lines whose raw syntax shows: the active lines, widened to whole
    /// widget groups (a table or code block is source while the cursor is
    /// anywhere in it).
    static func revealedGroups(_ active: Set<Int>, in lines: [LiveLine]) -> Set<LiveGroup> {
        var out = Set<LiveGroup>()
        for i in active where i < lines.count {
            if let g = lines[i].group { out.insert(g) }
        }
        return out
    }
}

// MARK: - Line plan

public extension LivePreview {
    /// Plan for line `index`. `active`: the line holds the cursor or the
    /// selection; `groupRevealed`: some line of its group does.
    static func plan(_ index: Int, lines: [LiveLine], text: NSString, active: Bool, groupRevealed: Bool) -> LiveLinePlan {
        let line = lines[index]
        var plan = LiveLinePlan(style: .body, quote: line.quote, list: nil, drawsMarker: !active, spans: [],
                                taskDone: false, calloutFirst: false, calloutLast: false, quoteFirst: false, quoteLast: false)
        if let g = line.group, line.quote != nil {
            plan.quoteFirst = g.first == index
            plan.quoteLast = g.last == index
            if line.quote?.callout != nil {
                plan.calloutFirst = plan.quoteFirst
                plan.calloutLast = plan.quoteLast
            }
        }
        let sub = { (r: NSRange) in text.substring(with: NSRange(location: line.start + r.location, length: r.length)) }
        let content = NSRange(location: 0, length: line.length)

        // Quote prefix and callout marker.
        var inlineFrom = 0
        if let q = line.quote {
            inlineFrom = q.prefixLength
            if q.prefixLength > 0 {
                plan.spans.append(LiveSpan(NSRange(location: 0, length: q.prefixLength), active ? .marker : .hide))
            }
            if let c = q.callout, c.isTitle, c.markerLength > 0 {
                plan.spans.append(LiveSpan(NSRange(location: c.markerOffset, length: c.markerLength), active ? .marker : .hide))
                inlineFrom = c.markerOffset + c.markerLength
            }
        }

        switch line.kind {
        case .blank:
            return plan
        case let .heading(level, marker):
            plan.style = .heading(level: level)
            let at = line.quote?.prefixLength ?? 0
            plan.spans.append(LiveSpan(NSRange(location: at, length: min(marker, line.length - at)), active ? .marker : .hide))
            inlineFrom = at + marker
        case let .setextText(level):
            plan.style = .heading(level: level)
        case let .setextUnderline(level):
            if active {
                plan.style = .heading(level: level)
                plan.spans.append(LiveSpan(content, .marker))
            } else {
                plan.style = .collapsed
            }
            return plan
        case let .fence(open, info):
            guard let g = line.group else { return plan }
            if groupRevealed {
                plan.style = .code(fence: true, first: open, last: !open)
                plan.spans.append(LiveSpan(content, .marker))
            } else if open {
                plan.style = .widget(widget(forFence: g, info: info, lines: lines, text: text))
            } else {
                plan.style = .collapsed
            }
            return plan
        case .code:
            guard let g = line.group else { return plan }
            if groupRevealed {
                // An unclosed fence's last line still closes the panel.
                plan.style = .code(fence: false, first: false, last: g.last == index && !isFenceClose(lines[g.last].kind))
            } else {
                plan.style = .collapsed
            }
            return plan
        case .mathFence, .math:
            guard let g = line.group else { return plan }
            if groupRevealed {
                plan.style = .source
                if case .mathFence = line.kind { plan.spans.append(LiveSpan(content, .marker)) }
            } else if g.first == index {
                let src = (g.first...g.last).map { text.substring(with: lines[$0].range) }.joined(separator: "\n")
                plan.style = .widget(.math(latex: stripMath(src)))
            } else {
                plan.style = .collapsed
            }
            return plan
        case .hr:
            plan.style = active ? .ruleSource : .rule
            if active { plan.spans.append(LiveSpan(content, .marker)) }
            return plan
        case .tableHeader, .tableDelimiter, .tableRow:
            guard let g = line.group else { return plan }
            if groupRevealed {
                plan.style = .source
                if case .tableDelimiter = line.kind { plan.spans.append(LiveSpan(content, .marker)) }
            } else if g.first == index {
                let src = (g.first...g.last).map { text.substring(with: lines[$0].range) }.joined(separator: "\n")
                plan.style = .widget(.table(source: src))
            } else {
                plan.style = .collapsed
            }
            return plan
        case let .frontmatter(delimiter):
            let g = line.group ?? LiveGroup(first: index, last: index)
            plan.style = .frontmatter(first: g.first == index, last: g.last == index)
            if delimiter { plan.spans.append(LiveSpan(content, .marker)) }
            return plan
        case .image:
            if active {
                plan.spans += inlineSpans(sub(content), active: true)
                return plan
            }
            plan.style = .widget(.image(source: text.substring(with: line.range).trimmingCharacters(in: .whitespaces)))
            return plan
        case let .list(item):
            plan.list = item
            plan.taskDone = item.checked
            if !active {
                if let task = item.taskOffset {
                    // `- ` hides; `[ ]` stays (transparent) as the box's room.
                    plan.spans.append(LiveSpan(NSRange(location: item.markerOffset, length: task - item.markerOffset), .hide))
                    plan.spans.append(LiveSpan(NSRange(location: task, length: 3), .taskBox(checked: item.checked)))
                } else if !item.ordered {
                    plan.spans.append(LiveSpan(NSRange(location: item.markerOffset, length: item.markerLength), .bullet))
                }
            } else {
                let len = (item.taskOffset.map { $0 + 3 } ?? item.markerOffset + item.markerLength) - item.markerOffset
                plan.spans.append(LiveSpan(NSRange(location: item.markerOffset, length: len), .marker))
            }
            inlineFrom = item.taskOffset.map { $0 + 3 } ?? (item.markerOffset + item.markerLength)
        case .text:
            break
        }

        if inlineFrom < line.length {
            let r = NSRange(location: inlineFrom, length: line.length - inlineFrom)
            for s in inlineSpans(sub(r), active: active) {
                plan.spans.append(LiveSpan(NSRange(location: s.range.location + inlineFrom, length: s.range.length), s.style))
            }
        }
        return plan
    }

    /// The single-character ranged edit that toggles the task marker whose
    /// `[` is at UTF-16 `location` (`[ ]` ⇄ `[x]`), or nil when there is
    /// no task marker there.
    static func taskToggle(_ text: NSString, at location: Int) -> TextEdit? {
        guard location >= 0, location + 3 <= text.length else { return nil }
        let a = text.character(at: location), b = text.character(at: location + 1), c = text.character(at: location + 2)
        guard a == 91, c == 93 else { return nil }  // [ ]
        switch b {
        case 32: return TextEdit(location: location + 1, length: 1, replacement: "x")
        case 120, 88: return TextEdit(location: location + 1, length: 1, replacement: " ")
        default: return nil
        }
    }
}

// MARK: - Inline

public extension LivePreview {
    /// Inline spans of `s` (ranges relative to `s`). `active`: syntax is
    /// shown as `.marker` instead of hidden.
    static func inlineSpans(_ s: String, active: Bool) -> [LiveSpan] {
        let ns = s as NSString
        let n = ns.length
        guard n > 0 else { return [] }
        var c = [unichar](repeating: 0, count: n)
        ns.getCharacters(&c, range: NSRange(location: 0, length: n))
        var out: [LiveSpan] = []
        let syntax: LiveInline = active ? .marker : .hide
        func mark(_ loc: Int, _ len: Int) { if len > 0 { out.append(LiveSpan(NSRange(location: loc, length: len), syntax)) } }

        // Code spans first: nothing inside them is markdown.
        var protected = [Bool](repeating: false, count: n)
        var i = 0
        while i < n {
            if c[i] == 92, i + 1 < n { i += 2; continue }  // backslash escape
            guard c[i] == 96 else { i += 1; continue }
            var run = 1
            while i + run < n, c[i + run] == 96 { run += 1 }
            var j = i + run
            var close: Int?
            while j < n {
                if c[j] == 96 {
                    var r = 1
                    while j + r < n, c[j + r] == 96 { r += 1 }
                    if r == run { close = j; break }
                    j += r
                } else { j += 1 }
            }
            guard let close else { i += run; continue }
            out.append(LiveSpan(NSRange(location: i + run, length: close - i - run), .code))
            mark(i, run)
            mark(close, run)
            for k in i..<(close + run) { protected[k] = true }
            i = close + run
        }

        // Escapes, links, wikilinks, autolinks, footnotes.
        i = 0
        while i < n {
            if protected[i] { i += 1; continue }
            let ch = c[i]
            if ch == 92, i + 1 < n, isASCIIPunct(c[i + 1]) {
                if !active { mark(i, 1) }
                protected[i] = true; protected[i + 1] = true
                i += 2
                continue
            }
            if ch == 91, i + 1 < n, c[i + 1] == 91, let close = find(c, [93, 93], from: i + 2, protected) {
                // [[target]] / [[target|alias]]
                let inner = NSRange(location: i + 2, length: close - i - 2)
                let body = ns.substring(with: inner)
                let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let target = parts[0].trimmingCharacters(in: .whitespaces)
                if !target.isEmpty {
                    let href = target.lowercased().hasSuffix(".md") ? target : target + ".md"
                    let link: LiveLink = noteHref(href).map { .note($0) } ?? .inert
                    if parts.count == 2 {
                        let aliasStart = i + 2 + (parts[0] as NSString).length + 1
                        mark(i, aliasStart - i)
                        out.append(LiveSpan(NSRange(location: aliasStart, length: close - aliasStart), .link(link)))
                    } else {
                        mark(i, 2)
                        out.append(LiveSpan(inner, .link(link)))
                    }
                    mark(close, 2)
                    for k in i..<(close + 2) { protected[k] = true }
                    i = close + 2
                    continue
                }
            }
            if ch == 91, i + 1 < n, c[i + 1] == 94, let close = find(c, [93], from: i + 2, protected), close > i + 2,
               !(close + 1 < n && (c[close + 1] == 58 || c[close + 1] == 40)) {
                out.append(LiveSpan(NSRange(location: i, length: close - i + 1), .footnote))
                for k in i...close { protected[k] = true }
                i = close + 1
                continue
            }
            if ch == 91 || (ch == 33 && i + 1 < n && c[i + 1] == 91) {
                let image = ch == 33
                let open = image ? i + 1 : i
                if let textEnd = matchingBracket(c, from: open, protected), textEnd + 1 < n, c[textEnd + 1] == 40,
                   let urlEnd = matchingParen(c, from: textEnd + 1) {
                    let rawDest = ns.substring(with: NSRange(location: textEnd + 2, length: urlEnd - textEnd - 2))
                    let dest = linkDestination(rawDest)
                    if image {
                        out.append(LiveSpan(NSRange(location: i, length: urlEnd - i + 1), .marker))
                    } else if textEnd > open + 1 {
                        let link: LiveLink = safeHref(dest).map { .external($0) } ?? noteHref(dest).map { .note($0) } ?? .inert
                        mark(i, 1)
                        out.append(LiveSpan(NSRange(location: open + 1, length: textEnd - open - 1), .link(link)))
                        mark(textEnd, urlEnd - textEnd + 1)
                    }
                    for k in textEnd...urlEnd { protected[k] = true }
                    if image { for k in i..<textEnd { protected[k] = true } }
                    protected[i] = true
                    i = image ? urlEnd + 1 : open + 1
                    continue
                }
            }
            if ch == 60, let close = find(c, [62], from: i + 1, protected) {
                let inner = ns.substring(with: NSRange(location: i + 1, length: close - i - 1))
                if !inner.contains(" "), let href = safeHref(inner) {
                    mark(i, 1)
                    out.append(LiveSpan(NSRange(location: i + 1, length: close - i - 1), .link(.external(href))))
                    mark(close, 1)
                    for k in i...close { protected[k] = true }
                    i = close + 1
                    continue
                }
            }
            if (ch == 104 || ch == 72), (i == 0 || !isWordChar(c[i - 1])) {  // bare http(s)://
                let rest = ns.substring(from: i)
                if rest.lowercased().hasPrefix("http://") || rest.lowercased().hasPrefix("https://") {
                    var e = i
                    while e < n, !protected[e], c[e] > 32, c[e] != 60, c[e] != 62 { e += 1 }
                    while e > i, [46, 44, 59, 58, 33, 63, 41, 39, 34].contains(c[e - 1]) { e -= 1 }
                    let url = ns.substring(with: NSRange(location: i, length: e - i))
                    if let href = safeHref(url) {
                        out.append(LiveSpan(NSRange(location: i, length: e - i), .link(.external(href))))
                        for k in i..<e { protected[k] = true }
                        i = e
                        continue
                    }
                }
            }
            i += 1
        }

        // Emphasis, strong, strike, mark: delimiter runs.
        emphasis(c, protected: &protected, out: &out, syntax: syntax)
        return out
    }

    /// Absolute http(s)/mailto URL safe to open, else nil (web `safeHref`).
    static func safeHref(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url.absoluteString
        case "mailto":
            return url.absoluteString
        default:
            return nil
        }
    }

    /// Relative note link (`other.md`, `../a/b.md`, `/x`), opened inside
    /// the app. Anything with a scheme, `//host` or a bare `#fragment` is
    /// not a note link (web `noteHref`).
    static func noteHref(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty, !s.hasPrefix("#"), !s.hasPrefix("//") else { return nil }
        if s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return s
    }
}

// MARK: - Helpers

extension LivePreview {
    struct Fence {
        var char: unichar
        var count: Int
        var info: String
    }

    static func openFence(_ line: ArraySlice<unichar>) -> Fence? {
        var p = line.startIndex
        var sp = 0
        while p < line.endIndex, line[p] == 32, sp < 4 { p += 1; sp += 1 }
        guard sp <= 3, p < line.endIndex, line[p] == 96 || line[p] == 126 else { return nil }
        let ch = line[p]
        var run = 0
        while p < line.endIndex, line[p] == ch { p += 1; run += 1 }
        guard run >= 3 else { return nil }
        let rest = Array(line[p...])
        if ch == 96, rest.contains(96) { return nil }
        let info = String(utf16CodeUnits: rest, count: rest.count).trimmingCharacters(in: .whitespaces)
        let lang = info.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        return Fence(char: ch, count: run, info: lang)
    }

    static func closesFence(_ line: ArraySlice<unichar>, _ f: Fence) -> Bool {
        var p = line.startIndex
        var sp = 0
        while p < line.endIndex, line[p] == 32, sp < 4 { p += 1; sp += 1 }
        guard sp <= 3 else { return false }
        var run = 0
        while p < line.endIndex, line[p] == f.char { p += 1; run += 1 }
        guard run >= f.count else { return false }
        while p < line.endIndex { if line[p] != 32 && line[p] != 9 { return false }; p += 1 }
        return true
    }

    static func isFenceClose(_ kind: LiveLineKind) -> Bool {
        if case .fence(open: false, _) = kind { return true }
        return false
    }

    static func trim(_ s: ArraySlice<unichar>) -> ArraySlice<unichar> {
        var a = s.startIndex, b = s.endIndex
        while a < b, s[a] == 32 || s[a] == 9 { a += 1 }
        while b > a, s[b - 1] == 32 || s[b - 1] == 9 { b -= 1 }
        return s[a..<b]
    }

    static func isDashes(_ s: ArraySlice<unichar>, exactly n: Int) -> Bool {
        let t = trim(s)
        return t.count == n && t.allSatisfy { $0 == 45 } && s.first == 45
    }

    static func isTableDelimiter(_ s: ArraySlice<unichar>) -> Bool {
        let t = trim(s)
        guard !t.isEmpty, t.contains(45) else { return false }
        var pipes = 0
        for u in t {
            switch u {
            case 124: pipes += 1
            case 45, 58, 32, 9: continue
            default: return false
            }
        }
        return pipes > 0
    }

    /// `[!kind]±` right after the quote prefix.
    static func calloutHeader(_ line: ArraySlice<unichar>, from off: Int) -> LiveCallout? {
        let s = String(utf16CodeUnits: Array(line[(line.startIndex + off)...]), count: line.count - off)
        guard let m = s.range(of: "^\\[!([A-Za-z][A-Za-z0-9_-]*)\\]([+-]?) ?", options: .regularExpression) else { return nil }
        let marker = String(s[m])
        let raw = marker.dropFirst(2).prefix { $0 != "]" }.lowercased()
        let foldable = marker.contains("]+") || marker.contains("]-")
        return LiveCallout(kind: MarkdownCallout.canonicalKind(raw), rawKind: raw, isTitle: true, foldable: foldable,
                           markerOffset: off, markerLength: (marker as NSString).length)
    }

    static func classify(_ content: ArraySlice<unichar>, contentOffset off: Int, previous: LiveLine?, depth: Int) -> LiveLineKind {
        let t = trim(content)
        if t.isEmpty { return .blank }
        let base = content.startIndex
        var p = base
        var indent = 0
        while p < content.endIndex, content[p] == 32 || content[p] == 9 { indent += content[p] == 9 ? 4 : 1; p += 1 }
        let ws = p - base

        // ATX heading.
        if indent <= 3, content[p] == 35 {
            var h = 0
            var q = p
            while q < content.endIndex, content[q] == 35 { h += 1; q += 1 }
            if h <= 6, q == content.endIndex || content[q] == 32 || content[q] == 9 {
                var marker = q - base
                if q < content.endIndex { marker += 1 }
                return .heading(level: h, marker: marker)
            }
        }
        // Setext underline (only under a plain text line, same quote depth).
        if indent <= 3, let prev = previous, case .text = prev.kind, (prev.quote?.depth ?? 0) == depth,
           prev.quote?.callout?.isTitle != true {
            if t.allSatisfy({ $0 == 61 }) { return .setextUnderline(level: 1) }
            if t.allSatisfy({ $0 == 45 }) { return .setextUnderline(level: 2) }
        }
        // Thematic break.
        if indent <= 3, let first = t.first, first == 45 || first == 42 || first == 95 {
            var count = 0
            var ok = true
            for u in t {
                if u == first { count += 1 } else if u != 32 && u != 9 { ok = false; break }
            }
            if ok, count >= 3 { return .hr }
        }
        // List item.
        if p < content.endIndex {
            let m = content[p]
            var markerLen = 0
            var ordered = false
            if m == 45 || m == 42 || m == 43 {
                markerLen = 1
            } else if m >= 48 && m <= 57 {
                var q = p
                while q < content.endIndex, content[q] >= 48, content[q] <= 57, q - p < 9 { q += 1 }
                if q < content.endIndex, content[q] == 46 || content[q] == 41 { markerLen = q - p + 1; ordered = true }
            }
            if markerLen > 0 {
                let after = p + markerLen
                if after == content.endIndex || content[after] == 32 || content[after] == 9 {
                    var item = LiveListItem(indent: ws, markerOffset: off + ws, markerLength: markerLen, ordered: ordered,
                                            taskOffset: nil, checked: false, level: indent / 2)
                    var q = after
                    while q < content.endIndex, content[q] == 32 { q += 1 }
                    if q + 3 <= content.endIndex, content[q] == 91, content[q + 2] == 93,
                       content[q + 1] == 32 || content[q + 1] == 120 || content[q + 1] == 88,
                       q + 3 == content.endIndex || content[q + 3] == 32 {
                        item.taskOffset = off + (q - base)
                        item.checked = content[q + 1] != 32
                    }
                    return .list(item)
                }
            }
        }
        // Whole-line image.
        if t.first == 33, t.last == 41 {
            let s = String(utf16CodeUnits: Array(t), count: t.count)
            if s.range(of: "^!\\[[^\\]]*\\]\\([^)\\s]+(\\s+\"[^\"]*\")?\\)$", options: .regularExpression) != nil { return .image }
        }
        return .text
    }

    static func widget(forFence g: LiveGroup, info: String, lines: [LiveLine], text: NSString) -> LiveWidget {
        var body: [String] = []
        if g.last > g.first {
            let lastIsClose = isFenceClose(lines[g.last].kind)
            let end = lastIsClose ? g.last - 1 : g.last
            if end >= g.first + 1 {
                for j in (g.first + 1)...end { body.append(text.substring(with: lines[j].range)) }
            }
        }
        let code = body.joined(separator: "\n")
        switch info {
        case "mermaid": return .mermaid(code: code + "\n")
        case "math", "latex", "tex": return .math(latex: code)
        default: return .code(language: info.isEmpty ? nil : info, code: code + "\n")
        }
    }

    static func stripMath(_ src: String) -> String {
        var s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$") { s.removeFirst(2) }
        if s.hasSuffix("$$") { s.removeLast(2) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func linkDestination(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), let close = s.firstIndex(of: ">") { return String(s[s.index(after: s.startIndex)..<close]) }
        if let space = s.firstIndex(of: " ") { s = String(s[..<space]) }
        return s
    }

    static func isASCIIPunct(_ u: unichar) -> Bool {
        (u >= 33 && u <= 47) || (u >= 58 && u <= 64) || (u >= 91 && u <= 96) || (u >= 123 && u <= 126)
    }

    static func isWordChar(_ u: unichar) -> Bool {
        (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u >= 0x80
    }

    static func isSpace(_ u: unichar?) -> Bool {
        guard let u else { return true }
        return u == 32 || u == 9 || u == 10 || u == 0xA0
    }

    static func find(_ c: [unichar], _ needle: [unichar], from: Int, _ protected: [Bool]) -> Int? {
        var i = from
        while i + needle.count <= c.count {
            if !protected[i], Array(c[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    static func matchingBracket(_ c: [unichar], from open: Int, _ protected: [Bool]) -> Int? {
        var depth = 0
        var i = open
        while i < c.count {
            if c[i] == 92 { i += 2; continue }
            if protected[i], i != open { i += 1; continue }
            if c[i] == 91 { depth += 1 }
            if c[i] == 93 { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    static func matchingParen(_ c: [unichar], from open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < c.count {
            if c[i] == 92 { i += 2; continue }
            if c[i] == 40 { depth += 1 }
            if c[i] == 41 { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    /// Delimiter-run emphasis (`*`, `_`, `~~`, `==`), a pragmatic subset
    /// of CommonMark's rules: flanking runs, `_` not intraword, runs pair
    /// with an equal-length closer.
    static func emphasis(_ c: [unichar], protected: inout [Bool], out: inout [LiveSpan], syntax: LiveInline) {
        let n = c.count
        struct Run { var at: Int; var len: Int; var ch: unichar; var canOpen: Bool; var canClose: Bool }
        var runs: [Run] = []
        var i = 0
        while i < n {
            let ch = c[i]
            guard !protected[i], ch == 42 || ch == 95 || ch == 126 || ch == 61 else { i += 1; continue }
            var len = 1
            while i + len < n, c[i + len] == ch, !protected[i + len] { len += 1 }
            let before: unichar? = i > 0 ? c[i - 1] : nil
            let after: unichar? = i + len < n ? c[i + len] : nil
            let leftFlank = !isSpace(after) && !(isPunct(after) && !isSpace(before) && !isPunct(before))
            let rightFlank = !isSpace(before) && !(isPunct(before) && !isSpace(after) && !isPunct(after))
            var canOpen = leftFlank
            var canClose = rightFlank
            if ch == 95 {
                canOpen = leftFlank && (!rightFlank || isPunct(before))
                canClose = rightFlank && (!leftFlank || isPunct(after))
            }
            if (ch == 126 || ch == 61) && len != 2 { i += len; continue }
            runs.append(Run(at: i, len: len, ch: ch, canOpen: canOpen, canClose: canClose))
            i += len
        }
        var stack: [Run] = []
        for var r in runs {
            if r.canClose {
                var matched = false
                var si = stack.count - 1
                while si >= 0, r.len > 0 {
                    var o = stack[si]
                    guard o.ch == r.ch else { si -= 1; continue }
                    let use: Int
                    if r.ch == 126 || r.ch == 61 { use = 2 } else { use = min(o.len, r.len) >= 2 ? 2 : 1 }
                    guard o.len >= use, r.len >= use else { si -= 1; continue }
                    let openAt = o.at + o.len - use
                    let closeAt = r.at
                    let style: LiveInline
                    switch r.ch {
                    case 126: style = .strike
                    case 61: style = .mark
                    default: style = use == 2 ? .strong : .emphasis
                    }
                    if closeAt > openAt + use {
                        out.append(LiveSpan(NSRange(location: openAt + use, length: closeAt - openAt - use), style))
                        out.append(LiveSpan(NSRange(location: openAt, length: use), syntax))
                        out.append(LiveSpan(NSRange(location: closeAt, length: use), syntax))
                    }
                    o.len -= use
                    r.at += use
                    r.len -= use
                    stack.removeSubrange((si + 1)...)
                    if o.len == 0 { stack.remove(at: si); si -= 1 } else { stack[si] = o }
                    matched = true
                    if r.len == 0 { break }
                }
                if matched && r.len == 0 { continue }
            }
            if r.canOpen, r.len > 0 { stack.append(r) }
        }
    }

    static func isPunct(_ u: unichar?) -> Bool {
        guard let u else { return false }
        return isASCIIPunct(u)
    }
}
