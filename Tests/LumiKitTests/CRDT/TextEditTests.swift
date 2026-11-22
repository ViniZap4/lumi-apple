import Testing
import Foundation
@testable import LumiKit

@Suite("TextDiff / TextDelta / PositionMapper (pure)")
struct TextEditPureTests {
    private func e(_ l: Int, _ n: Int, _ s: String) -> TextEdit { TextEdit(location: l, length: n, replacement: s) }

    @Test("identical strings produce no edit")
    func identical() {
        #expect(TextDiff.edit(from: "same", to: "same") == nil)
        #expect(TextDiff.edit(from: "", to: "") == nil)
    }

    @Test("basic shapes keep prefix and suffix")
    func shapes() {
        #expect(TextDiff.edit(from: "hello world", to: "hello brave world") == e(6, 0, "brave "))
        #expect(TextDiff.edit(from: "abcdef", to: "abef") == e(2, 2, ""))
        #expect(TextDiff.edit(from: "abcdef", to: "abXYef") == e(2, 2, "XY"))
        #expect(TextDiff.edit(from: "abc", to: "zabc") == e(0, 0, "z"))
        #expect(TextDiff.edit(from: "", to: "new") == e(0, 0, "new"))
        #expect(TextDiff.edit(from: "old", to: "") == e(0, 3, ""))
        #expect(TextDiff.edit(from: "aaa", to: "aa") == e(2, 1, ""))
    }

    @Test("offsets are UTF-16 code units")
    func utf16() {
        #expect(TextDiff.edit(from: "😀a", to: "😀b") == e(2, 1, "b"))
        #expect(TextDiff.edit(from: "x😀y", to: "xy") == e(1, 2, ""))
    }

    @Test("V12: a shared high surrogate never splits the pair")
    func v12Surrogates() {
        // 😀 = D83D DE00, 😁 = D83D DE01 — the prefix would stop mid-pair.
        let edit = TextDiff.edit(from: "a😀b", to: "a😁b")
        #expect(edit == e(1, 2, "😁"))
        #expect(TextEdit.apply([edit!], to: "a😀b") == "a😁b")
        // Shared low surrogate on the suffix side: U+1F600 = D83D DE00,
        // U+1FA00 = D83E DE00 — the suffix must back off to the pair.
        let suffixEdit = TextDiff.edit(from: "a\u{1F600}", to: "a\u{1FA00}")
        #expect(suffixEdit == e(1, 2, "\u{1FA00}"))
    }

    @Test("canonically-equivalent but distinct scalars are still diffed")
    func canonical() {
        let edit = TextDiff.edit(from: "caf\u{E9}", to: "cafe\u{301}")
        #expect(TextEdit.apply([edit!], to: "caf\u{E9}") == "cafe\u{301}")
    }

    @Test("delta → sequential edits at running offsets, delete+insert fused")
    func deltaEdits() {
        #expect(TextDelta.edits(from: [.retain(5), .insert(" brave")]) == [e(5, 0, " brave")])
        #expect(TextDelta.edits(from: [.retain(2), .delete(3), .insert("XY")]) == [e(2, 3, "XY")])
        #expect(TextDelta.edits(from: [.insert("> "), .retain(5), .delete(1)]) == [e(0, 0, "> "), e(7, 1, "")])
        let text = "hello world"
        let edits = TextDelta.edits(from: [.insert(">> "), .retain(6), .delete(5), .insert("there")])
        #expect(TextEdit.apply(edits, to: text) == ">> hello there")
    }

    @Test("V14: a caret at 6 maps to 9 after a remote '>> ' insert at 0")
    func v14() {
        #expect(PositionMapper.map(6, through: [e(0, 0, ">> ")]) == 9)
    }

    @Test("mapping: before/after/inside edits and assoc at the insertion point")
    func mapping() {
        let ins = e(4, 0, "XX")
        #expect(PositionMapper.map(3, through: [ins]) == 3)
        #expect(PositionMapper.map(4, through: [ins], assoc: .after) == 6)
        #expect(PositionMapper.map(4, through: [ins], assoc: .before) == 4)
        #expect(PositionMapper.map(9, through: [ins]) == 11)
        let del = e(2, 4, "")
        #expect(PositionMapper.map(1, through: [del]) == 1)
        #expect(PositionMapper.map(3, through: [del]) == 2)
        #expect(PositionMapper.map(6, through: [del]) == 2)
        #expect(PositionMapper.map(8, through: [del]) == 4)
        let sel = PositionMapper.map(NSRange(location: 2, length: 3), through: [e(0, 0, "ab")])
        #expect(sel == NSRange(location: 4, length: 3))
    }
}
