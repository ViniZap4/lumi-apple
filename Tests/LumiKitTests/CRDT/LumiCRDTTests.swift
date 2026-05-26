import Testing
import Foundation
@testable import LumiKit

/// Serialized because yrs (the Rust runtime under YSwift) panics with
/// `ExclusiveAcqFailed(BorrowMutError)` when multiple tests open
/// transactions concurrently — the UniFFI bridge doesn't isolate the
/// borrow checker per-Doc cleanly under swift-testing's default
/// parallel runner.
@Suite("LumiCRDT — Phase H slice 1", .serialized)
struct LumiCRDTTests {

    @Test("empty doc reads empty text")
    func emptyDoc() async {
        let crdt = LumiCRDT()
        let text = await crdt.text()
        #expect(text == "")
    }

    @Test("seed parameter installs initial body")
    func seedInitialBody() async {
        let crdt = LumiCRDT(seed: "hello world")
        let text = await crdt.text()
        #expect(text == "hello world")
    }

    @Test("setText replaces the entire body")
    func setTextReplaces() async {
        let crdt = LumiCRDT(seed: "old contents")
        await crdt.setText("brand new")
        #expect(await crdt.text() == "brand new")
        await crdt.setText("")
        #expect(await crdt.text() == "")
    }

    /// Core CRDT round-trip: doc A makes edits, encodes its full state
    /// as an update, doc B applies it. B must converge to the same text.
    @Test("encodeStateAsUpdate → apply round-trips text between docs")
    func fullStateRoundTrip() async throws {
        let docA = LumiCRDT()
        let docB = LumiCRDT()

        await docA.setText("Hello from A")
        let update = await docA.encodeStateAsUpdate()
        #expect(!update.isEmpty)

        try await docB.apply(update: update)
        #expect(await docB.text() == "Hello from A")
    }

    /// Incremental diff: A has text X, B has text Y. A sends its state
    /// vector to B, B replies with a diff against that vector; A
    /// applies it. Result: A converges to the merged state (B's edits
    /// woven in on top of A's).
    @Test("encodeDiff(againstStateVector:) lets two docs converge incrementally")
    func incrementalDiffConverges() async throws {
        let docA = LumiCRDT()
        let docB = LumiCRDT()

        // Initial sync: A has "Hello"; B starts empty, pulls A's state.
        await docA.setText("Hello")
        let initial = await docA.encodeStateAsUpdate()
        try await docB.apply(update: initial)
        #expect(await docB.text() == "Hello")

        // B independently appends " world"; A wants the new chars only.
        // Note: we use setText here rather than a fine-grained insert
        // because setText is the only public mutation in slice 1. The
        // important invariant is that A *converges* to the same text,
        // not that the wire payload is minimal.
        await docB.setText("Hello world")

        let svA = await docA.stateVector()
        #expect(!svA.isEmpty)
        let diff = try await docB.encodeDiff(againstStateVector: svA)

        try await docA.apply(update: diff)
        #expect(await docA.text() == "Hello world")
    }

    /// State vector against itself: the diff must apply without
    /// changing the doc (no-op), even after multiple sync rounds.
    @Test("encodeDiff against own state vector is a no-op apply")
    func selfDiffIsNoOp() async throws {
        let crdt = LumiCRDT(seed: "stable")
        let sv = await crdt.stateVector()
        let diff = try await crdt.encodeDiff(againstStateVector: sv)
        // Empty diff is also acceptable; what matters is that applying
        // it doesn't corrupt the text.
        try await crdt.apply(update: diff)
        #expect(await crdt.text() == "stable")
    }

    /// Empty state vector means "the peer has nothing" — diff should
    /// produce the full state.
    @Test("encodeDiff with empty state vector yields the full state")
    func diffAgainstEmptyVectorIsFullState() async throws {
        let docA = LumiCRDT(seed: "complete text")
        let fullState = await docA.encodeStateAsUpdate()
        let diffAgainstEmpty = try await docA.encodeDiff(againstStateVector: Data())

        // Both payloads should bring a fresh peer to the same text.
        let recv1 = LumiCRDT()
        try await recv1.apply(update: fullState)
        #expect(await recv1.text() == "complete text")

        let recv2 = LumiCRDT()
        try await recv2.apply(update: diffAgainstEmpty)
        #expect(await recv2.text() == "complete text")
    }

    /// Malformed update bytes must throw (not crash, not silently
    /// no-op). lib0-v1 has a length-prefixed format; arbitrary
    /// garbage will fail to decode.
    @Test("apply rejects malformed update bytes with a throw")
    func malformedUpdateThrows() async {
        let crdt = LumiCRDT()
        let garbage = Data([0xff, 0xff, 0xff, 0xff, 0x00])
        await #expect(throws: (any Error).self) {
            try await crdt.apply(update: garbage)
        }
        // Doc still functions after the failed apply.
        #expect(await crdt.text() == "")
    }

    /// Independent text channels in different docs don't cross-talk
    /// when the `textName` differs. Confirms our keying matches the
    /// server's domain shape.
    @Test("different textName isolates channels")
    func differentTextNameIsolates() async throws {
        let docA = LumiCRDT(textName: "body", seed: "body content")
        let docB = LumiCRDT(textName: "presence")

        let update = await docA.encodeStateAsUpdate()
        try await docB.apply(update: update)

        // docB has a 'presence' channel; the 'body' channel update
        // landed but reading 'presence' (its named channel) shows
        // empty because no data flowed there.
        #expect(await docB.text() == "")
    }
}
