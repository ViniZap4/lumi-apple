import Foundation

/// Where a motion lands and how an operator should treat the span.
struct MotionResult: Hashable {
    var target: Int
    var linewise: Bool = false
    var inclusive: Bool = false
    /// A jump: sets the `'` / `` ` `` previous-context mark.
    var jump: Bool = false
    /// `j` / `k`: keep the desired column.
    var vertical: Bool = false
    /// `gj` / `gk`: the host may refine the target with its layout.
    var displayLines: Int? = nil
}

enum MotionContext: Equatable {
    case normal
    case visual
    case op(VimOperator)

    var isOperator: Bool { if case .op = self { return true }; return false }
}

extension VimEngine {
    /// Resolve a motion from `cursor`. nil = the motion failed (vim beeps;
    /// a pending operator is cancelled).
    static func resolveMotion(
        _ m: MotionSpec,
        count: Int?,
        doc: Doc,
        cursor: Int,
        state: inout VimState,
        context: MotionContext
    ) -> MotionResult? {
        let n = max(1, count ?? 1)
        let line = doc.line(of: cursor)
        let isOp = context.isOperator

        switch m {
        case .left:
            let start = doc.lineStart(line)
            guard cursor > start else { return nil }
            return MotionResult(target: max(start, cursor - n))

        case .right:
            let limit = isOp ? doc.lineEnd(line) : doc.lastChar(line)
            guard cursor < limit else { return nil }
            return MotionResult(target: min(limit, cursor + n))

        case .leftWrap:
            var t = cursor
            for _ in 0..<n {
                guard t > 0 else { break }
                t -= 1
                if doc[t] == "\n", !isOp, t > doc.lineStart(doc.line(of: t)) { t -= 1 }
            }
            guard t != cursor else { return nil }
            return MotionResult(target: t)

        case .rightWrap:
            var t = cursor
            for _ in 0..<n {
                guard t < doc.count else { break }
                t += 1
                if !isOp, t < doc.count, doc[t] == "\n", t > doc.lineStart(doc.line(of: t)) { t += 1 }
            }
            t = min(t, doc.count)
            guard t != cursor else { return nil }
            return MotionResult(target: t)

        case .up, .down, .displayUp, .displayDown:
            let up = (m == .up || m == .displayUp)
            let targetLine = up ? line - n : line + n
            if up ? line == 0 : line == doc.lastLine { return nil }
            let tl = doc.clampLine(targetLine)
            let col = state.desiredColumn ?? doc.column(of: cursor)
            let target = isOp ? doc.lineStart(tl)
                : doc.offset(line: tl, column: col == Int.max ? Int.max / 2 : col, allowEnd: context == .visual && col == Int.max)
            var r = MotionResult(target: target, linewise: true, vertical: true)
            if m == .displayUp || m == .displayDown { r.displayLines = up ? -n : n }
            return r

        case .lineDown, .lineUp, .currentLine:
            let tl: Int
            switch m {
            case .lineDown: tl = line + n
            case .lineUp: tl = line - n
            default: tl = line + n - 1
            }
            guard tl >= 0, tl <= doc.lastLine else {
                if m == .currentLine { return MotionResult(target: doc.firstNonBlank(doc.lastLine), linewise: true) }
                return nil
            }
            return MotionResult(target: doc.firstNonBlank(tl), linewise: true)

        case .lineStart:
            return MotionResult(target: doc.lineStart(line))

        case .firstNonBlank:
            return MotionResult(target: doc.firstNonBlank(line))

        case .lineEnd:
            let tl = doc.clampLine(line + n - 1)
            if isOp { return MotionResult(target: doc.lineEnd(tl)) }
            if context == .visual, tl < doc.lastLine || state.insertOneShot > 0 {
                // Visual `$` takes the line break too (`v$d` joins).
                return MotionResult(target: doc.lineEnd(tl), inclusive: true)
            }
            if state.insertOneShot > 0 { return MotionResult(target: doc.lineEnd(tl), inclusive: true) }
            return MotionResult(target: doc.lastChar(tl), inclusive: true)

        case .lastNonBlank:
            let tl = doc.clampLine(line + n - 1)
            return MotionResult(target: doc.lastNonBlank(tl) ?? doc.lineStart(tl), inclusive: true)

        case .column:
            return MotionResult(target: doc.offset(line: line, column: n - 1, allowEnd: false))

        case .fileStart:
            let tl = doc.clampLine((count ?? 1) - 1)
            return MotionResult(target: doc.firstNonBlank(tl), linewise: true, jump: true)

        case .fileEnd:
            let tl = doc.clampLine(count.map { $0 - 1 } ?? doc.lastLine)
            return MotionResult(target: doc.firstNonBlank(tl), linewise: true, jump: true)

        case let .wordForward(big):
            var t = cursor
            for k in 0..<n {
                let next = nextWordStart(doc, t, big: big)
                if isOp, k == n - 1, doc.line(of: next) > doc.line(of: t) || next == doc.count {
                    // The last word moved over ends its line: the operator
                    // stops at the line end, not at the next line's word.
                    let tLine = doc.line(of: t)
                    let le = doc.lineEnd(tLine)
                    if (t..<le).contains(where: { !isBlank(doc[$0]) }) {
                        t = le
                        break
                    }
                }
                t = next
            }
            if t == cursor { return nil }
            return MotionResult(target: t)

        case let .wordBackward(big):
            var t = cursor
            for _ in 0..<n { t = prevWordStart(doc, t, big: big) }
            if t == cursor, cursor == 0 { return nil }
            return MotionResult(target: t)

        case let .wordEnd(big):
            var t = cursor
            for _ in 0..<n { t = nextWordEnd(doc, t, big: big) }
            return MotionResult(target: t, inclusive: true)

        case let .wordEndBackward(big):
            var t = cursor
            for _ in 0..<n { t = prevWordEnd(doc, t, big: big) }
            return MotionResult(target: t, inclusive: true)

        case let .find(kind, ch):
            state.lastFind = FindMemory(kind: kind, target: ch)
            return findOnLine(doc, cursor: cursor, kind: kind, target: ch, count: n, repeating: false)

        case let .repeatFind(reverse):
            guard let last = state.lastFind else { return nil }
            let kind = reverse ? last.kind.reversed : last.kind
            return findOnLine(doc, cursor: cursor, kind: kind, target: last.target, count: n, repeating: true)

        case .matchPair:
            if let count {
                guard count <= 100 else { return nil }
                let tl = doc.clampLine((count * doc.lineCount + 99) / 100 - 1)
                return MotionResult(target: doc.firstNonBlank(tl), linewise: true, jump: true)
            }
            guard let t = matchingBracket(doc, from: cursor) else { return nil }
            return MotionResult(target: t, inclusive: true, jump: true)

        case .sentenceForward:
            let starts = sentenceStarts(doc)
            var t = cursor
            for _ in 0..<n {
                if let s = starts.first(where: { $0 > t }) { t = s } else { t = doc.count; break }
            }
            if t == doc.count, !isOp { t = max(0, doc.count - 1) }
            return MotionResult(target: t, jump: true)

        case .sentenceBackward:
            let starts = sentenceStarts(doc)
            var t = cursor
            for _ in 0..<n { t = starts.last(where: { $0 < t }) ?? 0 }
            return MotionResult(target: t, jump: true)

        case .paragraphForward:
            var l = line
            for _ in 0..<n {
                while l < doc.lastLine, doc.isEmptyLine(l) { l += 1 }
                while l <= doc.lastLine, !doc.isEmptyLine(l) { l += 1 }
                if l > doc.lastLine { break }
            }
            if l > doc.lastLine {
                return MotionResult(target: isOp ? doc.count : doc.lastChar(doc.lastLine), inclusive: false, jump: true)
            }
            return MotionResult(target: doc.lineStart(l), jump: true)

        case .paragraphBackward:
            var l = line
            for _ in 0..<n {
                while l > 0, doc.isEmptyLine(l) { l -= 1 }
                while l >= 0, !doc.isEmptyLine(l) { l -= 1 }
                if l < 0 { break }
            }
            return MotionResult(target: l < 0 ? 0 : doc.lineStart(l), jump: true)

        case .screenTop, .screenMiddle, .screenBottom:
            let first = doc.clampLine(state.viewport?.firstLine ?? 0)
            let last = doc.clampLine(state.viewport?.lastLine ?? doc.lastLine)
            let tl: Int
            switch m {
            case .screenTop: tl = min(last, first + n - 1)
            case .screenBottom: tl = max(first, last - n + 1)
            default: tl = (first + last) / 2
            }
            return MotionResult(target: doc.firstNonBlank(tl), linewise: true, jump: true)

        case let .searchNext(reverse):
            guard let last = state.lastSearch else {
                state.message = VimMessage("E35: No previous regular expression", isError: true)
                return nil
            }
            let dir = reverse ? last.direction.reversed : last.direction
            guard let t = searchTarget(doc: doc, pattern: last.pattern, from: cursor, direction: dir, count: n, state: &state) else { return nil }
            state.hlsearchSuspended = false
            return MotionResult(target: t, jump: true)

        case let .searchWord(forward, whole):
            guard let (word, start) = wordAtOrAfter(doc, cursor) else {
                state.message = VimMessage("E348: No string under cursor", isError: true)
                return nil
            }
            let escaped = escapeVimPattern(word)
            let pattern = whole && isKeywordChar(word.first ?? " ") ? "\\<" + escaped + "\\>" : escaped
            let dir: SearchDirection = forward ? .forward : .backward
            state.lastSearch = SearchMemory(pattern: pattern, direction: dir)
            appendSearchHistory(pattern, state: &state)
            state.hlsearchSuspended = false
            // Search from the word's start so `#` skips the word itself.
            let from = forward ? cursor : start
            guard let t = searchTarget(doc: doc, pattern: pattern, from: from, direction: dir, count: n, state: &state, smartcase: false) else { return nil }
            return MotionResult(target: t, jump: true)

        case let .mark(name, exact):
            guard let off = markOffset(name, state: state, doc: doc) else {
                state.message = VimMessage("E20: Mark not set", isError: true)
                return nil
            }
            let t = min(off, doc.count)
            if exact { return MotionResult(target: t, jump: true) }
            return MotionResult(target: doc.firstNonBlank(doc.line(of: t)), linewise: true, jump: true)

        case let .unmatched(ch):
            let forward = ch == ")" || ch == "}"
            let open: Character = (ch == "(" || ch == ")") ? "(" : "{"
            let close: Character = open == "(" ? ")" : "}"
            var depth = 0
            var t = cursor
            var found: Int?
            var remaining = n
            if forward {
                t += 1
                while t < doc.count {
                    if doc[t] == open { depth += 1 } else if doc[t] == close {
                        if depth == 0 { remaining -= 1; if remaining == 0 { found = t; break } } else { depth -= 1 }
                    }
                    t += 1
                }
            } else {
                t -= 1
                while t >= 0 {
                    if doc[t] == close { depth += 1 } else if doc[t] == open {
                        if depth == 0 { remaining -= 1; if remaining == 0 { found = t; break } } else { depth -= 1 }
                    }
                    t -= 1
                }
            }
            guard let found else { return nil }
            return MotionResult(target: found, inclusive: forward, jump: true)
        }
    }

    // MARK: Word scanning

    static func nextWordStart(_ doc: Doc, _ pos: Int, big: Bool) -> Int {
        let n = doc.count
        guard pos < n else { return n }
        var i = pos
        let c0 = CharClass(doc[i], big: big)
        if c0.isWordish {
            while i < n, CharClass(doc[i], big: big) == c0 { i += 1 }
        }
        while i < n {
            let c = doc[i]
            if c == "\n" {
                if i > pos, i == 0 || doc[i - 1] == "\n" { return i }
                i += 1
                continue
            }
            if isBlank(c) || c.isWhitespace { i += 1; continue }
            break
        }
        return i
    }

    static func nextWordEnd(_ doc: Doc, _ pos: Int, big: Bool) -> Int {
        let n = doc.count
        guard n > 0 else { return 0 }
        var i = pos + 1
        while i < n, doc[i] == "\n" || doc[i].isWhitespace { i += 1 }
        guard i < n else { return max(pos, n - 1) }
        let c = CharClass(doc[i], big: big)
        while i + 1 < n, CharClass(doc[i + 1], big: big) == c { i += 1 }
        return i
    }

    static func prevWordStart(_ doc: Doc, _ pos: Int, big: Bool) -> Int {
        var i = pos - 1
        guard i >= 0 else { return 0 }
        while i > 0 {
            let c = doc[i]
            if c == "\n" {
                if doc[i - 1] == "\n" { return i }
                i -= 1
                continue
            }
            if c.isWhitespace { i -= 1; continue }
            break
        }
        let cls = CharClass(doc[i], big: big)
        if cls == .newline || cls == .blank { return i }
        while i > 0, CharClass(doc[i - 1], big: big) == cls { i -= 1 }
        return i
    }

    static func prevWordEnd(_ doc: Doc, _ pos: Int, big: Bool) -> Int {
        guard doc.count > 0 else { return 0 }
        var i = min(pos, doc.count - 1)
        let c0 = CharClass(doc[i], big: big)
        if c0.isWordish {
            while i > 0, CharClass(doc[i - 1], big: big) == c0 { i -= 1 }
        }
        i -= 1
        while i >= 0 {
            let c = doc[i]
            if c == "\n" {
                if i == 0 || doc[i - 1] == "\n" { return i }
                i -= 1
                continue
            }
            if c.isWhitespace { i -= 1; continue }
            return i
        }
        return 0
    }

    // MARK: Find

    static func findOnLine(_ doc: Doc, cursor: Int, kind: FindKind, target: Character, count: Int, repeating: Bool) -> MotionResult? {
        let line = doc.line(of: cursor)
        let start = doc.lineStart(line), end = doc.lineEnd(line)
        func locate(_ n: Int) -> Int? {
            var found = 0
            switch kind {
            case .forwardOnto, .forwardBefore:
                var i = cursor + 1
                while i < end {
                    if doc[i] == target { found += 1; if found == n { return i } }
                    i += 1
                }
            case .backwardOnto, .backwardAfter:
                var i = cursor - 1
                while i >= start {
                    if doc[i] == target { found += 1; if found == n { return i } }
                    i -= 1
                }
            }
            return nil
        }
        guard var hit = locate(count) else { return nil }
        // `;` after `t`/`T` doesn't get stuck on the adjacent target.
        if repeating, count == 1, kind.cursorPosition(ofTargetChar: hit) == cursor {
            guard let next = locate(2) else { return nil }
            hit = next
        }
        switch kind {
        case .forwardOnto: return MotionResult(target: hit, inclusive: true)
        case .forwardBefore: return MotionResult(target: hit - 1, inclusive: true)
        case .backwardOnto: return MotionResult(target: hit)
        case .backwardAfter: return MotionResult(target: hit + 1)
        }
    }

    // MARK: Brackets

    static func matchingBracket(_ doc: Doc, from cursor: Int) -> Int? {
        let line = doc.line(of: cursor)
        let end = doc.lineEnd(line)
        var i = cursor
        let pairs: [Character: (Character, Bool)] = [
            "(": (")", true), "[": ("]", true), "{": ("}", true),
            ")": ("(", false), "]": ("[", false), "}": ("{", false)
        ]
        while i < end, pairs[doc[i]] == nil { i += 1 }
        guard i < end, let (other, forward) = pairs[doc[i]] else { return nil }
        let me = doc[i]
        var depth = 0
        var j = i
        while true {
            j += forward ? 1 : -1
            guard j >= 0, j < doc.count else { return nil }
            if doc[j] == me { depth += 1 } else if doc[j] == other {
                if depth == 0 { return j }
                depth -= 1
            }
        }
    }

    // MARK: Sentences

    /// Offsets where sentences start (vim `(` / `)`): after `.!?` (plus
    /// closing `)]"'`) followed by white space, and at paragraph edges.
    static func sentenceStarts(_ doc: Doc) -> [Int] {
        var starts: [Int] = []
        let n = doc.count
        func firstNonWhite(from: Int) -> Int? {
            var k = from
            while k < n {
                if doc[k] == "\n" {
                    if k == 0 || doc[k - 1] == "\n" { return k }
                    k += 1
                    continue
                }
                if doc[k].isWhitespace { k += 1; continue }
                return k
            }
            return nil
        }
        if let f = firstNonWhite(from: 0) { starts.append(f) }
        var i = 0
        while i < n {
            let c = doc[i]
            if c == "\n", i == 0 || doc[i - 1] == "\n" {
                // Empty line: a start itself, and so is the text after it.
                starts.append(i)
                if i + 1 < n, doc[i + 1] != "\n", let f = firstNonWhite(from: i + 1) { starts.append(f) }
            } else if c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < n, ")]\"'".contains(doc[j]) { j += 1 }
                if j == n || doc[j].isWhitespace || doc[j] == "\n" {
                    if let f = firstNonWhite(from: j), f > i { starts.append(f) }
                }
            }
            i += 1
        }
        return Array(Set(starts)).sorted()
    }

    // MARK: Marks

    static func markOffset(_ name: Character, state: VimState, doc: Doc) -> Int? {
        switch name {
        case "`": return state.marks["'"]
        case "<": return state.lastVisual.map { min($0.anchor, $0.head) } ?? state.marks["<"]
        case ">": return state.lastVisual.map { max($0.anchor, $0.head) } ?? state.marks[">"]
        default:
            if let v = state.marks[name] { return v }
            if name.isUppercase { return state.marks[Character(name.lowercased())] }
            return nil
        }
    }

    // MARK: Words under the cursor

    /// The keyword (or WORD of non-blanks) at or after the cursor on its
    /// line, with its start offset — what `*` / `#` search for.
    static func wordAtOrAfter(_ doc: Doc, _ cursor: Int) -> (String, Int)? {
        let line = doc.line(of: cursor)
        let end = doc.lineEnd(line)
        var i = cursor
        while i < end, !isKeywordChar(doc[i]) { i += 1 }
        if i < end {
            var lo = i
            while lo > doc.lineStart(line), isKeywordChar(doc[lo - 1]) { lo -= 1 }
            var hi = i
            while hi < end, isKeywordChar(doc[hi]) { hi += 1 }
            return (doc.text(lo, hi), lo)
        }
        // No keyword: the non-blank run under/after the cursor.
        i = cursor
        while i < end, isBlank(doc[i]) { i += 1 }
        guard i < end else { return nil }
        var lo = i
        while lo > doc.lineStart(line), !isBlank(doc[lo - 1]) { lo -= 1 }
        var hi = i
        while hi < end, !isBlank(doc[hi]) { hi += 1 }
        return (doc.text(lo, hi), lo)
    }
}
