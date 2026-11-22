import Testing
import Foundation
@testable import LumiKit

@Suite("Markdown block identity")
struct MarkdownBlockIdentityTests {
    private let source = """
    # Title

    First paragraph.

    ---

    Second paragraph.

    ---

    - a
    - b
    """

    @Test("ids are stable across re-parses of the same text")
    func stableAcrossParses() {
        #expect(MarkdownParser.parse(source).blockIDs == MarkdownParser.parse(source).blockIDs)
    }

    @Test("identical blocks get distinct ids via occurrence")
    func duplicatesAreDistinct() {
        let ids = MarkdownParser.parse(source).blockIDs
        #expect(Set(ids).count == ids.count)
        let rules = ids.enumerated().filter { MarkdownParser.parse(source).blocks[$0.offset] == .thematicBreak }.map(\.element)
        #expect(rules.count == 2)
        #expect(rules[0].contentHash == rules[1].contentHash)
        #expect(rules[0].occurrence == 0 && rules[1].occurrence == 1)
    }

    @Test("inserting a block keeps every other block's id (unlike offset identity)")
    func insertionKeepsOtherIDs() {
        let before = MarkdownParser.parse(source).blockIDs
        let edited = source.replacingOccurrences(of: "First paragraph.", with: "Inserted.\n\nFirst paragraph.")
        let after = MarkdownParser.parse(edited).blockIDs
        #expect(after.count == before.count + 1)
        #expect(Set(before).isSubset(of: Set(after)))
    }

    @Test("editing one block changes exactly that block's id")
    func editChangesOneID() {
        let before = MarkdownParser.parse(source).blockIDs
        let after = MarkdownParser.parse(source.replacingOccurrences(of: "Second paragraph.", with: "Second paragraph!")).blockIDs
        #expect(before.count == after.count)
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.count == 1)
    }

    @Test("splice keeps common prefix and suffix")
    func spliceMinimal() {
        let old = MarkdownParser.parse(source).blockIDs
        let new = MarkdownParser.parse(source.replacingOccurrences(of: "Second paragraph.", with: "Changed.")).blockIDs
        let splice = MarkdownBlockIdentity.splice(from: old, to: new)
        #expect(splice.removed.count == 1)
        #expect(splice.inserted.count == 1)
        #expect(splice.removed == splice.inserted)
        #expect(MarkdownBlockIdentity.splice(from: old, to: old).isEmpty)
    }

    @Test("splice handles pure insertion, deletion and full replacement")
    func spliceEdges() {
        let a = MarkdownBlockID(contentHash: 1, occurrence: 0)
        let b = MarkdownBlockID(contentHash: 2, occurrence: 0)
        let c = MarkdownBlockID(contentHash: 3, occurrence: 0)
        let x = MarkdownBlockID(contentHash: 9, occurrence: 0)
        #expect(MarkdownBlockIdentity.splice(from: [a, c], to: [a, b, c]) == .init(prefix: 1, removed: 1..<1, inserted: 1..<2))
        #expect(MarkdownBlockIdentity.splice(from: [a, b, c], to: [a, c]) == .init(prefix: 1, removed: 1..<2, inserted: 1..<1))
        #expect(MarkdownBlockIdentity.splice(from: [a, b], to: [x]) == .init(prefix: 0, removed: 0..<2, inserted: 0..<1))
        #expect(MarkdownBlockIdentity.splice(from: [], to: [a, b]) == .init(prefix: 0, removed: 0..<0, inserted: 0..<2))
        // Repeated ids: [a, a] → [a] must not over-count the shared part.
        let a1 = MarkdownBlockID(contentHash: 1, occurrence: 1)
        let s = MarkdownBlockIdentity.splice(from: [a, a1], to: [a])
        #expect(s.prefix + (2 - s.removed.upperBound) <= 1 + 1)
        #expect(s.removed.count - s.inserted.count == 1)
    }
}
