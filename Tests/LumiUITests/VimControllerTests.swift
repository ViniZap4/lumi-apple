import Testing
import Foundation
import LumiKit
@testable import LumiUI

#if canImport(AppKit)
import AppKit
#endif

/// Records what the controller pushes into the text view.
@MainActor
final class FakeSurface: EditorTextSurface {
    let storage: NSMutableString
    private(set) var edits: [TextEdit] = []
    private(set) var selection = NSRange(location: 0, length: 0)
    var currentSelection: NSRange { selection }

    init(_ text: String) { storage = NSMutableString(string: text) }

    func applyEdits(_ e: [TextEdit]) {
        edits += e
        for x in e { x.apply(to: storage) }
    }

    func showSelection(_ range: NSRange, scroll: Bool) { selection = range }
    func discardMarkedText() {}
    func setUserSelection(_ r: NSRange) { selection = r }
}

/// A collaborative document double: records local ops, lets the test
/// inject remote changes.
@MainActor
final class FakeDocument: CollaborativeDocument {
    var text: String
    var isEditable = true
    var changeHandler: ((DocumentChange) -> Void)?
    private(set) var localOps: [[TextEdit]] = []
    private(set) var undoCalls = 0
    private(set) var redoCalls = 0
    private(set) var groupBreaks = 0

    init(_ text: String) { self.text = text }

    func applyLocal(_ edits: [TextEdit]) {
        localOps.append(edits)
        text = TextEdit.apply(edits, to: text)
    }
    func undo() -> Bool { undoCalls += 1; return true }
    func redo() -> Bool { redoCalls += 1; return true }
    func breakUndoGroup() { groupBreaks += 1 }

    func remote(_ edits: [TextEdit]) {
        text = TextEdit.apply(edits, to: text)
        changeHandler?(.remote(edits))
    }
}

@MainActor
private func keys(_ c: VimController, _ s: String) {
    for ch in s {
        switch ch {
        case "⎋": c.send(.escape)
        default: c.send(.character(ch))
        }
    }
}

@Suite("VimController — ranged edits, CRDT ops, cursor preservation")
@MainActor
struct VimControllerTests {
    @Test("typing emits one small ranged op per keystroke to the view and the CRDT (no String round-trip)")
    func rangedLocalOps() {
        let doc = FakeDocument("hello world")
        let c = VimController(document: doc)
        c.bindDocument()
        let surface = FakeSurface(doc.text)
        c.surface = surface
        keys(c, "A!?⎋0x")
        #expect(doc.localOps == [
            [TextEdit(location: 11, length: 0, replacement: "!")],
            [TextEdit(location: 12, length: 0, replacement: "?")],
            [TextEdit(location: 0, length: 1, replacement: "")],
        ])
        #expect(surface.edits == doc.localOps.flatMap { $0 })
        #expect(surface.storage as String == "ello world!?")
        #expect(doc.text == c.buffer.text)
    }

    @Test("a remote edit keeps vim mode, the cursor (V14) and the visual anchor")
    func remotePreservesCursor() {
        let doc = FakeDocument("hello world")
        let c = VimController(document: doc)
        c.bindDocument()
        let surface = FakeSurface(doc.text)
        c.surface = surface
        keys(c, "wv") // cursor on 'w' (6), visual anchored there
        doc.remote([TextEdit(location: 0, length: 0, replacement: ">> ")])
        #expect(c.buffer.text == ">> hello world")
        #expect(c.buffer.cursor == 9)
        #expect(c.state.mode == .visual(.characterwise, anchor: 9))
        #expect(surface.storage as String == ">> hello world")
        #expect(surface.selection == NSRange(location: 9, length: 1))
        // Remote edits never echo back as local ops.
        #expect(doc.localOps.isEmpty)
    }

    @Test("insert mode survives remote edits before and after the caret; typing continues in place")
    func insertModeSurvives() {
        let doc = FakeDocument("abc def")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface(doc.text)
        keys(c, "wi") // insert before 'd' (4)
        doc.remote([TextEdit(location: 0, length: 0, replacement: "XX")])
        doc.remote([TextEdit(location: 9, length: 0, replacement: "!")])
        keys(c, "Z")
        #expect(c.state.mode == .insert)
        #expect(c.buffer.text == "XXabc Zdef!")
        #expect(doc.localOps.last == [TextEdit(location: 6, length: 0, replacement: "Z")])
    }

    @Test("a remote deletion spanning the cursor collapses it to the edit; marks follow")
    func remoteDeleteMapsMarks() {
        let doc = FakeDocument("one two three")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface(doc.text)
        keys(c, "$ma0w") // mark a at end (12), cursor on 't' of two (4)
        doc.remote([TextEdit(location: 2, length: 6, replacement: "")]) // "on" + "three"
        #expect(c.buffer.text == "onthree")
        #expect(c.buffer.cursor == 2)
        #expect(c.state.marks["a"] == 6)
    }

    @Test("u / Ctrl-R in idle normal mode go to the CRDT undo, with counts")
    func undoIntercept() {
        let doc = FakeDocument("abc")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface(doc.text)
        keys(c, "x")
        keys(c, "u")
        c.send(.character("2"))
        c.send(.controlR)
        #expect(doc.undoCalls == 1)
        #expect(doc.redoCalls == 2)
        // Engine snapshots are not kept for server notes.
        #expect(c.state.history.undo.isEmpty)
        #expect(doc.groupBreaks >= 1)
    }

    @Test("undo changes come back through the document and move the caret to the change")
    func undoChangeMovesCaret() {
        let doc = FakeDocument("abc def")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface(doc.text)
        doc.changeHandler?(.undo([TextEdit(location: 4, length: 3, replacement: "")]))
        #expect(c.buffer.text == "abc ")
        #expect(c.buffer.cursor == 3) // clamped in normal mode
    }

    @Test("a throwaway controller (SwiftUI re-init) never steals remote changes")
    func throwawayDoesNotSteal() {
        let doc = FakeDocument("abc")
        let c = VimController(document: doc)
        c.bindDocument()
        _ = VimController(document: doc) // what State(initialValue:) re-evaluation does
        doc.remote([TextEdit(location: 0, length: 0, replacement: "X")])
        #expect(c.buffer.text == "Xabc")
    }

    @Test("nothing is editable before the session syncs (§2.2.3)")
    func notEditableBeforeSync() {
        let doc = FakeDocument("")
        doc.isEditable = false
        let c = VimController(document: doc)
        c.bindDocument()
        keys(c, "ihello")
        #expect(doc.localOps.isEmpty)
        #expect(c.buffer.text == "")
    }

    @Test("UTF-16 offsets around emoji and combining marks stay exact")
    func utf16Offsets() {
        let doc = FakeDocument("a😀b")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface(doc.text)
        keys(c, "$iZ") // insert before 'b' (char 2 → UTF-16 3)
        #expect(doc.localOps == [[TextEdit(location: 3, length: 0, replacement: "Z")]])
        doc.remote([TextEdit(location: 1, length: 2, replacement: "é")])
        #expect(c.buffer.text == "aéZb")
        keys(c, "Y")
        #expect(c.buffer.text == "aéZYb")
        #expect(doc.text == c.buffer.text)
    }

    @Test("local binding: outside changes apply as a ranged diff that keeps insert mode")
    func bindingKeepsMode() {
        let c = VimController(initialText: "hello")
        let surface = FakeSurface("hello")
        c.surface = surface
        var pushed: [String] = []
        c.onTextChange = { pushed.append($0) }
        keys(c, "A!")
        #expect(pushed == ["hello!"])
        c.replaceAll(with: "say hello!")
        #expect(c.state.mode == .insert)
        #expect(surface.edits.last == TextEdit(location: 0, length: 0, replacement: "say "))
        keys(c, "?")
        #expect(c.buffer.text == "say hello!?")
        // History survived (engine undo still works for local notes).
        #expect(!c.state.history.undo.isEmpty)
    }

    @Test("dead-key / IME commits are fed to the engine as typed text")
    func insertTyped() {
        let doc = FakeDocument("")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface("")
        keys(c, "i")
        c.insertTyped("á")
        c.insertTyped("日本\n")
        #expect(c.buffer.text == "á日本\n")
        #expect(doc.text == "á日本\n")
    }

    @Test("command selectors map to engine input; unknown ones are swallowed")
    func commandSelectors() {
        #expect(VimKeyMapper.input(forCommand: "insertNewline:") == .return)
        #expect(VimKeyMapper.input(forCommand: "deleteBackward:") == .backspace)
        #expect(VimKeyMapper.input(forCommand: "moveLeft:") == .arrow(.left))
        #expect(VimKeyMapper.input(forCommand: "moveUp:") == .arrow(.up))
        #expect(VimKeyMapper.input(forCommand: "cancelOperation:") == .escape)
        #expect(VimKeyMapper.input(forCommand: "moveWordForward:") == nil)
        #expect(VimKeyMapper.controlInput(for: "r") == .controlR)
    }
}

#if canImport(AppKit)

@Suite("VimAppKitTextView — TextKit 2, input system, incremental highlighting")
@MainActor
struct VimAppKitTextViewTests {
    private func make(_ text: String) -> (VimAppKitTextView, VimController, FakeDocument) {
        let doc = FakeDocument(text)
        let c = VimController(document: doc)
        c.bindDocument()
        let view = VimAppKitTextView(usingTextLayoutManager: true)
        view.styler = EditorStyler(theme: .tokyoNight, fontSize: 13)
        view.attach(c)
        return (view, c, doc)
    }

    @Test("the view stays on TextKit 2 and mirrors the buffer")
    func textKit2() {
        let (view, c, _) = make("hello\nworld")
        #expect(view.textLayoutManager != nil)
        c.send(.character("x"))
        #expect(view.string == "ello\nworld")
        #expect(view.textLayoutManager != nil)
    }

    @Test("ABNT2 dead key: ´ is marked text (not in the buffer), then 'a' commits á through the engine")
    func deadKey() {
        let (view, c, doc) = make("xy")
        c.send(.character("a")) // append after 'x' → insert mode at 1
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(c.buffer.text == "xy")
        #expect(doc.localOps.isEmpty)
        view.insertText("á", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(c.buffer.text == "xáy")
        #expect(view.string == "xáy")
        #expect(doc.localOps == [[TextEdit(location: 1, length: 0, replacement: "á")]])
    }

    @Test("insert-mode arrow commands move the caret instead of typing hjkl")
    func arrowsInInsert() {
        let (view, c, _) = make("abc")
        c.send(.character("i"))
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "abZc")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("press-and-hold accent replaces the previous character as one ranged op")
    func accentMenu() {
        let (view, c, doc) = make("")
        c.send(.character("i"))
        view.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        #expect(c.buffer.text == "é")
        #expect(view.string == "é")
        #expect(doc.localOps.last == [TextEdit(location: 0, length: 1, replacement: "é")])
    }

    @Test("a remote edit re-highlights only the touched paragraph")
    func incrementalHighlight() {
        let (view, c, doc) = make("# title\nplain line\n**bold** end")
        defer { withExtendedLifetime(c) {} }
        doc.remote([TextEdit(location: 8, length: 0, replacement: "very ")])
        #expect(view.string == "# title\nvery plain line\n**bold** end")
        #expect(view.lastHighlightedRange == NSRange(location: 8, length: 16))
    }

    @Test("a remote edit maps the caret through the change in the view (V14)")
    func remoteCaretInView() {
        let (view, c, doc) = make("hello world")
        c.send(.character("w"))
        doc.remote([TextEdit(location: 0, length: 0, replacement: ">> ")])
        #expect(view.selectedRange() == NSRange(location: 9, length: 1))
    }
}

#endif
