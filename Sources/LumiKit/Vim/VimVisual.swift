import Foundation

extension VimEngine {
    /// The region a visual selection covers.
    static func visualRegion(kind: VimMode.VisualKind, anchor: Int, head: Int, toEnd: Bool, doc: Doc) -> Region {
        let lo = min(anchor, head), hi = max(anchor, head)
        switch kind {
        case .characterwise:
            return .chars(lo, min(hi + 1, doc.count))
        case .linewise:
            return .lines(doc.line(of: lo), doc.line(of: hi))
        case .block:
            let ca = doc.column(of: anchor), ch = doc.column(of: head)
            return .block(BlockRegion(
                firstLine: doc.line(of: lo), lastLine: doc.line(of: hi),
                left: min(ca, ch), right: max(ca, ch), toEnd: toEnd
            ))
        }
    }

    /// Leave visual mode, remembering the selection for `gv` / `'<`.
    static func exitVisual(_ st: inout VimState, _ b: TextBuffer) {
        guard case let .visual(kind, anchor) = st.mode else { return }
        rememberVisual(kind: kind, anchor: anchor, head: b.cursor, &st)
        st.mode = .normal
        st.blockToLineEnd = false
    }

    static func rememberVisual(kind: VimMode.VisualKind, anchor: Int, head: Int, _ st: inout VimState) {
        st.lastVisual = VisualSnapshot(kind: kind, anchor: anchor, head: head, toLineEnd: st.blockToLineEnd)
        st.marks["<"] = min(anchor, head)
        st.marks[">"] = max(anchor, head)
    }

    static func executeVisual(_ cmd: ParsedCommand, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        guard case let .visual(kind, anchor) = st.mode else { return }
        let doc = Doc(b.text)
        let count = cmd.count
        let n = max(1, count ?? 1)
        let head = min(b.cursor, doc.count)
        let region = visualRegion(kind: kind, anchor: anchor, head: head, toEnd: st.blockToLineEnd, doc: doc)
        var keepDesired = false

        switch cmd.action {
        case .escape:
            exitVisual(&st, b)

        case let .motion(m):
            guard let r = resolveMotion(m, count: count, doc: doc, cursor: head, state: &st, context: .visual) else { break }
            moveCursor(r, m, from: head, doc: doc, &st, &b, &fx)
            keepDesired = r.vertical || m == .lineEnd
            if kind == .block {
                if m == .lineEnd { st.blockToLineEnd = true }
                else if !r.vertical { st.blockToLineEnd = false }
            }

        case let .objectSelect(spec):
            guard var obj = resolveObject(spec, count: n, doc: doc, cursor: head) else { break }
            let lo = min(anchor, head), hi = max(anchor, head)
            if lo == obj.from, hi + 1 == obj.to, "([{<bB)]}>\"'`t".contains(spec.kind),
               let outer = resolveObject(spec, count: n + 1, doc: doc, cursor: head) {
                obj = outer
            }
            if obj.linewise {
                st.mode = .visual(kind == .characterwise ? .linewise : kind, anchor: min(lo, obj.from))
                b.cursor = max(hi, max(obj.from, obj.to - 1))
            } else if anchor == head {
                st.mode = .visual(kind, anchor: obj.from)
                b.cursor = max(obj.from, obj.to - 1)
            } else if head >= anchor {
                st.mode = .visual(kind, anchor: min(anchor, obj.from))
                b.cursor = max(head, obj.to - 1)
            } else {
                st.mode = .visual(kind, anchor: max(anchor, obj.to - 1))
                b.cursor = min(head, obj.from)
            }

        case let .visual(k2):
            if k2 == kind { exitVisual(&st, b) } else { st.mode = .visual(k2, anchor: anchor) }

        case let .swapEnds(horizontal):
            if horizontal, kind == .block {
                let la = doc.line(of: anchor), lh = doc.line(of: head)
                let ca = doc.column(of: anchor), ch = doc.column(of: head)
                st.mode = .visual(kind, anchor: doc.offset(line: la, column: ch))
                b.cursor = doc.offset(line: lh, column: ca)
            } else {
                st.mode = .visual(kind, anchor: head)
                b.cursor = anchor
            }

        case .reselect:
            let current = VisualSnapshot(kind: kind, anchor: anchor, head: head, toLineEnd: st.blockToLineEnd)
            if let v = st.lastVisual {
                st.mode = .visual(v.kind, anchor: min(v.anchor, doc.count))
                b.cursor = min(v.head, doc.count)
                st.blockToLineEnd = v.toLineEnd
            }
            st.lastVisual = current

        case .cmdline:
            exitVisual(&st, b)
            st.mode = .commandLine(prefix: ":", buffer: "'<,'>")
            st.commandLineHistoryIndex = nil
            st.commandLineHistoryDraft = nil

        case let .search(prefix):
            st.commandLineVisual = VisualSnapshot(kind: kind, anchor: anchor, head: head, toLineEnd: st.blockToLineEnd)
            enterSearch(prefix, op: nil, register: nil, count: count, &st, &b)

        case let .visualOperator(op):
            exitVisual(&st, b)
            let amount = (op == .shiftLeft || op == .shiftRight) ? n : 1
            applyOperator(op, region, register: cmd.register, amount: amount, doc: doc, &st, &b)
            if op == .yank { b.cursor = regionStart(region, doc: doc) }

        case let .visualLinewise(op):
            exitVisual(&st, b)
            let (a, z) = lineSpan(region, doc: doc)
            applyOperator(op, .lines(a, z), register: cmd.register, amount: 1, doc: doc, &st, &b)
            if op == .yank { b.cursor = doc.lineStart(a) }

        case let .visualToEnd(op):
            exitVisual(&st, b)
            if case var .block(r) = region {
                r.toEnd = true
                applyOperator(op, .block(r), register: cmd.register, amount: 1, doc: doc, &st, &b)
            } else {
                let (a, z) = lineSpan(region, doc: doc)
                applyOperator(op, .lines(a, z), register: cmd.register, amount: 1, doc: doc, &st, &b)
            }

        case let .visualJoin(spaces):
            exitVisual(&st, b)
            let (a, z) = lineSpan(region, doc: doc)
            guard a < doc.lastLine else { break }
            join(firstLine: a, lines: max(2, z - a + 1), spaces: spaces, &st, &b)

        case let .visualReplace(c):
            exitVisual(&st, b)
            pushUndo(&st, b)
            var spans: [(Int, Int)] = []
            switch region {
            case let .chars(f, t): spans = [(f, t)]
            case let .lines(a, z): spans = (a...z).map { (doc.lineStart($0), doc.lineEnd($0)) }
            case let .block(r): spans = (r.firstLine...r.lastLine).map { blockSpan(r, line: $0, doc: doc) }
            }
            for (s, e) in spans.reversed() where s < e {
                let old = doc.text(s, e)
                let new = String(old.map { $0 == "\n" ? "\n" : c })
                if new != old { edit(s, e, new, &st, &b) }
            }
            b.cursor = spans.first?.0 ?? head

        case let .visualPut(after):
            let reg = readRegister(cmd.register, st)
            exitVisual(&st, b)
            guard let reg else { break }
            pushUndo(&st, b)
            let (replaced, replacedKind) = regionText(region, doc: doc)
            switch region {
            case let .chars(f, t):
                let text = reg.kind == .linewise ? "\n" + reg.text : reg.text
                edit(f, t, text, &st, &b)
                b.cursor = reg.kind == .linewise ? f + 1 : max(f, f + text.count - 1)
            case let .lines(a, z):
                var text = reg.text
                if reg.kind != .linewise { text += "\n" }
                if !text.hasSuffix("\n") { text += "\n" }
                if z < doc.lastLine {
                    edit(doc.lineStart(a), doc.lineStart(z + 1), text, &st, &b)
                } else {
                    edit(doc.lineStart(a), doc.count, String(text.dropLast()), &st, &b)
                }
                b.cursor = Doc(b.text).firstNonBlank(a)
            case .block:
                deleteRegion(region, doc: doc, &st, &b)
                let at = b.cursor
                edit(at, at, reg.text, &st, &b)
                b.cursor = at
            }
            if after {
                storeRegister(replaced, kind: replacedKind, register: nil, isDelete: true, &st)
            }

        case let .visualInsert(append):
            exitVisual(&st, b)
            pushUndo(&st, b)
            switch region {
            case let .block(r):
                if append {
                    if r.toEnd {
                        startInsert(at: doc.lineEnd(r.firstLine), count: 1,
                                    kind: .block(firstLine: r.firstLine, lastLine: r.lastLine, column: 0, toLineEnd: true, pad: false), &st, &b)
                    } else {
                        let col = r.right + 1
                        let len = doc.lineLength(r.firstLine)
                        var at = doc.lineStart(r.firstLine) + min(col, len)
                        if len < col {
                            edit(doc.lineEnd(r.firstLine), doc.lineEnd(r.firstLine), String(repeating: " ", count: col - len), &st, &b)
                            at = doc.lineStart(r.firstLine) + col
                        }
                        startInsert(at: at, count: 1,
                                    kind: .block(firstLine: r.firstLine, lastLine: r.lastLine, column: col, toLineEnd: false, pad: true), &st, &b)
                    }
                } else {
                    startInsert(at: doc.offset(line: r.firstLine, column: r.left, allowEnd: true), count: 1,
                                kind: .block(firstLine: r.firstLine, lastLine: r.lastLine, column: r.left, toLineEnd: false, pad: false), &st, &b)
                }
            case let .chars(f, t):
                startInsert(at: append ? t : f, count: 1, kind: .plain, &st, &b)
            case let .lines(a, z):
                startInsert(at: append ? doc.lineEnd(z) : doc.firstNonBlank(a), count: 1, kind: .plain, &st, &b)
            }

        case let .increment(delta):
            exitVisual(&st, b)
            let (a, z) = lineSpan(region, doc: doc)
            pushUndo(&st, b)
            for l in stride(from: z, through: a, by: -1) {
                let cur = Doc(b.text)
                var from = cur.lineStart(l)
                if case let .block(r) = region { from = blockSpan(r, line: l, doc: cur).0 }
                if case let .chars(f, _) = region, l == a { from = f }
                incrementQuiet(line: l, from: from, by: delta * n, doc: cur, &st, &b)
            }
            b.cursor = Doc(b.text).lineStart(a)

        case let .scroll(kind):
            scroll(kind, count: count, doc: doc, &st, &b, &fx)
            keepDesired = true

        case let .scrollCursor(pos, _):
            fx = .scrollCursor(pos)
            keepDesired = true

        default:
            break
        }
        if !keepDesired { st.desiredColumn = nil }
        clamp(st, &b)
    }

    static func regionStart(_ region: Region, doc: Doc) -> Int {
        switch region {
        case let .chars(f, _): return f
        case let .lines(a, _): return doc.lineStart(a)
        case let .block(r): return doc.offset(line: r.firstLine, column: r.left)
        }
    }

    /// Ctrl-A on one line without its own undo step (visual increment).
    private static func incrementQuiet(line: Int, from: Int, by delta: Int, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        let le = doc.lineEnd(line)
        var i = from
        while i < le, !(doc[i].isASCII && doc[i].isNumber) { i += 1 }
        guard i < le else { return }
        var start = i
        var end = i
        while end < le, doc[end].isASCII, doc[end].isNumber { end += 1 }
        if start > doc.lineStart(line), doc[start - 1] == "-" { start -= 1 }
        guard let value = Int(doc.text(start, end)) else { return }
        edit(start, end, String(value + delta), &st, &b)
    }
}
