import Testing
import Foundation
@testable import LumiKit

@Suite("Awareness — y-protocols wire format + state machine")
struct AwarenessTests {
    @Test("encode matches y-protocols encodeAwarenessUpdate byte for byte")
    func wireBytes() {
        // awarenessProtocol.encodeAwarenessUpdate(aw, [1]) with clientID 1,
        // clock 1, state {"a":1}: varUint(1) varUint(1) varUint(1) varString('{"a":1}')
        let one = AwarenessCodec.encode([AwarenessEntry(clientID: 1, clock: 1, stateJSON: #"{"a":1}"#)])
        #expect(Array(one) == [0x01, 0x01, 0x01, 0x07] + Array(#"{"a":1}"#.utf8))
        // Multi-byte varints (clientID 300 → AC 02) and a removal (null).
        let two = AwarenessCodec.encode([
            AwarenessEntry(clientID: 300, clock: 128, stateJSON: nil),
        ])
        #expect(Array(two) == [0x01, 0xAC, 0x02, 0x80, 0x01, 0x04] + Array("null".utf8))
    }

    @Test("decode round-trips and maps JSON null to a removal")
    func roundTrip() throws {
        let entries = [
            AwarenessEntry(clientID: 3_000_000_000, clock: 7, stateJSON: #"{"user":{"name":"Ana"}}"#),
            AwarenessEntry(clientID: 5, clock: 2, stateJSON: nil),
        ]
        #expect(try AwarenessCodec.decode(AwarenessCodec.encode(entries)) == entries)
    }

    @Test("decode rejects trailing garbage and legacy JSON presence")
    func rejects() {
        var bytes = AwarenessCodec.encode([AwarenessEntry(clientID: 1, clock: 1, stateJSON: "{}")])
        bytes.append(0x00)
        #expect(throws: AwarenessCodec.DecodeError.self) { try AwarenessCodec.decode(bytes) }
        #expect(throws: AwarenessCodec.DecodeError.self) { try AwarenessCodec.decode(Data(#"{"client_id":"x"}"#.utf8)) }
    }

    @Test("local state carries the web's user shape and colour")
    func localState() throws {
        var aw = AwarenessState(clientID: 42)
        let update = aw.setLocal(AwarenessUser(username: "vini", displayName: "Vini").stateJSON())
        let entries = try AwarenessCodec.decode(update)
        #expect(entries.count == 1)
        #expect(entries[0].clientID == 42)
        #expect(entries[0].clock == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(entries[0].stateJSON!.utf8)) as! [String: [String: String]]
        #expect(obj["user"]?["name"] == "Vini")
        #expect(obj["user"]?["color"] == AwarenessUser.color(for: "vini"))
        #expect(obj["user"]?["colorLight"] == AwarenessUser.color(for: "vini") + "33")
    }

    @Test("colour hash mirrors the web's pickColor (h*31+c |0, abs, mod 10)")
    func colourHash() {
        // JS: 'a' → 97 % 10 = 7 → '#a9b1d6'; 'ab' → 97*31+98 = 3105 % 10 = 5 → '#f7768e'
        #expect(AwarenessUser.color(for: "a") == "#a9b1d6")
        #expect(AwarenessUser.color(for: "ab") == "#f7768e")
        #expect(AwarenessUser.color(for: "") == "#7aa2f7")
    }

    @Test("apply: newer clocks win, null removes, stale frames are ignored")
    func applySemantics() {
        var aw = AwarenessState(clientID: 1)
        let web = ##"{"user":{"name":"Web","color":"#7aa2f7"}}"##
        var r = aw.apply(AwarenessCodec.encode([AwarenessEntry(clientID: 9, clock: 3, stateJSON: web)]))
        #expect(r.changed)
        #expect(aw.peers == [PeerPresence(clientID: 9, name: "Web", color: "#7aa2f7")])
        r = aw.apply(AwarenessCodec.encode([AwarenessEntry(clientID: 9, clock: 2, stateJSON: #"{"user":{"name":"Old"}}"#)]))
        #expect(!r.changed)
        // Server leave frame: same clock + 1, state null.
        r = aw.apply(AwarenessCodec.encode([AwarenessEntry(clientID: 9, clock: 4, stateJSON: nil)]))
        #expect(r.changed)
        #expect(aw.peers.isEmpty)
    }

    @Test("a leave frame for our own clientID makes us re-announce with a higher clock")
    func ownLeave() throws {
        var aw = AwarenessState(clientID: 7)
        _ = aw.setLocal(#"{"user":{"name":"me"}}"#)
        let r = aw.apply(AwarenessCodec.encode([AwarenessEntry(clientID: 7, clock: 1, stateJSON: nil)]))
        let reply = try #require(r.reply)
        let e = try AwarenessCodec.decode(reply)
        #expect(e[0].clock == 2)
        #expect(e[0].stateJSON != nil)
    }

    @Test("tick renews after 15 s and expires peers silent for 30 s")
    func tick() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var aw = AwarenessState(clientID: 1)
        _ = aw.setLocal("{}", now: t0)
        _ = aw.apply(AwarenessCodec.encode([AwarenessEntry(clientID: 2, clock: 1, stateJSON: #"{"user":{"name":"p"}}"#)]), now: t0)
        var r = aw.tick(now: t0.addingTimeInterval(10))
        #expect(r.renewal == nil && !r.changed)
        r = aw.tick(now: t0.addingTimeInterval(16))
        #expect(r.renewal != nil)
        #expect(aw.clock == 2)
        r = aw.tick(now: t0.addingTimeInterval(31))
        #expect(r.changed)
        #expect(aw.peers.isEmpty)
    }
}
