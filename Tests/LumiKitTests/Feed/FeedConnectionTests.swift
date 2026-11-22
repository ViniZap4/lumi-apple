import Foundation
import Testing
@testable import LumiKit

/// Fake streaming server for `/api/events`: each host gets a script of
/// responses (one per connection attempt). Chunks are delivered with small
/// delays so the client really reads incrementally; `hold` keeps the
/// connection open without bytes (ping-timeout tests).
final class FakeFeedProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var contentType = "text/event-stream"
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var hold = false
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var scripts: [String: [Reply]] = [:]
    private nonisolated(unsafe) static var seen: [String: [URLRequest]] = [:]
    private var pump: Task<Void, Never>?

    static func script(host: String, _ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        scripts[host] = replies
        seen[host] = []
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen[host] ?? []
    }

    private static func next(for req: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        let host = req.url?.host ?? ""
        seen[host, default: []].append(req)
        guard var list = scripts[host], !list.isEmpty else { return Reply(status: 503) }
        let r = list.removeFirst()
        scripts[host] = list.isEmpty ? [Reply(hold: true)] : list
        return r
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.next(for: request)
        var headers = reply.headers
        headers["Content-Type"] = reply.contentType
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let box = ProtocolBox(proto: self, client: client)
        pump = Task {
            for chunk in reply.chunks {
                try? await Task.sleep(for: .milliseconds(2))
                if Task.isCancelled { return }
                box.client?.urlProtocol(box.proto, didLoad: chunk)
            }
            if reply.hold {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                return
            }
            box.client?.urlProtocolDidFinishLoading(box.proto)
        }
    }

    override func stopLoading() { pump?.cancel() }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeFeedProtocol.self]
        return URLSession(configuration: c)
    }
}

/// URLProtocolClient isn't Sendable; the loading system serialises calls.
private struct ProtocolBox: @unchecked Sendable {
    let proto: URLProtocol
    let client: URLProtocolClient?
}

private func uniqueHost() -> String { "feed-\(UUID().uuidString.prefix(8).lowercased()).test" }

private func chunked(_ data: Data, size: Int = 7) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { data[$0..<min($0 + size, data.count)] }
}

private func fastConfig(pingTimeout: Duration = .seconds(30)) -> FeedConnection.Config {
    var c = FeedConnection.Config()
    c.pingTimeout = pingTimeout
    c.watchdogInterval = .milliseconds(20)
    c.jitter = { $0 }
    c.reconnectJitterMs = { 0 }
    c.sleep = { d in try await Task.sleep(for: min(d, .milliseconds(5))) } // compress backoff time
    return c
}

/// Collect outputs until `stop` returns true or the timeout elapses.
private func collect(_ conn: FeedConnection, timeout: Duration = .seconds(5),
                     until stop: @escaping @Sendable ([FeedConnection.Output]) -> Bool) async -> [FeedConnection.Output] {
    await withTaskGroup(of: [FeedConnection.Output]?.self) { group in
        group.addTask {
            var out: [FeedConnection.Output] = []
            for await o in conn.outputs {
                out.append(o)
                if stop(out) { return out }
            }
            return out
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        var result: [FeedConnection.Output] = []
        for await r in group {
            if let r { result = r; break } else { break }
        }
        group.cancelAll()
        await conn.stop()
        return result
    }
}

private func states(_ o: [FeedConnection.Output]) -> [AccountFeedState] {
    o.compactMap { if case let .state(s) = $0 { s } else { nil } }
}

@Suite("FeedConnection — URLSession SSE client against a fake /api/events")
struct FeedConnectionTests {
    @Test("streams events in order, auth in the header only, reconnects on `reconnect`")
    func basicAndReconnect() async throws {
        let host = uniqueHost()
        let data = try Fixtures.data("feed/stream.basic.sse")
        FakeFeedProtocol.script(host: host, [FakeFeedProtocol.Reply(chunks: chunked(data)),
                                             FakeFeedProtocol.Reply(chunks: chunked(data), hold: true)])
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)/lumi")!, session: FakeFeedProtocol.session,
                                  config: fastConfig(), tokenProvider: { "secret-token" })
        await conn.start()
        let out = await collect(conn) { o in states(o).filter { $0 == .open }.count >= 2 }
        let evs = out.compactMap { if case let .event(e) = $0 { e } else { nil } }
        #expect(states(out).prefix(2) == [.connecting, .open])
        #expect(evs.count >= 5)
        #expect(evs[1] == .vaultHead(vaultID: "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f", seq: 43))
        let reqs = FakeFeedProtocol.requests(host: host)
        #expect(reqs.count >= 2, "reconnect event opens a new stream")
        let first = try #require(reqs.first)
        #expect(first.url?.absoluteString == "https://\(host)/lumi/api/events")
        #expect(first.url?.query == nil, "token never in the URL")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(first.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test("401 → auth_dead and no further attempts")
    func unauthorized() async {
        let host = uniqueHost()
        FakeFeedProtocol.script(host: host, [FakeFeedProtocol.Reply(status: 401, contentType: "application/json")])
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)")!, session: FakeFeedProtocol.session,
                                  config: fastConfig(), tokenProvider: { "t" })
        await conn.start()
        let out = await collect(conn) { states($0).contains(.authDead) }
        #expect(states(out).last == .authDead)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(FakeFeedProtocol.requests(host: host).count == 1)
    }

    @Test("session.ended → auth_dead, stream not reopened")
    func sessionEnded() async throws {
        let host = uniqueHost()
        FakeFeedProtocol.script(host: host, [FakeFeedProtocol.Reply(chunks: [try Fixtures.data("feed/stream.session-ended.sse")])])
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)")!, session: FakeFeedProtocol.session,
                                  config: fastConfig(), tokenProvider: { "t" })
        await conn.start()
        let out = await collect(conn) { states($0).contains(.authDead) }
        #expect(out.contains(.event(.sessionEnded(reason: "revoked"))))
        #expect(states(out) == [.connecting, .open, .authDead])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(FakeFeedProtocol.requests(host: host).count == 1)
    }

    @Test("missing endpoint (404) or an HTML fallback → disabled (graceful degradation)", arguments: [404, 200])
    func featureDetect(_ status: Int) async {
        let host = uniqueHost()
        FakeFeedProtocol.script(host: host, [FakeFeedProtocol.Reply(status: status, contentType: "text/html",
                                                                    chunks: [Data("<html>".utf8)])])
        var cfg = fastConfig()
        cfg.sleep = { _ in try await Task.sleep(for: .seconds(60)) } // don't re-probe during the test
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)")!, session: FakeFeedProtocol.session,
                                  config: cfg, tokenProvider: { "t" })
        await conn.start()
        let out = await collect(conn) { states($0).contains(.disabled) }
        #expect(states(out) == [.connecting, .disabled])
    }

    @Test("no bytes for the ping timeout → reconnect")
    func pingTimeout() async {
        let host = uniqueHost()
        let hello = Data("event: hello\ndata: {\"protocol\":1,\"vaults\":[]}\n\n".utf8)
        FakeFeedProtocol.script(host: host, [FakeFeedProtocol.Reply(chunks: [hello], hold: true),
                                             FakeFeedProtocol.Reply(chunks: [hello], hold: true)])
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)")!, session: FakeFeedProtocol.session,
                                  config: fastConfig(pingTimeout: .milliseconds(150)), tokenProvider: { "t" })
        await conn.start()
        let out = await collect(conn) { o in states(o).filter { $0 == .open }.count >= 2 }
        #expect(out.contains { if case .problem = $0 { true } else { false } })
        let s = states(out)
        #expect(s.contains(.backoff(attempt: 1, retryInSeconds: 1)), "after hello the curve restarts at attempt 1")
        #expect(FakeFeedProtocol.requests(host: host).count >= 2)
    }

    @Test("429 with Retry-After backs off at least that long; 5xx climbs the curve")
    func retryAfter() async {
        let host = uniqueHost()
        FakeFeedProtocol.script(host: host, [
            FakeFeedProtocol.Reply(status: 429, contentType: "application/json", headers: ["Retry-After": "7"]),
            FakeFeedProtocol.Reply(status: 500, contentType: "application/json"),
            FakeFeedProtocol.Reply(status: 500, contentType: "application/json")
        ])
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)")!, session: FakeFeedProtocol.session,
                                  config: fastConfig(), tokenProvider: { "t" })
        await conn.start()
        let out = await collect(conn) { o in states(o).filter { if case .backoff = $0 { true } else { false } }.count >= 3 }
        let backoffs = states(out).compactMap { s -> Double? in if case let .backoff(_, d) = s { d } else { nil } }
        #expect(backoffs.prefix(3) == [7, 2, 4])
    }

    @Test("no token → auth_dead without touching the network")
    func noToken() async {
        let host = uniqueHost()
        FakeFeedProtocol.script(host: host, [])
        let conn = FeedConnection(baseURL: URL(string: "https://\(host)")!, session: FakeFeedProtocol.session,
                                  config: fastConfig(), tokenProvider: { nil })
        await conn.start()
        let out = await collect(conn) { states($0).contains(.authDead) }
        #expect(states(out) == [.connecting, .authDead])
        #expect(FakeFeedProtocol.requests(host: host).isEmpty)
    }
}
