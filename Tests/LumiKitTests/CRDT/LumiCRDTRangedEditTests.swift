import Testing
import Foundation
@testable import LumiKit

@Suite("LumiCRDT — ranged diff (pure)")
struct LumiCRDTRangedEditPureTests {
    private typealias Edit = LumiCRDT.RangedEdit

    @Test("identical strings produce no edit")
    func identical() {
        #expect(LumiCRDT.rangedEdit(from: "same", to: "same") == nil)
        #expect(LumiCRDT.rangedEdit(from: "", to: "") == nil)
    }

    @Test("insert in the middle keeps prefix and suffix")
    func middleInsert() {
        #expect(LumiCRDT.rangedEdit(from: "hello world", to: "hello brave world")
            == Edit(start: 6, deleteLength: 0, insert: "brave "))
    }

    @Test("delete, replace, append, prepend")
    func basicShapes() {
        #expect(LumiCRDT.rangedEdit(from: "abcdef", to: "abef") == Edit(start: 2, deleteLength: 2, insert: ""))
        #expect(LumiCRDT.rangedEdit(from: "abcdef", to: "abXYef") == Edit(start: 2, deleteLength: 2, insert: "XY"))
        #expect(LumiCRDT.rangedEdit(from: "abc", to: "abcd") == Edit(start: 3, deleteLength: 0, insert: "d"))
        #expect(LumiCRDT.rangedEdit(from: "abc", to: "zabc") == Edit(start: 0, deleteLength: 0, insert: "z"))
        #expect(LumiCRDT.rangedEdit(from: "", to: "new") == Edit(start: 0, deleteLength: 0, insert: "new"))
        #expect(LumiCRDT.rangedEdit(from: "old", to: "") == Edit(start: 0, deleteLength: 3, insert: ""))
    }

    @Test("prefix and suffix never overlap on repeated characters")
    func repeatedChars() {
        // "aaa" -> "aa": prefix 2, suffix limited to 0 → delete one 'a'.
        #expect(LumiCRDT.rangedEdit(from: "aaa", to: "aa") == Edit(start: 2, deleteLength: 1, insert: ""))
        #expect(LumiCRDT.rangedEdit(from: "aa", to: "aaa") == Edit(start: 2, deleteLength: 0, insert: "a"))
    }

    @Test("offsets are UTF-16 code units (emoji = 2 units)")
    func utf16Offsets() {
        // "😀" is a surrogate pair → occupies 2 UTF-16 units.
        #expect(LumiCRDT.rangedEdit(from: "😀a", to: "😀b") == Edit(start: 2, deleteLength: 1, insert: "b"))
        #expect(LumiCRDT.rangedEdit(from: "x😀y", to: "xy") == Edit(start: 1, deleteLength: 2, insert: ""))
    }

    @Test("canonically-equivalent but distinct scalars are still diffed")
    func canonicalEquivalence() {
        // Precomposed é (U+00E9) vs e + combining acute (U+0065 U+0301).
        let edit = LumiCRDT.rangedEdit(from: "caf\u{E9}", to: "cafe\u{301}")
        #expect(edit == Edit(start: 3, deleteLength: 1, insert: "e\u{301}"))
    }
}

/// Extension of the `.serialized` `LumiCRDTTests` suite (not a separate
/// suite) so these share its ordering domain — separate suites run in
/// parallel and yrs panics on concurrent transactions across docs.
extension LumiCRDTTests {
    @Test("setText reaches the exact target text, including non-BMP and combining marks")
    func exactResult() async {
        let crdt = LumiCRDT(seed: "caf\u{E9} 😀 one two")
        for target in ["cafe\u{301} 😀 one two", "cafe\u{301} 😀😀 one", "", "fresh", "fresh 👩‍👩‍👧 end"] {
            await crdt.setText(target)
            #expect(await crdt.text() == target)
        }
    }

    @Test("a one-character edit to a large doc produces a small update")
    func smallUpdate() async throws {
        let body = String(repeating: "lorem ipsum dolor sit amet ", count: 400) // ~10.8 KB
        let crdt = LumiCRDT(seed: body)
        let sv = await crdt.stateVector()
        await crdt.setText(body + "!")
        let update = try await crdt.encodeDiff(againstStateVector: sv)
        // Whole-body delete + reinsert would carry the entire body again.
        #expect(update.count < 200)
    }

    @Test("unchanged setText produces an empty diff")
    func noop() async throws {
        let crdt = LumiCRDT(seed: "stable")
        let sv = await crdt.stateVector()
        await crdt.setText("stable")
        let peer = LumiCRDT()
        try await peer.apply(update: await crdt.encodeStateAsUpdate())
        let diff = try await crdt.encodeDiff(againstStateVector: sv)
        try await peer.apply(update: diff)
        #expect(await peer.text() == "stable")
        #expect(await crdt.stateVector() == sv)
    }

    @Test("concurrent setText edits in different regions both survive the merge")
    func concurrentRegionsMerge() async throws {
        let a = LumiCRDT(seed: "alpha\nbeta\ngamma\n")
        let b = LumiCRDT()
        try await b.apply(update: await a.encodeStateAsUpdate())
        let svA = await a.stateVector()
        let svB = await b.stateVector()

        await a.setText("ALPHA\nbeta\ngamma\n")   // edit first line
        await b.setText("alpha\nbeta\nGAMMA!\n")  // edit last line

        let fromA = try await a.encodeDiff(againstStateVector: svB)
        let fromB = try await b.encodeDiff(againstStateVector: svA)
        try await a.apply(update: fromB)
        try await b.apply(update: fromA)

        let merged = "ALPHA\nbeta\nGAMMA!\n"
        #expect(await a.text() == merged)
        #expect(await b.text() == merged)
    }
}
