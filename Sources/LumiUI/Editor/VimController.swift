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
}

/// Owns the editor buffer (`TextBuffer`) and `VimState`, dispatches input
/// through the pure `VimEngine`, and is the **single source of truth**
/// for the editor text:
///
/// - every engine step that changes the text is reduced to one ranged
///   `TextEdit` (UTF-16, surrogate-safe) that goes to the text view and,
///   for server notes, to the CRDT (`CollaborativeDocument.applyLocal`);
/// - remote CRDT deltas arrive as ranged edits and are applied to the
///   buffer and the text view in place, with the cursor, visual anchor
///   and marks mapped through them (CRDT-CLIENT-PROTOCOL §4.3);
/// - edits the text view makes on its own (paste, cut, drag, dictation,
///   Writing Tools, plain-mode typing) come back through
///   `applyExternalEdit`.
///
/// Local notes bind a `String` via `onTextChange`; that callback only
/// ever *receives* text — an external binding change goes through
/// `replaceAll(with:)` as a ranged diff that keeps mode and history.
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
    @ObservationIgnored public private(set) weak var document: CollaborativeDocument?

    public init(initialText: String = "", vimEnabled: Bool = true) {
        self.buffer = TextBuffer(text: initialText, cursor: 0)
        self.state = vimEnabled ? .initial : VimState(mode: .insert)
        self.vimEnabled = vimEnabled
    }

    /// Collaborative editor over a live replica. The initial text is the
    /// replica's (§2.2.4). Call `bindDocument()` once the editor is
    /// mounted to start receiving remote changes — not from `init`,
    /// because SwiftUI re-evaluates `State(initialValue:)` on every parent
    /// render and a throwaway controller would steal the handler.
    public init(document: CollaborativeDocument, vimEnabled: Bool = true) {
        self.buffer = TextBuffer(text: document.text, cursor: 0)
        self.state = vimEnabled ? .initial : VimState(mode: .insert)
        self.vimEnabled = vimEnabled
        self.document = document
    }

    /// Become the document's editor: remote changes flow into this
    /// controller from now on. Catches up if the replica moved since
    /// `init`.
    public func bindDocument() {
        guard let document else { return }
        document.changeHandler = { [weak self] change in
            self?.applyDocumentChange(change)
        }
        if document.text != buffer.text {
            applyDocumentChange(.resync(document.text))
        }
    }

    /// Editing allowed (collaborative: only once synced).
    public var isEditable: Bool { document?.isEditable ?? true }

    public func setJJEscapeEnabled(_ enabled: Bool) {
        state.jjEscapeEnabled = enabled
    }

    // MARK: - Input

    public func send(_ input: VimInput) {
        guard isEditable else { return }
        if !vimEnabled {
            // Plain mode: Esc does nothing; everything else arrives as
            // native text-view edits.
            return
        }
        if let document, interceptUndo(input, document: document) { return }

        let previousRegister = state.defaultRegister
        let old = buffer
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer

        if document != nil {
            // The CRDT owns undo for server notes (§8): an engine history
            // push marks a vim change boundary; the snapshots themselves
            // would revert peers' edits, so they are dropped.
            if !state.history.undo.isEmpty || !state.history.redo.isEmpty {
                document?.breakUndoGroup()
                state.history = VimHistory()
            }
        }
        if buffer.text != old.text, let edit = TextDiff.edit(from: old.text, to: buffer.text) {
            commitLocal([edit], applyToSurface: true)
        }
        showEngineSelection()

        if state.defaultRegister != previousRegister, !state.defaultRegister.text.isEmpty {
            writeToSystemPasteboard(state.defaultRegister.text)
        }
        if let effect = result.effect {
            onEffect?(effect)
        }
    }

    /// Text committed by the input system (`insertText`, a finished IME
    /// composition, a dead-key result such as ABNT2 `´` + `a` → `á`).
    /// Fed to the engine character by character so insert-mode features
    /// (jj, dot-repeat, macros) see it.
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
        guard state.mode == .normal else { return false }
        var probe = state
        probe.pendingCount = nil
        guard VimEngine.isIdleNormal(probe) else { return false }
        let isUndo: Bool
        switch input {
        case .character("u"): isUndo = true
        case .controlR: isUndo = false
        default: return false
        }
        let count = state.pendingCount ?? 1
        state.pendingCount = nil
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

    /// The text view already changed its storage (paste, cut, drag and
    /// drop, dictation, autocorrect, Writing Tools, plain-mode typing):
    /// mirror the edit into the buffer and the CRDT.
    func applyExternalEdit(_ edit: TextEdit) {
        guard !edit.isNoOp else { return }
        let ns = NSMutableString(string: buffer.text)
        guard edit.apply(to: ns) else {
            // Out of sync with the view — the view is what the user sees.
            return
        }
        if document == nil, vimEnabled {
            state.history.push(.init(buffer: buffer))
        } else {
            document?.breakUndoGroup()
        }
        let newText = ns as String
        let caret = edit.location + edit.replacementLength
        buffer = TextBuffer(text: newText, cursor: Self.charOffset(utf16: caret, in: newText))
        if vimEnabled, state.mode != .insert {
            buffer.cursor = buffer.clampedCursor(allowPastEnd: false)
        }
        commitLocal([edit], applyToSurface: false)
        document?.breakUndoGroup()
    }

    /// The user moved the caret with the mouse / touch.
    func userMovedSelection(to range: NSRange) {
        let allowPastEnd = !vimEnabled || state.mode == .insert
        buffer.cursor = Self.charOffset(utf16: range.location, in: buffer.text)
        buffer.cursor = buffer.clampedCursor(allowPastEnd: allowPastEnd)
    }

    /// Local-note binding changed from outside (revert, reload): apply as
    /// a ranged diff, keeping mode, registers and history.
    public func replaceAll(with text: String) {
        guard text != buffer.text, let edit = TextDiff.edit(from: buffer.text, to: text) else { return }
        let cursor16 = PositionMapper.map(Self.utf16Offset(char: buffer.cursor, in: buffer.text), through: [edit])
        buffer = TextBuffer(text: text, cursor: Self.charOffset(utf16: cursor16, in: text))
        buffer.cursor = buffer.clampedCursor(allowPastEnd: state.mode == .insert)
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
            buffer.cursor = buffer.clampedCursor(allowPastEnd: state.mode == .insert)
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
            // Should not happen (the replica and the buffer move in
            // lockstep); fall back to the replica's text.
            if let document { applyDocumentChange(.resync(document.text)) }
            return
        }
        let newText = ns as String

        // Map every live position through the change (UTF-16 domain).
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
        if let entry = state.commandLineEntryCursor { state.commandLineEntryCursor = map(entry) }
        buffer = TextBuffer(text: newText, cursor: cursor)
        let allowPastEnd = !vimEnabled || state.mode == .insert
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
        surface?.showSelection(selectionUTF16Range, scroll: scroll)
    }

    private func writeToSystemPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// Cursor offset in UTF-16 code units.
    public var cursorUTF16Offset: Int {
        Self.utf16Offset(char: buffer.cursor, in: buffer.text)
    }

    /// Selection to render: the visual-mode range, or a one-character
    /// "block cursor" in normal / command-line mode, or a caret in insert.
    public var selectionUTF16Range: NSRange {
        guard case let .visual(kind, anchor) = state.mode else {
            let showsBlock = state.mode == .normal || state.mode.commandLinePrefix != nil
            if showsBlock,
               buffer.cursor < buffer.text.count,
               !buffer.text.isEmpty
            {
                let cursorChar = buffer.text[buffer.cursorIndex]
                if cursorChar != "\n" {
                    let from = cursorUTF16Offset
                    let to = utf16Offset(of: buffer.cursor + 1)
                    return NSRange(location: from, length: to - from)
                }
            }
            return NSRange(location: cursorUTF16Offset, length: 0)
        }
        let cursor = buffer.cursor
        switch kind {
        case .characterwise:
            let from = min(anchor, cursor)
            let to = min(buffer.text.count, max(anchor, cursor) + 1)
            let utf16From = utf16Offset(of: from)
            let utf16To = utf16Offset(of: to)
            return NSRange(location: utf16From, length: utf16To - utf16From)
        case .linewise:
            let anchorLine = lineForOffset(anchor)
            let cursorLine = lineForOffset(cursor)
            let firstLine = min(anchorLine, cursorLine)
            let lastLine = max(anchorLine, cursorLine)
            let from = buffer.lineStart(of: firstLine)
            var to = buffer.lineEnd(of: lastLine)
            if to < buffer.text.count { to += 1 }
            let utf16From = utf16Offset(of: from)
            let utf16To = utf16Offset(of: to)
            return NSRange(location: utf16From, length: utf16To - utf16From)
        }
    }

    private func utf16Offset(of charOffset: Int) -> Int {
        Self.utf16Offset(char: charOffset, in: buffer.text)
    }

    /// Character offset → UTF-16 offset.
    static func utf16Offset(char: Int, in text: String) -> Int {
        let safe = max(0, min(char, text.count))
        return text.index(text.startIndex, offsetBy: safe).utf16Offset(in: text)
    }

    /// UTF-16 offset → character offset, rounding down to a grapheme
    /// boundary (never lands inside a surrogate pair or cluster).
    static func charOffset(utf16 offset: Int, in text: String) -> Int {
        let u = text.utf16
        var idx = u.index(u.startIndex, offsetBy: max(0, min(offset, u.count)))
        while idx > text.startIndex, idx.samePosition(in: text) == nil {
            idx = u.index(before: idx)
        }
        return text.distance(from: text.startIndex, to: idx)
    }

    /// hlsearch: every occurrence of the active search pattern (UTF-16).
    public var searchHighlights: [NSRange] {
        guard let pattern = activeSearchPattern, !pattern.isEmpty else { return [] }
        return allMatches(in: buffer.text, pattern: pattern).map { range in
            let from = utf16Offset(of: range.lowerBound)
            let to = utf16Offset(of: range.upperBound)
            return NSRange(location: from, length: to - from)
        }
    }

    private var activeSearchPattern: String? {
        if case let .commandLine(prefix, currentBuffer) = state.mode,
           (prefix == "/" || prefix == "?"),
           !currentBuffer.isEmpty
        {
            return currentBuffer
        }
        guard !state.hlsearchSuspended else { return nil }
        return state.lastSearch?.pattern
    }

    private func lineForOffset(_ offset: Int) -> Int {
        var b = buffer
        b.cursor = max(0, min(offset, b.text.count))
        return b.cursorLine
    }

    /// Human-readable mode label for status lines (`NORMAL`, `INSERT`, …).
    public var modeLabel: String { state.mode.label }
}
