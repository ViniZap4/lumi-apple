import Testing
import Foundation
import LumiKit
@testable import LumiUI

@Suite("VimController — pane key routing")
@MainActor
struct VimControllerPaneTests {
    private func make(_ text: String = "one\ntwo\nthree\n", moves: Bool = true) -> (VimController, Box) {
        let c = VimController(initialText: text)
        let box = Box()
        c.onPaneCommand = { cmd in
            box.commands.append(cmd)
            return moves
        }
        return (c, box)
    }

    final class Box { var commands: [PaneCommand] = [] }

    @Test("normal ⌃j moves the pane, not the cursor")
    func normalMoves() {
        let (c, box) = make()
        c.send(.ctrl("j"))
        #expect(box.commands == [.move(.down)])
        #expect(c.buffer.cursor == 0)
    }

    @Test("no pane that way: the key is consumed (cursor stays)")
    func consumedWhenNowhere() {
        let (c, box) = make(moves: false)
        c.send(.ctrl("j"))
        #expect(box.commands == [.move(.down)])
        #expect(c.buffer.cursor == 0)
    }

    @Test("insert: ⌃h is backspace and ⌃j a newline")
    func insertKeepsVim() {
        let (c, box) = make("ab")
        c.send(.character("A"))
        c.send(.ctrl("h"))
        c.send(.ctrl("j"))
        #expect(box.commands.isEmpty)
        #expect(c.buffer.text == "a\n")
    }

    @Test("⌃w l moves; ⌃w then unknown key does nothing to the text")
    func ctrlW() {
        let (c, box) = make()
        c.send(.ctrl("w"))
        #expect(c.paneKeys.awaitingWindowCommand)
        c.send(.character("l"))
        #expect(box.commands == [.move(.right)])
        c.send(.ctrl("w"))
        c.send(.character("x"))
        #expect(c.buffer.text == "one\ntwo\nthree\n")
    }

    @Test("a pane move leaves visual mode")
    func leavesVisual() {
        let (c, _) = make()
        c.send(.character("v"))
        #expect(c.state.mode.isVisual)
        c.send(.ctrl("l"))
        #expect(c.state.mode == .normal)
    }

    @Test("without a host, ⌃j is vim's line down")
    func noHost() {
        let c = VimController(initialText: "one\ntwo\n")
        c.send(.ctrl("j"))
        #expect(c.buffer.cursor == 4)
    }
}
