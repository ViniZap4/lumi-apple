import Foundation

extension VimEngine {
    // MARK: Insert / replace mode

    static func handleTyping(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        if st.insertSession == nil { st.insertSession = InsertSession(start: b.cursor, count: 1, kind: .plain) }

        if st.awaitingInsertRegister {
            st.awaitingInsertRegister = false
            var text: String?
            if let r = input.char { text = readRegister(r, st)?.text }
            else if input.ctrl == "w" { text = wordAtOrAfter(Doc(b.text), max(0, b.cursor - 1))?.0 }
            if let text, !text.isEmpty { typeText(text, record: true, &st, &b) }
            return
        }

        switch input {
        case .escape:
            finishInsert(&st, &b)
            return
        case let .character(c):
            if handleEscapeSequence(c, &st, &b) {
                finishInsert(&st, &b)
                return
            }
            typeText(String(c), record: true, &st, &b)
            st.insertSession?.inputs.append(input)
            return
        default:
            st.insertEscapeRun = ""
        }
        typingKey(input, record: true, &st, &b)
    }

    /// One non-character key in insert / replace mode.
    static func typingKey(_ input: VimInput, record: Bool, _ st: inout VimState, _ b: inout TextBuffer) {
        let replace = st.mode == .replace
        func rec() { if record { st.insertSession?.inputs.append(input) } }
        switch input {
        case let .character(c):
            typeText(String(c), record: record, &st, &b)
            rec()
        case .return, .control("j"), .control("m"):
            let doc = Doc(b.text)
            let line = doc.line(of: b.cursor)
            var ind = st.options.autoindent ? doc.indent(line) : ""
            if ind.count > b.cursor - doc.lineStart(line) { ind = String(ind.prefix(b.cursor - doc.lineStart(line))) }
            insertRaw("\n" + ind, &st, &b)
            rec()
        case .backspace, .control("h"):
            backspace(&st, &b, replace: replace)
            rec()
        case .delete:
            if b.cursor < b.text.count { edit(b.cursor, b.cursor + 1, "", &st, &b) }
            rec()
        case .tab:
            if st.options.expandtab {
                let doc = Doc(b.text)
                let col = doc.column(of: b.cursor)
                let ts = max(1, st.options.tabstop)
                insertRaw(String(repeating: " ", count: ts - col % ts), &st, &b)
            } else {
                insertRaw("\t", &st, &b)
            }
            rec()
        case .control("w"):
            deleteWordBefore(&st, &b)
            rec()
        case .controlU:
            let doc = Doc(b.text)
            let line = doc.line(of: b.cursor)
            let ls = doc.lineStart(line)
            let fnb = doc.lastNonBlank(line) == nil ? doc.lineEnd(line) : doc.firstNonBlank(line)
            let from = b.cursor > fnb ? fnb : ls
            if from < b.cursor {
                edit(from, b.cursor, "", &st, &b)
                b.cursor = from
            }
            rec()
        case .control("t"), .controlD:
            let doc = Doc(b.text)
            let line = doc.line(of: b.cursor)
            let before = doc.indent(line).count
            let wasAt = b.cursor
            shiftLines(line, line, right: input == .control("t"), amount: 1, doc: doc, &st, &b)
            let after = Doc(b.text).indent(line).count
            b.cursor = max(doc.lineStart(line) + after, wasAt + (after - before))
            rec()
        case .controlR:
            st.awaitingInsertRegister = true
        case .control("o"):
            st.insertOneShot = 1
            st.mode = .normal
        case .control("a"):
            if !st.lastInsertedText.isEmpty { typeText(st.lastInsertedText, record: record, &st, &b) }
            rec()
        case .control("e"), .control("y"):
            let doc = Doc(b.text)
            let line = doc.line(of: b.cursor)
            let other = input == .control("e") ? line + 1 : line - 1
            guard other >= 0, other <= doc.lastLine else { return }
            let col = doc.column(of: b.cursor)
            guard col < doc.lineLength(other) else { return }
            typeText(String(doc[doc.lineStart(other) + col]), record: record, &st, &b)
            rec()
        case let .arrow(direction):
            let doc = Doc(b.text)
            let line = doc.line(of: b.cursor)
            switch direction {
            case .left: if b.cursor > doc.lineStart(line) { b.cursor -= 1 }
            case .right: if b.cursor < doc.lineEnd(line) { b.cursor += 1 }
            case .up, .down:
                let target = direction == .up ? line - 1 : line + 1
                guard target >= 0, target <= doc.lastLine else { break }
                let column = b.cursor - doc.lineStart(line)
                b.cursor = doc.lineStart(target) + min(column, doc.lineLength(target))
            }
            // Moving starts a new insert (vim): the count no longer repeats.
            st.insertSession?.count = 1
            st.insertSession?.inputs = []
            st.insertSession?.start = b.cursor
        default:
            break
        }
    }

    /// Type text: insert, or overwrite in replace mode.
    static func typeText(_ text: String, record: Bool, _ st: inout VimState, _ b: inout TextBuffer) {
        if st.mode == .replace {
            for ch in text {
                let doc = Doc(b.text)
                let line = doc.line(of: b.cursor)
                if ch != "\n", b.cursor < doc.lineEnd(line) {
                    st.insertSession?.replaced.append(doc[b.cursor])
                    edit(b.cursor, b.cursor + 1, String(ch), &st, &b)
                } else {
                    st.insertSession?.replaced.append(nil)
                    edit(b.cursor, b.cursor, String(ch), &st, &b)
                }
                b.cursor += 1
                st.insertSession?.typed.append(ch)
            }
            return
        }
        insertRaw(text, &st, &b)
    }

    static func insertRaw(_ text: String, _ st: inout VimState, _ b: inout TextBuffer) {
        let at = min(b.cursor, b.text.count)
        let before = b.text.count
        edit(at, at, text, &st, &b)
        b.cursor = at + (b.text.count - before)
        st.insertSession?.typed += text
    }

    private static func backspace(_ st: inout VimState, _ b: inout TextBuffer, replace: Bool) {
        guard b.cursor > 0 else { return }
        if replace {
            if let orig = st.insertSession?.replaced.popLast() {
                b.cursor -= 1
                if let o = orig { edit(b.cursor, b.cursor + 1, String(o), &st, &b) }
                else { edit(b.cursor, b.cursor + 1, "", &st, &b) }
                if st.insertSession?.typed.isEmpty == false { st.insertSession?.typed.removeLast() }
            } else {
                let doc = Doc(b.text)
                if b.cursor > doc.lineStart(doc.line(of: b.cursor)) { b.cursor -= 1 }
            }
            return
        }
        edit(b.cursor - 1, b.cursor, "", &st, &b)
        b.cursor -= 1
        if st.insertSession?.typed.isEmpty == false { st.insertSession?.typed.removeLast() }
    }

    private static func deleteWordBefore(_ st: inout VimState, _ b: inout TextBuffer) {
        guard b.cursor > 0 else { return }
        let doc = Doc(b.text)
        var i = b.cursor
        if doc[i - 1] == "\n" {
            edit(i - 1, i, "", &st, &b)
            b.cursor = i - 1
            return
        }
        let ls = doc.lineStart(doc.line(of: i))
        while i > ls, isBlank(doc[i - 1]) { i -= 1 }
        if i > ls {
            let cls = CharClass(doc[i - 1], big: false)
            while i > ls, CharClass(doc[i - 1], big: false) == cls { i -= 1 }
        }
        edit(i, b.cursor, "", &st, &b)
        let removed = b.cursor - i
        b.cursor = i
        if var s = st.insertSession {
            s.typed = String(s.typed.dropLast(min(removed, s.typed.count)))
            st.insertSession = s
        }
    }

    /// Esc: repeat for a count, replicate a block insert, back to normal.
    static func finishInsert(_ st: inout VimState, _ b: inout TextBuffer) {
        st.insertEscapeRun = ""
        st.insertEscapeRunAt = nil
        st.awaitingInsertRegister = false
        guard let session = st.insertSession else {
            st.mode = .normal
            clamp(st, &b)
            return
        }
        if session.count > 1, !session.inputs.isEmpty {
            for _ in 1..<min(session.count, 10_000) {
                if case .openLine = session.kind { typingKey(.return, record: false, &st, &b) }
                for k in session.inputs { typingKey(k, record: false, &st, &b) }
            }
        }
        let typed = st.insertSession?.typed ?? session.typed
        var cursorOverride: Int?
        if case let .block(first, last, col, toEnd, pad) = session.kind, last > first, !session.typed.isEmpty, !session.typed.contains("\n") {
            let doc = Doc(b.text)
            for l in stride(from: last, through: first + 1, by: -1) {
                let len = doc.lineLength(l)
                if toEnd {
                    edit(doc.lineEnd(l), doc.lineEnd(l), session.typed, &st, &b)
                } else if len < col {
                    guard pad else { continue }
                    edit(doc.lineEnd(l), doc.lineEnd(l), String(repeating: " ", count: col - len) + session.typed, &st, &b)
                } else {
                    let at = doc.lineStart(l) + col
                    edit(at, at, session.typed, &st, &b)
                }
            }
            cursorOverride = Doc(b.text).offset(line: first, column: toEnd ? doc.lineLength(first) - session.typed.count : col)
        }
        st.lastInsertedText = typed
        st.marks["^"] = b.cursor
        st.marks["."] = max(0, b.cursor - 1)
        st.mode = .normal
        st.insertSession = nil
        if let c = cursorOverride {
            b.cursor = c
        } else {
            let doc = Doc(b.text)
            let cur = min(b.cursor, doc.count)
            if cur > doc.lineStart(doc.line(of: cur)) { b.cursor = cur - 1 }
        }
        clamp(st, &b)
    }

    // MARK: Insert-mode escape sequences (`jk`, `ff`)

    /// The sequences in effect: the user's list plus the legacy `jj`.
    static func effectiveEscapeSequences(_ state: VimState) -> [String] {
        var seqs = state.escapeSequences.filter { $0.count >= 2 }
        if state.jjEscapeEnabled, !seqs.contains("jj") { seqs.append("jj") }
        return seqs
    }

    /// Feed one typed character to the escape-sequence matcher. Returns
    /// true when it completed a sequence (the typed prefix is removed).
    private static func handleEscapeSequence(_ char: Character, _ st: inout VimState, _ b: inout TextBuffer) -> Bool {
        let seqs = effectiveEscapeSequences(st)
        guard !seqs.isEmpty, st.mode == .insert else {
            st.insertEscapeRun = ""
            return false
        }
        var run = st.insertEscapeRun
        if let last = st.insertEscapeRunAt, let now = st.inputTime, now - last > st.escapeTimeout {
            run = ""
        }
        let candidate = run + String(char)
        if !run.isEmpty, seqs.contains(candidate) {
            let n = run.count
            if b.cursor >= n {
                let doc = Doc(b.text)
                if doc.text(b.cursor - n, b.cursor) == run {
                    edit(b.cursor - n, b.cursor, "", &st, &b)
                    b.cursor -= n
                    if var s = st.insertSession {
                        s.typed = String(s.typed.dropLast(min(n, s.typed.count)))
                        if s.inputs.count >= n { s.inputs.removeLast(n) }
                        st.insertSession = s
                    }
                }
            }
            st.insertEscapeRun = ""
            st.insertEscapeRunAt = nil
            return true
        }
        var next = ""
        var suffix = Substring(candidate)
        while !suffix.isEmpty {
            if seqs.contains(where: { $0.count > suffix.count && $0.hasPrefix(suffix) }) {
                next = String(suffix)
                break
            }
            suffix = suffix.dropFirst()
        }
        st.insertEscapeRun = next
        st.insertEscapeRunAt = st.inputTime
        return false
    }
}
