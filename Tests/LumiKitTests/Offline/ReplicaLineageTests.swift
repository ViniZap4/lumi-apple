import Testing
import Foundation
@testable import LumiKit

@Suite("ReplicaLineage — crdt_epoch decision and wire decoding")
struct ReplicaLineageTests {
    @Test("epoch decision table")
    func decisionTable() {
        #expect(ReplicaLineage.compareEpoch(replica: "a", server: "a") == .same)
        #expect(ReplicaLineage.compareEpoch(replica: "a", server: "b") == .changed)
        #expect(ReplicaLineage.compareEpoch(replica: nil, server: "b") == .unknown)
        #expect(ReplicaLineage.compareEpoch(replica: "a", server: nil) == .unknown)
        #expect(ReplicaLineage.compareEpoch(replica: "", server: "a") == .unknown)
        #expect(ReplicaLineage.compareEpoch(replica: nil, server: nil) == .unknown)
    }

    @Test("note DTO, snapshot and ws-ticket decode crdt_epoch; absent stays nil")
    func decoding() throws {
        let vault = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let note = try JSONDecoder().decode(RemoteNote.self, from: Data("""
        {"id":"n","vault_id":"\(vault)","path":"n.md","title":"N","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z","crdt_epoch":"0123abcd"}
        """.utf8))
        #expect(note.crdtEpoch == "0123abcd")
        let old = try JSONDecoder().decode(RemoteNote.self, from: Data("""
        {"id":"n","vault_id":"\(vault)","path":"n.md","title":"N"}
        """.utf8))
        #expect(old.crdtEpoch == nil)
        // Round-trips through the cache encoding.
        let again = try JSONDecoder().decode(RemoteNote.self, from: JSONEncoder().encode(note))
        #expect(again.crdtEpoch == "0123abcd")

        let ticket = try JSONDecoder().decode(WSTicket.self, from: Data("""
        {"ticket":"t","expires_at":"2026-01-01T00:00:30Z","crdt_epoch":"e1"}
        """.utf8))
        #expect(ticket.crdtEpoch == "e1")
        #expect(try JSONDecoder().decode(WSTicket.self, from: Data(#"{"ticket":"t"}"#.utf8)).crdtEpoch == nil)

        let snap = try JSONDecoder().decode(RemoteNoteSnapshot.self, from: Data("""
        {"id":"n","path":"n.md","text":"x","vector_clock":"AA==","crdt_epoch":"e1"}
        """.utf8))
        #expect(snap.crdtEpoch == "e1")
    }

    @Test("replica state records carry the epoch; old records without it keep the stored one")
    func replicaStateCodable() throws {
        let s = ReplicaState(dirty: true, knownServerSV: Data([0]), noteCreatedAt: nil, crdtEpoch: "e1")
        let back = try JSONDecoder().decode(ReplicaState.self, from: JSONEncoder().encode(s))
        #expect(back.crdtEpoch == "e1")
        let legacy = try JSONDecoder().decode(ReplicaState.self, from: Data(#"{"dirty":false,"knownServerSV":""}"#.utf8))
        #expect(legacy.crdtEpoch == nil)
    }
}
