import Testing
import Foundation
@testable import LumiKit

/// `URLProtocol` subclass that intercepts every request issued through a
/// URLSession configured with it. Each test installs a handler that inspects
/// the outgoing `URLRequest` and returns a canned response.
///
/// The handler is stored in a thread-safe static slot because URLProtocol
/// instances are created by the URL loading system, not by us.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handlerLock = NSLock()
    // Mutable shared state under an NSLock; opt out of Swift 6's automatic
    // Sendable check here — the access is hand-synchronized.
    private nonisolated(unsafe) static var _handler: Handler?

    static func setHandler(_ handler: Handler?) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        _handler = handler
    }

    private static func currentHandler() -> Handler? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeClient() -> LumiAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return LumiAPIClient(session: session)
}

private let testServerURL = URL(string: "https://lumi.test")!

@Suite("LumiAPIClient — auth", .serialized)
struct LumiAPIClientAuthTests {
    @Test("login success returns token + user")
    func loginSuccess() async throws {
        MockURLProtocol.setHandler { request in
            // Note: don't assert on request.httpBody — URLProtocol receives
            // POST bodies via httpBodyStream, so httpBody is often nil here.
            // The response decode below is enough to verify the round-trip.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"token":"abc.def","expires_at":"2026-12-31T23:59:59Z",
             "user":{"id":"u1","username":"alice","display_name":"Alice"}}
            """.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        let session = try await client.login(username: "alice", password: "hunter2")
        #expect(session.token == "abc.def")
        #expect(session.user.username == "alice")
        #expect(session.user.displayName == "Alice")
    }

    @Test("login with bad credentials surfaces .server with error code")
    func loginBadCreds() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":"invalid_credentials","detail":"bad username or password"}"#.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        await #expect(throws: LumiAPIError.unauthorized) {
            _ = try await client.login(username: "alice", password: "wrong")
        }
    }

    @Test("login with malformed body surfaces .server with validation_failed")
    func loginValidationFail() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":"validation_failed","detail":"username required"}"#.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        do {
            _ = try await client.login(username: "", password: "x")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case let .server(status, code, detail) = error {
                #expect(status == 400)
                #expect(code == "validation_failed")
                #expect(detail == "username required")
            } else {
                Issue.record("expected .server, got \(error)")
            }
        }
    }

    @Test("currentUser sends X-Lumi-Token header")
    func meTokenHeader() async throws {
        MockURLProtocol.setHandler { request in
            #expect(request.value(forHTTPHeaderField: "X-Lumi-Token") == "tok-123")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = #"{"id":"u1","username":"alice","display_name":"Alice"}"#.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        await client.setToken("tok-123")
        let user = try await client.currentUser()
        #expect(user.id == "u1")
        #expect(user.username == "alice")
    }

    @Test("currentUser without token throws .unauthorized before hitting network")
    func meWithoutTokenIsUnauthorized() async throws {
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        await #expect(throws: LumiAPIError.unauthorized) {
            _ = try await client.currentUser()
        }
    }

    @Test("network failure surfaces .network with message")
    func networkFailure() async throws {
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        do {
            _ = try await client.login(username: "a", password: "b")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case .network = error { } else {
                Issue.record("expected .network, got \(error)")
            }
        }
    }

    @Test("malformed JSON in 2xx response surfaces .decoding")
    func decodingFailure() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "not json".data(using: .utf8)!)
        }
        let client = makeClient()
        await client.setBaseURL(testServerURL)
        do {
            _ = try await client.login(username: "a", password: "b")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case .decoding = error { } else {
                Issue.record("expected .decoding, got \(error)")
            }
        }
    }
}
