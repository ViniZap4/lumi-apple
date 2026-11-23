import Foundation
import Observation
import LumiKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// The platform text view as seen by the controller. The controller is
/// the single source of truth for the text; it pushes every change into
/// the surface as **ranged** edits (never `string = …`), so TextKit keeps
/// layout, undo coalescing and IME state for untouched text.
@MainActor
protocol EditorTextSurface: AnyObject {
    /// Apply sequential UTF-16 edits to the storage. Programmatic: must
    /// not loop back into `VimController.applyExternalEdit`.
    func applyEdits(_ edits: [TextEdit])
    /// Show the engine's cursor/selection.
    func showSelection(_ range: NSRange, scroll: Bool)
    /// The user's current selection (UTF-16).
    var currentSelection: NSRange { get }
    /// Drop an in-progress IME composition before a remote edit lands.
    func discardMarkedText()
    /// UTF-16 offsets of the first and last visible characters.
    func visibleRange() -> NSRange?
    /// Offset `count` display (wrapped) lines from `from`, keeping the
    /// horizontal position; nil when the view can't tell.
    func displayLineOffset(from: Int, count: Int) -> Int?
    /// Scroll so the cursor line sits at `position`.
    func scrollCursor(to position: VimScrollPosition, cursor: Int)
    /// Scroll by whole lines (negative = up).
    func scrollLines(_ lines: Int)
    /// Briefly highlight these UTF-16 ranges (yank highlight). Purely
    /// visual: never touches the storage.
    func flashYank(_ ranges: [NSRange])
    /// Source line (fractional, 0-based) at the top of the viewport;
    /// `-1` at the very top, `.infinity` at the very bottom.
    func viewportTopLine() -> Double?
    /// Scroll so source line `line` (fractional) sits at the top.
    func scrollViewport(toLine line: Double)
}

extension EditorTextSurface {
    func visibleRange() -> NSRange? { nil }
    func displayLineOffset(from: Int, count: Int) -> Int? { nil }
    func scrollCursor(to position: VimScrollPosition, cursor: Int) {}
    func scrollLines(_ lines: Int) {}
    func flashYank(_ ranges: [NSRange]) {}
    func viewportTopLine() -> Double? { nil }
    func scrollViewport(toLine line: Double) {}
}

/// What the chrome shows about the editor: mode, pending keys (legend /
/// showcmd), recording, messages.
public struct VimStatus: Equatable, Sendable {
    public var mode: VimMode
    public var pending: VimPendingInfo
    public var recording: Character?
    public var message: VimMessage?
    public var insertOneShot: Bool
    public var substituteConfirm: Bool
    public var leader: String
    public var leaderMaps: [(keys: String, rhs: String)]
    public var escapeSequences: [String]

    public static func == (a: VimStatus, b: VimStatus) -> Bool {
        a.mode == b.mode && a.pending == b.pending && a.recording == b.recording && a.message == b.message
            && a.insertOneShot == b.insertOneShot && a.substituteConfirm == b.substituteConfirm && a.leader == b.leader
            && a.leaderMaps.map(\.keys) == b.leaderMaps.map(\.keys) && a.leaderMaps.map(\.rhs) == b.leaderMaps.map(\.rhs)
            && a.escapeSequences == b.escapeSequences
    }

    public init(mode: VimMode = .normal, pending: VimPendingInfo = VimPendingInfo(), recording: Character? = nil,
                message: VimMessage? = nil, insertOneShot: Bool = false, substituteConfirm: Bool = false,
                leader: String = "\\", leaderMaps: [(keys: String, rhs: String)] = [], escapeSequences: [String] = []) {
        self.mode = mode
        self.pending = pending
        self.recording = recording
        self.message = message
        self.insertOneShot = insertOneShot
        self.substituteConfirm = substituteConfirm
        self.leader = leader
        self.leaderMaps = leaderMaps
        self.escapeSequences = escapeSequences
    }

    /// The legend context for this editor state.
    public var legendContext: LegendContext {
        if substituteConfirm { return .substituteConfirm }
        switch mode {
        case .insert: return .insert
        case .replace: return .replace
        case .commandLine(let p, _): return p == ":" ? .commandLine : .search
        case let .visual(kind, _):
            switch kind {
            case .characterwise: return .visual
            case .linewise: return .visualLine
            case .block: return .visualBlock
            }
        case .normal:
            return pending.op != nil ? .operatorPending : .normal
        }
    }
}

/// Owns the editor buffer (`TextBuffer`) and `VimState`, dispatches input
/// through the pure `VimEngine`, and is the **single source of truth**
/// for the editor text:
///
/// - every engine step that changes the text reaches the text view and,
///   for server notes, the CRDT (`CollaborativeDocument.applyLocal`) as
///   the ranged UTF-16 edits the engine logged (`TextBuffer.edits`) — a
///   `:s` over many lines is one edit per match in one transaction;
/// - remote CRDT deltas arrive as ranged edits and are applied to the
///   buffer and the text view in place, with the cursor, visual anchor
///   and marks mapped through them (CRDT-CLIENT-PROTOCOL §4.3);
/// - edits the text view makes on its own (paste, cut, drag, dictation,
///   Writing Tools, plain-mode typing) come back through
///   `applyExternalEdit`.
@Observable
@MainActor
public final class VimController {
    public private(set) var buffer: TextBuffer
    public var state: VimState
    /// False → plain editing: the text view handles keys natively and the
    /// controller only mirrors its edits (non-vim users on server notes).
    public let vimEnabled: Bool

    @ObservationIgnored public var onEffect: ((VimEffect) -> Void)?
    /// Local-note sink: receives the full text after every change.
    @ObservationIgnored public var onTextChange: ((String) -> Void)?
    @ObservationIgnored weak var surface: EditorTextSurface?
    /// The editor's viewport moved (user or programmatic scroll).
    @ObservationIgnored public var onViewportScroll: (() -> Void)?
    /// The user touched the editor (key, click, wheel): it leads the
    /// split preview's scroll sync.
    @ObservationIgnored public var onUserInteraction: (() -> Void)?
    @ObservationIgnored public private(set) weak var document: CollaborativeDocument?
    @ObservationIgnored private var mapTimer: Task<Void, Never>?

    public init(initialText: String = "", vimEnabled: Bool = true) {
        self.buffer = TextBuffer(text: initialText, cursor: 0)
        self.state = vimEnabled ? .initial : VimState(mode: .insert)
        self.vimEnabled = vimEnabled
    }

    /// Collaborative editor over a live replica. Call `bindDocument()`
    /// once the editor is mounted to start receiving remote changes.
    public init(document: CollaborativeDocument, vimEnabled: Bool = true) {
        self.buffer = TextBuffer(text: document.text, cursor: 0)
        self.state = vimEnabled ? .initial : VimState(mode: .insert)
        self.vimEnabled = vimEnabled
        self.document = document
    }

    public func bindDocument() {
        guard let document else { return }
        document.changeHandler = { [weak self] change in
            self?.applyDocumentChange(change)
        }
        if document.text != buffer.text {
            applyDocumentChange(.resync(document.text))
        }
    }

    public var isEditable: Bool { document?.isEditable ?? true }

    public func setJJEscapeEnabled(_ enabled: Bool) {
        state.jjEscapeEnabled = enabled
    }

    public func setEscapeSequences(_ sequences: [String], timeout: TimeInterval) {
        state.escapeSequences = sequences
        state.escapeTimeout = timeout
    }

    /// Install a parsed `.vimrc` (mappings, leader, options).
    public func applyVimrc(_ parsed: ParsedVimrc?) {
        if let parsed {
            state.apply(vimrc: parsed)
        } else {
            state.mappings = []
            state.leader = Vimrc.defaultLeader
        }
        state.addDefaultLeaderMaps()
    }

    /// Name of the open note (`"%`, Ctrl-G).
    public func setFileName(_ name: String?) {
        state.fileName = name
    }

    /// Snapshot for the chrome (legend, status line).
    public var status: VimStatus {
        let leaderKeys = state.leader
        let leaderMaps: [(keys: String, rhs: String)] = state.mappings.compactMap { m in
            guard m.exAlias == nil, m.mode != .insert else { return nil }
            let lhs = m.lhs.notation
            let lead = VimInput.parse(notation: leaderKeys)?.notation ?? leaderKeys
            guard lhs.hasPrefix(lead), lhs.count > lead.count else { return nil }
            return (String(lhs.dropFirst(lead.count)), m.rhs.notation)
        }
        return VimStatus(
            mode: state.mode,
            pending: state.pending,
            recording: state.recordingMacro,
            message: state.message,
            insertOneShot: state.insertOneShot > 0,
            substituteConfirm: state.substituteConfirm != nil,
            leader: leaderKeys,
            leaderMaps: leaderMaps,
            escapeSequences: VimEngineEscapes.sequences(state)
        )
    }

    // MARK: - Input

    public func send(_ input: VimInput) {
        guard isEditable else { return }
        if !vimEnabled { return }
        if let document, interceptUndo(input, document: document) { return }
        if VimEngine.wantsClipboard(state) { state.clipboard = readSystemPasteboard() }
        if !state.mode.isTyping { state.viewport = currentViewport() }
        let old = buffer
        run(VimEngine.handle(input, state: state, buffer: startBuffer(), at: ProcessInfo.processInfo.systemUptime), old: old)
    }

    private func startBuffer() -> TextBuffer {
        var b = buffer
        b.edits = []
        return b
    }

    private func run(_ result: VimEngine.Result, old: TextBuffer) {
        let previousRegister = state.defaultRegister
        let previousYank = state.lastYank?.seq
        state = result.state
        var nb = result.buffer
        let edits = nb.edits
        nb.edits = []
        buffer = nb

        if document != nil {
            // The CRDT owns undo for server notes (§8): an engine history
            // push marks a vim change boundary; the snapshots themselves
            // would revert peers' edits, so they are dropped.
            if !state.history.undo.isEmpty || !state.history.redo.isEmpty {
                document?.breakUndoGroup()
                state.history = VimHistory()
            }
        }
        if buffer.text != old.text {
            let ranged: [TextEdit]
            if !edits.isEmpty, TextEdit.apply(edits, to: old.text) == buffer.text {
                ranged = edits
            } else if let edit = TextDiff.edit(from: old.text, to: buffer.text) {
                ranged = [edit]
            } else {
                ranged = []
            }
            if !ranged.isEmpty { commitLocal(ranged, applyToSurface: true) }
        }

        var scroll = true
        if let effect = result.effect {
            switch effect {
            case let .displayLines(from, count):
                let from16 = Self.utf16Offset(char: from, in: buffer.text)
                if let target = surface?.displayLineOffset(from: from16, count: count) {
                    buffer.cursor = Self.charOffset(utf16: target, in: buffer.text)
                    var b = buffer
                    b.cursor = clampForMode(b)
                    buffer = b
                }
            case let .scrollCursor(position):
                surface?.scrollCursor(to: position, cursor: cursorUTF16Offset)
                scroll = false
            case let .scrollLines(n):
                surface?.scrollLines(n)
            case .save, .saveAndClose, .close, .host:
                break
            }
        }
        showEngineSelection(scroll: scroll)
        if let yank = state.lastYank, yank.seq != previousYank {
            let text = buffer.text
            surface?.flashYank(yank.spans.map { span in
                let lo = Self.utf16Offset(char: span.lowerBound, in: text)
                return NSRange(location: lo, length: Self.utf16Offset(char: span.upperBound, in: text) - lo)
            })
        }

        if state.defaultRegister != previousRegister, !state.defaultRegister.text.isEmpty {
            writeToSystemPasteboard(state.defaultRegister.text)
        }
        scheduleMapTimeout()
        if let effect = result.effect {
            switch effect {
            case .save, .saveAndClose, .close, .host: onEffect?(effect)
            default: break
            }
        }
    }

    private func clampForMode(_ b: TextBuffer) -> Int {
        let allowPastEnd = state.mode.isTyping
        return b.clampedCursor(allowPastEnd: allowPastEnd)
    }

    /// A half-typed mapping resolves after `timeoutlen`.
    private func scheduleMapTimeout() {
        mapTimer?.cancel()
        guard !state.mapPending.isEmpty else { return }
        let ms = max(50, state.options.timeoutlen)
        mapTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard !Task.isCancelled, let self, !self.state.mapPending.isEmpty else { return }
            let old = self.buffer
            self.run(VimEngine.timeout(state: self.state, buffer: self.startBuffer()), old: old)
        }
    }

    /// Text committed by the input system (`insertText`, a finished IME
    /// composition, a dead-key result). Fed to the engine character by
    /// character so insert-mode features (jj, dot-repeat, macros) see it.
    public func insertTyped(_ string: String) {
        for ch in string {
            switch ch {
            case "\n", "\r\n", "\r": send(.return)
            case "\t": send(.tab)
            default: send(.character(ch))
            }
        }
    }

    /// `u` / `Ctrl-R` in idle normal mode on a server note → CRDT undo.
    private func interceptUndo(_ input: VimInput, document: CollaborativeDocument) -> Bool {
        guard state.mode == .normal, state.insertOneShot == 0, state.substituteConfirm == nil else { return false }
        let info = state.pending
        let onlyCount = state.pendingKeys.allSatisfy { $0.char?.isNumber == true }
        guard onlyCount, info.register == nil, state.mapPending.isEmpty else { return false }
        let isUndo: Bool
        switch input {
        case .character("u"), .character("U"): isUndo = true
        case .controlR: isUndo = false
        default: return false
        }
        let count = info.count ?? 1
        state.pendingKeys = []
        state.recordingInputs = []
        state.recordingBaseline = nil
        document.breakUndoGroup()
        for _ in 0..<count {
            let did = isUndo ? document.undo() : document.redo()
            if !did { break }
        }
        return true
    }

    /// Menu / Cmd-Z undo (plain mode and the Edit menu).
    public func undo() {
        if let document {
            document.breakUndoGroup()
            document.undo()
        } else if vimEnabled {
            send(.character("u"))
        }
    }

    public func redo() {
        if let document {
            document.breakUndoGroup()
            document.redo()
        } else if vimEnabled {
            send(.controlR)
        }
    }

    // MARK: - Edits made by the text view itself

    func applyExternalEdit(_ edit: TextEdit) {
        guard !edit.isNoOp else { return }
        let ns = NSMutableString(string: buffer.text)
        guard edit.apply(to: ns) else { return }
        if document == nil, vimEnabled {
            state.history.push(.init(buffer: buffer))
        } else {
            document?.breakUndoGroup()
        }
        let oldText = buffer.text
        let newText = ns as String
        let caret = edit.location + edit.replacementLength
        state.marks = state.marks.mapValues { m in
            Self.charOffset(utf16: PositionMapper.map(Self.utf16Offset(char: m, in: oldText), through: [edit]), in: newText)
        }
        buffer = TextBuffer(text: newText, cursor: Self.charOffset(utf16: caret, in: newText))
        if vimEnabled, !state.mode.isTyping {
            buffer.cursor = buffer.clampedCursor(allowPastEnd: false)
        }
        commitLocal([edit], applyToSurface: false)
        document?.breakUndoGroup()
    }

    /// A ranged edit the app makes on the user's behalf (a task checkbox
    /// toggled in the split preview): applied to the buffer, the text
    /// view and — for server notes — the CRDT as one ranged op, with
    /// the cursor and marks mapped through it.
    public func applyProgrammaticEdit(_ edit: TextEdit) {
        guard isEditable, !edit.isNoOp else { return }
        let ns = NSMutableString(string: buffer.text)
        guard edit.apply(to: ns) else { return }
        if document == nil, vimEnabled {
            state.history.push(.init(buffer: buffer))
        } else {
            document?.breakUndoGroup()
        }
        let oldText = buffer.text
        let newText = ns as String
        func map(_ char: Int) -> Int {
            Self.charOffset(utf16: PositionMapper.map(Self.utf16Offset(char: char, in: oldText), through: [edit]), in: newText)
        }
        state.marks = state.marks.mapValues(map)
        if case let .visual(kind, anchor) = state.mode { state.mode = .visual(kind, anchor: map(anchor)) }
        let plainSelection = vimEnabled ? nil : surface.map { PositionMapper.map($0.currentSelection, through: [edit]) }
        buffer = TextBuffer(text: newText, cursor: map(buffer.cursor))
        buffer.cursor = buffer.clampedCursor(allowPastEnd: !vimEnabled || state.mode.isTyping)
        commitLocal([edit], applyToSurface: true)
        document?.breakUndoGroup()
        if let plainSelection {
            surface?.showSelection(plainSelection, scroll: false)
        } else {
            showEngineSelection(scroll: false)
        }
    }

    // MARK: - Viewport (split preview scroll sync)

    public func viewportTopLine() -> Double? { surface?.viewportTopLine() }
    public func scrollViewport(toLine line: Double) { surface?.scrollViewport(toLine: line) }

    /// The user moved the caret with the mouse / touch.
    func userMovedSelection(to range: NSRange) {
        let allowPastEnd = !vimEnabled || state.mode.isTyping
        buffer.cursor = Self.charOffset(utf16: range.location, in: buffer.text)
        buffer.cursor = buffer.clampedCursor(allowPastEnd: allowPastEnd)
        state.desiredColumn = nil
    }

    public func replaceAll(with text: String) {
        guard text != buffer.text, let edit = TextDiff.edit(from: buffer.text, to: text) else { return }
        let cursor16 = PositionMapper.map(Self.utf16Offset(char: buffer.cursor, in: buffer.text), through: [edit])
        buffer = TextBuffer(text: text, cursor: Self.charOffset(utf16: cursor16, in: text))
        buffer.cursor = buffer.clampedCursor(allowPastEnd: state.mode.isTyping)
        surface?.applyEdits([edit])
        showEngineSelection()
    }

    private func commitLocal(_ edits: [TextEdit], applyToSurface: Bool) {
        if applyToSurface { surface?.applyEdits(edits) }
        document?.applyLocal(edits)
        onTextChange?(buffer.text)
    }

    // MARK: - Remote changes

    func applyDocumentChange(_ change: DocumentChange) {
        switch change {
        case .remote(let edits):
            applyIncoming(edits, isUndo: false)
        case .undo(let edits):
            applyIncoming(edits, isUndo: true)
        case .resync(let text):
            surface?.discardMarkedText()
            let old = buffer.text
            buffer = TextBuffer(text: text, cursor: min(buffer.cursor, text.count))
            buffer.cursor = buffer.clampedCursor(allowPastEnd: state.mode.isTyping)
            if let edit = TextDiff.edit(from: old, to: text) { surface?.applyEdits([edit]) }
            showEngineSelection()
            onTextChange?(text)
        }
    }

    private func applyIncoming(_ edits: [TextEdit], isUndo: Bool) {
        guard !edits.isEmpty else { return }
        surface?.discardMarkedText()
        let oldText = buffer.text
        let ns = NSMutableString(string: oldText)
        for e in edits where !e.apply(to: ns) {
            if let document { applyDocumentChange(.resync(document.text)) }
            return
        }
        let newText = ns as String

        func map(_ char: Int, _ assoc: PositionAssoc = .after) -> Int {
            let u = PositionMapper.map(Self.utf16Offset(char: char, in: oldText), through: edits, assoc: assoc)
            return Self.charOffset(utf16: u, in: newText)
        }
        let plainSelection = vimEnabled ? nil : surface.map { PositionMapper.map($0.currentSelection, through: edits) }
        var cursor: Int
        if isUndo, let first = edits.first {
            cursor = Self.charOffset(utf16: first.location, in: newText)
        } else {
            cursor = map(buffer.cursor)
        }
        if case let .visual(kind, anchor) = state.mode {
            state.mode = .visual(kind, anchor: map(anchor))
        }
        state.marks = state.marks.mapValues { map($0) }
        if var v = state.lastVisual {
            v.anchor = map(v.anchor)
            v.head = map(v.head)
            state.lastVisual = v
        }
        if let entry = state.commandLineEntryCursor { state.commandLineEntryCursor = map(entry) }
        if var session = state.insertSession {
            session.start = map(session.start, .before)
            state.insertSession = session
        }
        buffer = TextBuffer(text: newText, cursor: cursor)
        let allowPastEnd = !vimEnabled || state.mode.isTyping
        buffer.cursor = buffer.clampedCursor(allowPastEnd: allowPastEnd)
        cursor = buffer.cursor

        surface?.applyEdits(edits)
        if let plainSelection {
            surface?.showSelection(plainSelection, scroll: isUndo)
        } else {
            showEngineSelection(scroll: isUndo)
        }
        onTextChange?(newText)
    }

    // MARK: - Selection

    func showEngineSelection(scroll: Bool = true) {
        guard vimEnabled else { return }
        // Visual mode is painted by the view (`visualHighlightRanges`);
        // the native selection stays a caret so AppKit's inactive-window
        // selection (an opaque grey on some themes) never covers it.
        let range = state.mode.isVisual ? NSRange(location: cursorUTF16Offset, length: 0) : selectionUTF16Range
        surface?.showSelection(range, scroll: scroll)
    }

    private func readSystemPasteboard() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }

    private func writeToSystemPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    private func currentViewport() -> VimViewport? {
        guard let r = surface?.visibleRange() else { return nil }
        let text = buffer.text
        let first = lineIndex(atUTF16: r.location, in: text)
        let last = lineIndex(atUTF16: NSMaxRange(r), in: text)
        return VimViewport(firstLine: first, lastLine: last)
    }

    private func lineIndex(atUTF16 offset: Int, in text: String) -> Int {
        var n = 0
        var i = 0
        for u in text.utf16 {
            if i >= offset { break }
            if u == 10 { n += 1 }
            i += 1
        }
        return n
    }

    /// Cursor offset in UTF-16 code units.
    public var cursorUTF16Offset: Int {
        Self.utf16Offset(char: buffer.cursor, in: buffer.text)
    }

    /// The character the cursor sits on (UTF-16), empty at a line end.
    public var cursorCharacterRange: NSRange {
        let from = cursorUTF16Offset
        guard buffer.cursor < buffer.text.count else { return NSRange(location: from, length: 0) }
        let ch = buffer.text[buffer.cursorIndex]
        if ch == "\n" { return NSRange(location: from, length: 0) }
        let to = utf16Offset(of: buffer.cursor + 1)
        return NSRange(location: from, length: to - from)
    }

    /// Native selection to show: the visual range (character / line
    /// visual) or a caret at the cursor. The cursor itself is drawn by
    /// the editor's cursor overlay (block / bar / underline).
    public var selectionUTF16Range: NSRange {
        guard case let .visual(kind, anchor) = state.mode else {
            return NSRange(location: cursorUTF16Offset, length: 0)
        }
        let cursor = buffer.cursor
        switch kind {
        case .characterwise:
            let from = min(anchor, cursor)
            let to = min(buffer.text.count, max(anchor, cursor) + 1)
            let utf16From = utf16Offset(of: from)
            return NSRange(location: utf16From, length: utf16Offset(of: to) - utf16From)
        case .linewise:
            let anchorLine = lineForOffset(anchor)
            let cursorLine = lineForOffset(cursor)
            let from = buffer.lineStart(of: min(anchorLine, cursorLine))
            var to = buffer.lineEnd(of: max(anchorLine, cursorLine))
            if to < buffer.text.count { to += 1 }
            let utf16From = utf16Offset(of: from)
            return NSRange(location: utf16From, length: utf16Offset(of: to) - utf16From)
        case .block:
            return NSRange(location: cursorUTF16Offset, length: 0)
        }
    }

    /// What the editor paints as the visual selection: the character /
    /// line range, or one range per line for a block. Drawn as a
    /// rendering attribute so it is visible whatever the focus state.
    public var visualHighlightRanges: [NSRange] {
        guard case let .visual(kind, _) = state.mode else { return [] }
        if kind == .block { return blockSelectionRanges }
        let r = selectionUTF16Range
        return r.length > 0 ? [r] : []
    }

    /// Text of the visual selection (⌘C in visual mode), nil otherwise.
    public var visualSelectionText: String? {
        let ranges = visualHighlightRanges
        guard !ranges.isEmpty else { return nil }
        let ns = buffer.text as NSString
        return ranges.filter { NSMaxRange($0) <= ns.length }.map { ns.substring(with: $0) }.joined(separator: "\n")
    }

    /// Visual-block selection, one UTF-16 range per line.
    public var blockSelectionRanges: [NSRange] {
        guard case let .visual(.block, anchor) = state.mode else { return [] }
        let text = buffer.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = []
        var off = 0
        for l in lines { starts.append(off); off += l.count + 1 }
        func lineCol(_ o: Int) -> (Int, Int) {
            var l = 0
            while l + 1 < starts.count, starts[l + 1] <= o { l += 1 }
            return (l, o - starts[l])
        }
        let (la, ca) = lineCol(anchor), (lh, ch) = lineCol(buffer.cursor)
        let left = min(ca, ch), right = max(ca, ch)
        var out: [NSRange] = []
        for l in min(la, lh)...max(la, lh) {
            let len = lines[l].count
            let s = starts[l] + min(left, len)
            let e = state.blockToLineEnd ? starts[l] + len : starts[l] + min(right + 1, len)
            guard e > s else { continue }
            let s16 = utf16Offset(of: s), e16 = utf16Offset(of: e)
            out.append(NSRange(location: s16, length: e16 - s16))
        }
        return out
    }

    private func utf16Offset(of charOffset: Int) -> Int {
        Self.utf16Offset(char: charOffset, in: buffer.text)
    }

    static func utf16Offset(char: Int, in text: String) -> Int {
        let safe = max(0, min(char, text.count))
        return text.index(text.startIndex, offsetBy: safe).utf16Offset(in: text)
    }

    static func charOffset(utf16 offset: Int, in text: String) -> Int {
        characterOffset(utf16: offset, in: text)
    }

    /// hlsearch: every occurrence of the active search pattern (UTF-16).
    public var searchHighlights: [NSRange] {
        guard let pattern = activeSearchPattern, !pattern.isEmpty else { return [] }
        let opts = SearchCaseOptions(ignorecase: state.options.ignorecase, smartcase: state.options.smartcase)
        return allMatchesUTF16(in: buffer.text, pattern: pattern, case: opts)
    }

    private var activeSearchPattern: String? {
        if case let .commandLine(prefix, current) = state.mode, prefix == "/" || prefix == "?", !current.isEmpty {
            return state.options.incsearch ? current : nil
        }
        if let c = state.substituteConfirm { return c.pattern }
        guard state.options.hlsearch, !state.hlsearchSuspended else { return nil }
        return state.lastSearch?.pattern
    }

    private func lineForOffset(_ offset: Int) -> Int {
        var b = buffer
        b.cursor = max(0, min(offset, b.text.count))
        return b.cursorLine
    }

    public var modeLabel: String { state.mode.label }
}

/// Escape sequences in effect (legend).
enum VimEngineEscapes {
    static func sequences(_ s: VimState) -> [String] {
        var seqs = s.escapeSequences.filter { $0.count >= 2 }
        if s.jjEscapeEnabled, !seqs.contains("jj") { seqs.append("jj") }
        return seqs
    }
}
