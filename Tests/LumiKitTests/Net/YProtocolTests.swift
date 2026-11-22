import Testing
import Foundation
@testable import LumiKit

@Suite("YProtocol — lib0 varint + y-protocols v1 framing")
struct YProtocolTests {
    // MARK: - varInt

    @Test("writeVarUint produces canonical lib0 LEB128 bytes for known cases")
    func writeVarUintCanonical() {
        var out = Data()
        YProtocol.writeVarUint(0, into: &out)
        #expect(out == Data([0x00]))

        out.removeAll()
        YProtocol.writeVarUint(0x7f, into: &out)  // largest single-byte
        #expect(out == Data([0x7f]))

        out.removeAll()
        YProtocol.writeVarUint(0x80, into: &out)  // boundary: two bytes
        #expect(out == Data([0x80, 0x01]))

        out.removeAll()
        YProtocol.writeVarUint(300, into: &out)  // canonical multi-byte
        #expect(out == Data([0xac, 0x02]))

        out.removeAll()
        YProtocol.writeVarUint(0xffffffff, into: &out)
        // 0xffffffff = 32 bits set → five 7-bit groups.
        #expect(out == Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
    }

    @Test("readVarUint reverses writeVarUint for a swath of values")
    func varUintRoundtrip() throws {
        // Hit single-byte, two-byte, three-byte, and a high-bit boundary.
        for v in [UInt64(0), 1, 0x7f, 0x80, 300, 0x3fff, 0x4000, 1 << 28, UInt64(UInt32.max)] {
            var out = Data()
            YProtocol.writeVarUint(v, into: &out)
            let (decoded, consumed) = try YProtocol.readVarUint(out, offset: 0)
            #expect(decoded == v)
            #expect(consumed == out.count)
        }
    }

    @Test("readVarUint at non-zero offset reads from the correct slice")
    func varUintOffset() throws {
        var out = Data([0xde, 0xad])  // junk prefix the caller already consumed
        YProtocol.writeVarUint(0x80, into: &out)
        let (value, consumed) = try YProtocol.readVarUint(out, offset: 2)
        #expect(value == 0x80)
        #expect(consumed == 2)
    }

    @Test("readVarUint throws shortRead when the stream ends mid-varint")
    func varUintShortRead() {
        // Last byte has the continuation bit set → varint not complete.
        let truncated = Data([0xff])
        #expect(throws: YProtocol.DecodeError.shortRead) {
            _ = try YProtocol.readVarUint(truncated, offset: 0)
        }
    }

    // MARK: - varBytes

    @Test("writeVarBytes / readVarBytes round-trip on arbitrary payloads")
    func varBytesRoundtrip() throws {
        let payloads: [Data] = [
            Data(),
            Data([0]),
            Data(repeating: 0xaa, count: 127),  // varint-len fits in one byte
            Data(repeating: 0xbb, count: 128),  // varint-len needs two bytes
            Data(repeating: 0xcc, count: 1024),
        ]
        for p in payloads {
            var out = Data()
            YProtocol.writeVarBytes(p, into: &out)
            let (decoded, consumed) = try YProtocol.readVarBytes(out, offset: 0)
            #expect(decoded == p)
            #expect(consumed == out.count)
        }
    }

    @Test("readVarBytes throws shortRead when body is truncated")
    func varBytesShortRead() {
        // Declares length=5 but only 3 bytes follow.
        let bad = Data([0x05, 0xde, 0xad, 0xbe])
        #expect(throws: YProtocol.DecodeError.shortRead) {
            _ = try YProtocol.readVarBytes(bad, offset: 0)
        }
    }

    // MARK: - Message helpers

    @Test("encodeSyncStep1 / decode round-trip carries the state vector")
    func step1Roundtrip() throws {
        let sv = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let frame = YProtocol.encodeSyncStep1(stateVector: sv)
        // Layout: [0 (sync), 0 (step1), varInt(5), 5 bytes]
        #expect(frame.first == YProtocol.messageSync)
        #expect(frame[1] == YProtocol.syncStep1)
        let parsed = try YProtocol.decode(frame)
        #expect(parsed.type == YProtocol.messageSync)
        #expect(parsed.syncSub == YProtocol.syncStep1)
        #expect(parsed.body == sv)
    }

    @Test("encodeSyncStep2 carries an update of arbitrary length")
    func step2Roundtrip() throws {
        let update = Data(repeating: 0x7e, count: 250)  // forces multi-byte varint
        let frame = YProtocol.encodeSyncStep2(update: update)
        let parsed = try YProtocol.decode(frame)
        #expect(parsed.type == YProtocol.messageSync)
        #expect(parsed.syncSub == YProtocol.syncStep2)
        #expect(parsed.body == update)
    }

    @Test("encodeSyncUpdate carries an update body")
    func syncUpdateRoundtrip() throws {
        let update = Data([0xaa, 0xbb, 0xcc])
        let frame = YProtocol.encodeSyncUpdate(update: update)
        let parsed = try YProtocol.decode(frame)
        #expect(parsed.type == YProtocol.messageSync)
        #expect(parsed.syncSub == YProtocol.syncUpdate)
        #expect(parsed.body == update)
    }

    @Test("encodeAwareness wraps an opaque payload")
    func awarenessRoundtrip() throws {
        let payload = Data([0xfe, 0xed])
        let frame = YProtocol.encodeAwareness(payload)
        // Layout: [1 (awareness), varInt(2), payload]
        #expect(frame.first == YProtocol.messageAwareness)
        let parsed = try YProtocol.decode(frame)
        #expect(parsed.type == YProtocol.messageAwareness)
        #expect(parsed.body == payload)
    }

    @Test("decode throws shortRead on a single-byte frame missing the payload")
    func decodeShortRead() {
        // [messageSync] with no sub-type byte after it.
        #expect(throws: YProtocol.DecodeError.shortRead) {
            _ = try YProtocol.decode(Data([YProtocol.messageSync]))
        }
    }

    @Test("decode throws unknownMessageType for unknown opcodes")
    func decodeUnknownType() {
        let frame = Data([0x42])  // not in the spec
        do {
            _ = try YProtocol.decode(frame)
            Issue.record("expected unknownMessageType throw")
        } catch let YProtocol.DecodeError.unknownMessageType(t) {
            #expect(t == 0x42)
        } catch {
            Issue.record("expected unknownMessageType, got \(error)")
        }
    }

    @Test("decode treats query-awareness as a body-less message")
    func decodeQueryAwareness() throws {
        let parsed = try YProtocol.decode(Data([YProtocol.messageQueryAwareness]))
        #expect(parsed.type == YProtocol.messageQueryAwareness)
        #expect(parsed.body.isEmpty)
    }

    // MARK: - Sync URL building

    private static let vault = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test("SyncURL swaps http→ws and stamps a ticket")
    func wsURLFromHTTP() throws {
        let url = try #require(SyncURL.make(baseURL: URL(string: "http://lumi.test")!, vaultID: Self.vault, noteID: "hello-world", auth: .ticket("tk-1")))
        #expect(url.absoluteString == "ws://lumi.test/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/notes/hello-world/sync?ticket=tk-1")
    }

    @Test("SyncURL falls back to ?token= and upgrades https→wss, keeping a base path")
    func wsURLToken() throws {
        let url = try #require(SyncURL.make(baseURL: URL(string: "https://lumi.test/lumi/")!, vaultID: Self.vault, noteID: "x", auth: .token("tok")))
        #expect(url.absoluteString == "wss://lumi.test/lumi/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/notes/x/sync?token=tok")
    }

    @Test("SyncURL percent-encodes slugs with reserved chars")
    func wsURLEncodesSlug() throws {
        let url = try #require(SyncURL.make(baseURL: URL(string: "https://lumi.test")!, vaultID: Self.vault, noteID: "with space", auth: .token("t")))
        #expect(url.absoluteString.contains("/notes/with%20space/sync"))
    }

    @Test("message numbering matches y-websocket (auth=2, queryAwareness=3)")
    func numbering() throws {
        #expect(YProtocol.messageSync == 0)
        #expect(YProtocol.messageAwareness == 1)
        #expect(YProtocol.messageAuth == 2)
        #expect(YProtocol.messageQueryAwareness == 3)
        #expect(YProtocol.encodeQueryAwareness() == Data([3]))
        let denied = try YProtocol.decode(Data([2, 0, 3, 0x61, 0x62, 0x63]))
        #expect(denied.type == YProtocol.messageAuth)
        #expect(denied.syncSub == YProtocol.authPermissionDenied)
    }

    @Test("backoff: 100 ms doubling, capped at 2.5 s, jitter bounded")
    func backoff() {
        #expect(SyncBackoff.delay(attempt: 1, jitter: 0) == 0.1)
        #expect(SyncBackoff.delay(attempt: 2, jitter: 0) == 0.2)
        #expect(SyncBackoff.delay(attempt: 5, jitter: 0) == 1.6)
        #expect(SyncBackoff.delay(attempt: 6, jitter: 0) == 2.5)
        #expect(SyncBackoff.delay(attempt: 99, jitter: 0) == 2.5)
        #expect(SyncBackoff.delay(attempt: 0, jitter: 0) == 0.1)
        for _ in 0..<50 {
            let d = SyncBackoff.delay(attempt: 9)
            #expect(d >= 2.0 && d <= 3.0)
        }
    }
}
