import Foundation

/// Ex command lines (`:`): ranges, `:s`, `:g`, `:normal`, `:d`, `:y`,
/// `:set`, the `:map` family, `:registers`, `:marks` …
extension VimEngine {
    static let exDepthLimit = 8

    private struct ExCursor {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }
        var atEnd: Bool { i >= chars.count }
        var peek: Character? { i < chars.count ? chars[i] : nil }
        mutating func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
        var rest: String { i < chars.count ? String(chars[i...]) : "" }
        mutating func number() -> Int? {
            var v: Int?
            while i < chars.count, chars[i].isASCII, let d = chars[i].wholeNumberValue {
                v = min(99_999_999, (v ?? 0) * 10 + d)
                i += 1
            }
            return v
        }
    }

    private enum AddressError: Error { case message(String) }

    static func executeEx(_ raw: String, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?, depth: Int) {
        guard depth < exDepthLimit else { return }
        var line = raw
        while line.first == ":" || line.first == " " { line.removeFirst() }
        if line.isEmpty { return }
        let doc = Doc(b.text)
        let curLine = doc.line(of: min(b.cursor, doc.count))
        var c = ExCursor(line)

        // Range.
        var range: (Int, Int)?
        do {
            range = try parseRange(&c, doc: doc, st: &st, curLine: curLine)
        } catch let AddressError.message(m) {
            st.message = VimMessage(m, isError: true)
            return
        } catch { return }
        c.skipSpaces()

        // Command name.
        var name = ""
        if let p = c.peek {
            if p.isLetter {
                while let q = c.peek, q.isLetter { name.append(q); c.i += 1 }
                // `:s#a#b#`, `:g!`: names end at the first non-letter.
            } else if p == ">" || p == "<" {
                while c.peek == p { name.append(p); c.i += 1 }
            } else if "&~!=#@*".contains(p) {
                name = String(p)
                c.i += 1
                if p == "&", c.peek == "&" { name = "&&"; c.i += 1 }
            }
        }
        // Abbreviations like `:s` keep letters that are part of the pattern
        // delimiter out (`:s/`), but `:substitute` is one word.
        var bang = false
        if c.peek == "!", !["s", "substitute", "&", "&&", "~"].contains(name) { bang = true; c.i += 1 }
        let argsRaw = c.rest
        let args = argsRaw.trimmingCharacters(in: .whitespaces)

        // Ex aliases from `map :W :write`.
        if let alias = st.mappings.first(where: { $0.exAlias == name }) {
            let rhs = alias.rhs.notation.replacingOccurrences(of: "<CR>", with: "")
            var r = rhs
            while r.first == ":" { r.removeFirst() }
            let prefix = range.map { "\($0.0 + 1),\($0.1 + 1)" } ?? ""
            executeEx(prefix + r + (bang ? "!" : "") + (args.isEmpty ? "" : " " + args), &st, &b, &fx, depth: depth + 1)
            return
        }

        func lines() -> (Int, Int) { range ?? (curLine, curLine) }

        switch name {
        case "":
            guard let range else { return }
            st.marks["'"] = b.cursor
            b.cursor = doc.firstNonBlank(range.1)

        case "w", "write", "up", "update", "wa", "wall":
            fx = .save(force: bang)
        case "wq", "x", "xi", "xit", "exi", "exit", "wqa", "wqall", "xa", "xall":
            fx = .saveAndClose(force: bang)
        case "q", "quit", "qa", "qall", "quita", "quitall", "clo", "close":
            fx = .close(force: bang)

        case "s", "su", "sub", "substitute":
            substitute(range: range, args: argsRaw, &st, &b)
        case "&", "&&":
            let flags = name == "&&" ? (st.lastSubstitute?.flags ?? "") + args : args
            substituteRepeat(range: range, flags: flags, usingLastSearch: false, &st, &b)
        case "~":
            substituteRepeat(range: range, flags: args, usingLastSearch: true, &st, &b)

        case "d", "de", "del", "dele", "delete":
            let (reg, cnt) = registerAndCount(args)
            var (a, z) = lines()
            if let cnt { a = z; z = doc.clampLine(z + cnt - 1) }
            applyOperator(.delete, .lines(a, z), register: reg, amount: 1, doc: doc, &st, &b)
        case "y", "ya", "yank":
            let (reg, cnt) = registerAndCount(args)
            var (a, z) = lines()
            if let cnt { a = z; z = doc.clampLine(z + cnt - 1) }
            let saved = b.cursor
            applyOperator(.yank, .lines(a, z), register: reg, amount: 1, doc: doc, &st, &b)
            b.cursor = saved

        case "norm", "norma", "normal":
            exNormal(range: range, keys: argsRaw.drop(while: { $0 == " " }).description, remap: !bang, &st, &b, &fx, depth: depth)

        case "g", "gl", "global", "v", "vg", "vglobal":
            guard depth == 0 else {
                st.message = VimMessage("E147: Cannot do :global recursive", isError: true)
                return
            }
            global(range: range ?? (0, doc.lastLine), args: argsRaw, invert: bang || name.hasPrefix("v"), &st, &b, &fx, depth: depth)

        case "noh", "nohl", "nohlsearch":
            st.hlsearchSuspended = true

        case "se", "set", "setl", "setlocal", "setg", "setglobal":
            exSet(args, &st)

        case "map", "nm", "nmap", "im", "imap", "vm", "vmap", "xm", "xmap",
             "no", "noremap", "nn", "nnoremap", "ino", "inoremap", "vn", "vnoremap", "xn", "xnoremap":
            if args.isEmpty {
                st.message = VimMessage(listMappings(st))
                return
            }
            exMap(name + " " + args, &st)
        case "unm", "unmap", "nun", "nunmap", "iu", "iunmap", "vu", "vunmap", "xu", "xunmap":
            exMap(name + " " + args, &st)
        case "mapc", "mapclear", "nmapc", "nmapclear", "imapc", "imapclear", "vmapc", "vmapclear":
            let mode: VimMapping.Mode? = name.hasPrefix("n") ? .normal : name.hasPrefix("i") ? .insert : name.hasPrefix("v") ? .visual : nil
            st.mappings.removeAll { $0.exAlias == nil && (mode == nil || $0.mode == mode) }

        case "let":
            let parsed = Vimrc.parse("let " + args)
            if let d = parsed.diagnostics.first(where: { $0.severity == .error || $0.severity == .warning }) {
                st.message = VimMessage(d.message, isError: true)
            } else {
                st.leader = parsed.leader
            }

        case "reg", "regi", "registers", "di", "dis", "display":
            st.message = VimMessage(listRegisters(st, only: args))

        case "marks":
            st.message = VimMessage(listMarks(st, doc: doc, only: args))

        case "delm", "delmarks":
            if bang {
                st.marks = st.marks.filter { !($0.key.isLowercase && $0.key.isLetter) }
            } else {
                for ch in args where ch != " " { st.marks[ch] = nil }
            }

        case "j", "jo", "join":
            var (a, z) = lines()
            if range == nil || a == z { z = min(doc.lastLine, a + 1) }
            if let cnt = Int(args) { z = doc.clampLine(z + cnt - 1) }
            guard a < z else { return }
            join(firstLine: a, lines: z - a + 1, spaces: !bang, &st, &b)

        case ">", ">>", ">>>", "<", "<<", "<<<":
            let (a, z) = lines()
            pushUndo(&st, b)
            shiftLines(a, z, right: name.first == ">", amount: name.count, doc: doc, &st, &b)
            b.cursor = Doc(b.text).firstNonBlank(z)

        case "m", "mo", "move":
            moveLines(lines(), to: args, doc: doc, &st, &b)
        case "t", "co", "copy":
            copyLines(lines(), to: args, doc: doc, &st, &b)

        case "pu", "put":
            let reg = args.first
            guard let r = readRegister(reg, st) else { return }
            var text = r.text
            if !text.hasSuffix("\n") { text += "\n" }
            let target = range?.1 ?? curLine
            pushUndo(&st, b)
            if bang {
                edit(doc.lineStart(target), doc.lineStart(target), text, &st, &b)
                b.cursor = Doc(b.text).firstNonBlank(target)
            } else if target >= doc.lastLine {
                edit(doc.count, doc.count, "\n" + text.dropLast(), &st, &b)
                b.cursor = Doc(b.text).firstNonBlank(target + 1)
            } else {
                edit(doc.lineStart(target + 1), doc.lineStart(target + 1), text, &st, &b)
                b.cursor = Doc(b.text).firstNonBlank(target + 1)
            }

        case "u", "un", "undo":
            undo(&st, &b)
        case "red", "redo":
            redo(&st, &b)

        case "sor", "sort":
            sortLines(range ?? (0, doc.lastLine), flags: args, reverse: bang, doc: doc, &st, &b)

        case "f", "fi", "file":
            let name = st.fileName.map { "\"\($0)\"" } ?? "[No Name]"
            st.message = VimMessage("\(name) \(doc.lineCount) lines")

        default:
            st.message = VimMessage("E492: Not an editor command: \(line)", isError: true)
        }
        clamp(st, &b)
    }

    // MARK: Ranges

    private static func parseRange(_ c: inout ExCursor, doc: Doc, st: inout VimState, curLine: Int) throws -> (Int, Int)? {
        c.skipSpaces()
        if c.peek == "%" {
            c.i += 1
            return (0, doc.lastLine)
        }
        if c.peek == "*" {
            c.i += 1
            guard let lo = markOffset("<", state: st, doc: doc), let hi = markOffset(">", state: st, doc: doc) else {
                throw AddressError.message("E20: Mark not set")
            }
            return (doc.line(of: lo), doc.line(of: hi))
        }
        var addrs: [Int] = []
        var base = curLine
        while true {
            c.skipSpaces()
            let a = try parseAddress(&c, doc: doc, st: &st, base: base)
            c.skipSpaces()
            if c.peek == "," {
                c.i += 1
                addrs.append(a ?? base)
                continue
            }
            if c.peek == ";" {
                c.i += 1
                let v = a ?? base
                addrs.append(v)
                base = v
                continue
            }
            if let a { addrs.append(a) }
            break
        }
        guard !addrs.isEmpty else { return nil }
        var lo = addrs.count >= 2 ? addrs[addrs.count - 2] : addrs[0]
        var hi = addrs[addrs.count - 1]
        if lo > hi { swap(&lo, &hi) }
        guard lo >= 0, hi <= doc.lastLine else { throw AddressError.message("E16: Invalid range") }
        return (lo, hi)
    }

    /// One address (0-based line) or nil when none is written.
    private static func parseAddress(_ c: inout ExCursor, doc: Doc, st: inout VimState, base: Int) throws -> Int? {
        var value: Int?
        guard let p = c.peek else { return nil }
        switch p {
        case ".":
            c.i += 1
            value = base
        case "$":
            c.i += 1
            value = doc.lastLine
        case "'":
            c.i += 1
            guard let m = c.peek else { throw AddressError.message("E20: Mark not set") }
            c.i += 1
            guard let off = markOffset(m, state: st, doc: doc) else { throw AddressError.message("E20: Mark not set") }
            value = doc.line(of: min(off, doc.count))
        case "/", "?":
            c.i += 1
            var pat = ""
            while let q = c.peek, q != p {
                if q == "\\", c.i + 1 < c.chars.count, c.chars[c.i + 1] == p { pat.append(p); c.i += 2; continue }
                pat.append(q)
                c.i += 1
            }
            if c.peek == p { c.i += 1 }
            if pat.isEmpty { pat = st.lastSearch?.pattern ?? "" }
            guard !pat.isEmpty else { throw AddressError.message("E35: No previous regular expression") }
            let from = p == "/" ? doc.lineEnd(base) : doc.lineStart(base)
            let dir: SearchDirection = p == "/" ? .forward : .backward
            let opts = SearchCaseOptions(ignorecase: st.options.ignorecase, smartcase: st.options.smartcase)
            guard let r = nextMatch(in: doc.string, pattern: pat, from: from, direction: dir, case: opts) else {
                throw AddressError.message("E486: Pattern not found: \(pat)")
            }
            st.lastSearch = SearchMemory(pattern: pat, direction: dir)
            value = doc.line(of: r.lowerBound)
        case "\\":
            c.i += 1
            if let q = c.peek, q == "/" || q == "?" || q == "&" {
                c.i += 1
                guard let pat = st.lastSearch?.pattern,
                      let r = nextMatch(in: doc.string, pattern: pat, from: doc.lineEnd(base), direction: q == "?" ? .backward : .forward)
                else { throw AddressError.message("E35: No previous regular expression") }
                value = doc.line(of: r.lowerBound)
            }
        default:
            if p.isASCII, p.isNumber {
                value = max(0, (c.number() ?? 1) - 1)
            }
        }
        // Offsets: +N, -N, +, -.
        while let q = c.peek, q == "+" || q == "-" {
            c.i += 1
            let n = c.number() ?? 1
            value = (value ?? base) + (q == "+" ? n : -n)
        }
        if let v = value, v < 0 || v > doc.lastLine {
            if v == -1 { return 0 }
            throw AddressError.message("E16: Invalid range")
        }
        return value
    }

    private static func registerAndCount(_ args: String) -> (Character?, Int?) {
        var s = Substring(args)
        var reg: Character?
        if let f = s.first, !(f.isASCII && f.isNumber) {
            reg = f
            s = s.dropFirst()
        }
        let cnt = Int(s.trimmingCharacters(in: .whitespaces))
        return (reg, cnt)
    }

    // MARK: :substitute

    /// Split `/pat/rep/flags` on an unescaped delimiter.
    static func splitDelimited(_ s: String) -> (delim: Character, parts: [String])? {
        guard let d = s.first, !d.isLetter, !d.isNumber, d != " ", d != "\"", d != "|", d != "\\" else { return nil }
        var parts: [String] = []
        var cur = ""
        var it = s.dropFirst().makeIterator()
        while let ch = it.next() {
            if ch == "\\" {
                guard let nx = it.next() else { cur.append(ch); break }
                if nx == d { cur.append(d) } else { cur.append(ch); cur.append(nx) }
                continue
            }
            if ch == d, parts.count < 2 {
                parts.append(cur)
                cur = ""
                continue
            }
            cur.append(ch)
        }
        parts.append(cur)
        return (d, parts)
    }

    private static func substitute(range: (Int, Int)?, args: String, _ st: inout VimState, _ b: inout TextBuffer) {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard let (_, parts) = splitDelimited(trimmed) else {
            // `:s` / `:s g`: repeat the last substitute with new flags.
            substituteRepeat(range: range, flags: trimmed, usingLastSearch: false, &st, &b)
            return
        }
        var pattern = parts[0]
        var replacement = parts.count > 1 ? parts[1] : ""
        let tail = parts.count > 2 ? parts[2] : ""
        if pattern.isEmpty {
            guard let last = st.lastSearch?.pattern else {
                st.message = VimMessage("E35: No previous regular expression", isError: true)
                return
            }
            pattern = last
        }
        // `~` in the replacement is the previous replacement string.
        if let prev = st.lastSubstitute?.replacement {
            var out = ""
            var it = replacement.makeIterator()
            while let ch = it.next() {
                if ch == "\\" { out.append(ch); if let nx = it.next() { out.append(nx) }; continue }
                if ch == "~" { out += prev } else { out.append(ch) }
            }
            replacement = out
        }
        var flags = ""
        var countStr = ""
        for ch in tail {
            if ch.isASCII, ch.isNumber { countStr.append(ch) } else if ch != " " { flags.append(ch) }
        }
        if flags.contains("&"), let lastFlags = st.lastSubstitute?.flags {
            flags = lastFlags + flags.replacingOccurrences(of: "&", with: "")
        }
        runSubstitute(pattern: pattern, replacement: replacement, flags: flags, count: Int(countStr), range: range, &st, &b)
    }

    private static func substituteRepeat(range: (Int, Int)?, flags rawFlags: String, usingLastSearch: Bool, _ st: inout VimState, _ b: inout TextBuffer) {
        guard let last = st.lastSubstitute else {
            st.message = VimMessage("E35: No previous regular expression", isError: true)
            return
        }
        var flags = ""
        var countStr = ""
        for ch in rawFlags {
            if ch.isASCII, ch.isNumber { countStr.append(ch) } else if ch != " " { flags.append(ch) }
        }
        if flags.hasPrefix("&") { flags = last.flags + flags.dropFirst() }
        let pattern = usingLastSearch ? (st.lastSearch?.pattern ?? last.pattern) : last.pattern
        runSubstitute(pattern: pattern, replacement: last.replacement, flags: flags, count: Int(countStr), range: range, &st, &b)
    }

    private static func runSubstitute(pattern: String, replacement: String, flags: String, count: Int?, range: (Int, Int)?, _ st: inout VimState, _ b: inout TextBuffer) {
        let doc = Doc(b.text)
        let cur = doc.line(of: min(b.cursor, doc.count))
        var (a, z) = range ?? (cur, cur)
        if let count { a = z; z = doc.clampLine(z + count - 1) }
        st.lastSubstitute = SubstituteMemory(pattern: pattern, replacement: replacement, flags: flags)
        st.lastSearch = SearchMemory(pattern: pattern, direction: .forward)
        st.hlsearchSuspended = false
        appendSearchHistory(pattern, state: &st)

        var opts = SearchCaseOptions(ignorecase: st.options.ignorecase, smartcase: st.options.smartcase)
        if flags.contains("i") { opts = SearchCaseOptions(ignorecase: true, smartcase: false) }
        if flags.contains("I") { opts = SearchCaseOptions(ignorecase: false, smartcase: false) }
        guard let regex = compileVimPattern(pattern, case: opts) else {
            st.message = VimMessage("E486: Pattern not found: \(pattern)", isError: true)
            return
        }
        let global = flags.contains("g")

        if flags.contains("c") {
            pushUndo(&st, b)
            st.trackedOffsets.append(doc.lineEnd(z))
            var confirm = SubstituteConfirm(
                pattern: pattern, replacement: replacement, global: global,
                caseFlag: flags.contains("I") ? "I" : flags.contains("i") ? "i" : nil,
                searchFrom: doc.lineStart(a), limitIndex: st.trackedOffsets.count - 1
            )
            confirm.current = nextConfirmMatch(confirm, regex: regex, st: st, b: b)
            guard let cm = confirm.current else {
                st.trackedOffsets.removeLast()
                st.message = VimMessage("E486: Pattern not found: \(pattern)", isError: true)
                return
            }
            st.substituteConfirm = confirm
            b.cursor = cm.lowerBound
            st.message = VimMessage("replace with \(replacement) (y/n/a/q/l)?")
            return
        }

        let text = b.text
        let ns = text as NSString
        let start16 = utf16Offset(in: text, characterOffset: doc.lineStart(a))
        let end16 = utf16Offset(in: text, characterOffset: doc.lineEnd(z))
        let all = regex.matches(in: text, options: [], range: NSRange(location: start16, length: ns.length - start16))
        var chosen: [NSTextCheckingResult] = []
        var lastLineStart = -1
        var scanPos = start16
        var lineStart16 = start16
        for m in all {
            guard m.range.location <= end16 else { break }
            // Track which line the match starts on (UTF-16 domain).
            if m.range.location > scanPos {
                let seg = NSRange(location: scanPos, length: m.range.location - scanPos)
                let r = ns.range(of: "\n", options: .backwards, range: seg)
                if r.location != NSNotFound { lineStart16 = r.location + 1 }
                scanPos = m.range.location
            }
            if !global, lineStart16 == lastLineStart { continue }
            chosen.append(m)
            lastLineStart = lineStart16
        }
        let n = chosen.count
        if flags.contains("n") {
            st.message = VimMessage("\(n) match\(n == 1 ? "" : "es")")
            return
        }
        guard n > 0 else {
            if !flags.contains("e") { st.message = VimMessage("E486: Pattern not found: \(pattern)", isError: true) }
            return
        }
        pushUndo(&st, b)
        var edits: [TextEdit] = []
        for m in chosen.reversed() {
            let rep = expandReplacement(replacement, match: m, in: ns)
            edits.append(TextEdit(location: m.range.location, length: m.range.length, replacement: rep))
        }
        let lastEnd = NSMaxRange(chosen.last!.range)
        applyBulk(edits, &st, &b)
        let newLoc = PositionMapper.map(lastEnd, through: edits, assoc: .after)
        let nd = Doc(b.text)
        let lastLine = nd.line(of: characterOffset(utf16: newLoc, in: b.text))
        st.marks["'"] = b.cursor
        b.cursor = nd.firstNonBlank(lastLine)
        st.marks["."] = b.cursor
        let lineCount = Set(chosen.map { m -> Int in
            doc.line(of: characterOffset(utf16: m.range.location, in: text))
        }).count
        if n > 1 { st.message = VimMessage("\(n) substitution\(n == 1 ? "" : "s") on \(lineCount) line\(lineCount == 1 ? "" : "s")") }
    }

    /// Expand `&`, `\1`, `\r`, `\u` … in a replacement string.
    static func expandReplacement(_ repl: String, match: NSTextCheckingResult, in ns: NSString) -> String {
        var out = ""
        var one: Character?
        var all: Character?
        func group(_ i: Int) -> String {
            guard i < match.numberOfRanges else { return "" }
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        func emit(_ s: String) {
            for ch in s {
                var t = String(ch)
                if let o = one { t = o == "u" ? t.uppercased() : t.lowercased(); one = nil }
                else if let a = all { t = a == "U" ? t.uppercased() : t.lowercased() }
                out += t
            }
        }
        var it = repl.makeIterator()
        while let ch = it.next() {
            if ch == "\\" {
                guard let nx = it.next() else { out.append("\\"); break }
                switch nx {
                case "0"..."9": emit(group(Int(String(nx)) ?? 0))
                case "n", "r": out.append("\n")
                case "t": out.append("\t")
                case "u", "l": one = nx
                case "U", "L": all = nx
                case "e", "E": all = nil; one = nil
                default: emit(String(nx))
                }
                continue
            }
            if ch == "&" { emit(group(0)); continue }
            emit(String(ch))
        }
        return out
    }

    private static func nextConfirmMatch(_ c: SubstituteConfirm, regex: NSRegularExpression, st: VimState, b: TextBuffer) -> Range<Int>? {
        guard c.limitIndex < st.trackedOffsets.count, let limit = st.trackedOffsets[c.limitIndex] else { return nil }
        let text = b.text
        let ns = text as NSString
        let from16 = utf16Offset(in: text, characterOffset: min(c.searchFrom, text.count))
        guard from16 <= ns.length else { return nil }
        guard let m = regex.firstMatch(in: text, options: [], range: NSRange(location: from16, length: ns.length - from16)),
              let r = characterRange(in: text, utf16Range: m.range), r.lowerBound <= limit
        else { return nil }
        return r
    }

    static func handleSubstituteConfirm(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer) {
        guard var c = st.substituteConfirm else { return }
        var opts = SearchCaseOptions(ignorecase: st.options.ignorecase, smartcase: st.options.smartcase)
        if c.caseFlag == "i" { opts = SearchCaseOptions(ignorecase: true, smartcase: false) }
        if c.caseFlag == "I" { opts = SearchCaseOptions(ignorecase: false, smartcase: false) }
        guard let regex = compileVimPattern(c.pattern, case: opts), let cur = c.current else {
            finishConfirm(&st, &b)
            return
        }
        func replaceCurrent(_ range: Range<Int>) {
            let text = b.text
            let ns = text as NSString
            let r16 = NSRange(location: utf16Offset(in: text, characterOffset: range.lowerBound),
                              length: utf16Offset(in: text, characterOffset: range.upperBound) - utf16Offset(in: text, characterOffset: range.lowerBound))
            guard let m = regex.firstMatch(in: text, options: [.anchored], range: NSRange(location: r16.location, length: ns.length - r16.location)) else { return }
            let rep = expandReplacement(c.replacement, match: m, in: ns)
            let lineStart = Doc(text).lineStart(Doc(text).line(of: range.lowerBound))
            edit(range.lowerBound, range.upperBound, rep, &st, &b)
            c.replacedCount += 1
            c.lastLine = lineStart
            advance(after: range, replacementLength: rep.count)
        }
        func advance(after range: Range<Int>, replacementLength: Int) {
            let base = range.lowerBound + replacementLength
            if c.global {
                c.searchFrom = range.isEmpty && replacementLength == 0 ? base + 1 : base
            } else {
                let d = Doc(b.text)
                c.searchFrom = d.lineEndInclusive(d.line(of: min(base, d.count)))
                if c.searchFrom == d.count, d.lineEnd(d.line(of: min(base, d.count))) == d.count { c.searchFrom = d.count + 1 }
            }
        }
        switch input {
        case .character("y"):
            replaceCurrent(cur)
        case .character("l"):
            replaceCurrent(cur)
            st.substituteConfirm = c
            finishConfirm(&st, &b)
            return
        case .character("n"):
            advance(after: cur, replacementLength: cur.count)
        case .character("a"):
            replaceCurrent(cur)
            while let next = nextConfirmMatch(c, regex: regex, st: st, b: b) { replaceCurrent(next) }
            st.substituteConfirm = c
            finishConfirm(&st, &b)
            return
        case .character("q"), .escape:
            st.substituteConfirm = c
            finishConfirm(&st, &b)
            return
        default:
            st.message = VimMessage("replace with \(c.replacement) (y/n/a/q/l)?")
            return
        }
        c.current = c.searchFrom <= b.text.count ? nextConfirmMatch(c, regex: regex, st: st, b: b) : nil
        st.substituteConfirm = c
        if let next = c.current {
            b.cursor = next.lowerBound
            st.message = VimMessage("replace with \(c.replacement) (y/n/a/q/l)?")
        } else {
            finishConfirm(&st, &b)
        }
    }

    private static func finishConfirm(_ st: inout VimState, _ b: inout TextBuffer) {
        guard let c = st.substituteConfirm else { return }
        st.substituteConfirm = nil
        if c.limitIndex < st.trackedOffsets.count { st.trackedOffsets.remove(at: c.limitIndex) }
        st.recordingInputs = []
        st.recordingBaseline = nil
        st.message = VimMessage("\(c.replacedCount) substitution\(c.replacedCount == 1 ? "" : "s")")
        if c.lastLine >= 0 { b.cursor = Doc(b.text).firstNonBlank(Doc(b.text).line(of: c.lastLine)) }
        clamp(st, &b)
    }

    // MARK: :global, :normal

    private static func global(range: (Int, Int), args: String, invert: Bool, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?, depth: Int) {
        guard let (d, _) = splitDelimited(args.trimmingCharacters(in: .whitespaces)) else {
            st.message = VimMessage("E476: Invalid command", isError: true)
            return
        }
        // pattern up to the next unescaped delimiter; the rest is the command.
        let body = Array(args.trimmingCharacters(in: .whitespaces).dropFirst())
        var pattern = ""
        var i = 0
        while i < body.count, body[i] != d {
            if body[i] == "\\", i + 1 < body.count, body[i + 1] == d { pattern.append(d); i += 2; continue }
            pattern.append(body[i])
            i += 1
        }
        let command = i < body.count ? String(body[(i + 1)...]).trimmingCharacters(in: .whitespaces) : ""
        if pattern.isEmpty { pattern = st.lastSearch?.pattern ?? "" }
        let opts = SearchCaseOptions(ignorecase: st.options.ignorecase, smartcase: st.options.smartcase)
        guard !pattern.isEmpty, let regex = compileVimPattern(pattern, case: opts) else {
            st.message = VimMessage("E35: No previous regular expression", isError: true)
            return
        }
        st.lastSearch = SearchMemory(pattern: pattern, direction: .forward)
        st.hlsearchSuspended = false
        let doc = Doc(b.text)
        var hits: [Int] = []
        for l in range.0...range.1 {
            let s = doc.lineText(l)
            let matched = regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
            if matched != invert { hits.append(doc.lineStart(l)) }
        }
        guard !hits.isEmpty else {
            st.message = VimMessage("Pattern not found: \(pattern)", isError: true)
            return
        }
        let cmd = command.isEmpty ? "p" : command
        if cmd == "p" || cmd == "print" { return }
        let saved = st.trackedOffsets
        let base = saved.count
        st.trackedOffsets = saved + hits.map { Optional($0) }
        pushUndo(&st, b)
        for k in 0..<hits.count {
            guard base + k < st.trackedOffsets.count, let off = st.trackedOffsets[base + k] else { continue }
            b.cursor = min(off, b.text.count)
            if st.mode != .normal { st.mode = .normal }
            executeEx(cmd, &st, &b, &fx, depth: depth + 1)
        }
        st.trackedOffsets = Array(st.trackedOffsets.prefix(base))
        clamp(st, &b)
    }

    private static func exNormal(range: (Int, Int)?, keys: String, remap: Bool, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?, depth: Int) {
        let inputs = VimInput.parse(notation: keys) ?? keys.map { VimInput.character($0) }
        guard !inputs.isEmpty else { return }
        func run() {
            st.pendingKeys = []
            for k in inputs {
                if remap { mapInput(k, &st, &b, &fx, depth: 1) } else { feed(k, &st, &b, &fx) }
            }
            // An unfinished command is aborted, an insert is ended.
            if st.mode != .normal || !st.pendingKeys.isEmpty || st.substituteConfirm != nil {
                st.mapPending = []
                feed(.escape, &st, &b, &fx)
                if st.mode != .normal { feed(.escape, &st, &b, &fx) }
                st.pendingKeys = []
            }
        }
        guard let range else { run(); return }
        let doc = Doc(b.text)
        let base = st.trackedOffsets.count
        st.trackedOffsets += (range.0...range.1).map { Optional(doc.lineStart($0)) }
        for k in 0...(range.1 - range.0) {
            guard base + k < st.trackedOffsets.count, let off = st.trackedOffsets[base + k] else { continue }
            b.cursor = min(off, b.text.count)
            st.mode = .normal
            run()
        }
        st.trackedOffsets = Array(st.trackedOffsets.prefix(base))
    }

    // MARK: :m, :t, :sort

    private static func targetLine(_ arg: String, doc: Doc, st: inout VimState, cur: Int) -> Int? {
        var c = ExCursor(arg.trimmingCharacters(in: .whitespaces))
        if c.peek == "0" { return -1 }
        return (try? parseAddress(&c, doc: doc, st: &st, base: cur)) ?? nil
    }

    private static func moveLines(_ span: (Int, Int), to arg: String, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        guard let t = targetLine(arg, doc: doc, st: &st, cur: span.0) else {
            st.message = VimMessage("E14: Invalid address", isError: true)
            return
        }
        if t >= span.0 && t < span.1 { st.message = VimMessage("E134: Cannot move a range of lines into itself", isError: true); return }
        if t == span.0 - 1 || t == span.1 { return }
        let text = (span.0...span.1).map { doc.lineText($0) }.joined(separator: "\n")
        pushUndo(&st, b)
        let movedCount = span.1 - span.0 + 1
        // Delete first, then insert (adjusting the target line).
        if span.1 < doc.lastLine {
            edit(doc.lineStart(span.0), doc.lineStart(span.1 + 1), "", &st, &b)
        } else {
            edit(span.0 > 0 ? doc.lineEnd(span.0 - 1) : 0, doc.count, "", &st, &b)
        }
        let nd = Doc(b.text)
        let tl = t > span.1 ? t - movedCount : t
        var cursorLine: Int
        if tl < 0 {
            edit(0, 0, text + "\n", &st, &b)
            cursorLine = movedCount - 1
        } else if tl >= nd.lastLine {
            edit(nd.count, nd.count, "\n" + text, &st, &b)
            cursorLine = nd.lastLine + movedCount
        } else {
            edit(nd.lineStart(tl + 1), nd.lineStart(tl + 1), text + "\n", &st, &b)
            cursorLine = tl + movedCount
        }
        let fd = Doc(b.text)
        cursorLine = fd.clampLine(cursorLine)
        b.cursor = fd.firstNonBlank(cursorLine)
    }

    private static func copyLines(_ span: (Int, Int), to arg: String, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        guard let t = targetLine(arg, doc: doc, st: &st, cur: span.0) else {
            st.message = VimMessage("E14: Invalid address", isError: true)
            return
        }
        let text = (span.0...span.1).map { doc.lineText($0) }.joined(separator: "\n")
        let n = span.1 - span.0 + 1
        pushUndo(&st, b)
        if t < 0 {
            edit(0, 0, text + "\n", &st, &b)
        } else if t >= doc.lastLine {
            edit(doc.count, doc.count, "\n" + text, &st, &b)
        } else {
            edit(doc.lineStart(t + 1), doc.lineStart(t + 1), text + "\n", &st, &b)
        }
        let fd = Doc(b.text)
        b.cursor = fd.firstNonBlank(fd.clampLine(t + n))
    }

    private static func sortLines(_ span: (Int, Int), flags: String, reverse: Bool, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        guard span.1 > span.0 else { return }
        var lines = (span.0...span.1).map { doc.lineText($0) }
        let ic = flags.contains("i"), numeric = flags.contains("n"), unique = flags.contains("u")
        func key(_ s: String) -> String { ic ? s.lowercased() : s }
        func num(_ s: String) -> Int? {
            guard let r = s.range(of: "-?[0-9]+", options: .regularExpression) else { return nil }
            return Int(s[r])
        }
        lines.sort { a, z in
            if numeric {
                let x = num(a) ?? Int.min, y = num(z) ?? Int.min
                return x < y
            }
            return key(a) < key(z)
        }
        if reverse { lines.reverse() }
        if unique {
            var seen: [String] = []
            lines = lines.filter { l in
                if let last = seen.last, key(last) == key(l) { return false }
                seen.append(l)
                return true
            }
        }
        let new = lines.joined(separator: "\n")
        let old = doc.text(doc.lineStart(span.0), doc.lineEnd(span.1))
        guard new != old else { return }
        pushUndo(&st, b)
        edit(doc.lineStart(span.0), doc.lineEnd(span.1), new, &st, &b)
        b.cursor = doc.lineStart(span.0)
    }

    // MARK: :set

    static func exSet(_ args: String, _ st: inout VimState) {
        let tokens = args.split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.isEmpty || tokens == ["all"] {
            let o = st.options
            var parts = ["tabstop=\(o.tabstop)", "shiftwidth=\(o.shiftwidth)", "\(o.expandtab ? "" : "no")expandtab",
                         "\(o.ignorecase ? "" : "no")ignorecase", "\(o.smartcase ? "" : "no")smartcase",
                         "\(o.hlsearch ? "" : "no")hlsearch", "\(o.incsearch ? "" : "no")incsearch",
                         "\(o.autoindent ? "" : "no")autoindent", "timeoutlen=\(o.timeoutlen)"]
            if let v = o.number { parts.append("\(v ? "" : "no")number") }
            if let v = o.relativenumber { parts.append("\(v ? "" : "no")relativenumber") }
            if let v = o.wrap { parts.append("\(v ? "" : "no")wrap") }
            st.message = VimMessage(parts.joined(separator: "  "))
            return
        }
        for tok in tokens {
            if let err = applySetToken(tok, &st) {
                st.message = VimMessage(err, isError: true)
                return
            }
        }
    }

    private static let boolOptions: [String: String] = [
        "number": "number", "nu": "number", "relativenumber": "relativenumber", "rnu": "relativenumber",
        "wrap": "wrap", "expandtab": "expandtab", "et": "expandtab", "ignorecase": "ignorecase", "ic": "ignorecase",
        "smartcase": "smartcase", "scs": "smartcase", "hlsearch": "hlsearch", "hls": "hlsearch",
        "incsearch": "incsearch", "is": "incsearch", "autoindent": "autoindent", "ai": "autoindent",
    ]
    private static let numOptions: [String: String] = [
        "tabstop": "tabstop", "ts": "tabstop", "shiftwidth": "shiftwidth", "sw": "shiftwidth",
        "softtabstop": "softtabstop", "sts": "softtabstop", "timeoutlen": "timeoutlen", "tm": "timeoutlen",
    ]

    private static func applySetToken(_ tok: String, _ st: inout VimState) -> String? {
        if let eq = tok.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            var name = String(tok[..<eq])
            var op: Character?
            if let l = name.last, "+-^".contains(l) { op = l; name.removeLast() }
            guard let key = numOptions[name] else { return "E518: Unknown option: \(name)" }
            guard let v = Int(tok[tok.index(after: eq)...]) else { return "E521: Number required after =: \(tok)" }
            func apply(_ old: Int) -> Int {
                switch op {
                case "+": return old + v
                case "-": return old - v
                case "^": return old * v
                default: return v
                }
            }
            switch key {
            case "tabstop": st.options.tabstop = max(1, min(32, apply(st.options.tabstop)))
            case "shiftwidth": st.options.shiftwidth = max(1, min(32, apply(st.options.shiftwidth)))
            case "timeoutlen": st.options.timeoutlen = max(0, min(10_000, apply(st.options.timeoutlen)))
            default: break
            }
            return nil
        }
        var name = tok
        if name.hasSuffix("?") {
            name.removeLast()
            if let key = boolOptions[name] {
                st.message = VimMessage((boolValue(key, st) ? "  " : "no") + key)
            } else if let key = numOptions[name] {
                let v: Int
                switch key {
                case "tabstop": v = st.options.tabstop
                case "shiftwidth", "softtabstop": v = st.options.shiftwidth
                default: v = st.options.timeoutlen
                }
                st.message = VimMessage("  \(key)=\(v)")
            } else {
                return "E518: Unknown option: \(name)"
            }
            return nil
        }
        var toggle = false
        var value = true
        if name.hasSuffix("!") { toggle = true; name.removeLast() }
        if name.hasPrefix("inv"), boolOptions[String(name.dropFirst(3))] != nil { toggle = true; name = String(name.dropFirst(3)) }
        if boolOptions[name] == nil, name.hasPrefix("no"), boolOptions[String(name.dropFirst(2))] != nil {
            value = false
            name = String(name.dropFirst(2))
        }
        guard let key = boolOptions[name] else {
            if numOptions[name] != nil { return "E521: Number required after =: \(name)" }
            return "E518: Unknown option: \(name)"
        }
        if toggle { value = !boolValue(key, st) }
        switch key {
        case "number": st.options.number = value
        case "relativenumber": st.options.relativenumber = value
        case "wrap": st.options.wrap = value
        case "expandtab": st.options.expandtab = value
        case "ignorecase": st.options.ignorecase = value
        case "smartcase": st.options.smartcase = value
        case "hlsearch": st.options.hlsearch = value
        case "incsearch": st.options.incsearch = value
        case "autoindent": st.options.autoindent = value
        default: break
        }
        return nil
    }

    private static func boolValue(_ key: String, _ st: VimState) -> Bool {
        switch key {
        case "number": return st.options.number ?? false
        case "relativenumber": return st.options.relativenumber ?? false
        case "wrap": return st.options.wrap ?? true
        case "expandtab": return st.options.expandtab
        case "ignorecase": return st.options.ignorecase
        case "smartcase": return st.options.smartcase
        case "hlsearch": return st.options.hlsearch
        case "incsearch": return st.options.incsearch
        case "autoindent": return st.options.autoindent
        default: return false
        }
    }

    // MARK: :map

    private static func exMap(_ line: String, _ st: inout VimState) {
        let parsed = Vimrc.parse(line, leader: st.leader)
        if let d = parsed.diagnostics.first(where: { $0.severity == .error }) {
            st.message = VimMessage(d.message, isError: true)
            return
        }
        let isUnmap = line.contains("unm") || line.hasPrefix("nun") || line.hasPrefix("iu") || line.hasPrefix("vu") || line.hasPrefix("xu")
        if isUnmap {
            // Re-parse against a vimrc holding the current maps so the
            // unmap semantics (mode matching, leader) are the parser's.
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let cmd = parts[0]
            let mode: VimMapping.Mode = cmd.hasPrefix("n") ? .normal : cmd.hasPrefix("i") ? .insert : (cmd.hasPrefix("v") || cmd.hasPrefix("x")) ? .visual : .all
            var keys = parts[1].trimmingCharacters(in: .whitespaces)
            if keys.lowercased().hasPrefix("<leader>") { keys = st.leader + keys.dropFirst(8) }
            let norm = Vimrc.normalizeKeys(keys, leader: st.leader)
            guard norm.error == nil, let lhs = VimInput.parse(notation: norm.keys) else { return }
            let before = st.mappings.count
            st.mappings.removeAll { $0.lhs == lhs && (mode == .all || $0.mode == mode || $0.mode == .all) }
            if st.mappings.count == before { st.message = VimMessage("E31: No such mapping", isError: true) }
            return
        }
        for m in parsed.maps {
            guard let vm = VimMapping(vimrc: m, leader: parsed.leader) else { continue }
            st.mappings.removeAll { $0.lhs == vm.lhs && $0.mode == vm.mode && $0.exAlias == vm.exAlias }
            st.mappings.append(vm)
        }
    }

    private static func listMappings(_ st: VimState) -> String {
        guard !st.mappings.isEmpty else { return "No mapping found" }
        return st.mappings.map { m in
            let mode: String
            switch m.mode {
            case .all: mode = " "
            case .operatorPending: mode = "o"
            case .normal: mode = "n"
            case .insert: mode = "i"
            case .visual: mode = "v"
            }
            let lhs = m.exAlias.map { ":" + $0 } ?? m.lhs.notation
            return "\(mode)  \(lhs.padding(toLength: max(lhs.count, 12), withPad: " ", startingAt: 0)) \(m.noremap ? "*" : " ") \(m.rhs.notation)"
        }.joined(separator: "\n")
    }

    // MARK: :registers, :marks

    private static func listRegisters(_ st: VimState, only: String) -> String {
        func show(_ s: String) -> String {
            let t = s.replacingOccurrences(of: "\n", with: "^J").replacingOccurrences(of: "\t", with: "^I")
            return t.count > 70 ? String(t.prefix(69)) + "…" : t
        }
        func kind(_ k: Register.Kind) -> String {
            switch k {
            case .characterwise: return "c"
            case .linewise: return "l"
            case .blockwise: return "b"
            }
        }
        var rows: [(Character, Register)] = []
        rows.append(("\"", st.defaultRegister))
        for c in "0123456789abcdefghijklmnopqrstuvwxyz-" {
            if let r = st.registers[c] { rows.append((c, r)) }
        }
        if !st.lastInsertedText.isEmpty { rows.append((".", Register(text: st.lastInsertedText))) }
        if let ex = st.lastExCommand { rows.append((":", Register(text: ex))) }
        if let p = st.lastSearch?.pattern { rows.append(("/", Register(text: p))) }
        if let f = st.fileName { rows.append(("%", Register(text: f))) }
        if let c = st.clipboard { rows.append(("+", Register(text: c))) }
        let filter = only.filter { $0 != " " && $0 != "\"" || only.contains("\"\"") }
        let lines = rows
            .filter { !$0.1.text.isEmpty && (filter.isEmpty || filter.contains($0.0)) }
            .map { "  \(kind($0.1.kind))  \"\($0.0)   \(show($0.1.text))" }
        return (["Type Name Content"] + lines).joined(separator: "\n")
    }

    private static func listMarks(_ st: VimState, doc: Doc, only: String) -> String {
        var names = st.marks.keys.filter { only.isEmpty || only.contains($0) }
        let order = "'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\"[]^.<>"
        names.sort { (order.firstIndex(of: $0) ?? order.endIndex) < (order.firstIndex(of: $1) ?? order.endIndex) }
        let rows = names.compactMap { name -> String? in
            guard let off = st.marks[name] else { return nil }
            let o = min(off, doc.count)
            let l = doc.line(of: o)
            let text = doc.lineText(l).trimmingCharacters(in: .whitespaces)
            let lineStr = String(l + 1).leftPad(6)
            let colStr = String(doc.column(of: o)).leftPad(5)
            return " \(name) \(lineStr)\(colStr) \(text.prefix(60))"
        }
        return (["mark line  col file/text"] + rows).joined(separator: "\n")
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

extension VimMapping {
    /// Build an engine mapping from a parsed `.vimrc` line.
    public init?(vimrc m: VimrcMap, leader: String) {
        let mode: Mode
        switch m.mode {
        case .all: mode = .all
        case .normal: mode = .normal
        case .insert: mode = .insert
        case .visual: mode = .visual
        }
        let lhsKeys = m.leader ? leader + m.lhs : m.lhs
        if lhsKeys.hasPrefix(":"), lhsKeys.count > 1, mode == .all {
            guard let rhs = VimInput.parse(notation: m.rhs) else { return nil }
            self.init(mode: mode, lhs: [], rhs: rhs, noremap: m.noremap, exAlias: String(lhsKeys.dropFirst()))
            return
        }
        guard let lhs = VimInput.parse(notation: lhsKeys), !lhs.isEmpty,
              let rhs = VimInput.parse(notation: m.rhs) else { return nil }
        self.init(mode: mode, lhs: lhs, rhs: rhs, noremap: m.noremap)
    }
}
