import Foundation

/// A motion, before it is resolved against a buffer.
enum MotionSpec: Hashable {
    case left, right, up, down
    case leftWrap        // <BS>
    case rightWrap       // <Space>
    case wordForward(big: Bool), wordBackward(big: Bool)
    case wordEnd(big: Bool), wordEndBackward(big: Bool)
    case lineStart, firstNonBlank, lineEnd, lastNonBlank, column
    case lineDown        // + <CR>
    case lineUp          // -
    case currentLine     // _
    case fileStart, fileEnd
    case find(FindKind, Character)
    case repeatFind(reverse: Bool)
    case matchPair
    case sentenceForward, sentenceBackward
    case paragraphForward, paragraphBackward
    case screenTop, screenMiddle, screenBottom
    case displayDown, displayUp
    case searchNext(reverse: Bool)
    case searchWord(forward: Bool, whole: Bool)
    case mark(Character, exact: Bool)
    case unmatched(Character)
}

/// `iw`, `a"`, `ip` …
struct TextObjectSpec: Hashable {
    var inner: Bool
    var kind: Character
}

enum InsertEntry: Hashable { case i, a, I, A, o, O, gi, gI }

enum ScrollCommand: Hashable { case halfDown, halfUp, pageDown, pageUp, lineDown, lineUp }

/// What a complete normal / visual command does.
enum NormalAction: Hashable {
    case motion(MotionSpec)
    case operatorMotion(VimOperator, MotionSpec)
    case operatorObject(VimOperator, TextObjectSpec)
    case operatorLines(VimOperator)
    case operatorSearch(VimOperator, Character)
    case objectSelect(TextObjectSpec)
    case deleteChar(forward: Bool)
    case substituteChar, substituteLine
    case deleteToEnd, changeToEnd, yankLine
    case put(after: Bool, cursorAfter: Bool)
    case join(spaces: Bool)
    case swapCaseChar
    case replaceChar(Character)
    case replaceMode
    case insert(InsertEntry)
    case undo, redo, undoLine
    case dot
    case record(Character)
    case stopRecord
    case play(Character)
    case setMark(Character)
    case visual(VimMode.VisualKind)
    case reselect
    case cmdline
    case search(Character)
    case repeatSubstitute(allLines: Bool)
    case increment(Int)
    case scroll(ScrollCommand)
    case scrollCursor(VimScrollPosition, firstNonBlank: Bool)
    case saveQuit(save: Bool)
    case fileInfo
    case escape
    case nop
    // Visual mode only.
    case visualOperator(VimOperator)
    case visualLinewise(VimOperator)
    case visualToEnd(VimOperator)
    case swapEnds(horizontal: Bool)
    case visualInsert(append: Bool)
    case visualReplace(Character)
    case visualPut(after: Bool)
    case visualJoin(spaces: Bool)
}

struct ParsedCommand: Hashable {
    var register: Character?
    var count: Int?
    var action: NormalAction
    /// Indexes of the count digits in the key list (for `.` with a new count).
    var countIndices: [Int]
}

enum ParseResult: Hashable {
    case incomplete(VimPendingInfo.Awaiting, VimOperator?)
    case invalid
    case complete(ParsedCommand)
}

private enum MotionParse {
    case ok(MotionSpec, Int)
    case need(VimPendingInfo.Awaiting)
    case invalid
    case notMotion
}

extension VimEngine {
    static func isValidRegisterName(_ c: Character) -> Bool {
        if c.isASCII, c.isLetter || c.isNumber { return true }
        return "\"-_+*.%:/".contains(c)
    }

    static func isValidMarkName(_ c: Character) -> Bool {
        (c.isASCII && c.isLetter) || "'`[]<>.^\"".contains(c)
    }

    /// Parse the keys of a normal- or visual-mode command.
    static func parse(_ keys: [VimInput], visual: Bool, recording: Bool) -> ParseResult {
        var i = 0
        var register: Character?
        var count1: Int?
        var indices: [Int] = []
        let n = keys.count

        while i < n {
            let k = keys[i]
            if k.char == "\"" {
                guard i + 1 < n else { return .incomplete(.register, nil) }
                guard let r = keys[i + 1].char, isValidRegisterName(r) else { return .invalid }
                register = r
                i += 2
                continue
            }
            if let c = k.char, c.isASCII, let d = c.wholeNumberValue, d > 0 || count1 != nil {
                count1 = min(99_999, (count1 ?? 0) * 10 + d)
                indices.append(i)
                i += 1
                continue
            }
            break
        }
        guard i < n else { return .incomplete(.none, nil) }

        func done(_ action: NormalAction, count: Int? = count1) -> ParseResult {
            .complete(ParsedCommand(register: register, count: count, action: action, countIndices: indices))
        }

        let k = keys[i]

        // Operators (normal: wait for a motion; visual: act on the selection).
        var opInfo: (VimOperator, Int)?
        if let c = k.char {
            switch c {
            case "d": opInfo = (.delete, 1)
            case "c": opInfo = (.change, 1)
            case "y": opInfo = (.yank, 1)
            case ">": opInfo = (.shiftRight, 1)
            case "<": opInfo = (.shiftLeft, 1)
            case "=": opInfo = (.reindent, 1)
            case "g":
                guard i + 1 < n else { return .incomplete(.gPrefix, nil) }
                switch keys[i + 1].char {
                case "~": opInfo = (.swapCase, 2)
                case "u": opInfo = (.lowercase, 2)
                case "U": opInfo = (.uppercase, 2)
                case "?": opInfo = (.rot13, 2)
                default: break
                }
            default: break
            }
        }

        if visual {
            if let (op, len) = opInfo {
                guard i + len == n else { return .invalid }
                return done(.visualOperator(op))
            }
            if let c = k.char {
                switch c {
                case "x": return done(.visualOperator(.delete))
                case "s": return done(.visualOperator(.change))
                case "~": return done(.visualOperator(.swapCase))
                case "u": return done(.visualOperator(.lowercase))
                case "U": return done(.visualOperator(.uppercase))
                case "X": return done(.visualLinewise(.delete))
                case "D": return done(.visualToEnd(.delete))
                case "Y": return done(.visualLinewise(.yank))
                case "C": return done(.visualToEnd(.change))
                case "S", "R": return done(.visualLinewise(.change))
                case "J": return done(.visualJoin(spaces: true))
                case "p": return done(.visualPut(after: true))
                case "P": return done(.visualPut(after: false))
                case "I": return done(.visualInsert(append: false))
                case "A": return done(.visualInsert(append: true))
                case "o": return done(.swapEnds(horizontal: false))
                case "O": return done(.swapEnds(horizontal: true))
                case "v": return done(.visual(.characterwise))
                case "V": return done(.visual(.linewise))
                case ":": return done(.cmdline)
                case "/", "?": return done(.search(c))
                case "r":
                    guard i + 1 < n else { return .incomplete(.replaceChar, nil) }
                    guard let t = literalChar(keys[i + 1]) else { return .invalid }
                    return done(.visualReplace(t))
                case "i", "a":
                    guard i + 1 < n else { return .incomplete(.textObject, nil) }
                    guard let o = keys[i + 1].char, isTextObjectKind(o) else { return .invalid }
                    return done(.objectSelect(TextObjectSpec(inner: c == "i", kind: o)))
                case "g":
                    if i + 1 < n {
                        switch keys[i + 1].char {
                        case "v": return done(.reselect)
                        case "J": return done(.visualJoin(spaces: false))
                        default: break
                        }
                    }
                default: break
                }
            }
            if let c = k.ctrl {
                switch c {
                case "v": return done(.visual(.block))
                case "a": return done(.increment(1))
                case "x": return done(.increment(-1))
                default: break
                }
            }
            if k == .escape { return done(.escape) }
            switch parseMotion(keys, i) {
            case let .ok(m, end): return end == n ? done(.motion(m)) : .invalid
            case let .need(a): return .incomplete(a, nil)
            case .invalid, .notMotion: break
            }
            if let c = k.ctrl {
                switch c {
                case "d": return done(.scroll(.halfDown))
                case "u": return done(.scroll(.halfUp))
                case "f": return done(.scroll(.pageDown))
                case "b": return done(.scroll(.pageUp))
                case "e": return done(.scroll(.lineDown))
                case "y": return done(.scroll(.lineUp))
                default: break
                }
            }
            if k.char == "z" {
                guard i + 1 < n else { return .incomplete(.zPrefix, nil) }
                if let z = zCommand(keys[i + 1]) { return done(z) }
            }
            return .invalid
        }

        if let (op, len) = opInfo {
            var j = i + len
            var count2: Int?
            while j < n, let c = keys[j].char, c.isASCII, let d = c.wholeNumberValue, d > 0 || count2 != nil {
                count2 = min(99_999, (count2 ?? 0) * 10 + d)
                indices.append(j)
                j += 1
            }
            let total: Int? = {
                switch (count1, count2) {
                case let (a?, b?): return a * b
                case let (a?, nil): return a
                case let (nil, b?): return b
                default: return nil
                }
            }()
            guard j < n else { return .incomplete(.motion, op) }
            let m = keys[j]
            let opKeys = Array(op.keys)
            // Doubled operator: dd, >>, g~~, g~g~, guu, gUU …
            if opKeys.count == 1, m.char == opKeys[0] {
                return j + 1 == n ? done(.operatorLines(op), count: total) : .invalid
            }
            if opKeys.count == 2 {
                if m.char == opKeys[1] {
                    return j + 1 == n ? done(.operatorLines(op), count: total) : .invalid
                }
                if m.char == "g", j + 1 < n, keys[j + 1].char == opKeys[1] {
                    return j + 2 == n ? done(.operatorLines(op), count: total) : .invalid
                }
            }
            if let c = m.char, c == "i" || c == "a" {
                guard j + 1 < n else { return .incomplete(.textObject, op) }
                guard let o = keys[j + 1].char, isTextObjectKind(o) else { return .invalid }
                return j + 2 == n ? done(.operatorObject(op, TextObjectSpec(inner: c == "i", kind: o)), count: total) : .invalid
            }
            if let c = m.char, c == "/" || c == "?" {
                return j + 1 == n ? done(.operatorSearch(op, c), count: total) : .invalid
            }
            switch parseMotion(keys, j) {
            case let .ok(spec, end): return end == n ? done(.operatorMotion(op, spec), count: total) : .invalid
            case let .need(a): return .incomplete(a, op)
            case .invalid, .notMotion: return .invalid
            }
        }

        switch parseMotion(keys, i) {
        case let .ok(m, end): return end == n ? done(.motion(m)) : .invalid
        case let .need(a): return .incomplete(a, nil)
        case .invalid: return .invalid
        case .notMotion: break
        }

        func single(_ a: NormalAction) -> ParseResult { i + 1 == n ? done(a) : .invalid }

        switch k {
        case .escape: return single(.escape)
        case .delete: return single(.deleteChar(forward: true))
        case .tab: return single(.nop)
        default: break
        }

        if let c = k.ctrl {
            switch c {
            case "r": return single(.redo)
            case "a": return single(.increment(1))
            case "x": return single(.increment(-1))
            case "d": return single(.scroll(.halfDown))
            case "u": return single(.scroll(.halfUp))
            case "f": return single(.scroll(.pageDown))
            case "b": return single(.scroll(.pageUp))
            case "e": return single(.scroll(.lineDown))
            case "y": return single(.scroll(.lineUp))
            case "v", "q": return single(.visual(.block))
            case "g": return single(.fileInfo)
            default: return single(.nop)
            }
        }

        guard let c = k.char else { return .invalid }
        switch c {
        case "x": return single(.deleteChar(forward: true))
        case "X": return single(.deleteChar(forward: false))
        case "s": return single(.substituteChar)
        case "S": return single(.substituteLine)
        case "D": return single(.deleteToEnd)
        case "C": return single(.changeToEnd)
        case "Y": return single(.yankLine)
        case "p": return single(.put(after: true, cursorAfter: false))
        case "P": return single(.put(after: false, cursorAfter: false))
        case "J": return single(.join(spaces: true))
        case "~": return single(.swapCaseChar)
        case "R": return single(.replaceMode)
        case "i": return single(.insert(.i))
        case "a": return single(.insert(.a))
        case "I": return single(.insert(.I))
        case "A": return single(.insert(.A))
        case "o": return single(.insert(.o))
        case "O": return single(.insert(.O))
        case "u": return single(.undo)
        case "U": return single(.undoLine)
        case ".": return single(.dot)
        case "v": return single(.visual(.characterwise))
        case "V": return single(.visual(.linewise))
        case ":": return single(.cmdline)
        case "/", "?": return single(.search(c))
        case "&": return single(.repeatSubstitute(allLines: false))
        case "r":
            guard i + 1 < n else { return .incomplete(.replaceChar, nil) }
            guard let t = literalChar(keys[i + 1]) else { return .invalid }
            return i + 2 == n ? done(.replaceChar(t)) : .invalid
        case "q":
            if recording { return single(.stopRecord) }
            guard i + 1 < n else { return .incomplete(.macroRecord, nil) }
            guard let r = keys[i + 1].char, (r.isASCII && (r.isLetter || r.isNumber)) || r == "\"" else { return .invalid }
            return i + 2 == n ? done(.record(r)) : .invalid
        case "@":
            guard i + 1 < n else { return .incomplete(.macroPlay, nil) }
            guard let r = keys[i + 1].char, (r.isASCII && (r.isLetter || r.isNumber)) || "@:\"".contains(r) else { return .invalid }
            return i + 2 == n ? done(.play(r)) : .invalid
        case "m":
            guard i + 1 < n else { return .incomplete(.markSet, nil) }
            guard let r = keys[i + 1].char, isValidMarkName(r), r != "." , r != "^" else { return .invalid }
            return i + 2 == n ? done(.setMark(r)) : .invalid
        case "g":
            guard i + 1 < n else { return .incomplete(.gPrefix, nil) }
            guard i + 2 == n, let g = keys[i + 1].char else { return .invalid }
            switch g {
            case "v": return done(.reselect)
            case "J": return done(.join(spaces: false))
            case "p": return done(.put(after: true, cursorAfter: true))
            case "P": return done(.put(after: false, cursorAfter: true))
            case "i": return done(.insert(.gi))
            case "I": return done(.insert(.gI))
            case "&": return done(.repeatSubstitute(allLines: true))
            default: return .invalid
            }
        case "z":
            guard i + 1 < n else { return .incomplete(.zPrefix, nil) }
            guard i + 2 == n, let z = zCommand(keys[i + 1]) else { return .invalid }
            return done(z)
        case "Z":
            guard i + 1 < n else { return .incomplete(.bigZPrefix, nil) }
            guard i + 2 == n else { return .invalid }
            switch keys[i + 1].char {
            case "Z": return done(.saveQuit(save: true))
            case "Q": return done(.saveQuit(save: false))
            default: return .invalid
            }
        case "[", "]":
            guard i + 1 < n else { return .incomplete(.bracket, nil) }
            guard i + 2 == n else { return .invalid }
            switch keys[i + 1].char {
            case "p": return done(.put(after: c == "]", cursorAfter: false))
            case "P": return done(.put(after: false, cursorAfter: false))
            default: return .invalid
            }
        default:
            return .invalid
        }
    }

    private static func zCommand(_ k: VimInput) -> NormalAction? {
        switch k {
        case .character("z"): return .scrollCursor(.center, firstNonBlank: false)
        case .character("t"): return .scrollCursor(.top, firstNonBlank: false)
        case .character("b"): return .scrollCursor(.bottom, firstNonBlank: false)
        case .character("."): return .scrollCursor(.center, firstNonBlank: true)
        case .return: return .scrollCursor(.top, firstNonBlank: true)
        case .character("-"): return .scrollCursor(.bottom, firstNonBlank: true)
        default: return nil
        }
    }

    /// A key usable as the argument of `r`, `f`, `t` … (Enter and Tab
    /// count: `r<CR>` splits the line).
    static func literalChar(_ k: VimInput) -> Character? {
        switch k {
        case let .character(c): return c
        case .return: return "\n"
        case .tab: return "\t"
        default: return nil
        }
    }

    static func isTextObjectKind(_ c: Character) -> Bool {
        "wWsp\"'`()b[]{}B<>t".contains(c)
    }

    private static func parseMotion(_ keys: [VimInput], _ j: Int) -> MotionParse {
        let n = keys.count
        let k = keys[j]
        func ok(_ m: MotionSpec, _ len: Int = 1) -> MotionParse { .ok(m, j + len) }
        switch k {
        case let .arrow(d):
            switch d {
            case .left: return ok(.left)
            case .right: return ok(.right)
            case .up: return ok(.up)
            case .down: return ok(.down)
            }
        case .backspace: return ok(.leftWrap)
        case .return: return ok(.lineDown)
        case let .control(c):
            switch c {
            case "h": return ok(.leftWrap)
            case "n", "j": return ok(.down)
            case "p": return ok(.up)
            case "m": return ok(.lineDown)
            default: return .notMotion
            }
        case let .character(c):
            switch c {
            case "h": return ok(.left)
            case "l": return ok(.right)
            case "j": return ok(.down)
            case "k": return ok(.up)
            case " ": return ok(.rightWrap)
            case "w": return ok(.wordForward(big: false))
            case "W": return ok(.wordForward(big: true))
            case "b": return ok(.wordBackward(big: false))
            case "B": return ok(.wordBackward(big: true))
            case "e": return ok(.wordEnd(big: false))
            case "E": return ok(.wordEnd(big: true))
            case "0": return ok(.lineStart)
            case "^": return ok(.firstNonBlank)
            case "$": return ok(.lineEnd)
            case "|": return ok(.column)
            case "+": return ok(.lineDown)
            case "-": return ok(.lineUp)
            case "_": return ok(.currentLine)
            case "G": return ok(.fileEnd)
            case ";": return ok(.repeatFind(reverse: false))
            case ",": return ok(.repeatFind(reverse: true))
            case "%": return ok(.matchPair)
            case "(": return ok(.sentenceBackward)
            case ")": return ok(.sentenceForward)
            case "{": return ok(.paragraphBackward)
            case "}": return ok(.paragraphForward)
            case "H": return ok(.screenTop)
            case "M": return ok(.screenMiddle)
            case "L": return ok(.screenBottom)
            case "n": return ok(.searchNext(reverse: false))
            case "N": return ok(.searchNext(reverse: true))
            case "*": return ok(.searchWord(forward: true, whole: true))
            case "#": return ok(.searchWord(forward: false, whole: true))
            case "f", "F", "t", "T":
                guard j + 1 < n else { return .need(.findChar) }
                guard let t = literalChar(keys[j + 1]), let kind = FindKind.from(char: c) else { return .invalid }
                return ok(.find(kind, t), 2)
            case "'", "`":
                guard j + 1 < n else { return .need(.markJump) }
                guard let m = keys[j + 1].char, isValidMarkName(m) else { return .invalid }
                return ok(.mark(m, exact: c == "`"), 2)
            case "g":
                guard j + 1 < n else { return .need(.gPrefix) }
                switch keys[j + 1].char {
                case "g": return ok(.fileStart, 2)
                case "e": return ok(.wordEndBackward(big: false), 2)
                case "E": return ok(.wordEndBackward(big: true), 2)
                case "_": return ok(.lastNonBlank, 2)
                case "j": return ok(.displayDown, 2)
                case "k": return ok(.displayUp, 2)
                case "0": return ok(.lineStart, 2)
                case "^": return ok(.firstNonBlank, 2)
                case "$": return ok(.lineEnd, 2)
                case "*": return ok(.searchWord(forward: true, whole: false), 2)
                case "#": return ok(.searchWord(forward: false, whole: false), 2)
                default: return .notMotion
                }
            case "[", "]":
                guard j + 1 < n else { return .need(.bracket) }
                switch keys[j + 1].char {
                case "(" where c == "[": return ok(.unmatched("("), 2)
                case "{" where c == "[": return ok(.unmatched("{"), 2)
                case ")" where c == "]": return ok(.unmatched(")"), 2)
                case "}" where c == "]": return ok(.unmatched("}"), 2)
                default: return .notMotion
                }
            default:
                return .notMotion
            }
        default:
            return .notMotion
        }
    }

    /// What the pending keys (and any half-typed mapping) are waiting for.
    public static func pendingInfo(_ state: VimState) -> VimPendingInfo {
        var info = VimPendingInfo()
        let mapDisplay = state.mode.isTyping && state.mapTentative > 0 ? "" : state.mapPending.display
        let keys = state.pendingKeys
        info.display = mapDisplay + keys.display
        if !state.mapPending.isEmpty, state.mapTentative == 0, keys.isEmpty {
            info.awaiting = .mapping
            return info
        }
        guard !keys.isEmpty, state.mode == .normal || state.mode.isVisual else { return info }
        // Register / count prefix.
        var i = 0
        var count: Int?
        while i < keys.count {
            if keys[i].char == "\"", i + 1 < keys.count {
                info.register = keys[i + 1].char
                i += 2
                continue
            }
            if let c = keys[i].char, c.isASCII, let d = c.wholeNumberValue, d > 0 || count != nil {
                count = (count ?? 0) * 10 + d
                i += 1
                continue
            }
            break
        }
        info.count = count
        if case let .incomplete(awaiting, op) = parse(keys, visual: state.mode.isVisual, recording: state.recordingMacro != nil) {
            info.awaiting = awaiting
            info.op = op
            if let op, let c2 = opCount(keys, op: op) { info.count = (count ?? 1) * c2 }
        }
        return info
    }

    private static func opCount(_ keys: [VimInput], op: VimOperator) -> Int? {
        // Digits typed after the operator keys.
        let opKeys = Array(op.keys)
        guard let start = (0..<keys.count).first(where: { idx in
            idx + opKeys.count <= keys.count && (0..<opKeys.count).allSatisfy { keys[idx + $0].char == opKeys[$0] }
        }) else { return nil }
        var j = start + opKeys.count
        var c: Int?
        while j < keys.count, let ch = keys[j].char, ch.isASCII, let d = ch.wholeNumberValue, d > 0 || c != nil {
            c = (c ?? 0) * 10 + d
            j += 1
        }
        return c
    }

    /// Keys that wait for a literal character: mappings don't apply to it.
    static func awaitsLiteral(_ state: VimState) -> Bool {
        switch pendingInfo(state).awaiting {
        case .register, .markSet, .markJump, .findChar, .replaceChar, .macroRecord, .macroPlay: return true
        default: return false
        }
    }
}
