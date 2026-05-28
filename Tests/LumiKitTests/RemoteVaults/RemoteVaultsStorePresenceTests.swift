import Testing
import Foundation
@testable import LumiKit

/// Post-H follow-up: presence TTL + leave-frame handling.
///
/// The store maintains a per-peer `lastSeen` stamp and an explicit
/// "left" path so peers disappear from the UI both when the server
/// emits a clean leave frame AND when their heartbeat silently stops
/// (hard network drop). These tests drive both via a fixed clock so
/// the wall-clock TTL (45s) doesn't have to elapse.
@Suite("RemoteVaultsStore — presence TTL + leave-frame handling")
@MainActor
struct RemoteVaultsStorePresenceTests {

    @Test("a normal heartbeat frame upserts the peer into openNotePresence")
    func heartbeatAdds() throws {
        let store = RemoteVaultsStore(client: LumiAPIClient())
        let id = UUID()
        let p = PresenceState.make(clientID: id, username: "alice", displayName: "Alice")
        store.applyPresenceFrame(try p.encoded())
        #expect(store.openNotePresence.count == 1)
        #expect(store.openNotePresence.first?.clientID == id)
    }

    @Test("a leave frame (left == true) removes the peer immediately")
    func leaveFrameRemoves() throws {
        let store = RemoteVaultsStore(client: LumiAPIClient())
        let id = UUID()
        let arrive = PresenceState.make(clientID: id, username: "bob", displayName: "Bob")
        store.applyPresenceFrame(try arrive.encoded())
        #expect(store.openNotePresence.count == 1)

        let leave = PresenceState.makeLeave(clientID: id)
        store.applyPresenceFrame(try leave.encoded())
        #expect(store.openNotePresence.isEmpty)
    }

    @Test("cullStalePresence drops peers older than the TTL, keeps fresh ones")
    func cullDropsStale() throws {
        let store = RemoteVaultsStore(client: LumiAPIClient())
        let staleID = UUID()
        let freshID = UUID()
        let now = Date()
        let stale = PresenceState.make(clientID: staleID, username: "alice", displayName: "Alice")
        let fresh = PresenceState.make(clientID: freshID, username: "bob", displayName: "Bob")

        // Drive arrival timestamps via the test-seam overload.
        store.applyPresenceFrame(try stale.encoded(),
                                 now: now.addingTimeInterval(-60))
        store.applyPresenceFrame(try fresh.encoded(),
                                 now: now.addingTimeInterval(-5))
        #expect(store.openNotePresence.count == 2)

        store.cullStalePresence(now: now)

        #expect(store.openNotePresence.count == 1)
        #expect(store.openNotePresence.first?.clientID == freshID)
    }

    @Test("a fresh heartbeat resets the lastSeen stamp")
    func heartbeatRefreshesLastSeen() throws {
        let store = RemoteVaultsStore(client: LumiAPIClient())
        let id = UUID()
        let now = Date()
        let p = PresenceState.make(clientID: id, username: "alice", displayName: "Alice")

        // Arrive at T-60s — would be evicted on a cull@now.
        store.applyPresenceFrame(try p.encoded(),
                                 now: now.addingTimeInterval(-60))
        // Re-broadcast at T-5s. The new stamp must replace the old one
        // so the peer survives the cull.
        store.applyPresenceFrame(try p.encoded(),
                                 now: now.addingTimeInterval(-5))

        store.cullStalePresence(now: now)
        #expect(store.openNotePresence.count == 1)
    }

    @Test("presenceStaleSeconds matches 3x the heartbeat cadence")
    func ttlMatchesContract() {
        #expect(RemoteVaultsStore.presenceStaleSeconds ==
                RemoteVaultsStore.presenceHeartbeatSeconds * 3)
    }
}
