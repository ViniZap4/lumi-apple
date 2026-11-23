import Foundation

/// `i` (inner) vs `a` (around).
public enum TextObjectKind: Sendable, Hashable {
    case inner
    case around
}

/// A resolved text object: half-open character range.
struct ObjectRange: Hashable {
    var from: Int
    var to: Int
    var linewise: Bool = false
}

extension VimEngine {
    /// Resolve `iw`, `a(`, `ip`, `it` … at `cursor`. nil when there is no
    /// such object there (e.g. `di(` outside parentheses).
    static func resolveObject(_ spec: TextObjectSpec, count: Int, doc: Doc, cursor: Int) -> ObjectRange? {
        guard doc.count > 0 else { return nil }
        let cursor = max(0, min(cursor, doc.count - 1))
        let n = max(1, count)
        switch spec.kind {
        case "w": return wordObject(doc, cursor, inner: spec.inner, big: false, count: n)
        case "W": return wordObject(doc, cursor, inner: spec.inner, big: true, count: n)
        case "s": return sentenceObject(doc, cursor, inner: spec.inner, count: n)
        case "p": return paragraphObject(doc, cursor, inner: spec.inner, count: n)
        case "\"", "'", "`": return quoteObject(doc, cursor, quote: spec.kind, inner: spec.inner, count: n)
        case "(", ")", "b": return bracketObject(doc, cursor, open: "(", close: ")", inner: spec.inner, count: n)
        case "{", "}", "B": return bracketObject(doc, cursor, open: "{", close: "}", inner: spec.inner, count: n)
        case "[", "]": return bracketObject(doc, cursor, open: "[", close: "]", inner: spec.inner, count: n)
        case "<", ">": return bracketObject(doc, cursor, open: "<", close: ">", inner: spec.inner, count: n)
        case "t": return tagObject(doc, cursor, inner: spec.inner, count: n)
        default: return nil
        }
    }

    // MARK: Words

    private static func wordObject(_ doc: Doc, _ cursor: Int, inner: Bool, big: Bool, count: Int) -> ObjectRange? {
        let line = doc.line(of: cursor)
        let ls = doc.lineStart(line), le = doc.lineEnd(line)
        if ls == le { return nil }
        let pos = min(cursor, le - 1)
        func cls(_ i: Int) -> CharClass { CharClass(doc[i], big: big) }
        func runEnd(_ i: Int) -> Int {
            let c = cls(i)
            var j = i
            while j < le, cls(j) == c { j += 1 }
            return j
        }
        var from = pos
        let c0 = cls(pos)
        while from > ls, cls(from - 1) == c0 { from -= 1 }
        var to = runEnd(pos)

        if inner {
            for _ in 1..<count {
                guard to < le else { break }
                to = runEnd(to)
            }
            return ObjectRange(from: from, to: to)
        }

        if c0 == .blank {
            // Blank run + the following word.
            if to < le { to = runEnd(to) }
            for _ in 1..<count {
                guard to < le else { break }
                to = runEnd(to)
                if to < le, cls(to) != .blank { to = runEnd(to) }
            }
            return ObjectRange(from: from, to: to)
        }
        // Word + trailing blanks (or leading blanks when none trail).
        var usedTrailing = false
        for k in 0..<count {
            if k > 0 {
                guard to < le else { break }
                if cls(to) == .blank { to = runEnd(to) }
                guard to < le else { break }
                to = runEnd(to)
            }
            if to < le, cls(to) == .blank {
                to = runEnd(to)
                usedTrailing = true
            } else {
                usedTrailing = false
            }
        }
        if !usedTrailing {
            var f = from
            while f > ls, cls(f - 1) == .blank { f -= 1 }
            // Keep the indent when the word starts the line's text.
            if f > ls { from = f }
        }
        return ObjectRange(from: from, to: to)
    }

    // MARK: Sentences

    private static func sentenceObject(_ doc: Doc, _ cursor: Int, inner: Bool, count: Int) -> ObjectRange? {
        let starts = sentenceStarts(doc)
        var from = starts.last(where: { $0 <= cursor }) ?? 0
        var idx = starts.firstIndex(where: { $0 > cursor })
        var to = idx.map { starts[$0] } ?? doc.count
        for _ in 1..<count {
            guard let i = idx else { break }
            idx = i + 1 < starts.count ? i + 1 : nil
            to = idx.map { starts[$0] } ?? doc.count
        }
        // Trailing white space (never past an empty line).
        var textEnd = to
        while textEnd > from, doc[textEnd - 1].isWhitespace || doc[textEnd - 1] == "\n" { textEnd -= 1 }
        if inner {
            if cursor >= textEnd, textEnd < to {
                // Cursor in the gap: the gap itself.
                from = textEnd
                return ObjectRange(from: from, to: to)
            }
            return ObjectRange(from: from, to: textEnd)
        }
        var end = textEnd
        while end < doc.count, isBlank(doc[end]) { end += 1 }
        if end == textEnd {
            while from > 0, isBlank(doc[from - 1]) { from -= 1 }
        }
        return ObjectRange(from: from, to: end)
    }

    // MARK: Paragraphs

    private static func paragraphObject(_ doc: Doc, _ cursor: Int, inner: Bool, count: Int) -> ObjectRange? {
        let line = doc.line(of: cursor)
        func runBounds(_ l: Int) -> (Int, Int) {
            let empty = doc.isEmptyLine(l)
            var a = l, b = l
            while a > 0, doc.isEmptyLine(a - 1) == empty { a -= 1 }
            while b < doc.lastLine, doc.isEmptyLine(b + 1) == empty { b += 1 }
            return (a, b)
        }
        var (first, last) = runBounds(line)
        let startedEmpty = doc.isEmptyLine(line)
        if inner {
            for _ in 1..<count {
                guard last < doc.lastLine else { break }
                last = runBounds(last + 1).1
            }
        } else {
            for k in 0..<count {
                if k > 0 {
                    guard last < doc.lastLine else { break }
                    last = runBounds(last + 1).1
                }
                if last < doc.lastLine {
                    last = runBounds(last + 1).1
                } else if !startedEmpty, k == 0, first > 0, doc.isEmptyLine(first - 1) {
                    first = runBounds(first - 1).0
                }
            }
        }
        return ObjectRange(from: doc.lineStart(first), to: doc.lineEndInclusive(last), linewise: true)
    }

    // MARK: Quotes

    private static func quoteObject(_ doc: Doc, _ cursor: Int, quote: Character, inner: Bool, count: Int) -> ObjectRange? {
        let line = doc.line(of: cursor)
        let ls = doc.lineStart(line), le = doc.lineEnd(line)
        var qs: [Int] = []
        var i = ls
        while i < le {
            if doc[i] == "\\" { i += 2; continue }
            if doc[i] == quote { qs.append(i) }
            i += 1
        }
        var pair: (Int, Int)?
        if let k = qs.firstIndex(of: cursor) {
            if k % 2 == 0 { if k + 1 < qs.count { pair = (qs[k], qs[k + 1]) } } else { pair = (qs[k - 1], qs[k]) }
        } else {
            var k = 0
            while k + 1 < qs.count {
                if qs[k] < cursor, cursor < qs[k + 1] { pair = (qs[k], qs[k + 1]); break }
                k += 2
            }
            if pair == nil {
                // Not inside: the first quoted string after the cursor.
                k = 0
                while k + 1 < qs.count {
                    if qs[k] > cursor { pair = (qs[k], qs[k + 1]); break }
                    k += 2
                }
            }
        }
        guard let (open, close) = pair else { return nil }
        if inner {
            if count >= 2 { return ObjectRange(from: open, to: close + 1) }
            return ObjectRange(from: open + 1, to: close)
        }
        var from = open, to = close + 1
        if to < le, isBlank(doc[to]) {
            while to < le, isBlank(doc[to]) { to += 1 }
        } else {
            while from > ls, isBlank(doc[from - 1]) { from -= 1 }
        }
        return ObjectRange(from: from, to: to)
    }

    // MARK: Brackets

    private static func bracketObject(_ doc: Doc, _ cursor: Int, open: Character, close: Character, inner: Bool, count: Int) -> ObjectRange? {
        func findOpen(before pos: Int) -> Int? {
            var depth = 0
            var i = pos
            while i >= 0 {
                if doc[i] == close { depth += 1 } else if doc[i] == open {
                    if depth == 0 { return i }
                    depth -= 1
                }
                i -= 1
            }
            return nil
        }
        func findClose(after openPos: Int) -> Int? {
            var depth = 0
            var i = openPos + 1
            while i < doc.count {
                if doc[i] == open { depth += 1 } else if doc[i] == close {
                    if depth == 0 { return i }
                    depth -= 1
                }
                i += 1
            }
            return nil
        }
        var o: Int?
        if doc[cursor] == open {
            o = cursor
        } else if doc[cursor] == close {
            o = cursor > 0 ? findOpen(before: cursor - 1) : nil
        } else {
            o = findOpen(before: cursor)
        }
        for _ in 1..<count {
            guard let cur = o, cur > 0 else { o = nil; break }
            o = findOpen(before: cur - 1)
        }
        guard let openPos = o, let closePos = findClose(after: openPos) else { return nil }
        if !inner { return ObjectRange(from: openPos, to: closePos + 1) }
        var from = openPos + 1
        var to = closePos
        // Multi-line block: leave the brace lines intact (`ci{` keeps
        // `{` and `}` on their own lines).
        if from < doc.count, doc[from] == "\n" {
            from += 1
            let cl = doc.line(of: closePos)
            let csl = doc.lineStart(cl)
            if (csl..<closePos).allSatisfy({ isBlank(doc[$0]) }), csl >= from {
                to = csl
            }
        }
        return ObjectRange(from: from, to: max(from, to))
    }

    // MARK: Tags

    private static func tagObject(_ doc: Doc, _ cursor: Int, inner: Bool, count: Int) -> ObjectRange? {
        guard let regex = try? NSRegularExpression(pattern: "<(/?)([A-Za-z][\\w:.-]*)[^<>]*?(/?)>") else { return nil }
        let text = doc.string
        let ns = text as NSString
        struct Tag { var name: String; var closing: Bool; var range: Range<Int> }
        var tags: [Tag] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 3).length > 0 { continue }
            guard let r = characterRange(in: text, utf16Range: m.range) else { continue }
            tags.append(Tag(name: ns.substring(with: m.range(at: 2)).lowercased(), closing: m.range(at: 1).length > 0, range: r))
        }
        var stack: [Tag] = []
        var pairs: [(Tag, Tag)] = []
        for t in tags {
            if !t.closing {
                stack.append(t)
            } else if let idx = stack.lastIndex(where: { $0.name == t.name }) {
                pairs.append((stack[idx], t))
                stack.removeSubrange(idx...)
            }
        }
        let enclosing = pairs
            .filter { $0.0.range.lowerBound <= cursor && cursor < $0.1.range.upperBound }
            .sorted { ($0.1.range.upperBound - $0.0.range.lowerBound) < ($1.1.range.upperBound - $1.0.range.lowerBound) }
        guard count - 1 < enclosing.count else { return nil }
        let (o, c) = enclosing[count - 1]
        return inner ? ObjectRange(from: o.range.upperBound, to: c.range.lowerBound)
            : ObjectRange(from: o.range.lowerBound, to: c.range.upperBound)
    }
}
