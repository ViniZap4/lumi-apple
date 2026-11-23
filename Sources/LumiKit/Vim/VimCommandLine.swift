import Foundation

extension VimEngine {
    static func enterSearch(_ prefix: Character, op: VimOperator?, register: Character?, count: Int?, _ st: inout VimState, _ b: inout TextBuffer) {
        st.mode = .commandLine(prefix: prefix, buffer: "")
        st.commandLineEntryCursor = b.cursor
        st.commandLineHistoryIndex = nil
        st.commandLineHistoryDraft = nil
        st.searchContext = SearchContext(op: op, register: register, count: count)
    }

    static func handleCommandLine(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        guard case let .commandLine(prefix, current) = st.mode else { return }

        if st.awaitingInsertRegister {
            st.awaitingInsertRegister = false
            var text: String?
            if let r = input.char { text = readRegister(r, st)?.text }
            else if input.ctrl == "w" { text = wordAtOrAfter(Doc(b.text), b.cursor)?.0 }
            if let text {
                let clean = text.replacingOccurrences(of: "\n", with: "\r")
                setCommandLine(prefix, current + clean, &st, &b)
            }
            return
        }

        switch input {
        case .escape:
            cancelCommandLine(&st, &b)

        case .backspace, .control("h"):
            if current.isEmpty {
                cancelCommandLine(&st, &b)
                return
            }
            setCommandLine(prefix, String(current.dropLast()), &st, &b)

        case .controlU:
            setCommandLine(prefix, "", &st, &b)

        case .control("w"):
            var s = current
            while let l = s.last, l == " " { s.removeLast() }
            if let l = s.last {
                let word = isKeywordChar(l)
                while let c = s.last, c != " ", isKeywordChar(c) == word { s.removeLast() }
            }
            setCommandLine(prefix, s, &st, &b)

        case .controlR:
            st.awaitingInsertRegister = true

        case .return, .control("m"), .control("j"):
            st.commandLineHistoryIndex = nil
            st.commandLineHistoryDraft = nil
            if prefix == ":" {
                st.mode = .normal
                appendHistory(current, prefix: prefix, &st)
                let visual = st.commandLineVisual
                st.commandLineVisual = nil
                _ = visual
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    st.lastExCommand = current
                }
                executeEx(current, &st, &b, &fx, depth: 0)
                // Ex commands are not repeated by `.`.
                st.recordingInputs = []
                st.recordingBaseline = nil
                clamp(st, &b)
                return
            }
            executeSearch(prefix: prefix, pattern: current, &st, &b)

        case .historyPrev, .arrow(.up):
            walkHistory(forward: false, prefix: prefix, current: current, &st, &b)

        case .historyNext, .arrow(.down):
            walkHistory(forward: true, prefix: prefix, current: current, &st, &b)

        case let .character(c):
            setCommandLine(prefix, current + String(c), &st, &b)

        case .tab:
            if prefix == ":" { setCommandLine(prefix, current + "\t", &st, &b) }

        default:
            break
        }
    }

    private static func setCommandLine(_ prefix: Character, _ text: String, _ st: inout VimState, _ b: inout TextBuffer) {
        st.mode = .commandLine(prefix: prefix, buffer: text)
        st.commandLineHistoryIndex = nil
        st.commandLineHistoryDraft = nil
        updateIncrementalPreview(prefix: prefix, pattern: text, &st, &b)
    }

    private static func cancelCommandLine(_ st: inout VimState, _ b: inout TextBuffer) {
        if let snap = st.commandLineEntryCursor { b.cursor = snap }
        st.commandLineEntryCursor = nil
        st.commandLineHistoryIndex = nil
        st.commandLineHistoryDraft = nil
        st.searchContext = nil
        if let v = st.commandLineVisual {
            st.mode = .visual(v.kind, anchor: v.anchor)
            st.blockToLineEnd = v.toLineEnd
            b.cursor = v.head
            st.commandLineVisual = nil
        } else {
            st.mode = .normal
        }
        clamp(st, &b)
    }

    private static func executeSearch(prefix: Character, pattern raw: String, _ st: inout VimState, _ b: inout TextBuffer) {
        let ctx = st.searchContext ?? SearchContext()
        st.searchContext = nil
        if let snap = st.commandLineEntryCursor { b.cursor = snap }
        st.commandLineEntryCursor = nil
        let visual = st.commandLineVisual
        st.commandLineVisual = nil
        st.mode = visual.map { VimMode.visual($0.kind, anchor: $0.anchor) } ?? .normal
        if let visual { st.blockToLineEnd = visual.toLineEnd; b.cursor = visual.head }
        appendHistory(raw, prefix: prefix, &st)

        let direction: SearchDirection = prefix == "?" ? .backward : .forward
        var pattern = raw
        // A trailing unescaped delimiter (`/foo/`) ends the pattern.
        if pattern.count > 1, pattern.last == prefix, pattern.dropLast().last != "\\" { pattern.removeLast() }
        if pattern.isEmpty {
            guard let last = st.lastSearch else {
                st.message = VimMessage("E35: No previous regular expression", isError: true)
                clamp(st, &b)
                return
            }
            pattern = last.pattern
        }
        let doc = Doc(b.text)
        let from = b.cursor
        guard let target = searchTarget(doc: doc, pattern: pattern, from: from, direction: direction, count: max(1, ctx.count ?? 1), state: &st) else {
            clamp(st, &b)
            return
        }
        st.lastSearch = SearchMemory(pattern: pattern, direction: direction)
        st.hlsearchSuspended = false
        if let op = ctx.op {
            let r = MotionResult(target: target, jump: true)
            st.marks["'"] = from
            applyMotionOperator(op, r, .searchNext(reverse: false), cursor: from, register: ctx.register, doc: doc, &st, &b)
        } else {
            if visual == nil { st.marks["'"] = from }
            b.cursor = target
        }
        clamp(st, &b)
    }

    static func appendHistory(_ entry: String, prefix: Character, _ st: inout VimState) {
        guard !entry.isEmpty else { return }
        if prefix == ":" {
            guard st.exHistory.last != entry else { return }
            st.exHistory.append(entry)
            if st.exHistory.count > VimState.commandLineHistoryLimit {
                st.exHistory.removeFirst(st.exHistory.count - VimState.commandLineHistoryLimit)
            }
        } else {
            appendSearchHistory(entry, state: &st)
        }
    }

    private static func walkHistory(forward: Bool, prefix: Character, current: String, _ st: inout VimState, _ b: inout TextBuffer) {
        let history = prefix == ":" ? st.exHistory : st.searchHistory
        guard !history.isEmpty else { return }
        let newIndex: Int?
        if forward {
            guard let idx = st.commandLineHistoryIndex else { return }
            newIndex = idx >= history.count - 1 ? nil : idx + 1
        } else if let idx = st.commandLineHistoryIndex {
            guard idx > 0 else { return }
            newIndex = idx - 1
        } else {
            st.commandLineHistoryDraft = current
            newIndex = history.count - 1
        }
        let shown: String
        if let idx = newIndex {
            shown = history[idx]
            st.commandLineHistoryIndex = idx
        } else {
            shown = st.commandLineHistoryDraft ?? ""
            st.commandLineHistoryIndex = nil
            st.commandLineHistoryDraft = nil
        }
        st.mode = .commandLine(prefix: prefix, buffer: shown)
        updateIncrementalPreview(prefix: prefix, pattern: shown, &st, &b)
    }

    /// Incsearch: preview the match from the entry cursor on every change.
    private static func updateIncrementalPreview(prefix: Character, pattern: String, _ st: inout VimState, _ b: inout TextBuffer) {
        guard prefix == "/" || prefix == "?", let snap = st.commandLineEntryCursor else { return }
        b.cursor = snap
        guard st.options.incsearch, !pattern.isEmpty else { return }
        let direction: SearchDirection = prefix == "?" ? .backward : .forward
        let opts = SearchCaseOptions(ignorecase: st.options.ignorecase, smartcase: st.options.smartcase)
        if let range = nextMatch(in: b.text, pattern: pattern, from: snap, direction: direction, case: opts) {
            b.cursor = range.lowerBound
        }
    }
}
