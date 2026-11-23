import Testing
import Foundation
@testable import LumiKit

@Suite("Panes — focus graph")
struct PaneGraphTests {
    private func go(_ from: PaneID?, _ c: PaneCommand, _ l: PaneLayout, previous: PaneID? = nil) -> PaneTarget? {
        PaneGraph.target(from: from, c, layout: l, previous: previous)
    }

    @Test("explorer alone: ⌃h opens the books drawer, nothing else moves")
    func explorerAlone() {
        let l = PaneLayout(main: .explorer)
        #expect(PaneGraph.panes(l) == [.explorer])
        #expect(go(.explorer, .move(.left), l) == PaneTarget(.sidebar, revealsSidebar: true))
        #expect(go(.explorer, .move(.right), l) == nil)
        #expect(go(.explorer, .move(.down), l) == nil)
        #expect(go(.explorer, .move(.up), l) == nil)
        #expect(go(.explorer, .next, l) == nil)
    }

    @Test("no sidebar available (iPhone): ⌃h goes nowhere")
    func noSidebar() {
        let l = PaneLayout(sidebarAvailable: false, main: .reader)
        #expect(go(.reader, .move(.left), l) == nil)
    }

    @Test("sidebar | reader")
    func sidebarReader() {
        let l = PaneLayout(sidebarVisible: true, main: .reader)
        #expect(PaneGraph.panes(l) == [.sidebar, .reader])
        #expect(go(.reader, .move(.left), l) == PaneTarget(.sidebar))
        #expect(go(.sidebar, .move(.right), l) == PaneTarget(.reader))
        #expect(go(.sidebar, .move(.left), l) == nil)
        #expect(go(.sidebar, .move(.down), l) == nil)
    }

    @Test("editor | preview (beside): ⌃l ⌃h, no vertical neighbours")
    func beside() {
        let l = PaneLayout(main: .editor, preview: .beside)
        #expect(PaneGraph.panes(l) == [.editor, .preview])
        #expect(go(.editor, .move(.right), l) == PaneTarget(.preview))
        #expect(go(.preview, .move(.left), l) == PaneTarget(.editor))
        #expect(go(.preview, .move(.right), l) == nil)
        #expect(go(.editor, .move(.down), l) == nil)
        #expect(go(.preview, .move(.up), l) == nil)
        #expect(go(.editor, .move(.left), l) == PaneTarget(.sidebar, revealsSidebar: true))
    }

    @Test("narrow split (tabs): preview is below the editor")
    func tabbed() {
        let l = PaneLayout(main: .editor, preview: .tabbed)
        #expect(go(.editor, .move(.down), l) == PaneTarget(.preview))
        #expect(go(.preview, .move(.up), l) == PaneTarget(.editor))
        #expect(go(.editor, .move(.right), l) == nil)
        #expect(go(.preview, .move(.down), l) == nil)
        #expect(go(.preview, .move(.left), l) == PaneTarget(.sidebar, revealsSidebar: true))
    }

    @Test("⌃w w / W cycle with wrap; ⌃w p previous")
    func cycle() {
        let l = PaneLayout(sidebarVisible: true, main: .editor, preview: .beside)
        #expect(PaneGraph.panes(l) == [.sidebar, .editor, .preview])
        #expect(go(.preview, .next, l) == PaneTarget(.sidebar))
        #expect(go(.sidebar, .previous, l) == PaneTarget(.preview))
        #expect(go(.editor, .next, l) == PaneTarget(.preview))
        #expect(go(.editor, .last, l, previous: .preview) == PaneTarget(.preview))
        #expect(go(.editor, .last, l, previous: nil) == nil)
        #expect(go(.editor, .last, l, previous: .editor) == nil)
        let hidden = PaneLayout(main: .editor, preview: .beside)
        #expect(go(.editor, .last, hidden, previous: .sidebar) == PaneTarget(.sidebar, revealsSidebar: true))
    }

    @Test("a stale focus resolves to the main pane")
    func resolve() {
        let l = PaneLayout(main: .reader)
        #expect(PaneGraph.resolve(.preview, in: l) == .reader)
        #expect(PaneGraph.resolve(nil, in: l) == .reader)
        #expect(go(.preview, .move(.left), l) == PaneTarget(.sidebar, revealsSidebar: true))
        // The preview only exists beside the editor.
        #expect(PaneLayout(main: .reader, preview: .beside).preview == .none)
    }

    @Test("nothing open: ⌃h still opens the drawer")
    func empty() {
        #expect(go(nil, .move(.left), PaneLayout()) == PaneTarget(.sidebar, revealsSidebar: true))
        #expect(go(nil, .move(.right), PaneLayout()) == nil)
        let open = PaneLayout(sidebarVisible: true)
        #expect(PaneGraph.resolve(nil, in: open) == .sidebar)
        #expect(go(nil, .move(.right), open) == nil)
    }
}

@Suite("Panes — editor key routing")
struct EditorPaneKeysTests {
    private func state(_ mode: VimMode = .normal, vimrc: String? = nil) -> VimState {
        var s = VimState.initial
        s.mode = mode
        if let vimrc { s.apply(vimrc: Vimrc.parse(vimrc)) }
        return s
    }

    @Test("normal: ⌃h ⌃j ⌃k ⌃l are pane moves")
    func normal() {
        var k = EditorPaneKeys()
        let s = state()
        #expect(k.feed(.ctrl("h"), state: s) == .pane(.move(.left), passIfUnhandled: false))
        #expect(k.feed(.ctrl("j"), state: s) == .pane(.move(.down), passIfUnhandled: false))
        #expect(k.feed(.ctrl("k"), state: s) == .pane(.move(.up), passIfUnhandled: false))
        #expect(k.feed(.ctrl("l"), state: s) == .pane(.move(.right), passIfUnhandled: false))
        #expect(k.feed(.character("j"), state: s) == .pass)
        #expect(k.feed(.controlD, state: s) == .pass)
    }

    @Test("visual: pane moves too")
    func visual() {
        var k = EditorPaneKeys()
        #expect(k.feed(.ctrl("l"), state: state(.visual(.characterwise, anchor: 0))) == .pane(.move(.right), passIfUnhandled: false))
    }

    @Test("insert / replace / command line: ⌃h backspace, ⌃j newline stay vim's")
    func insert() {
        var k = EditorPaneKeys()
        for mode: VimMode in [.insert, .replace, .commandLine(prefix: ":", buffer: "")] {
            #expect(k.feed(.ctrl("h"), state: state(mode)) == .pass)
            #expect(k.feed(.ctrl("j"), state: state(mode)) == .pass)
            #expect(k.feed(.ctrl("w"), state: state(mode)) == .pass)
        }
        #expect(!k.awaitingWindowCommand)
    }

    @Test("mid-command (count, operator) the key is vim's")
    func pending() {
        var k = EditorPaneKeys()
        var s = state()
        s.pendingKeys = [.character("d")]
        #expect(k.feed(.ctrl("h"), state: s) == .pass)
        s.pendingKeys = [.character("3")]
        #expect(k.feed(.ctrl("w"), state: s) == .pass)
    }

    @Test("setting off: ⌃hjkl pass, ⌃w chords still move")
    func settingOff() {
        var k = EditorPaneKeys(ctrlHJKL: false)
        let s = state()
        #expect(k.feed(.ctrl("l"), state: s) == .pass)
        #expect(k.feed(.ctrl("w"), state: s) == .consume)
        #expect(k.awaitingWindowCommand)
        #expect(k.feed(.character("l"), state: s) == .pane(.move(.right), passIfUnhandled: false))
        #expect(!k.awaitingWindowCommand)
    }

    @Test("⌃w chords: hjkl, ⌃h…, arrows, w W p; unknown key cancels")
    func windowChords() {
        let s = state()
        let cases: [(VimInput, PaneCommand?)] = [
            (.character("h"), .move(.left)), (.ctrl("j"), .move(.down)), (.arrow(.up), .move(.up)),
            (.character("w"), .next), (.ctrl("w"), .next), (.character("W"), .previous),
            (.character("p"), .last), (.character("x"), nil), (.escape, nil),
        ]
        for (second, expected) in cases {
            var k = EditorPaneKeys()
            #expect(k.feed(.ctrl("w"), state: s) == .consume)
            let out = k.feed(second, state: s)
            if let expected {
                #expect(out == .pane(expected, passIfUnhandled: false))
            } else {
                #expect(out == .consume)
            }
        }
    }

    @Test(".vimrc maps of ⌃h win; a map onto <C-w>h is a pane move; <C-w>… maps hand ⌃w to vim")
    func vimrc() {
        var k = EditorPaneKeys()
        let mapped = state(vimrc: "nnoremap <C-h> :noh<CR>")
        #expect(k.feed(.ctrl("h"), state: mapped) == .pass)
        #expect(k.feed(.ctrl("l"), state: mapped) == .pane(.move(.right), passIfUnhandled: false))
        let insertOnly = state(vimrc: "inoremap <C-h> <Left>")
        #expect(k.feed(.ctrl("h"), state: insertOnly) == .pane(.move(.left), passIfUnhandled: false))
        let navigator = state(vimrc: "nnoremap <C-j> <C-w>j")
        #expect(k.feed(.ctrl("j"), state: navigator) == .pane(.move(.down), passIfUnhandled: false))
        let ctrlW = state(vimrc: "nnoremap <C-w>x :w<CR>")
        #expect(k.feed(.ctrl("w"), state: ctrlW) == .pass)
        // Visual-only map leaves normal mode alone.
        let visualOnly = state(vimrc: "vnoremap <C-k> y")
        #expect(k.feed(.ctrl("k"), state: visualOnly) == .pane(.move(.up), passIfUnhandled: false))
        #expect(k.feed(.ctrl("k"), state: { var s = visualOnly; s.mode = .visual(.linewise, anchor: 0); return s }()) == .pass)
    }
}
