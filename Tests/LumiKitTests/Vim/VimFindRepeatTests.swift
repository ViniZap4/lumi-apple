import Testing
import Foundation
@testable import LumiKit

private func run(_ keys: String, on text: String, cursor: Int = 0) -> VimEngine.Result {
    var state = VimState.initial
    var buffer = TextBuffer(text: text, cursor: cursor)
    for char in keys {
        let input: VimInput = .character(char)
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — find-repeat ; ,")
struct VimFindRepeatTests {
    @Test("; repeats the last forward find")
    func semiRepeats() {
        // "abc bcd b" — 'b' at offsets 1, 4, 8.
        let r = run("fb;", on: "abc bcd b")
        #expect(r.buffer.cursor == 4)
    }

    @Test("; with count repeats N times")
    func semiCount() {
        // 'b' at 1, 4, 8. Start with fb (cursor=1), then 2; jumps two more 'b's → 8.
        let r = run("fb2;", on: "abc bcd b")
        #expect(r.buffer.cursor == 8)
    }

    @Test(", reverses last find direction")
    func commaReverses() {
        // fb → cursor=1, ; → cursor=4, , → reverse find from 4: prev 'b' at 1.
        let r = run("fb;,", on: "abc bcd b")
        #expect(r.buffer.cursor == 1)
    }

    @Test("; without prior find is a no-op")
    func semiNoMemory() {
        let r = run(";", on: "abc def", cursor: 2)
        #expect(r.buffer.cursor == 2)
    }

    @Test("; composes with operator (d;)")
    func semiWithDelete() {
        // "x.y.z." cursor=0. df. → delete through first '.' → "y.z." cursor=0.
        // Then d; → delete through next '.' → "z." cursor=0.
        let r = run("df.d;", on: "x.y.z.")
        #expect(r.buffer.text == "z.")
    }

    @Test("; preserves last-find memory across repeats")
    func memoryStable() {
        let r = run("fb;;", on: "ab cb db eb fb")
        // 'b' at 1, 4, 7, 10, 13. f(1) ;(4) ;(7).
        #expect(r.buffer.cursor == 7)
        #expect(r.state.lastFind?.target == "b")
    }

    @Test(", after t flips to T-style")
    func commaAfterTill() {
        // "ab cb db" — 'b' at 1, 4, 7. cursor=0.
        // tb → cursor=0 (one before 'b' at 1, but cursor was already 0 → unchanged? no wait).
        // Let me trace: cursor=0 'a'. t b finds 'b' at 1, cursor lands at 0 (b-1).
        // Already at 0 — no movement, but lastFind = (forwardBefore, 'b').
        // ;: tb again from 0, finds next 'b' at 1, cursor → 0. No motion.
        // Use cursor=2 to get useful coverage: t b → 'b' at 4, cursor=3.
        let r = run("tb,", on: "ab cb db", cursor: 5)
        // tb from cursor 5: find 'b' on the line, forward: at 7. cursor → 6.
        // , from cursor 6: reversed t (T) → find 'b' backward from 6: at 4. cursor → 5.
        #expect(r.buffer.cursor == 5)
    }
}
