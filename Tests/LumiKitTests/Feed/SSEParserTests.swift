import Foundation
import Testing
@testable import LumiKit

private func parseAll(_ data: Data, splits: [Int]) -> [SSEItem] {
    var p = SSEParser()
    var out: [SSEItem] = []
    var start = 0
    for s in splits + [data.count] where s >= start {
        out += p.feed(data[start..<s])
        start = s
    }
    return out
}

private func events(_ items: [SSEItem]) -> [SSEEvent] {
    items.compactMap { if case let .event(e) = $0 { e } else { nil } }
}

@Suite("SSE parser + feed events against the shared .sse fixtures")
struct SSEParserTests {
    @Test("basic stream decodes every §3.3 event in order")
    func basic() throws {
        let data = try Fixtures.data("feed/stream.basic.sse")
        let items = parseAll(data, splits: [])
        #expect(items.contains(.comment("ping")))
        let decoded = events(items).compactMap(FeedEvent.decode)
        let v1 = "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f", v2 = "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d"
        guard case let .hello(h) = decoded.first else { Issue.record("first event must be hello"); return }
        #expect(h.protocolVersion == 1)
        #expect(h.vaults == [FeedVaultHead(vaultID: v1, seq: 42, role: "Editor", canEdit: true),
                             FeedVaultHead(vaultID: v2, seq: 7, role: "Viewer", canEdit: false)])
        #expect(Array(decoded.dropFirst()) == [
            .vaultHead(vaultID: v1, seq: 43),
            .vaultAccess(vaultID: v2, role: "Editor", canEdit: true),
            .vaultUpdated(vaultID: v1, fields: ["name", "federation"]),
            .vaultRevoked(vaultID: v2, reason: "removed"),
            .reconnect(afterMs: 0)
        ])
    }

    @Test("every chunk boundary yields the same events", arguments: ["feed/stream.basic.sse", "feed/stream.crlf-multiline.sse", "feed/stream.session-ended.sse"])
    func chunkCuts(_ fixture: String) throws {
        let data = try Fixtures.data(fixture)
        let whole = parseAll(data, splits: [])
        for cut in 1..<data.count {
            #expect(parseAll(data, splits: [cut]) == whole, "cut at \(cut)")
        }
        #expect(parseAll(data, splits: Array(1..<data.count)) == whole, "1-byte chunks")
    }

    @Test("CRLF, BOM, multi-line data, field without space, unknown event")
    func crlfMultiline() throws {
        let evs = events(parseAll(try Fixtures.data("feed/stream.crlf-multiline.sse"), splits: []))
        #expect(evs.map(\.event) == ["hello", "vault.future_thing", "vault.head"])
        #expect(evs[0].data.contains("\n\"user_id\""))
        guard case let .hello(h)? = FeedEvent.decode(evs[0]) else { Issue.record("hello"); return }
        #expect(h.vaults.isEmpty)
        #expect(FeedEvent.decode(evs[1]) == .unknown(name: "vault.future_thing"))
        #expect(FeedEvent.decode(evs[2]) == .vaultHead(vaultID: "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f", seq: 44))
    }

    @Test("CR at a chunk end followed by LF is one line break")
    func splitCRLF() {
        var p = SSEParser()
        var out = p.feed(Array("data: a\r".utf8))
        out += p.feed(Array("\n\r\n".utf8))
        #expect(out == [.event(SSEEvent(event: "message", data: "a"))])
    }

    @Test("multi-byte UTF-8 split across chunks survives")
    func utf8Split() {
        let bytes = Array("data: ação\n\n".utf8)
        var p = SSEParser()
        let idx = bytes.firstIndex(of: 0xC3)! + 1 // inside "ç"
        let out = p.feed(bytes[..<idx]) + p.feed(bytes[idx...])
        #expect(out == [.event(SSEEvent(event: "message", data: "ação"))])
    }

    @Test("malformed known payload decodes to nil (counted as a problem)")
    func malformed() {
        #expect(FeedEvent.decode(SSEEvent(event: "vault.head", data: "{nope")) == nil)
        #expect(FeedEvent.decode(SSEEvent(event: "session.ended", data: "{\"reason\":\"revoked\"}")) == .sessionEnded(reason: "revoked"))
    }

    @Test("backoff: 1 s ×2 capped at 30 s, never below Retry-After")
    func backoff() {
        let none: (Double) -> Double = { $0 }
        #expect((1...7).map { FeedBackoff.delay(attempt: $0, jitter: none) } == [1, 2, 4, 8, 16, 30, 30])
        #expect(FeedBackoff.delay(attempt: 1, retryAfter: 12, jitter: none) == 12)
        let jittered = FeedBackoff.delay(attempt: 3)
        #expect(jittered >= 3.2 && jittered <= 4.8)
    }
}
