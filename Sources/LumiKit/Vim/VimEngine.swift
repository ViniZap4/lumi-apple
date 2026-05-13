import Foundation

/// Pure reducer for the vim engine. Calls into this are the only mutations
/// allowed on `VimState` and `TextBuffer`. Every transition is a function from
/// `(state, buffer, input) -> (state, buffer)`, which keeps testing trivial.
public enum VimEngine {
    public struct Result: Sendable, Hashable {
        public var state: VimState
        public var buffer: TextBuffer
        /// Side-effect requested by this input — set by ex commands (`:w` etc.).
        /// The host consumes it via `VimController.onEffect` and the engine
        /// produces a fresh nil on the next input. Effects do not persist
        /// across `handle` calls.
        public var effect: VimEffect?

        public init(state: VimState, buffer: TextBuffer, effect: VimEffect? = nil) {
            self.state = state
            self.buffer = buffer
            self.effect = effect
        }
    }

    public static func handle(_ input: VimInput, state: VimState, buffer: TextBuffer) -> Result {
        // During a `.` replay, bypass recording entirely so the replay can't
        // clobber `lastChange` with the inputs it's replaying.
        if state.isReplaying {
            return dispatch(input, state: state, buffer: buffer)
        }

        var preState = state
        // Macro recording: capture every input while a macro is being recorded.
        // Skipped during macro playback so the played inputs don't get re-captured
        // by an outer recording session.
        if preState.recordingMacro != nil, !preState.isPlayingMacro {
            preState.recordingMacroInputs.append(input)
        }

        let beforeFresh = isFreshNormal(preState)
        if beforeFresh {
            preState.recordingInputs = [input]
            preState.recordingBaseline = buffer.text
        } else {
            preState.recordingInputs.append(input)
        }

        var result = dispatch(input, state: preState, buffer: buffer)
        let afterFresh = isFreshNormal(result.state)

        if afterFresh {
            // Sequence ended. Commit if any handler left recording intact and
            // the buffer actually changed during the sequence. Meta-commands
            // (undo, redo, dot replay) deliberately clear recordingInputs to
            // skip the commit.
            if !result.state.recordingInputs.isEmpty,
               let baseline = result.state.recordingBaseline,
               baseline != result.buffer.text
            {
                result.state.lastChange = result.state.recordingInputs
            }
            result.state.recordingInputs = []
            result.state.recordingBaseline = nil
        }
        return result
    }

    private static func dispatch(_ input: VimInput, state: VimState, buffer: TextBuffer) -> Result {
        switch state.mode {
        case .normal:
            return handleNormal(input: input, state: state, buffer: buffer)
        case .insert:
            return handleInsert(input: input, state: state, buffer: buffer)
        case .visual:
            return handleVisual(input: input, state: state, buffer: buffer)
        case .commandLine:
            return handleCommandLine(input: input, state: state, buffer: buffer)
        }
    }

    private static func isFreshNormal(_ state: VimState) -> Bool {
        state.mode == .normal &&
            state.pendingOperator == nil &&
            state.pendingTextObjectKind == nil &&
            state.pendingFindKind == nil &&
            state.pendingCount == nil &&
            state.pendingRegister == nil &&
            !state.awaitingRegisterChar &&
            !state.awaitingMarkSet &&
            !state.awaitingMarkJumpLine &&
            !state.awaitingMarkJumpExact &&
            !state.awaitingGG &&
            !state.awaitingMacroRegister &&
            !state.awaitingMacroPlay
    }

    // MARK: Normal mode

    private static func handleNormal(input: VimInput, state: VimState, buffer: TextBuffer) -> Result {
        var state = state
        var buffer = buffer

        switch input {
        case .escape:
            state.pendingCount = nil
            state.pendingOperator = nil
            state.pendingTextObjectKind = nil
            state.pendingFindKind = nil
            state.pendingRegister = nil
            state.awaitingRegisterChar = false
            state.awaitingMarkSet = false
            state.awaitingMarkJumpLine = false
            state.awaitingMarkJumpExact = false
            state.awaitingGG = false
            state.awaitingMacroRegister = false
            state.awaitingMacroPlay = false
            return Result(state: state, buffer: buffer)

        case .return:
            // <Enter> in normal mode = down-then-first-non-blank
            buffer.cursor = Motion.down.resolve(in: buffer, count: state.effectiveCount)
            buffer.cursor = Motion.lineFirstNonBlank.resolve(in: buffer, count: 1)
            state.pendingCount = nil
            return clamp(state: state, buffer: buffer)

        case .backspace:
            // <BS> in normal = h
            buffer.cursor = Motion.left.resolve(in: buffer, count: state.effectiveCount)
            state.pendingCount = nil
            return clamp(state: state, buffer: buffer)

        case .tab:
            return Result(state: state, buffer: buffer)

        case .controlR:
            return redo(state: state, buffer: buffer)

        case .historyPrev, .historyNext:
            // Arrow-key history navigation is only meaningful inside
            // command-line mode. The UI bridge re-maps up/down to .character
            // outside command-line, so these shouldn't fire here in practice;
            // ignore defensively if they do.
            return Result(state: state, buffer: buffer)

        case let .character(char):
            return handleNormalCharacter(char, state: state, buffer: buffer)
        }
    }

    private static func handleNormalCharacter(
        _ char: Character,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer

        // Macro recording stop: `q` while recording finalizes the macro. Must
        // run before any other handler so `q` isn't interpreted as a normal key.
        if char == "q", state.recordingMacro != nil {
            return finalizeMacroRecording(state: state, buffer: buffer)
        }

        // Awaiting macro register name (after first `q`).
        if state.awaitingMacroRegister {
            state.awaitingMacroRegister = false
            if char.isLetter {
                state.recordingMacro = char
                state.recordingMacroInputs = []
            }
            return Result(state: state, buffer: buffer)
        }

        // Awaiting macro playback target (after `@`).
        if state.awaitingMacroPlay {
            state.awaitingMacroPlay = false
            let count = state.effectiveCount
            state.pendingCount = nil
            if char == "@" {
                if let last = state.lastPlayedMacro {
                    return playMacro(name: last, count: count, state: state, buffer: buffer)
                }
                return Result(state: state, buffer: buffer)
            }
            if char.isLetter {
                return playMacro(name: char, count: count, state: state, buffer: buffer)
            }
            return Result(state: state, buffer: buffer)
        }

        // Awaiting find target (after f/F/t/T): consume this char as the target.
        if let findKind = state.pendingFindKind {
            return resolveFind(findKind: findKind, target: char, state: state, buffer: buffer)
        }

        // Awaiting text object selector (after operator + i/a, or visual + i/a):
        // consume this char as the object marker.
        if let toKind = state.pendingTextObjectKind {
            return resolveTextObject(char: char, kind: toKind, state: state, buffer: buffer)
        }

        // Register prefix: after `"`, the next char names the register.
        if state.awaitingRegisterChar {
            state.awaitingRegisterChar = false
            if isValidRegister(char) {
                state.pendingRegister = char
            }
            return Result(state: state, buffer: buffer)
        }

        // Mark commands: m sets, ' jumps to line, ` jumps to exact position.
        if state.awaitingMarkSet {
            state.awaitingMarkSet = false
            if isValidMark(char) {
                state.marks[char] = buffer.cursor
            }
            return Result(state: state, buffer: buffer)
        }
        if state.awaitingMarkJumpLine {
            state.awaitingMarkJumpLine = false
            return resolveMarkJump(name: char, exact: false, state: state, buffer: buffer)
        }
        if state.awaitingMarkJumpExact {
            state.awaitingMarkJumpExact = false
            return resolveMarkJump(name: char, exact: true, state: state, buffer: buffer)
        }

        // Two-key motion `gg` (file start). After first `g`, the next char
        // is checked here.
        if state.awaitingGG {
            state.awaitingGG = false
            if char == "g" {
                if let pending = state.pendingOperator {
                    state.pendingOperator = nil
                    state.pendingCount = nil
                    return applyOperator(pending.op, motion: .fileStart, count: 1, state: state, buffer: buffer)
                }
                buffer.cursor = 0
                state.pendingCount = nil
                return clamp(state: state, buffer: buffer)
            }
            // Different char — fall through and process normally.
        }

        // Counts: leading digits accumulate. "0" alone is the line-start motion;
        // "0" after digits is part of the count.
        if char.isASCII, char.isNumber, !(char == "0" && state.pendingCount == nil) {
            let digit = Int(String(char)) ?? 0
            state.pendingCount = (state.pendingCount ?? 0) * 10 + digit
            return Result(state: state, buffer: buffer)
        }

        let count = state.pendingCount ?? 1

        // If an operator is pending, this character should resolve it.
        if let pending = state.pendingOperator {
            // Doubled operator (`dd`, `yy`, `cc`) — line-wise.
            if char == operatorChar(for: pending.op) {
                state.pendingOperator = nil
                state.pendingCount = nil
                return applyLinewiseOperator(pending.op, lineCount: count * pending.count, state: state, buffer: buffer)
            }
            // Text object suffix start: `i` (inner) or `a` (around).
            if char == "i" {
                state.pendingTextObjectKind = .inner
                return Result(state: state, buffer: buffer)
            }
            if char == "a" {
                state.pendingTextObjectKind = .around
                return Result(state: state, buffer: buffer)
            }
            // Find/till as motion: dfx, dt;, df., …
            if let findKind = FindKind.from(char: char) {
                state.pendingFindKind = findKind
                return Result(state: state, buffer: buffer)
            }
            // Find-repeat (;) or reverse-repeat (,) as motion under operator.
            if char == ";" || char == "," {
                return resolveFindRepeat(char: char, state: state, buffer: buffer)
            }
            // Search as motion: d/foo<CR>, d?foo<CR>. Keep pendingOperator and
            // pendingCount intact — `handleCommandLine` consumes them on Enter.
            // Snapshot cursor for incsearch + operator anchor.
            if char == "/" || char == "?" {
                state.mode = .commandLine(prefix: char, buffer: "")
                state.commandLineEntryCursor = buffer.cursor
                return Result(state: state, buffer: buffer)
            }
            // Search-repeat as motion under operator: dn, dN.
            if char == "n" || char == "N" {
                return resolveSearchRepeat(char: char, state: state, buffer: buffer)
            }
            // Mark jump as motion under operator: d'a, d`a.
            if char == "'" {
                state.awaitingMarkJumpLine = true
                return Result(state: state, buffer: buffer)
            }
            if char == "`" {
                state.awaitingMarkJumpExact = true
                return Result(state: state, buffer: buffer)
            }
            // Otherwise interpret as a motion.
            if let motion = motion(for: char) {
                state.pendingOperator = nil
                state.pendingCount = nil
                return applyOperator(pending.op, motion: motion, count: count * pending.count, state: state, buffer: buffer)
            }
            // Unknown follow-up — cancel the pending op.
            state.pendingOperator = nil
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        }

        // Plain motion (no operator)
        if let motion = motion(for: char) {
            buffer.cursor = motion.resolve(in: buffer, count: count)
            state.pendingCount = nil
            return clamp(state: state, buffer: buffer)
        }

        // Find/till as a cursor motion (no operator pending).
        if let findKind = FindKind.from(char: char) {
            state.pendingFindKind = findKind
            return Result(state: state, buffer: buffer)
        }
        // Find-repeat (no operator).
        if char == ";" || char == "," {
            return resolveFindRepeat(char: char, state: state, buffer: buffer)
        }
        // Search entry (no operator): `/` forward, `?` backward.
        if char == "/" || char == "?" {
            state.mode = .commandLine(prefix: char, buffer: "")
            state.commandLineEntryCursor = buffer.cursor
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        }
        // Ex command entry (no operator): `:` opens the command-line. Same
        // mode as search but with a `:` prefix; `handleCommandLine` branches on
        // it. Counts before `:` aren't supported (vim's `:` is its own beast
        // and ignores leading counts in our subset).
        if char == ":" {
            state.mode = .commandLine(prefix: char, buffer: "")
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        }
        // Search-repeat (no operator): `n` same direction, `N` reversed.
        if char == "n" || char == "N" {
            return resolveSearchRepeat(char: char, state: state, buffer: buffer)
        }

        // Operators — set pending and wait for motion.
        switch char {
        case "d": state.pendingOperator = PendingOperator(op: .delete, count: count); state.pendingCount = nil
        case "c": state.pendingOperator = PendingOperator(op: .change, count: count); state.pendingCount = nil
        case "y": state.pendingOperator = PendingOperator(op: .yank, count: count); state.pendingCount = nil
        case "x": return applyXDelete(count: count, state: state, buffer: buffer)
        case "p": return applyPaste(after: true, count: count, state: state, buffer: buffer)
        case "P": return applyPaste(after: false, count: count, state: state, buffer: buffer)
        case "i": return enterInsert(at: buffer.cursor, state: state, buffer: buffer)
        case "I":
            let target = Motion.lineFirstNonBlank.resolve(in: buffer, count: 1)
            return enterInsert(at: target, state: state, buffer: buffer)
        case "a":
            let target = min(buffer.text.count, buffer.cursor + 1)
            return enterInsert(at: target, state: state, buffer: buffer)
        case "A":
            let line = buffer.cursorLine
            let target = buffer.lineEnd(of: line)
            return enterInsert(at: target, state: state, buffer: buffer)
        case "o":
            return openLine(below: true, state: state, buffer: buffer)
        case "O":
            return openLine(below: false, state: state, buffer: buffer)
        case "u":
            return undo(state: state, buffer: buffer)
        case ".":
            return replayLastChange(state: state, buffer: buffer)
        case "\"":
            state.awaitingRegisterChar = true
            return Result(state: state, buffer: buffer)
        case "m":
            state.awaitingMarkSet = true
            return Result(state: state, buffer: buffer)
        case "'":
            state.awaitingMarkJumpLine = true
            return Result(state: state, buffer: buffer)
        case "`":
            state.awaitingMarkJumpExact = true
            return Result(state: state, buffer: buffer)
        case "v":
            state.mode = .visual(.characterwise, anchor: buffer.cursor)
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        case "V":
            state.mode = .visual(.linewise, anchor: buffer.cursor)
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        case "g":
            state.awaitingGG = true
            return Result(state: state, buffer: buffer)
        case "q":
            state.awaitingMacroRegister = true
            return Result(state: state, buffer: buffer)
        case "@":
            state.awaitingMacroPlay = true
            return Result(state: state, buffer: buffer)
        default:
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        }
        return Result(state: state, buffer: buffer)
    }

    // MARK: Visual mode

    private static func handleVisual(input: VimInput, state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        var buffer = inBuffer
        guard case let .visual(kind, anchor) = state.mode else {
            return Result(state: state, buffer: buffer)
        }

        // Mode-independent macro stop — see handleInsert for the same guard.
        if state.recordingMacro != nil, !state.isPlayingMacro,
           case .character("q") = input {
            return finalizeMacroRecording(state: state, buffer: buffer)
        }

        switch input {
        case .escape:
            state.mode = .normal
            state.pendingCount = nil
            state.pendingOperator = nil
            return clamp(state: state, buffer: buffer)

        case .return:
            buffer.cursor = Motion.down.resolve(in: buffer, count: state.effectiveCount)
            state.pendingCount = nil
            return clamp(state: state, buffer: buffer)

        case .backspace:
            buffer.cursor = Motion.left.resolve(in: buffer, count: state.effectiveCount)
            state.pendingCount = nil
            return clamp(state: state, buffer: buffer)

        case .tab, .controlR, .historyPrev, .historyNext:
            return Result(state: state, buffer: buffer)

        case let .character(char):
            // Awaiting find target (visual + f/F/t/T): consume as target.
            if let findKind = state.pendingFindKind {
                return resolveFindInVisual(findKind: findKind, target: char, state: state, buffer: buffer)
            }
            // Awaiting text object selector (visual + i/a): consume as object marker.
            if let toKind = state.pendingTextObjectKind {
                return resolveTextObjectInVisual(char: char, kind: toKind, state: state, buffer: buffer)
            }
            // Register prefix in visual mode: `"<letter>y` etc.
            if state.awaitingRegisterChar {
                state.awaitingRegisterChar = false
                if isValidRegister(char) {
                    state.pendingRegister = char
                }
                return Result(state: state, buffer: buffer)
            }
            if char == "\"" {
                state.awaitingRegisterChar = true
                return Result(state: state, buffer: buffer)
            }

            // Counts (digit prefix; bare 0 is line-start motion).
            if char.isASCII, char.isNumber, !(char == "0" && state.pendingCount == nil) {
                let digit = Int(String(char)) ?? 0
                state.pendingCount = (state.pendingCount ?? 0) * 10 + digit
                return Result(state: state, buffer: buffer)
            }
            let count = state.pendingCount ?? 1

            // Text object trigger: `i` or `a` in visual sets pending kind.
            if char == "i" {
                state.pendingTextObjectKind = .inner
                return Result(state: state, buffer: buffer)
            }
            if char == "a" {
                state.pendingTextObjectKind = .around
                return Result(state: state, buffer: buffer)
            }

            // Find/till in visual mode.
            if let findKind = FindKind.from(char: char) {
                state.pendingFindKind = findKind
                return Result(state: state, buffer: buffer)
            }
            // Find-repeat in visual mode.
            if char == ";" || char == "," {
                return resolveFindRepeatInVisual(char: char, state: state, buffer: buffer)
            }

            // Visual mode toggles
            if char == "v" {
                if kind == .characterwise {
                    state.mode = .normal
                    state.pendingCount = nil
                    return clamp(state: state, buffer: buffer)
                }
                state.mode = .visual(.characterwise, anchor: anchor)
                state.pendingCount = nil
                return Result(state: state, buffer: buffer)
            }
            if char == "V" {
                if kind == .linewise {
                    state.mode = .normal
                    state.pendingCount = nil
                    return clamp(state: state, buffer: buffer)
                }
                state.mode = .visual(.linewise, anchor: anchor)
                state.pendingCount = nil
                return Result(state: state, buffer: buffer)
            }

            // Swap anchor and cursor.
            if char == "o" {
                let newAnchor = buffer.cursor
                buffer.cursor = anchor
                state.mode = .visual(kind, anchor: newAnchor)
                state.pendingCount = nil
                return clamp(state: state, buffer: buffer)
            }

            // Operators consume the selection and exit visual mode.
            if let op = visualOperator(for: char) {
                return applyVisualOperator(
                    op,
                    kind: kind,
                    anchor: anchor,
                    state: state,
                    buffer: buffer
                )
            }

            // Motions extend selection.
            if let motion = motion(for: char) {
                buffer.cursor = motion.resolve(in: buffer, count: count)
                state.pendingCount = nil
                return clamp(state: state, buffer: buffer)
            }

            return Result(state: state, buffer: buffer)
        }
    }

    private static func visualOperator(for char: Character) -> VimOperator? {
        switch char {
        case "d", "x": return .delete
        case "c", "s": return .change
        case "y": return .yank
        default: return nil
        }
    }

    private static func applyVisualOperator(
        _ op: VimOperator,
        kind: VimMode.VisualKind,
        anchor: Int,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer

        let from = min(anchor, buffer.cursor)
        let to = max(anchor, buffer.cursor)

        switch kind {
        case .characterwise:
            let upper = min(to + 1, buffer.text.count)
            let yanked = String(buffer.text[
                buffer.text.index(buffer.text.startIndex, offsetBy: from)
                ..<
                buffer.text.index(buffer.text.startIndex, offsetBy: upper)
            ])
            writeRegister(text: yanked, kind: .characterwise, state: &state)

            switch op {
            case .yank:
                buffer.cursor = from
                state.mode = .normal
                state.pendingCount = nil
                return clamp(state: state, buffer: buffer)
            case .delete, .change:
                state.history.push(.init(buffer: buffer))
                buffer.text.removeSubrange(
                    buffer.text.index(buffer.text.startIndex, offsetBy: from)
                    ..<
                    buffer.text.index(buffer.text.startIndex, offsetBy: upper)
                )
                buffer.cursor = from
                state.mode = (op == .change) ? .insert : .normal
                state.pendingCount = nil
                return clamp(state: state, buffer: buffer)
            }

        case .linewise:
            let firstLine = min(lineForOffset(buffer: buffer, offset: anchor), buffer.cursorLine)
            let lastLine = max(lineForOffset(buffer: buffer, offset: anchor), buffer.cursorLine)
            let fromOffset = buffer.lineStart(of: firstLine)
            var toOffset = buffer.lineEnd(of: lastLine)
            if toOffset < buffer.text.count {
                toOffset += 1
            } else if fromOffset > 0 {
                state.mode = (op == .change) ? .insert : .normal
                state.pendingCount = nil
                return applyLinewiseRange(op, fromOffset: fromOffset - 1, toOffset: toOffset, state: state, buffer: buffer)
            }
            state.mode = (op == .change) ? .insert : .normal
            state.pendingCount = nil
            return applyLinewiseRange(op, fromOffset: fromOffset, toOffset: toOffset, state: state, buffer: buffer)
        }
    }

    private static func lineForOffset(buffer: TextBuffer, offset: Int) -> Int {
        var b = buffer
        b.cursor = max(0, min(offset, b.text.count))
        return b.cursorLine
    }

    // MARK: Macros

    /// Depth limit for nested macro playback. Each level adds several Swift
    /// call frames (handle → dispatch → handleNormalCharacter → playMacro)
    /// plus a copy of `VimState` (which now carries dictionaries), so we keep
    /// this small.
    private static let macroDepthLimit = 5

    private static func finalizeMacroRecording(state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        guard let regName = state.recordingMacro else {
            return Result(state: state, buffer: inBuffer)
        }
        var inputs = state.recordingMacroInputs
        // The wrapper just appended this `q`; trim it from the saved sequence.
        if !inputs.isEmpty {
            inputs.removeLast()
        }
        state.macros[regName] = inputs
        state.recordingMacro = nil
        state.recordingMacroInputs = []
        return Result(state: state, buffer: inBuffer)
    }

    private static func playMacro(
        name: Character,
        count: Int,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        guard let inputs = state.macros[name], !inputs.isEmpty else {
            // Even an empty/nonexistent macro records as the last-played name
            // so `@@` works after a missed name.
            state.lastPlayedMacro = name
            return Result(state: state, buffer: buffer)
        }
        if state.macroDepth >= macroDepthLimit {
            return Result(state: state, buffer: buffer)
        }
        state.lastPlayedMacro = name
        state.macroDepth += 1
        state.isPlayingMacro = true

        let times = max(1, count)
        var lastEffect: VimEffect?
        for _ in 0..<times {
            for input in inputs {
                let r = handle(input, state: state, buffer: buffer)
                state = r.state
                buffer = r.buffer
                if let e = r.effect { lastEffect = e }
                if state.macroDepth >= macroDepthLimit { break }
            }
            if state.macroDepth >= macroDepthLimit { break }
        }

        state.macroDepth = max(0, state.macroDepth - 1)
        if state.macroDepth == 0 {
            state.isPlayingMacro = false
        }
        return Result(state: state, buffer: buffer, effect: lastEffect)
    }

    // MARK: Registers + marks

    private static func isValidRegister(_ char: Character) -> Bool {
        char.isLetter
    }

    private static func isValidMark(_ char: Character) -> Bool {
        char.isLetter
    }

    /// Write `text` to the active register pair: always to the unnamed
    /// register, and additionally to a named register if a `"<letter>` prefix
    /// is pending. Consumes `pendingRegister`.
    private static func writeRegister(text: String, kind: Register.Kind, state: inout VimState) {
        let reg = Register(text: text, kind: kind)
        state.defaultRegister = reg
        if let key = state.pendingRegister {
            state.registers[key] = reg
        }
        state.pendingRegister = nil
    }

    /// Read the active register: a named one if `pendingRegister` is set,
    /// otherwise the unnamed register. Consumes `pendingRegister`.
    private static func readRegister(state: inout VimState) -> Register {
        if let key = state.pendingRegister {
            state.pendingRegister = nil
            return state.registers[key] ?? Register()
        }
        return state.defaultRegister
    }

    private static func resolveMarkJump(
        name: Character,
        exact: Bool,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let pending = state.pendingOperator
        state.pendingOperator = nil
        state.pendingCount = nil

        guard let stored = state.marks[name] else {
            return Result(state: state, buffer: buffer)
        }
        let safe = max(0, min(stored, buffer.text.count))

        // For exact (` `) jumps the target is the saved offset itself; for
        // line ('') jumps it's the start of the line containing the mark.
        var targetBuffer = buffer
        targetBuffer.cursor = safe
        let target: Int
        if exact {
            target = safe
        } else {
            target = buffer.lineStart(of: targetBuffer.cursorLine)
        }

        if let op = pending?.op {
            if exact {
                let from = min(buffer.cursor, target)
                let to = max(buffer.cursor, target)
                let upper = min(to + 1, buffer.text.count)
                return applyRangeOperator(op, fromOffset: from, toOffset: upper, state: state, buffer: buffer)
            }
            // Linewise: include both cursor's line and mark's line in full.
            let cursorLine = lineForOffset(buffer: buffer, offset: buffer.cursor)
            let markLine = lineForOffset(buffer: buffer, offset: safe)
            let firstLine = min(cursorLine, markLine)
            let lastLine = max(cursorLine, markLine)
            let lineFrom = buffer.lineStart(of: firstLine)
            var lineTo = buffer.lineEnd(of: lastLine)
            if lineTo < buffer.text.count { lineTo += 1 }
            return applyLinewiseRange(op, fromOffset: lineFrom, toOffset: lineTo, state: state, buffer: buffer)
        }

        buffer.cursor = target
        return clamp(state: state, buffer: buffer)
    }

    // MARK: Text object + find resolution

    private static func resolveTextObject(
        char: Character,
        kind: TextObjectKind,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        let buffer = inBuffer
        let pending = state.pendingOperator
        state.pendingTextObjectKind = nil
        state.pendingOperator = nil
        state.pendingCount = nil

        guard
            let textObject = TextObject.from(char: char),
            let range = textObject.resolve(in: buffer, kind: kind),
            let op = pending?.op
        else {
            return Result(state: state, buffer: buffer)
        }
        return applyRangeOperator(op, fromOffset: range.from, toOffset: range.to, state: state, buffer: buffer)
    }

    private static func resolveTextObjectInVisual(
        char: Character,
        kind: TextObjectKind,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        state.pendingTextObjectKind = nil

        guard
            let textObject = TextObject.from(char: char),
            let range = textObject.resolve(in: buffer, kind: kind),
            case let .visual(visualKind, _) = state.mode
        else {
            return Result(state: state, buffer: buffer)
        }
        // Set anchor to range start, cursor to last char of range (inclusive).
        let cursor = max(range.from, range.to - 1)
        state.mode = .visual(visualKind, anchor: range.from)
        buffer.cursor = cursor
        return clamp(state: state, buffer: buffer)
    }

    private static func resolveFind(
        findKind: FindKind,
        target: Character,
        state inState: VimState,
        buffer inBuffer: TextBuffer,
        recordAsLast: Bool = true
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let count = state.effectiveCount
        let pending = state.pendingOperator
        state.pendingFindKind = nil
        state.pendingCount = nil
        state.pendingOperator = nil

        guard let targetChar = findKind.locateTargetChar(in: buffer, target: target, count: count) else {
            return Result(state: state, buffer: buffer)
        }
        if recordAsLast {
            state.lastFind = FindMemory(kind: findKind, target: target)
        }

        if let op = pending?.op {
            let range = findKind.operatorRange(cursor: buffer.cursor, targetChar: targetChar)
            return applyRangeOperator(op, fromOffset: range.from, toOffset: range.to, state: state, buffer: buffer)
        }

        buffer.cursor = findKind.cursorPosition(ofTargetChar: targetChar)
        return clamp(state: state, buffer: buffer)
    }

    private static func resolveFindInVisual(
        findKind: FindKind,
        target: Character,
        state inState: VimState,
        buffer inBuffer: TextBuffer,
        recordAsLast: Bool = true
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let count = state.effectiveCount
        state.pendingFindKind = nil
        state.pendingCount = nil

        guard let targetChar = findKind.locateTargetChar(in: buffer, target: target, count: count) else {
            return Result(state: state, buffer: buffer)
        }
        if recordAsLast {
            state.lastFind = FindMemory(kind: findKind, target: target)
        }
        buffer.cursor = findKind.cursorPosition(ofTargetChar: targetChar)
        return clamp(state: state, buffer: buffer)
    }

    /// Resolve `;` or `,` against the most recent find. `;` repeats with the
    /// same direction; `,` reverses it. Recording is suppressed so the
    /// memory still reflects the original find direction.
    private static func resolveFindRepeat(
        char: Character,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        let buffer = inBuffer
        guard let last = state.lastFind else {
            state.pendingOperator = nil
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        }
        let kind = (char == ",") ? last.kind.reversed : last.kind
        return resolveFind(findKind: kind, target: last.target, state: state, buffer: buffer, recordAsLast: false)
    }

    // MARK: Command-line mode (search; ex commands later)

    private static func handleCommandLine(input: VimInput, state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        var buffer = inBuffer
        guard case let .commandLine(prefix, currentBuffer) = state.mode else {
            return Result(state: state, buffer: buffer)
        }

        switch input {
        case .escape:
            // Cancel: restore cursor to where the user pressed `/` or `?`,
            // drop any pending operator/count, return to normal.
            if let snap = state.commandLineEntryCursor {
                buffer.cursor = snap
            }
            state.commandLineEntryCursor = nil
            state.commandLineHistoryIndex = nil
            state.commandLineHistoryDraft = nil
            state.mode = .normal
            state.pendingOperator = nil
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)

        case .backspace:
            if currentBuffer.isEmpty {
                // Backspace on an empty pattern exits command-line mode (real
                // vim behavior), also cancelling any pending operator and
                // restoring the entry cursor.
                if let snap = state.commandLineEntryCursor {
                    buffer.cursor = snap
                }
                state.commandLineEntryCursor = nil
                state.commandLineHistoryIndex = nil
                state.commandLineHistoryDraft = nil
                state.mode = .normal
                state.pendingOperator = nil
                state.pendingCount = nil
                return Result(state: state, buffer: buffer)
            }
            var newBuffer = currentBuffer
            newBuffer.removeLast()
            state.mode = .commandLine(prefix: prefix, buffer: newBuffer)
            // Editing the buffer after walking history ends the walk —
            // subsequent <up> starts over from this new draft.
            state.commandLineHistoryIndex = nil
            state.commandLineHistoryDraft = nil
            updateIncrementalPreview(prefix: prefix, pattern: newBuffer, state: &state, buffer: &buffer)
            return Result(state: state, buffer: buffer)

        case .return:
            // Execute. Branch on the prefix: `:` is an ex command (no buffer
            // motion, may emit a host effect); `/` and `?` are search.
            state.mode = .normal
            state.commandLineHistoryIndex = nil
            state.commandLineHistoryDraft = nil

            if prefix == ":" {
                state.pendingOperator = nil
                state.pendingCount = nil
                appendToCommandLineHistory(currentBuffer, prefix: prefix, state: &state)
                switch parseExCommand(currentBuffer) {
                case .effect(let e):
                    return Result(state: state, buffer: buffer, effect: e)
                case .noHighlight:
                    state.hlsearchSuspended = true
                    return Result(state: state, buffer: buffer)
                case nil:
                    return Result(state: state, buffer: buffer)
                }
            }

            // Search: restore cursor to the snapshot before resolving so
            // (a) the search runs from the original position, and (b) any
            // pending operator's range is anchored at the snapshot, not the
            // live-preview position.
            if let snap = state.commandLineEntryCursor {
                buffer.cursor = snap
            }
            state.commandLineEntryCursor = nil

            // Record the typed pattern (or the empty buffer + reuse case) in
            // search history. Empty buffers don't pollute the ring.
            appendToCommandLineHistory(currentBuffer, prefix: prefix, state: &state)

            let direction: SearchDirection = (prefix == "?") ? .backward : .forward
            if currentBuffer.isEmpty {
                guard let last = state.lastSearch else {
                    state.pendingOperator = nil
                    state.pendingCount = nil
                    return Result(state: state, buffer: buffer)
                }
                return resolveSearch(direction: direction, pattern: last.pattern, state: state, buffer: buffer)
            }
            return resolveSearch(direction: direction, pattern: currentBuffer, state: state, buffer: buffer)

        case .tab, .controlR:
            // Ignored while typing a pattern.
            return Result(state: state, buffer: buffer)

        case .historyPrev:
            return walkHistory(forward: false, prefix: prefix, currentBuffer: currentBuffer, state: state, buffer: buffer)

        case .historyNext:
            return walkHistory(forward: true, prefix: prefix, currentBuffer: currentBuffer, state: state, buffer: buffer)

        case let .character(char):
            var newBuffer = currentBuffer
            newBuffer.append(char)
            state.mode = .commandLine(prefix: prefix, buffer: newBuffer)
            // Typing ends a history walk — see comment in `.backspace`.
            state.commandLineHistoryIndex = nil
            state.commandLineHistoryDraft = nil
            updateIncrementalPreview(prefix: prefix, pattern: newBuffer, state: &state, buffer: &buffer)
            return Result(state: state, buffer: buffer)
        }
    }

    /// Append `entry` to the appropriate history ring. Skips empty strings and
    /// duplicates of the most recent entry; caps the ring at
    /// `VimState.commandLineHistoryLimit`.
    private static func appendToCommandLineHistory(_ entry: String, prefix: Character, state: inout VimState) {
        guard !entry.isEmpty else { return }
        switch prefix {
        case ":":
            guard state.exHistory.last != entry else { return }
            state.exHistory.append(entry)
            if state.exHistory.count > VimState.commandLineHistoryLimit {
                state.exHistory.removeFirst(state.exHistory.count - VimState.commandLineHistoryLimit)
            }
        case "/", "?":
            guard state.searchHistory.last != entry else { return }
            state.searchHistory.append(entry)
            if state.searchHistory.count > VimState.commandLineHistoryLimit {
                state.searchHistory.removeFirst(state.searchHistory.count - VimState.commandLineHistoryLimit)
            }
        default:
            break
        }
    }

    private static func commandLineHistory(for prefix: Character, state: VimState) -> [String] {
        switch prefix {
        case ":": return state.exHistory
        case "/", "?": return state.searchHistory
        default: return []
        }
    }

    /// Step the history cursor older (forward: false) or newer (forward: true).
    /// On the first older-step we snapshot the user's draft so a newer-step
    /// past the most recent entry can restore it.
    private static func walkHistory(
        forward: Bool,
        prefix: Character,
        currentBuffer: String,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let history = commandLineHistory(for: prefix, state: state)
        guard !history.isEmpty else {
            return Result(state: state, buffer: buffer)
        }

        let newIndex: Int?
        if forward {
            guard let idx = state.commandLineHistoryIndex else {
                // Not walking; <down> is a no-op (vim shows an empty drafted
                // buffer, but since we never started walking there's nothing
                // to step toward).
                return Result(state: state, buffer: buffer)
            }
            if idx >= history.count - 1 {
                newIndex = nil // walked past newest → restore draft
            } else {
                newIndex = idx + 1
            }
        } else {
            if let idx = state.commandLineHistoryIndex {
                if idx > 0 {
                    newIndex = idx - 1
                } else {
                    return Result(state: state, buffer: buffer) // already at oldest
                }
            } else {
                // First <up>: snapshot draft, jump to most recent.
                state.commandLineHistoryDraft = currentBuffer
                newIndex = history.count - 1
            }
        }

        let displayed: String
        if let idx = newIndex {
            displayed = history[idx]
            state.commandLineHistoryIndex = idx
        } else {
            displayed = state.commandLineHistoryDraft ?? ""
            state.commandLineHistoryIndex = nil
            state.commandLineHistoryDraft = nil
        }
        state.mode = .commandLine(prefix: prefix, buffer: displayed)
        updateIncrementalPreview(prefix: prefix, pattern: displayed, state: &state, buffer: &buffer)
        return Result(state: state, buffer: buffer)
    }

    /// Incsearch live preview. Called whenever the pattern buffer changes
    /// (char append or backspace) while in command-line search mode. Always
    /// runs the search from the snapshot cursor — never the previous preview
    /// position — so each keystroke is an idempotent function of the pattern.
    /// On empty pattern or no match: cursor returns to the snapshot.
    /// `:` ex commands skip this entirely.
    private static func updateIncrementalPreview(
        prefix: Character,
        pattern: String,
        state: inout VimState,
        buffer: inout TextBuffer
    ) {
        guard prefix == "/" || prefix == "?",
              let snap = state.commandLineEntryCursor
        else { return }

        // Restart every preview from the entry position.
        buffer.cursor = snap
        guard !pattern.isEmpty else { return }

        let direction: SearchDirection = (prefix == "?") ? .backward : .forward
        if let range = nextMatch(in: buffer.text, pattern: pattern, from: snap, direction: direction) {
            buffer.cursor = range.lowerBound
        }
    }

    /// Execute a search. Honors `state.effectiveCount` (repeats the jump N
    /// times). On success, updates `lastSearch` (unless `recordAsLast == false`,
    /// used by `n`/`N` so they don't clobber the original direction). On
    /// failure (no match or bad regex), leaves cursor unchanged and clears any
    /// pending operator/count.
    private static func resolveSearch(
        direction: SearchDirection,
        pattern: String,
        state inState: VimState,
        buffer inBuffer: TextBuffer,
        recordAsLast: Bool = true
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let count = state.effectiveCount
        let pending = state.pendingOperator
        state.pendingOperator = nil
        state.pendingCount = nil

        var matchRange: Range<Int>?
        var fromOffset = buffer.cursor
        for _ in 0..<max(1, count) {
            guard let r = nextMatch(in: buffer.text, pattern: pattern, from: fromOffset, direction: direction) else {
                matchRange = nil
                break
            }
            matchRange = r
            fromOffset = r.lowerBound
        }

        guard let range = matchRange else {
            return Result(state: state, buffer: buffer)
        }
        if recordAsLast {
            state.lastSearch = SearchMemory(pattern: pattern, direction: direction)
        }
        // Any successful search reactivates hlsearch (matches vim's behavior
        // where `n` / `N` / `/foo` after `:noh` bring highlighting back).
        state.hlsearchSuspended = false

        if let op = pending?.op {
            // Operator range: from cursor to match start (or vice versa for
            // backward search). Characterwise — same semantics as vim's `d/`.
            let from = min(buffer.cursor, range.lowerBound)
            let to = max(buffer.cursor, range.lowerBound)
            return applyRangeOperator(op, fromOffset: from, toOffset: to, state: state, buffer: buffer)
        }

        buffer.cursor = range.lowerBound
        return clamp(state: state, buffer: buffer)
    }

    /// Parsed `:` command. Some are external effects the host must carry out
    /// (`:w` → save), others are pure engine-state mutations (`:noh` →
    /// suspend hlsearch). Unknown / empty input → nil at the parser level.
    private enum ExCommand: Sendable, Hashable {
        case effect(VimEffect)
        case noHighlight
    }

    /// Parse the buffer of a `:` command-line. Whitespace is trimmed. Bang
    /// variants (`:q!`, `:w!`, `:wq!`) emit force-flagged effects. Unknown
    /// commands → nil (silent no-op, same as a bad search regex).
    private static func parseExCommand(_ buffer: String) -> ExCommand? {
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "w": return .effect(.save(force: false))
        case "w!": return .effect(.save(force: true))
        case "wq", "x": return .effect(.saveAndClose(force: false))
        case "wq!", "x!": return .effect(.saveAndClose(force: true))
        case "q": return .effect(.close(force: false))
        case "q!": return .effect(.close(force: true))
        case "noh", "nohl", "nohlsearch": return .noHighlight
        default: return nil
        }
    }

    /// Resolve `n` or `N` against `lastSearch`. `n` repeats in the original
    /// direction; `N` flips it. `recordAsLast: false` so the memory's direction
    /// isn't perturbed by an `N`.
    private static func resolveSearchRepeat(
        char: Character,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        let buffer = inBuffer
        guard let last = state.lastSearch else {
            state.pendingOperator = nil
            state.pendingCount = nil
            return Result(state: state, buffer: buffer)
        }
        let direction: SearchDirection = (char == "N") ? last.direction.reversed : last.direction
        return resolveSearch(direction: direction, pattern: last.pattern, state: state, buffer: buffer, recordAsLast: false)
    }

    private static func resolveFindRepeatInVisual(
        char: Character,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        let state = inState
        let buffer = inBuffer
        guard let last = state.lastFind else { return Result(state: state, buffer: buffer) }
        let kind = (char == ",") ? last.kind.reversed : last.kind
        return resolveFindInVisual(findKind: kind, target: last.target, state: state, buffer: buffer, recordAsLast: false)
    }

    private static func applyRangeOperator(
        _ op: VimOperator,
        fromOffset: Int,
        toOffset: Int,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let from = max(0, min(fromOffset, buffer.text.count))
        let to = max(from, min(toOffset, buffer.text.count))

        let yanked = String(buffer.text[
            buffer.text.index(buffer.text.startIndex, offsetBy: from)
            ..<
            buffer.text.index(buffer.text.startIndex, offsetBy: to)
        ])
        writeRegister(text: yanked, kind: .characterwise, state: &state)

        switch op {
        case .yank:
            buffer.cursor = from
            return clamp(state: state, buffer: buffer)
        case .delete, .change:
            state.history.push(.init(buffer: buffer))
            buffer.text.removeSubrange(
                buffer.text.index(buffer.text.startIndex, offsetBy: from)
                ..<
                buffer.text.index(buffer.text.startIndex, offsetBy: to)
            )
            buffer.cursor = from
            if op == .change {
                state.mode = .insert
            }
            return clamp(state: state, buffer: buffer)
        }
    }

    // MARK: Insert mode

    private static func handleInsert(input: VimInput, state: VimState, buffer: TextBuffer) -> Result {
        var state = state
        var buffer = buffer

        // Mode-independent macro stop: `q` while recording finalizes regardless
        // of mode. The wrapper just appended this `q` to recordingMacroInputs,
        // and `finalizeMacroRecording` trims it. Gated on `!isPlayingMacro` so
        // a played-back `q` doesn't accidentally stop an outer recording.
        if state.recordingMacro != nil, !state.isPlayingMacro,
           case .character("q") = input {
            return finalizeMacroRecording(state: state, buffer: buffer)
        }

        switch input {
        case .escape:
            state.insertModeLastWasJ = false
            state.mode = .normal
            // vim convention: cursor steps left when leaving insert (unless at line start)
            let line = buffer.cursorLine
            let lineStart = buffer.lineStart(of: line)
            if buffer.cursor > lineStart {
                buffer.cursor -= 1
            }
            return clamp(state: state, buffer: buffer)

        case .return:
            insertString("\n", state: &state, buffer: &buffer)
            state.insertModeLastWasJ = false
            return Result(state: state, buffer: buffer)

        case .backspace:
            if buffer.cursor > 0 {
                let idx = buffer.text.index(buffer.text.startIndex, offsetBy: buffer.cursor)
                let before = buffer.text.index(before: idx)
                buffer.text.removeSubrange(before..<idx)
                buffer.cursor -= 1
            }
            state.insertModeLastWasJ = false
            return Result(state: state, buffer: buffer)

        case .tab:
            insertString("\t", state: &state, buffer: &buffer)
            state.insertModeLastWasJ = false
            return Result(state: state, buffer: buffer)

        case .controlR, .character:
            if case let .character(char) = input {
                // jj → Esc mapping. Only fires when the user has opted in
                // via `state.jjEscapeEnabled`, and only when the previous
                // input also inserted a literal `j` immediately before.
                // Removes the buffered first `j` and exits insert mode
                // (with the standard cursor-step-left).
                if char == "j", state.jjEscapeEnabled, state.insertModeLastWasJ {
                    // Drop the previous `j` (the one this handler inserted
                    // last call). Cursor sits right after it, so step back
                    // and remove the preceding character.
                    if buffer.cursor > 0 {
                        let idx = buffer.text.index(buffer.text.startIndex, offsetBy: buffer.cursor)
                        let before = buffer.text.index(before: idx)
                        buffer.text.removeSubrange(before..<idx)
                        buffer.cursor -= 1
                    }
                    state.mode = .normal
                    state.insertModeLastWasJ = false
                    // Vim's normal-cursor-after-insert convention: keep
                    // the cursor where it lands. Matches the existing
                    // .escape branch, except we don't step left again
                    // because we already removed the buffered `j`.
                    return clamp(state: state, buffer: buffer)
                }
                insertString(String(char), state: &state, buffer: &buffer)
                state.insertModeLastWasJ = (char == "j")
            } else {
                state.insertModeLastWasJ = false
            }
            return Result(state: state, buffer: buffer)

        case .historyPrev, .historyNext:
            state.insertModeLastWasJ = false
            return Result(state: state, buffer: buffer)
        }
    }

    private static func insertString(_ str: String, state: inout VimState, buffer: inout TextBuffer) {
        let idx = buffer.text.index(buffer.text.startIndex, offsetBy: min(buffer.cursor, buffer.text.count))
        buffer.text.insert(contentsOf: str, at: idx)
        buffer.cursor += str.count
    }

    // MARK: Operators

    private static func applyOperator(
        _ op: VimOperator,
        motion: Motion,
        count: Int,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer

        // Special: gg (handled via the sentinel above) — turn fileStart into linewise.
        let target = motion.resolve(in: buffer, count: count)
        let from = min(buffer.cursor, target)
        let to = max(buffer.cursor, target)

        let upper = motion.isInclusive ? min(to + 1, buffer.text.count) : to

        if motion.isLinewise {
            return applyLinewiseRange(op, fromOffset: from, toOffset: upper, state: state, buffer: buffer)
        }

        let yanked = String(buffer.text[
            buffer.text.index(buffer.text.startIndex, offsetBy: from)
            ..<
            buffer.text.index(buffer.text.startIndex, offsetBy: upper)
        ])
        writeRegister(text: yanked, kind: .characterwise, state: &state)

        switch op {
        case .yank:
            return Result(state: state, buffer: buffer)
        case .delete, .change:
            state.history.push(.init(buffer: buffer))
            buffer.text.removeSubrange(
                buffer.text.index(buffer.text.startIndex, offsetBy: from)
                ..<
                buffer.text.index(buffer.text.startIndex, offsetBy: upper)
            )
            buffer.cursor = from
            if op == .change {
                state.mode = .insert
            }
            return clamp(state: state, buffer: buffer)
        }
    }

    private static func applyLinewiseOperator(
        _ op: VimOperator,
        lineCount: Int,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        let buffer = inBuffer
        let firstLine = buffer.cursorLine
        let lastLine = min(buffer.lineCount - 1, firstLine + max(1, lineCount) - 1)
        let from = buffer.lineStart(of: firstLine)
        var to = buffer.lineEnd(of: lastLine)
        // Include trailing newline if present, so `dd` removes a whole line
        // and not just its content.
        if to < buffer.text.count {
            to += 1
        } else if from > 0 {
            // Last line — eat the preceding newline so we don't leave a stray
            // blank line above.
            return applyLinewiseRange(op, fromOffset: from - 1, toOffset: to, state: inState, buffer: buffer)
        }
        return applyLinewiseRange(op, fromOffset: from, toOffset: to, state: inState, buffer: buffer)
    }

    private static func applyLinewiseRange(
        _ op: VimOperator,
        fromOffset: Int,
        toOffset: Int,
        state inState: VimState,
        buffer inBuffer: TextBuffer
    ) -> Result {
        var state = inState
        var buffer = inBuffer
        let from = max(0, min(fromOffset, buffer.text.count))
        let to = max(from, min(toOffset, buffer.text.count))

        let yanked = String(buffer.text[
            buffer.text.index(buffer.text.startIndex, offsetBy: from)
            ..<
            buffer.text.index(buffer.text.startIndex, offsetBy: to)
        ])
        writeRegister(text: yanked, kind: .linewise, state: &state)

        switch op {
        case .yank:
            return Result(state: state, buffer: buffer)
        case .delete, .change:
            state.history.push(.init(buffer: buffer))
            buffer.text.removeSubrange(
                buffer.text.index(buffer.text.startIndex, offsetBy: from)
                ..<
                buffer.text.index(buffer.text.startIndex, offsetBy: to)
            )
            buffer.cursor = min(from, max(0, buffer.text.count - 1))
            if op == .change {
                state.mode = .insert
                // For `cc`, leave a blank line and put us into insert mode
                // at the start of it.
                let lineEnd = buffer.lineEnd(of: buffer.cursorLine)
                if buffer.cursor < lineEnd {
                    // already on existing line; nothing to add.
                }
            }
            return clamp(state: state, buffer: buffer)
        }
    }

    private static func applyXDelete(count: Int, state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        var buffer = inBuffer
        guard !buffer.text.isEmpty else { return Result(state: state, buffer: buffer) }
        state.history.push(.init(buffer: buffer))
        let from = buffer.cursor
        let to = min(buffer.text.count, from + max(1, count))
        let yanked = String(buffer.text[
            buffer.text.index(buffer.text.startIndex, offsetBy: from)
            ..<
            buffer.text.index(buffer.text.startIndex, offsetBy: to)
        ])
        writeRegister(text: yanked, kind: .characterwise, state: &state)
        buffer.text.removeSubrange(
            buffer.text.index(buffer.text.startIndex, offsetBy: from)
            ..<
            buffer.text.index(buffer.text.startIndex, offsetBy: to)
        )
        return clamp(state: state, buffer: buffer)
    }

    private static func applyPaste(after: Bool, count: Int, state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        var buffer = inBuffer
        let reg = readRegister(state: &state)
        guard !reg.text.isEmpty else { return Result(state: state, buffer: buffer) }
        state.history.push(.init(buffer: buffer))

        let times = max(1, count)
        let toInsert = String(repeating: reg.text, count: times)

        switch reg.kind {
        case .characterwise:
            let target = after ? min(buffer.text.count, buffer.cursor + 1) : buffer.cursor
            let idx = buffer.text.index(buffer.text.startIndex, offsetBy: target)
            buffer.text.insert(contentsOf: toInsert, at: idx)
            buffer.cursor = target + toInsert.count - 1
        case .linewise:
            let line = buffer.cursorLine
            let target: Int
            var payload = toInsert
            if !payload.hasSuffix("\n") { payload.append("\n") }
            if after {
                target = buffer.lineEnd(of: line)
                let idx = buffer.text.index(buffer.text.startIndex, offsetBy: target)
                buffer.text.insert("\n", at: idx)
                buffer.text.insert(contentsOf: payload.dropLast(), at: buffer.text.index(buffer.text.startIndex, offsetBy: target + 1))
                buffer.cursor = target + 1
            } else {
                target = buffer.lineStart(of: line)
                let idx = buffer.text.index(buffer.text.startIndex, offsetBy: target)
                buffer.text.insert(contentsOf: payload, at: idx)
                buffer.cursor = target
            }
        }
        return clamp(state: state, buffer: buffer)
    }

    // MARK: Insert entry helpers

    private static func enterInsert(at target: Int, state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        var buffer = inBuffer
        state.history.push(.init(buffer: buffer))
        state.mode = .insert
        state.pendingCount = nil
        state.pendingOperator = nil
        buffer.cursor = max(0, min(buffer.text.count, target))
        return Result(state: state, buffer: buffer)
    }

    private static func openLine(below: Bool, state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        var buffer = inBuffer
        state.history.push(.init(buffer: buffer))
        let line = buffer.cursorLine
        if below {
            let lineEnd = buffer.lineEnd(of: line)
            let insertAt = lineEnd
            let idx = buffer.text.index(buffer.text.startIndex, offsetBy: insertAt)
            buffer.text.insert("\n", at: idx)
            buffer.cursor = insertAt + 1
        } else {
            let lineStart = buffer.lineStart(of: line)
            let idx = buffer.text.index(buffer.text.startIndex, offsetBy: lineStart)
            buffer.text.insert("\n", at: idx)
            buffer.cursor = lineStart
        }
        state.mode = .insert
        return Result(state: state, buffer: buffer)
    }

    // MARK: Undo / redo / dot

    private static func undo(state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        let current = VimHistory.Snapshot(buffer: inBuffer)
        guard let snapshot = state.history.popUndo(current: current) else {
            return Result(state: state, buffer: inBuffer)
        }
        // Undo is a meta-command: clear recording so the wrapper doesn't
        // commit the undo-induced text change as a new "last change".
        state.recordingInputs = []
        state.recordingBaseline = nil
        return clamp(state: state, buffer: snapshot.asBuffer)
    }

    private static func redo(state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        var state = inState
        let current = VimHistory.Snapshot(buffer: inBuffer)
        guard let snapshot = state.history.popRedo(current: current) else {
            return Result(state: state, buffer: inBuffer)
        }
        state.recordingInputs = []
        state.recordingBaseline = nil
        return clamp(state: state, buffer: snapshot.asBuffer)
    }

    private static func replayLastChange(state inState: VimState, buffer inBuffer: TextBuffer) -> Result {
        guard let inputs = inState.lastChange, !inputs.isEmpty else {
            return Result(state: inState, buffer: inBuffer)
        }
        var state = inState
        var buffer = inBuffer
        state.isReplaying = true
        for input in inputs {
            let r = handle(input, state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        state.isReplaying = false
        // Skip commit: dot is a meta-command. lastChange must remain the
        // original change, not `.` itself.
        state.recordingInputs = []
        state.recordingBaseline = nil
        return Result(state: state, buffer: buffer)
    }

    // MARK: Clamps + lookups

    private static func clamp(state: VimState, buffer inBuffer: TextBuffer) -> Result {
        var buffer = inBuffer
        let allowPastEnd = state.mode == .insert
        buffer.cursor = buffer.clampedCursor(allowPastEnd: allowPastEnd)
        return Result(state: state, buffer: buffer)
    }

    private static func motion(for char: Character) -> Motion? {
        switch char {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        case "w": return .wordForward
        case "b": return .wordBack
        case "e": return .wordEnd
        case "0": return .lineStart
        case "^": return .lineFirstNonBlank
        case "$": return .lineEnd
        case "G": return .fileEnd
        default: return nil
        }
    }

    private static func operatorChar(for op: VimOperator) -> Character {
        switch op {
        case .delete: return "d"
        case .change: return "c"
        case .yank: return "y"
        }
    }
}
