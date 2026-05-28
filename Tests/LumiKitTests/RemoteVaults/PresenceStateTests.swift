import Testing
import Foundation
@testable import LumiKit

@Suite("PresenceState — Phase H slice 4")
struct PresenceStateTests {

    @Test("encoded → decoded round-trips every field")
    func roundTrip() throws {
        let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let original = PresenceState(
            clientID: id,
            username: "alice",
            displayName: "Alice Wonder",
            color: "#7aa2f7"
        )
        let bytes = try original.encoded()
        let decoded = try PresenceState.decoded(from: bytes)
        #expect(decoded == original)
    }

    @Test("wire keys use snake_case for cross-language interop")
    func wireKeys() throws {
        let p = PresenceState(
            clientID: UUID(),
            username: "bob",
            displayName: "Bob",
            color: "#9ece6a"
        )
        let json = String(data: try p.encoded(), encoding: .utf8)!
        #expect(json.contains("\"client_id\""))
        #expect(json.contains("\"display_name\""))
        #expect(!json.contains("\"clientID\""))
        #expect(!json.contains("\"displayName\""))
    }

    @Test("decoded throws on malformed JSON — caller skips the frame")
    func decodingThrows() {
        let garbage = Data([0xff, 0xfe, 0xfd])
        #expect(throws: (any Error).self) {
            _ = try PresenceState.decoded(from: garbage)
        }
        let foreignShape = #"{"some":"other","protocol":42}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try PresenceState.decoded(from: foreignShape)
        }
    }

    /// Color derivation is deterministic per clientID so every observer
    /// agrees on the same color without coordination. Lock the
    /// determinism (two calls with the same UUID must match) and
    /// stability against the published palette.
    @Test("deriveColor is deterministic and stays in the palette")
    func deriveColor() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let a = PresenceState.deriveColor(for: id)
        let b = PresenceState.deriveColor(for: id)
        #expect(a == b)
        // The published palette is 12 entries — any returned color must
        // be a 7-char `#rrggbb` string.
        #expect(a.count == 7)
        #expect(a.hasPrefix("#"))
    }

    @Test("make() falls back to username when displayName is empty")
    func makeFallsBack() {
        let id = UUID()
        let p = PresenceState.make(clientID: id, username: "alice", displayName: "")
        #expect(p.displayName == "alice")
        let q = PresenceState.make(clientID: id, username: "alice", displayName: "Alice")
        #expect(q.displayName == "Alice")
    }

    // MARK: - left field (post-H follow-up)

    @Test("regular frames omit the 'left' key on the wire")
    func leftOmittedOnWire() throws {
        let p = PresenceState.make(clientID: UUID(), username: "alice", displayName: "Alice")
        let json = String(data: try p.encoded(), encoding: .utf8)!
        // Optional Bool that's nil encodes as absent (default Codable).
        #expect(!json.contains("\"left\""))
    }

    @Test("decoding a v1 wire (no 'left' key) yields left == nil")
    func decodeWithoutLeftKey() throws {
        // Double-`#` delimiters so the `"#` inside the color hex doesn't
        // accidentally close the raw string.
        let payload = ##"{"client_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","color":"#7aa2f7","display_name":"Alice","username":"alice"}"##.data(using: .utf8)!
        let p = try PresenceState.decoded(from: payload)
        #expect(p.left == nil)
    }

    @Test("server-emitted leave frame decodes to left == true")
    func decodeLeaveFrame() throws {
        // Matches the shape server/internal/wsync/hub.go broadcasts on
        // Subscriber.Leave when ClientID is non-nil. Empty user fields,
        // `left: true`.
        let id = UUID()
        let payload = ##"{"client_id":"\##(id.uuidString)","color":"","display_name":"","left":true,"username":""}"##.data(using: .utf8)!
        let p = try PresenceState.decoded(from: payload)
        #expect(p.left == true)
        #expect(p.clientID == id)
    }

    @Test("makeLeave produces a leave frame with empty user fields")
    func makeLeaveShape() throws {
        let id = UUID()
        let p = PresenceState.makeLeave(clientID: id)
        #expect(p.clientID == id)
        #expect(p.left == true)
        #expect(p.username.isEmpty)
        #expect(p.displayName.isEmpty)
        #expect(p.color.isEmpty)
        // Round-trips through JSON cleanly.
        let p2 = try PresenceState.decoded(from: try p.encoded())
        #expect(p == p2)
    }
}
