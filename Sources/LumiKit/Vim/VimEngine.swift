import Foundation

/// Pure reducer for the vim engine: `(state, buffer, input) -> (state,
/// buffer, effect)`. No UI, no clock, no clipboard — the host supplies
/// those through `VimState` (`inputTime`, `clipboard`, `viewport`).
///
/// Layers, outermost first:
/// 1. `handle` — macro recording (typed keys) and key mappings.
/// 2. `feed` — dot-repeat recording (keys after mapping).
/// 3. `dispatch` — per-mode handling. Normal / visual keys accumulate in
///    `pendingKeys` and are re-parsed on every key (vim's own model).
///
/// Every text change goes through `edit(…)` → `TextBuffer.replaceCharacters`
/// so the host receives minimal ranged edits.
public enum VimEngine {
    public struct Result: Sendable, Hashable {
        public var state: VimState
        public var buffer: TextBuffer
        /// Side-effect requested by this input (`:w`, `zz`, `gj` …).
        public var effect: VimEffect?

        public init(state: VimState, buffer: TextBuffer, effect: VimEffect? = nil) {
            self.state = state
            self.buffer = buffer
            self.effect = effect
        }
    }

    /// Nested macro playback limit (aborts runaway recursion).
    static let macroDepthLimit = 100
    /// Recursive mapping expansion limit.
    static let mapDepthLimit = 50

    /// Timed variant: `time` is a monotonic clock reading (seconds) used by
    /// escape sequences and mapping timeouts.
    public static func handle(_ input: VimInput, state: VimState, buffer: TextBuffer, at time: TimeInterval?) -> Result {
        var timed = state
        timed.inputTime = time
        var result = handle(input, state: timed, buffer: buffer)
        result.state.inputTime = nil
        return result
    }

    public static func handle(_ input: VimInput, state: VimState, buffer: TextBuffer) -> Result {
        var st = state
        var b = buffer
        var fx: VimEffect?
        if st.isReplaying {
            dispatch(input, &st, &b, &fx)
            return Result(state: st, buffer: b, effect: fx)
        }
        if st.recordingMacro != nil, !st.isPlayingMacro {
            st.recordingMacroInputs.append(input)
        }
        if st.substituteConfirm == nil { st.message = nil }
        mapInput(input, &st, &b, &fx, depth: 0)
        return Result(state: st, buffer: b, effect: fx)
    }

    /// The host's mapping timer fired (`timeoutlen` without a key): resolve
    /// a half-typed mapping as typed (or as its exact match).
    public static func timeout(state: VimState, buffer: TextBuffer) -> Result {
        var st = state
        var b = buffer
        var fx: VimEffect?
        flushMapPending(&st, &b, &fx, depth: 0)
        return Result(state: st, buffer: b, effect: fx)
    }

    /// True when no command is in flight in normal mode.
    public static func isIdleNormal(_ state: VimState) -> Bool {
        isFreshNormal(state) && state.mapPending.isEmpty
    }

    /// True when the next key will read the `"+` / `"*` register, so the
    /// host should put the system clipboard into `state.clipboard` first.
    public static func wantsClipboard(_ state: VimState) -> Bool {
        if state.awaitingInsertRegister { return true }
        if let r = pendingInfo(state).register, r == "+" || r == "*" { return true }
        return false
    }

    /// True while an operator waits for its motion (operator-pending).
    public static func isOperatorPending(_ state: VimState) -> Bool {
        state.mode == .normal && pendingInfo(state).op != nil
    }

    static func isFreshNormal(_ s: VimState) -> Bool {
        s.mode == .normal && s.pendingKeys.isEmpty && s.insertOneShot == 0
            && s.substituteConfirm == nil && s.commandLineVisual == nil
    }

    // MARK: Mappings

    private static func mappingMode(_ s: VimState) -> VimMapping.Mode? {
        if s.substituteConfirm != nil { return nil }
        switch s.mode {
        case .insert, .replace: return s.awaitingInsertRegister ? nil : .insert
        case .visual, .normal:
            // The second key of `g…`, `z…`, `"x`, `fx`, `ma` … is never
            // mapped (vim reads it with mappings off); after an operator
            // only `map` / `noremap` (normal+visual+operator) apply.
            switch pendingInfo(s).awaiting {
            case .none, .mapping: return s.mode.isVisual ? .visual : .normal
            case .motion: return .operatorPending
            default: return nil
            }
        case .commandLine: return nil
        }
    }

    static func mapInput(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?, depth: Int) {
        if !st.mapPending.isEmpty, let now = st.inputTime, let at = st.mapPendingAt,
           now - at > Double(st.options.timeoutlen) / 1000 {
            flushMapPending(&st, &b, &fx, depth: depth)
        }
        guard depth < mapDepthLimit, let mode = mappingMode(st), !st.mappings.isEmpty else {
            if !st.mapPending.isEmpty { st.mapPending = []; st.mapTentative = 0 }
            feed(input, &st, &b, &fx)
            return
        }
        let candidate = st.mapPending + [input]
        let maps = st.mappings.filter { $0.exAlias == nil && $0.applies(in: mode) }
        let exact = maps.last { $0.lhs == candidate }
        let longer = maps.contains { $0.lhs.count > candidate.count && Array($0.lhs.prefix(candidate.count)) == candidate }

        if longer {
            st.mapPending = candidate
            st.mapPendingAt = st.inputTime
            if mode == .insert, input.char != nil {
                // Type it now; removed again if the mapping completes.
                st.mapTentative += 1
                let saved = st.mapPending
                feed(input, &st, &b, &fx)
                st.mapPending = saved
            }
            return
        }
        if let m = exact {
            let tentative = st.mapTentative
            st.mapPending = []
            st.mapTentative = 0
            st.mapPendingAt = nil
            if tentative > 0 { removeTentative(tentative, &st, &b) }
            for key in m.rhs {
                if m.noremap { feed(key, &st, &b, &fx) } else { mapInput(key, &st, &b, &fx, depth: depth + 1) }
            }
            return
        }
        guard !st.mapPending.isEmpty else {
            feed(input, &st, &b, &fx)
            return
        }
        let pending = st.mapPending
        let tentative = st.mapTentative
        st.mapPending = []
        st.mapTentative = 0
        st.mapPendingAt = nil
        if tentative > 0 {
            mapInput(input, &st, &b, &fx, depth: depth)
            return
        }
        feed(pending[0], &st, &b, &fx)
        for k in pending.dropFirst() + [input] {
            mapInput(k, &st, &b, &fx, depth: depth + 1)
        }
    }

    static func flushMapPending(_ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?, depth: Int) {
        guard !st.mapPending.isEmpty else { return }
        let pending = st.mapPending
        let tentative = st.mapTentative
        st.mapPending = []
        st.mapTentative = 0
        st.mapPendingAt = nil
        if let mode = mappingMode(st),
           let m = st.mappings.last(where: { $0.exAlias == nil && $0.applies(in: mode) && $0.lhs == pending }) {
            if tentative > 0 { removeTentative(tentative, &st, &b) }
            for key in m.rhs {
                if m.noremap { feed(key, &st, &b, &fx) } else { mapInput(key, &st, &b, &fx, depth: depth + 1) }
            }
            return
        }
        if tentative > 0 { return }
        for k in pending { feed(k, &st, &b, &fx) }
    }

    /// Remove the insert-mode keys typed while a mapping was pending.
    private static func removeTentative(_ n: Int, _ st: inout VimState, _ b: inout TextBuffer) {
        guard st.mode.isTyping, b.cursor >= n else { return }
        edit(b.cursor - n, b.cursor, "", &st, &b)
        b.cursor -= n
        if st.recordingInputs.count >= n { st.recordingInputs.removeLast(n) }
        if var s = st.insertSession {
            s.typed = String(s.typed.dropLast(n))
            if s.inputs.count >= n { s.inputs.removeLast(n) }
            st.insertSession = s
        }
    }

    // MARK: Dot recording

    static func feed(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        if st.isReplaying {
            dispatch(input, &st, &b, &fx)
            return
        }
        if isFreshNormal(st) {
            st.recordingInputs = [input]
            st.recordingBaseline = b.text
        } else {
            st.recordingInputs.append(input)
        }
        dispatch(input, &st, &b, &fx)
        if isFreshNormal(st) {
            if !st.recordingInputs.isEmpty, let base = st.recordingBaseline, base != b.text {
                st.lastChange = st.recordingInputs
            }
            st.recordingInputs = []
            st.recordingBaseline = nil
        }
    }

    static func dispatch(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        if st.substituteConfirm != nil {
            handleSubstituteConfirm(input, &st, &b)
            return
        }
        if st.insertOneShot == 1 { st.insertOneShot = 2 }
        switch st.mode {
        case .normal, .visual: handleNormalKey(input, &st, &b, &fx)
        case .insert, .replace: handleTyping(input, &st, &b, &fx)
        case .commandLine: handleCommandLine(input, &st, &b, &fx)
        }
        if st.insertOneShot == 2 {
            if st.mode == .normal, st.pendingKeys.isEmpty, st.commandLineVisual == nil {
                st.insertOneShot = 0
                st.mode = st.insertSession.map { _ in VimMode.insert } ?? .insert
                if st.insertSession == nil { st.insertSession = InsertSession(start: b.cursor, count: 1, kind: .plain) }
                b.cursor = max(0, min(b.cursor, b.text.count))
            } else if st.mode.isTyping {
                st.insertOneShot = 0
            }
        }
    }

    // MARK: Normal / visual keys

    private static func handleNormalKey(_ input: VimInput, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        // Macro stop works in visual mode too (vim).
        if st.mode.isVisual, st.pendingKeys.isEmpty, input.char == "q", st.recordingMacro != nil, !st.isPlayingMacro {
            finalizeMacroRecording(&st)
            return
        }
        st.pendingKeys.append(input)
        switch parse(st.pendingKeys, visual: st.mode.isVisual, recording: st.recordingMacro != nil && !st.isPlayingMacro) {
        case .incomplete:
            return
        case .invalid:
            st.pendingKeys = []
        case let .complete(cmd):
            st.pendingKeys = []
            if st.mode.isVisual {
                executeVisual(cmd, &st, &b, &fx)
            } else {
                execute(cmd, &st, &b, &fx)
            }
        }
    }

    // MARK: Edit primitive

    /// Replace `[from, to)` with `s`, logging a ranged edit and moving
    /// marks (and tracked offsets) through it.
    static func edit(_ from: Int, _ to: Int, _ s: String, _ st: inout VimState, _ b: inout TextBuffer) {
        let from = max(0, min(from, b.text.count))
        let to = max(from, min(to, b.text.count))
        guard from < to || !s.isEmpty else { return }
        var removedHasNewline = false
        if !st.trackedOffsets.isEmpty, to > from {
            let lo = b.text.index(b.text.startIndex, offsetBy: from)
            let hi = b.text.index(lo, offsetBy: to - from)
            removedHasNewline = b.text[lo..<hi].contains("\n")
        }
        b.replaceCharacters(from: from, to: to, with: s)
        let delta = s.count - (to - from)
        let inserted = s.count
        func adj(_ m: Int) -> Int {
            if m >= to { return m + delta }
            if m > from { return from + min(m - from, inserted) }
            return m
        }
        if !st.marks.isEmpty { st.marks = st.marks.mapValues(adj) }
        if var v = st.lastVisual {
            v.anchor = adj(v.anchor)
            v.head = adj(v.head)
            st.lastVisual = v
        }
        if !st.trackedOffsets.isEmpty {
            st.trackedOffsets = st.trackedOffsets.map { t in
                guard let m = t else { return nil }
                if m >= from, m < to, removedHasNewline, to > from { return nil }
                return adj(m)
            }
        }
    }

    /// Apply many sequential UTF-16 edits at once (`:s` over a range):
    /// one pass, each match its own ranged edit.
    static func applyBulk(_ edits: [TextEdit], _ st: inout VimState, _ b: inout TextBuffer) {
        guard !edits.isEmpty else { return }
        let old = b.text
        let ns = NSMutableString(string: old)
        for e in edits { e.apply(to: ns) }
        let new = ns as String
        func mapChar(_ c: Int) -> Int {
            let u = PositionMapper.map(utf16Offset(in: old, characterOffset: c), through: edits)
            return characterOffset(utf16: u, in: new)
        }
        st.marks = st.marks.mapValues(mapChar)
        if var v = st.lastVisual {
            v.anchor = mapChar(v.anchor)
            v.head = mapChar(v.head)
            st.lastVisual = v
        }
        st.trackedOffsets = st.trackedOffsets.map { $0.map(mapChar) }
        b.text = new
        for e in edits { b.appendEdit(e) }
    }

    static func pushUndo(_ st: inout VimState, _ b: TextBuffer) {
        st.history.push(.init(buffer: b))
    }

    /// Keep the cursor where the mode allows it.
    static func clamp(_ st: VimState, _ b: inout TextBuffer) {
        let count = b.text.count
        if count == 0 { b.cursor = 0; return }
        if st.mode.isTyping || st.insertOneShot > 0 || st.mode.commandLinePrefix != nil {
            b.cursor = max(0, min(b.cursor, count))
            return
        }
        if st.mode.isVisual {
            b.cursor = max(0, min(b.cursor, count))
            if b.cursor == count, !b.text.hasSuffix("\n") { b.cursor = count - 1 }
            return
        }
        // Normal: on a character of the line (the line start when empty).
        let c = max(0, min(b.cursor, count))
        let idx = b.text.index(b.text.startIndex, offsetBy: c)
        if idx < b.text.endIndex, b.text[idx] != "\n" { b.cursor = c; return }
        // On a newline or at the end: step back unless the line is empty.
        if c == 0 { b.cursor = 0; return }
        let prev = b.text.index(before: idx)
        b.cursor = b.text[prev] == "\n" ? c : c - 1
    }

    // MARK: Normal command execution

    static func execute(_ cmd: ParsedCommand, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        let doc = Doc(b.text)
        let count = cmd.count
        let n = max(1, count ?? 1)
        let cursor = min(b.cursor, doc.count)
        let line = doc.line(of: cursor)
        var keepDesired = false

        switch cmd.action {
        case .escape, .nop:
            break

        case let .motion(m):
            guard let r = resolveMotion(m, count: count, doc: doc, cursor: cursor, state: &st, context: .normal) else { break }
            moveCursor(r, m, from: cursor, doc: doc, &st, &b, &fx)
            keepDesired = r.vertical || m == .lineEnd

        case let .operatorMotion(op, m):
            var r: MotionResult?
            if op == .change, case let .wordForward(big) = m, cursor < doc.count, !doc[cursor].isWhitespace {
                // `cw` changes to the end of the word, like `ce`.
                var t = cursor
                for k in 0..<n {
                    let atEnd = t + 1 >= doc.count || CharClass(doc[t + 1], big: big) != CharClass(doc[t], big: big)
                    if k == 0, atEnd { continue }
                    t = nextWordEnd(doc, t, big: big)
                }
                r = MotionResult(target: t, inclusive: true)
            } else {
                r = resolveMotion(m, count: count, doc: doc, cursor: cursor, state: &st, context: .op(op))
            }
            guard let r else { break }
            if r.jump { st.marks["'"] = cursor }
            applyMotionOperator(op, r, m, cursor: cursor, register: cmd.register, doc: doc, &st, &b)

        case let .operatorObject(op, spec):
            guard let obj = resolveObject(spec, count: n, doc: doc, cursor: cursor) else { break }
            let region: Region = obj.linewise
                ? .lines(doc.line(of: obj.from), doc.line(of: max(obj.from, obj.to - 1)))
                : .chars(obj.from, obj.to)
            applyOperator(op, region, register: cmd.register, amount: 1, doc: doc, &st, &b)

        case let .operatorLines(op):
            let last = doc.clampLine(line + n - 1)
            if op == .yank || op == .delete || op == .change, line + n - 1 > doc.lastLine, n > 1, line == doc.lastLine { break }
            applyOperator(op, .lines(line, last), register: cmd.register, amount: 1, doc: doc, &st, &b)

        case let .operatorSearch(op, prefix):
            enterSearch(prefix, op: op, register: cmd.register, count: count, &st, &b)

        case let .deleteChar(forward):
            let ls = doc.lineStart(line), le = doc.lineEnd(line)
            let range = forward ? (cursor, min(le, cursor + n)) : (max(ls, cursor - n), cursor)
            guard range.0 < range.1 else { break }
            applyOperator(.delete, .chars(range.0, range.1), register: cmd.register, amount: 1, doc: doc, &st, &b)

        case .substituteChar:
            let le = doc.lineEnd(line)
            applyOperator(.change, .chars(cursor, min(le, cursor + n)), register: cmd.register, amount: 1, doc: doc, &st, &b)

        case .substituteLine:
            applyOperator(.change, .lines(line, doc.clampLine(line + n - 1)), register: cmd.register, amount: 1, doc: doc, &st, &b)

        case .deleteToEnd, .changeToEnd:
            let el = doc.clampLine(line + n - 1)
            let op: VimOperator = cmd.action == .deleteToEnd ? .delete : .change
            applyOperator(op, .chars(cursor, doc.lineEnd(el)), register: cmd.register, amount: 1, doc: doc, &st, &b)

        case .yankLine:
            applyOperator(.yank, .lines(line, doc.clampLine(line + n - 1)), register: cmd.register, amount: 1, doc: doc, &st, &b)

        case let .put(after, cursorAfter):
            guard let reg = readRegister(cmd.register, st) else {
                if let r = cmd.register { st.message = VimMessage("E353: Nothing in register \(r)", isError: true) }
                break
            }
            put(reg, after: after, cursorAfter: cursorAfter, count: n, &st, &b)

        case let .join(spaces):
            guard line < doc.lastLine else { break }
            join(firstLine: line, lines: max(2, n), spaces: spaces, &st, &b)

        case .swapCaseChar:
            let le = doc.lineEnd(line)
            guard cursor < le else { break }
            let end = min(le, cursor + n)
            pushUndo(&st, b)
            transformCase(.swapCase, .chars(cursor, end), doc: doc, &st, &b)
            b.cursor = min(end, max(doc.lineStart(line), le - 1))
            st.marks["."] = cursor

        case let .replaceChar(c):
            let le = doc.lineEnd(line)
            guard cursor + n <= le else { break }
            pushUndo(&st, b)
            if c == "\n" {
                edit(cursor, cursor + n, "\n", &st, &b)
                b.cursor = cursor + 1
            } else {
                edit(cursor, cursor + n, String(repeating: String(c), count: n), &st, &b)
                b.cursor = cursor + n - 1
            }
            st.marks["."] = cursor

        case .replaceMode:
            pushUndo(&st, b)
            st.mode = .replace
            st.insertSession = InsertSession(start: cursor, count: n, kind: .plain)

        case let .insert(entry):
            startInsertEntry(entry, count: n, doc: doc, &st, &b)

        case .undo, .undoLine:
            for _ in 0..<n { undo(&st, &b) }
        case .redo:
            for _ in 0..<n { redo(&st, &b) }

        case .dot:
            replayDot(count: count, &st, &b, &fx)

        case let .record(r):
            st.recordingMacro = r
            st.recordingMacroInputs = []

        case .stopRecord:
            finalizeMacroRecording(&st)

        case let .play(r):
            playMacro(r, count: n, &st, &b, &fx)

        case let .setMark(m):
            st.marks[m == "`" ? "'" : m] = cursor

        case let .visual(kind):
            st.mode = .visual(kind, anchor: cursor)
            st.blockToLineEnd = false

        case .reselect:
            guard let v = st.lastVisual else { break }
            st.mode = .visual(v.kind, anchor: min(v.anchor, doc.count))
            st.blockToLineEnd = v.toLineEnd
            b.cursor = min(v.head, doc.count)

        case .cmdline:
            st.mode = .commandLine(prefix: ":", buffer: count.map { $0 > 1 ? ".,.+\($0 - 1)" : "." } ?? "")
            st.commandLineHistoryIndex = nil
            st.commandLineHistoryDraft = nil

        case let .search(prefix):
            enterSearch(prefix, op: nil, register: nil, count: count, &st, &b)

        case let .repeatSubstitute(all):
            if all {
                executeEx("%s//~/&", &st, &b, &fx, depth: 0)
            } else {
                executeEx("s", &st, &b, &fx, depth: 0)
            }
            // `&` is a change (dot-repeatable): keep the recording.

        case let .increment(delta):
            increment(line: line, from: cursor, by: delta * n, doc: doc, &st, &b)

        case let .scroll(kind):
            scroll(kind, count: count, doc: doc, &st, &b, &fx)
            keepDesired = true

        case let .scrollCursor(pos, fnb):
            var l = line
            if let count { l = doc.clampLine(count - 1) }
            if fnb || count != nil { b.cursor = doc.firstNonBlank(l) }
            fx = .scrollCursor(pos)
            keepDesired = !fnb

        case let .saveQuit(save):
            fx = save ? .saveAndClose(force: false) : .close(force: true)

        case .fileInfo:
            let name = st.fileName.map { "\"\($0)\"" } ?? "[No Name]"
            let pct = doc.lineCount > 0 ? (line + 1) * 100 / doc.lineCount : 0
            st.message = VimMessage("\(name) \(doc.lineCount) lines --\(pct)%--")

        case .objectSelect, .visualOperator, .visualLinewise, .visualToEnd, .swapEnds,
             .visualInsert, .visualReplace, .visualPut, .visualJoin:
            break
        }
        if !keepDesired { st.desiredColumn = nil }
        clamp(st, &b)
    }

    static func moveCursor(_ r: MotionResult, _ m: MotionSpec, from: Int, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        if r.jump { st.marks["'"] = from }
        if r.vertical {
            if st.desiredColumn == nil { st.desiredColumn = doc.column(of: from) }
        } else if m == .lineEnd {
            st.desiredColumn = Int.max
        } else {
            st.desiredColumn = nil
        }
        b.cursor = r.target
        if let d = r.displayLines { fx = .displayLines(from: from, count: d) }
    }

    // MARK: Regions + operators

    enum Region: Hashable {
        case chars(Int, Int)
        case lines(Int, Int)
        case block(BlockRegion)
    }

    struct BlockRegion: Hashable {
        var firstLine: Int
        var lastLine: Int
        var left: Int
        var right: Int
        var toEnd: Bool
    }

    static func applyMotionOperator(_ op: VimOperator, _ r: MotionResult, _ m: MotionSpec, cursor: Int, register: Character?, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        var from = min(cursor, r.target)
        var to = max(cursor, r.target)
        var linewise = r.linewise
        if !linewise {
            if r.inclusive {
                to = min(to + 1, doc.count)
            } else if to > from, doc.column(of: to) == 0, doc.line(of: to) > doc.line(of: from) {
                // Exclusive motion ending in column 0: stop at the end of
                // the previous line; from the line's start it becomes
                // linewise (`d}` from a paragraph start).
                let fromLine = doc.line(of: from)
                to = doc.lineEnd(doc.line(of: to) - 1)
                if from <= doc.firstNonBlank(fromLine), m != .wordForward(big: false), m != .wordForward(big: true) {
                    linewise = true
                    from = doc.lineStart(fromLine)
                }
            }
        }
        let numbered: Bool
        switch m {
        case .matchPair, .sentenceForward, .sentenceBackward, .paragraphForward, .paragraphBackward, .searchNext, .searchWord, .mark:
            numbered = true
        default:
            numbered = false
        }
        if linewise {
            applyOperator(op, .lines(doc.line(of: from), doc.line(of: max(from, to))), register: register, amount: 1, doc: doc, &st, &b, forceNumbered: numbered)
        } else {
            if from == to, op != .change { return }
            applyOperator(op, .chars(from, to), register: register, amount: 1, doc: doc, &st, &b, forceNumbered: numbered)
        }
    }

    static func regionText(_ region: Region, doc: Doc) -> (String, Register.Kind) {
        switch region {
        case let .chars(f, t):
            return (doc.text(f, t), .characterwise)
        case let .lines(a, z):
            return ((a...z).map { doc.lineText($0) }.joined(separator: "\n") + "\n", .linewise)
        case let .block(r):
            let rows = (r.firstLine...r.lastLine).map { l -> String in
                let (s, e) = blockSpan(r, line: l, doc: doc)
                return doc.text(s, e)
            }
            return (rows.joined(separator: "\n"), .blockwise)
        }
    }

    /// Character span of block `r` on line `l` (clamped to the line).
    static func blockSpan(_ r: BlockRegion, line l: Int, doc: Doc) -> (Int, Int) {
        let ls = doc.lineStart(l), le = doc.lineEnd(l)
        let s = min(ls + r.left, le)
        let e = r.toEnd ? le : min(ls + r.right + 1, le)
        return (s, max(s, e))
    }

    static func applyOperator(
        _ op: VimOperator,
        _ region: Region,
        register: Character?,
        amount: Int,
        doc: Doc,
        _ st: inout VimState,
        _ b: inout TextBuffer,
        forceNumbered: Bool = false
    ) {
        let (text, kind) = regionText(region, doc: doc)
        let cursor = b.cursor
        func markSpan() {
            switch region {
            case let .chars(f, t): st.marks["["] = f; st.marks["]"] = max(f, t - 1)
            case let .lines(a, z): st.marks["["] = doc.lineStart(a); st.marks["]"] = doc.lastChar(z)
            case let .block(r): st.marks["["] = doc.lineStart(r.firstLine) + r.left; st.marks["]"] = doc.lineStart(r.lastLine) + r.right
            }
        }
        switch op {
        case .yank:
            storeRegister(text, kind: kind, register: register, isDelete: false, &st)
            markSpan()
            let spans: [Range<Int>]
            switch region {
            case let .chars(f, t): spans = [f..<max(f, t)]
            case let .lines(a, z): spans = [doc.lineStart(a)..<max(doc.lineStart(a), doc.lineEnd(z))]
            case let .block(r): spans = (r.firstLine...r.lastLine).map { l in let (s, e) = blockSpan(r, line: l, doc: doc); return s..<e }
            }
            st.lastYank = VimYank(seq: (st.lastYank?.seq ?? 0) + 1, spans: spans.filter { !$0.isEmpty })
            switch region {
            case let .chars(f, _): b.cursor = f
            case let .lines(a, z):
                if doc.line(of: cursor) != a { b.cursor = doc.offset(line: a, column: doc.column(of: cursor)) }
                if z - a + 1 > 2 { st.message = VimMessage("\(z - a + 1) lines yanked") }
            case let .block(r): b.cursor = doc.offset(line: r.firstLine, column: r.left)
            }

        case .delete:
            pushUndo(&st, b)
            storeRegister(text, kind: kind, register: register, isDelete: true, forceNumbered: forceNumbered, &st)
            deleteRegion(region, doc: doc, &st, &b)
            if case let .lines(a, z) = region, z - a + 1 > 2 { st.message = VimMessage("\(z - a + 1) fewer lines") }
            st.marks["."] = b.cursor

        case .change:
            pushUndo(&st, b)
            storeRegister(text, kind: kind, register: register, isDelete: true, forceNumbered: forceNumbered, &st)
            switch region {
            case let .chars(f, t):
                edit(f, t, "", &st, &b)
                startInsert(at: f, count: 1, kind: .plain, &st, &b)
            case let .lines(a, z):
                let ind = st.options.autoindent ? doc.indent(a) : ""
                edit(doc.lineStart(a), doc.lineEnd(z), ind, &st, &b)
                startInsert(at: doc.lineStart(a) + ind.count, count: 1, kind: .plain, &st, &b)
            case let .block(r):
                deleteRegion(region, doc: doc, &st, &b)
                let start = Doc(b.text).offset(line: r.firstLine, column: r.left, allowEnd: true)
                startInsert(at: start, count: 1, kind: .block(firstLine: r.firstLine, lastLine: r.lastLine, column: r.left, toLineEnd: r.toEnd, pad: false), &st, &b)
            }

        case .shiftRight, .shiftLeft:
            let (a, z) = lineSpan(region, doc: doc)
            pushUndo(&st, b)
            shiftLines(a, z, right: op == .shiftRight, amount: amount, doc: doc, &st, &b)
            b.cursor = Doc(b.text).firstNonBlank(a)
            if z - a + 1 > 2 { st.message = VimMessage("\(z - a + 1) lines \(op == .shiftRight ? ">" : "<")ed 1 time") }

        case .reindent:
            let (a, _) = lineSpan(region, doc: doc)
            b.cursor = doc.firstNonBlank(a)

        case .swapCase, .lowercase, .uppercase, .rot13:
            pushUndo(&st, b)
            transformCase(op, region, doc: doc, &st, &b)
            markSpan()
            switch region {
            case let .chars(f, _): b.cursor = f
            case let .lines(a, _): b.cursor = doc.lineStart(a)
            case let .block(r): b.cursor = doc.offset(line: r.firstLine, column: r.left)
            }
        }
    }

    static func lineSpan(_ region: Region, doc: Doc) -> (Int, Int) {
        switch region {
        case let .chars(f, t): return (doc.line(of: f), doc.line(of: max(f, t - 1)))
        case let .lines(a, z): return (a, z)
        case let .block(r): return (r.firstLine, r.lastLine)
        }
    }

    static func deleteRegion(_ region: Region, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        switch region {
        case let .chars(f, t):
            edit(f, t, "", &st, &b)
            b.cursor = f
        case let .lines(a, z):
            var target: Int
            if z < doc.lastLine {
                edit(doc.lineStart(a), doc.lineStart(z + 1), "", &st, &b)
                target = a
            } else if a > 0 {
                edit(doc.lineEnd(a - 1), doc.count, "", &st, &b)
                target = a - 1
            } else {
                edit(0, doc.count, "", &st, &b)
                target = 0
            }
            let nd = Doc(b.text)
            target = nd.clampLine(target)
            b.cursor = nd.firstNonBlank(target)
        case let .block(r):
            for l in stride(from: r.lastLine, through: r.firstLine, by: -1) {
                let (s, e) = blockSpan(r, line: l, doc: doc)
                if s < e { edit(s, e, "", &st, &b) }
            }
            b.cursor = Doc(b.text).offset(line: r.firstLine, column: r.left)
        }
    }

    static func transformCase(_ op: VimOperator, _ region: Region, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        func convert(_ s: String) -> String {
            switch op {
            case .lowercase: return s.lowercased()
            case .uppercase: return s.uppercased()
            case .rot13:
                return String(s.map { c -> Character in
                    guard let a = c.asciiValue, c.isLetter else { return c }
                    let base: UInt8 = c.isUppercase ? 65 : 97
                    return Character(UnicodeScalar((a - base + 13) % 26 + base))
                })
            default:
                return String(s.map { c -> Character in
                    if c.isUppercase { return Character(c.lowercased()) }
                    if c.isLowercase { return Character(c.uppercased()) }
                    return c
                })
            }
        }
        var spans: [(Int, Int)] = []
        switch region {
        case let .chars(f, t): spans = [(f, t)]
        case let .lines(a, z): spans = (a...z).map { (doc.lineStart($0), doc.lineEnd($0)) }
        case let .block(r): spans = (r.firstLine...r.lastLine).map { blockSpan(r, line: $0, doc: doc) }
        }
        for (s, e) in spans.reversed() where s < e {
            let old = doc.text(s, e)
            let new = convert(old)
            if new != old { edit(s, e, new, &st, &b) }
        }
    }

    static func indentWidth(_ s: String, tabstop: Int) -> Int {
        var w = 0
        for c in s { w = c == "\t" ? (w / tabstop + 1) * tabstop : w + 1 }
        return w
    }

    static func makeIndent(width: Int, options: VimOptions) -> String {
        if options.expandtab { return String(repeating: " ", count: max(0, width)) }
        let ts = max(1, options.tabstop)
        return String(repeating: "\t", count: width / ts) + String(repeating: " ", count: width % ts)
    }

    static func shiftLines(_ a: Int, _ z: Int, right: Bool, amount: Int, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        let sw = max(1, st.options.shiftwidth)
        for l in stride(from: z, through: a, by: -1) {
            let ls = doc.lineStart(l)
            if doc.isEmptyLine(l) { continue }
            let ind = doc.indent(l)
            if right {
                edit(ls, ls, String(repeating: st.options.indentUnit, count: max(1, amount)), &st, &b)
            } else {
                let w = indentWidth(ind, tabstop: max(1, st.options.tabstop))
                let nw = max(0, w - sw * max(1, amount))
                let new = makeIndent(width: nw, options: st.options)
                if new != ind { edit(ls, ls + ind.count, new, &st, &b) }
            }
        }
    }

    // MARK: Registers

    static func storeRegister(_ text: String, kind: Register.Kind, register: Character?, isDelete: Bool, forceNumbered: Bool = false, _ st: inout VimState) {
        let reg = Register(text: text, kind: kind)
        if register == "_" { return }
        if let r = register, r != "\"" {
            if r.isASCII, r.isLetter, r.isUppercase {
                let lower = Character(r.lowercased())
                var existing = st.registers[lower] ?? Register()
                if existing.text.isEmpty {
                    existing = reg
                } else if kind == .linewise || existing.kind == .linewise {
                    var t = existing.text
                    if !t.hasSuffix("\n") { t += "\n" }
                    t += text
                    if !t.hasSuffix("\n") { t += "\n" }
                    existing = Register(text: t, kind: .linewise)
                } else {
                    existing.text += text
                }
                st.registers[lower] = existing
                st.defaultRegister = existing
                return
            }
            if r == "+" || r == "*" {
                st.clipboard = text
                st.defaultRegister = reg
                return
            }
            if (r.isASCII && (r.isLetter || r.isNumber)) || r == "-" { st.registers[r] = reg }
            st.defaultRegister = reg
            return
        }
        st.defaultRegister = reg
        if !isDelete {
            st.registers["0"] = reg
            return
        }
        if kind != .characterwise || text.contains("\n") || forceNumbered {
            for d in stride(from: 9, through: 2, by: -1) {
                let to = Character(String(d)), from = Character(String(d - 1))
                if let v = st.registers[from] { st.registers[to] = v }
            }
            st.registers["1"] = reg
        } else {
            st.registers["-"] = reg
        }
    }

    static func readRegister(_ r: Character?, _ st: VimState) -> Register? {
        func nonEmpty(_ reg: Register?) -> Register? { (reg?.text.isEmpty ?? true) ? nil : reg }
        guard let r, r != "\"" else { return nonEmpty(st.defaultRegister) }
        switch r {
        case "+", "*":
            if let c = st.clipboard, !c.isEmpty {
                if c == st.defaultRegister.text { return st.defaultRegister }
                return Register(text: c, kind: c.hasSuffix("\n") && c.count > 1 ? .linewise : .characterwise)
            }
            return nonEmpty(st.defaultRegister)
        case ".": return nonEmpty(Register(text: st.lastInsertedText))
        case ":": return nonEmpty(Register(text: st.lastExCommand ?? ""))
        case "/": return nonEmpty(Register(text: st.lastSearch?.pattern ?? ""))
        case "%": return nonEmpty(Register(text: st.fileName ?? ""))
        case "_": return nil
        default:
            let key = r.isUppercase ? Character(r.lowercased()) : r
            return nonEmpty(st.registers[key])
        }
    }

    // MARK: Put

    static func put(_ reg: Register, after: Bool, cursorAfter: Bool, count: Int, _ st: inout VimState, _ b: inout TextBuffer) {
        let doc = Doc(b.text)
        let cursor = min(b.cursor, doc.count)
        let line = doc.line(of: cursor)
        pushUndo(&st, b)
        switch reg.kind {
        case .characterwise:
            let text = String(repeating: reg.text, count: max(1, count))
            var at = cursor
            if after, !doc.isEmptyLine(line) { at = min(cursor + 1, doc.lineEnd(line)) }
            edit(at, at, text, &st, &b)
            st.marks["["] = at
            st.marks["]"] = at + text.count - 1
            if cursorAfter { b.cursor = at + text.count }
            else if text.contains("\n") { b.cursor = at }
            else { b.cursor = at + text.count - 1 }
        case .linewise:
            var body = reg.text
            if !body.hasSuffix("\n") { body += "\n" }
            body = String(repeating: body, count: max(1, count))
            let start: Int
            if after {
                if line == doc.lastLine {
                    edit(doc.count, doc.count, "\n" + body.dropLast(), &st, &b)
                    start = doc.count + 1
                } else {
                    let at = doc.lineStart(line + 1)
                    edit(at, at, body, &st, &b)
                    start = at
                }
            } else {
                let at = doc.lineStart(line)
                edit(at, at, body, &st, &b)
                start = at
            }
            let nd = Doc(b.text)
            let first = nd.line(of: start)
            let added = body.filter { $0 == "\n" }.count
            st.marks["["] = start
            st.marks["]"] = nd.lineStart(nd.clampLine(first + added - 1))
            b.cursor = cursorAfter ? nd.lineStart(nd.clampLine(first + added)) : nd.firstNonBlank(first)
        case .blockwise:
            let rows = reg.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let width = rows.map(\.count).max() ?? 0
            var col = doc.column(of: cursor)
            if after, !doc.isEmptyLine(line) { col += 1 }
            for (k, row) in rows.enumerated().reversed() {
                let cur = Doc(b.text)
                let l = line + k
                let piece = String(repeating: row.padding(toLength: width, withPad: " ", startingAt: 0), count: max(1, count))
                if l > cur.lastLine {
                    let extra = String(repeating: "\n", count: l - cur.lastLine)
                    edit(cur.count, cur.count, extra + String(repeating: " ", count: col) + piece, &st, &b)
                    continue
                }
                let len = cur.lineLength(l)
                if len < col {
                    edit(cur.lineEnd(l), cur.lineEnd(l), String(repeating: " ", count: col - len) + piece, &st, &b)
                } else {
                    let at = cur.lineStart(l) + col
                    let text = at == cur.lineEnd(l) ? piece.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) : piece
                    edit(at, at, text, &st, &b)
                }
            }
            b.cursor = Doc(b.text).offset(line: line, column: col)
        }
        st.marks["."] = b.cursor
    }

    // MARK: Join

    static func join(firstLine: Int, lines: Int, spaces: Bool, _ st: inout VimState, _ b: inout TextBuffer) {
        pushUndo(&st, b)
        var doc = Doc(b.text)
        var pos = b.cursor
        for _ in 0..<(lines - 1) {
            guard firstLine < doc.lastLine else { break }
            let nl = doc.lineEnd(firstLine)
            var removeTo = nl + 1
            var insert = ""
            if spaces {
                while removeTo < doc.count, isBlank(doc[removeTo]) { removeTo += 1 }
                let nextEmpty = removeTo >= doc.count || doc[removeTo] == "\n"
                let curEmpty = doc.lineStart(firstLine) == nl
                let curEndsBlank = nl > doc.lineStart(firstLine) && isBlank(doc[nl - 1])
                if !nextEmpty, !curEmpty, !curEndsBlank, doc[removeTo] != ")" { insert = " " }
            }
            edit(nl, removeTo, insert, &st, &b)
            pos = nl
            doc = Doc(b.text)
        }
        b.cursor = pos
        st.marks["."] = pos
    }

    // MARK: Insert entry

    static func startInsert(at: Int, count: Int, kind: InsertSession.Kind, _ st: inout VimState, _ b: inout TextBuffer) {
        st.mode = .insert
        b.cursor = max(0, min(at, b.text.count))
        st.insertSession = InsertSession(start: b.cursor, count: max(1, count), kind: kind)
        st.desiredColumn = nil
    }

    static func startInsertEntry(_ entry: InsertEntry, count: Int, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        let cursor = min(b.cursor, doc.count)
        let line = doc.line(of: cursor)
        switch entry {
        case .i:
            pushUndo(&st, b)
            startInsert(at: cursor, count: count, kind: .plain, &st, &b)
        case .a:
            pushUndo(&st, b)
            let at = doc.isEmptyLine(line) ? cursor : min(cursor + 1, doc.lineEnd(line))
            startInsert(at: at, count: count, kind: .plain, &st, &b)
        case .I:
            pushUndo(&st, b)
            let at = doc.lastNonBlank(line) == nil ? doc.lineEnd(line) : doc.firstNonBlank(line)
            startInsert(at: at, count: count, kind: .plain, &st, &b)
        case .gI:
            pushUndo(&st, b)
            startInsert(at: doc.lineStart(line), count: count, kind: .plain, &st, &b)
        case .A:
            pushUndo(&st, b)
            startInsert(at: doc.lineEnd(line), count: count, kind: .plain, &st, &b)
        case .gi:
            pushUndo(&st, b)
            startInsert(at: min(st.marks["^"] ?? cursor, doc.count), count: count, kind: .plain, &st, &b)
        case .o:
            pushUndo(&st, b)
            let ind = st.options.autoindent ? doc.indent(line) : ""
            let at = doc.lineEnd(line)
            edit(at, at, "\n" + ind, &st, &b)
            startInsert(at: at + 1 + ind.count, count: count, kind: .openLine(below: true), &st, &b)
        case .O:
            pushUndo(&st, b)
            let ind = st.options.autoindent ? doc.indent(line) : ""
            let at = doc.lineStart(line)
            edit(at, at, ind + "\n", &st, &b)
            startInsert(at: at + ind.count, count: count, kind: .openLine(below: false), &st, &b)
        }
    }

    // MARK: Undo / redo / dot

    static func undo(_ st: inout VimState, _ b: inout TextBuffer) {
        let current = VimHistory.Snapshot(buffer: b)
        guard let snap = st.history.popUndo(current: current) else {
            st.message = VimMessage("Already at oldest change")
            return
        }
        restore(snap, &st, &b)
    }

    static func redo(_ st: inout VimState, _ b: inout TextBuffer) {
        let current = VimHistory.Snapshot(buffer: b)
        guard let snap = st.history.popRedo(current: current) else {
            st.message = VimMessage("Already at newest change")
            return
        }
        restore(snap, &st, &b)
    }

    private static func restore(_ snap: VimHistory.Snapshot, _ st: inout VimState, _ b: inout TextBuffer) {
        // Undo is a meta-command: never committed as the last change.
        st.recordingInputs = []
        st.recordingBaseline = nil
        if let edit = TextDiff.edit(from: b.text, to: snap.text) {
            let old = b.text
            b.text = snap.text
            b.appendEdit(edit)
            st.marks = st.marks.mapValues { m in
                let u = PositionMapper.map(utf16Offset(in: old, characterOffset: m), through: [edit])
                return characterOffset(utf16: u, in: snap.text)
            }
        }
        b.cursor = snap.cursor
    }

    static func replayDot(count: Int?, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        guard var inputs = st.lastChange, !inputs.isEmpty else { return }
        if let count { inputs = replacingCount(inputs, with: count) }
        if inputs.count >= 2, inputs[0].char == "\"", let r = inputs[1].char, let d = r.wholeNumberValue, (1...8).contains(d) {
            inputs[1] = .character(Character(String(d + 1)))
        }
        st.isReplaying = true
        for k in inputs { feed(k, &st, &b, &fx) }
        if st.mode.isTyping { handleTyping(.escape, &st, &b, &fx) }
        st.pendingKeys = []
        st.isReplaying = false
        st.recordingInputs = []
        st.recordingBaseline = nil
        st.lastChange = inputs
    }

    /// Swap the count of the first command in `inputs` for `count`.
    static func replacingCount(_ inputs: [VimInput], with count: Int) -> [VimInput] {
        for k in 1...inputs.count {
            if case let .complete(cmd) = parse(Array(inputs.prefix(k)), visual: false, recording: false) {
                var out = inputs
                for i in cmd.countIndices.sorted(by: >) { out.remove(at: i) }
                let at = (out.first?.char == "\"" && out.count >= 2) ? 2 : 0
                out.insert(contentsOf: String(count).map { VimInput.character($0) }, at: at)
                return out
            }
        }
        return inputs
    }

    // MARK: Macros

    static func finalizeMacroRecording(_ st: inout VimState) {
        guard let name = st.recordingMacro else { return }
        var inputs = st.recordingMacroInputs
        if !inputs.isEmpty { inputs.removeLast() }
        if name.isUppercase {
            let lower = Character(name.lowercased())
            st.macros[lower, default: []].append(contentsOf: inputs)
        } else {
            st.macros[name] = inputs
        }
        st.registers[name.isUppercase ? Character(name.lowercased()) : name] = Register(text: inputs.notation)
        st.recordingMacro = nil
        st.recordingMacroInputs = []
    }

    static func playMacro(_ rawName: Character, count: Int, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        var name = rawName
        if name == "@" {
            guard let last = st.lastPlayedMacro else { return }
            name = last
        }
        st.lastPlayedMacro = name
        if name == ":" {
            guard let ex = st.lastExCommand else { return }
            for _ in 0..<max(1, count) { executeEx(ex, &st, &b, &fx, depth: 1) }
            return
        }
        let key = name.isUppercase ? Character(name.lowercased()) : name
        var inputs = st.macros[key] ?? []
        if inputs.isEmpty, let text = readRegister(key, st)?.text, !text.isEmpty {
            inputs = VimInput.parse(notation: text) ?? text.map { VimInput.character($0) }
        }
        guard !inputs.isEmpty else { return }
        var steps: [VimState.MacroStep] = [.end]
        let times = max(1, count)
        steps.reserveCapacity(inputs.count * times + 1)
        for _ in 0..<times { for input in inputs.reversed() { steps.append(.input(input)) } }

        if st.isPlayingMacro {
            guard st.macroDepth < macroDepthLimit else {
                st.macroSteps = []
                return
            }
            st.macroDepth += 1
            st.macroSteps.append(contentsOf: steps)
            return
        }
        st.isPlayingMacro = true
        st.macroDepth = 1
        st.macroSteps = steps
        // The `@x` keys themselves are not a change.
        st.recordingInputs = []
        st.recordingBaseline = nil
        while let step = st.macroSteps.popLast() {
            switch step {
            case .end:
                st.macroDepth = max(0, st.macroDepth - 1)
            case let .input(input):
                let r = handle(input, state: st, buffer: b)
                st = r.state
                b = r.buffer
                if let e = r.effect { fx = e }
            }
        }
        st.macroSteps = []
        st.macroDepth = 0
        st.isPlayingMacro = false
    }

    // MARK: Misc commands

    static func increment(line: Int, from cursor: Int, by delta: Int, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer) {
        let le = doc.lineEnd(line)
        var i = cursor
        // Inside a number: back up to its start.
        while i > doc.lineStart(line), i < le, doc[i].isASCII, doc[i].isNumber, doc[i - 1].isASCII, doc[i - 1].isNumber { i -= 1 }
        while i < le, !(doc[i].isASCII && doc[i].isNumber) { i += 1 }
        guard i < le else { return }
        var start = i
        var end = i
        while end < le, doc[end].isASCII, doc[end].isNumber { end += 1 }
        if start > doc.lineStart(line), doc[start - 1] == "-" { start -= 1 }
        guard let value = Int(doc.text(start, end)) else { return }
        let new = String(value + delta)
        pushUndo(&st, b)
        edit(start, end, new, &st, &b)
        b.cursor = start + new.count - 1
        st.marks["."] = start
    }

    static func scroll(_ kind: ScrollCommand, count: Int?, doc: Doc, _ st: inout VimState, _ b: inout TextBuffer, _ fx: inout VimEffect?) {
        let height = max(2, st.viewport?.height ?? 20)
        let line = doc.line(of: b.cursor)
        let col = st.desiredColumn ?? doc.column(of: b.cursor)
        if st.desiredColumn == nil { st.desiredColumn = col }
        func moveTo(_ l: Int) { b.cursor = doc.offset(line: doc.clampLine(l), column: col == Int.max ? Int.max / 2 : col) }
        switch kind {
        case .halfDown, .halfUp:
            let amount = count ?? max(1, height / 2)
            let d = kind == .halfDown ? amount : -amount
            moveTo(line + d)
            fx = .scrollLines(d)
        case .pageDown, .pageUp:
            let amount = max(1, height - 2) * max(1, count ?? 1)
            let d = kind == .pageDown ? amount : -amount
            moveTo(line + d)
            fx = .scrollLines(d)
        case .lineDown, .lineUp:
            let n = max(1, count ?? 1)
            fx = .scrollLines(kind == .lineDown ? n : -n)
            if let vp = st.viewport {
                if kind == .lineDown, line < vp.firstLine + n { moveTo(vp.firstLine + n) }
                if kind == .lineUp, line > vp.lastLine - n { moveTo(vp.lastLine - n) }
            }
        }
    }
}

/// UTF-16 offset → character offset, rounding down to a grapheme boundary.
public func characterOffset(utf16 offset: Int, in text: String) -> Int {
    let u = text.utf16
    var idx = u.index(u.startIndex, offsetBy: max(0, min(offset, u.count)))
    while idx > text.startIndex, idx.samePosition(in: text) == nil {
        idx = u.index(before: idx)
    }
    return text.distance(from: text.startIndex, to: idx)
}
