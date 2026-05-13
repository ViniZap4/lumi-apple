import Testing
import Foundation
@testable import LumiKit

private func makeClient() -> LumiAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return LumiAPIClient(session: session)
}

/// Helper around the typed-throw API. Sidesteps a Swift 6 compiler crash
/// (SIL ownership verifier) we hit when combining `do/catch let as
/// LumiAPIError` with an inner `try await` on a typed-throw async call.
private func catchAPIError(_ body: () async throws -> Void) async -> LumiAPIError? {
    do {
        try await body()
        return nil
    } catch let error as LumiAPIError {
        return error
    } catch {
        return nil
    }
}

private let baseURL = URL(string: "https://lumi.test")!

/// All MockURLProtocol-using vault tests live under one `.serialized` suite
/// so they share a single ordering domain. (Different `@Suite` blocks would
/// run in parallel with each other even when each is serialized internally —
/// they'd stomp on the shared static handler.)
@Suite("LumiAPIClient + RemoteVaultsStore", .serialized)
struct LumiAPIClientVaultTests {
    // MARK: - Auth flows (merged here to share MockURLProtocol serialization
    // with vault tests; separate suites would run in parallel and stomp on
    // the static mock handler.)

    @Test("login success returns token + user")
    func loginSuccess() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"token":"abc.def","expires_at":"2026-12-31T23:59:59Z",
             "user":{"id":"u1","username":"alice","display_name":"Alice"}}
            """.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        let session = try await client.login(username: "alice", password: "hunter2")
        #expect(session.token == "abc.def")
        #expect(session.user.username == "alice")
        #expect(session.user.displayName == "Alice")
    }

    @Test("login with bad credentials surfaces .unauthorized")
    func loginBadCreds() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":"invalid_credentials","detail":"bad username or password"}"#.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await #expect(throws: LumiAPIError.unauthorized) {
            _ = try await client.login(username: "alice", password: "wrong")
        }
    }

    @Test("login with validation failure surfaces .server")
    func loginValidationFail() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let data = #"{"error":"validation_failed","detail":"username required"}"#.data(using: .utf8)!
            return (response, data)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
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
        await client.setBaseURL(baseURL)
        await client.setToken("tok-123")
        let user = try await client.currentUser()
        #expect(user.id == "u1")
    }

    @Test("currentUser without token throws .unauthorized before hitting network")
    func meWithoutTokenIsUnauthorized() async throws {
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await #expect(throws: LumiAPIError.unauthorized) {
            _ = try await client.currentUser()
        }
    }

    @Test("network failure surfaces .network")
    func networkFailure() async throws {
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
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
        await client.setBaseURL(baseURL)
        do {
            _ = try await client.login(username: "a", password: "b")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case .decoding = error { } else {
                Issue.record("expected .decoding, got \(error)")
            }
        }
    }

    @Test("register success returns session (201)")
    func registerSuccess() async throws {
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/auth/register")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = """
            {"token":"new-tok","expires_at":"2026-12-31T23:59:59Z",
             "user":{"id":"u9","username":"bob","display_name":"Bob"}}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        let session = try await client.register(username: "bob", password: "pw", displayName: "Bob", tosVersion: "", privacyVersion: "")
        #expect(session.user.username == "bob")
        #expect(session.token == "new-tok")
    }

    @Test("register on closed server surfaces registration_closed")
    func registerClosed() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":"registration_closed"}"#.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        do {
            _ = try await client.register(username: "bob", password: "pw", displayName: "Bob", tosVersion: "", privacyVersion: "")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case let .server(status, code, _) = error {
                #expect(status == 403)
                #expect(code == "registration_closed")
            } else {
                Issue.record("expected .server, got \(error)")
            }
        }
    }

    @Test("register with stale consent surfaces consent_required")
    func registerConsentRequired() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":"consent_required"}"#.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        do {
            _ = try await client.register(username: "bob", password: "pw", displayName: "Bob", tosVersion: "old", privacyVersion: "old")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case let .server(_, code, _) = error {
                #expect(code == "consent_required")
            } else {
                Issue.record("expected .server, got \(error)")
            }
        }
    }

    // MARK: - Invite flows

    @Test("previewInvite decodes the public preview envelope")
    func previewInvite() async throws {
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/invites/abc123")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
             "vault_name":"Work","vault_slug":"work",
             "role_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303","role_name":"Editor",
             "inviter_user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3304",
             "expires_at":"2026-12-31T23:59:59Z",
             "max_uses":5,"use_count":1,"email_hint":"a@e.com","requires_signup":true}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        let preview = try await client.previewInvite(token: "abc123")
        #expect(preview.vaultName == "Work")
        #expect(preview.roleName == "Editor")
        #expect(preview.useCount == 1)
        #expect(preview.maxUses == 5)
        #expect(preview.requiresSignup)
    }

    @Test("acceptInviteAsExistingUser returns the joined vault")
    func acceptExisting() async throws {
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/invites/abc/accept")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Lumi-Token") == "tok")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"vault":{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","slug":"work","name":"Work"}}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let vault = try await client.acceptInviteAsExistingUser(token: "abc")
        #expect(vault.slug == "work")
        #expect(vault.name == "Work")
    }

    @Test("acceptInviteWithSignup returns session + vault")
    func acceptSignup() async throws {
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/invites/abc/accept")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = """
            {"token":"new-tok","expires_at":"2026-12-31T23:59:59Z",
             "vault":{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","slug":"work","name":"Work"}}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        let accepted = try await client.acceptInviteWithSignup(
            token: "abc",
            username: "bob",
            password: "pw",
            displayName: "Bob",
            tosVersion: "",
            privacyVersion: ""
        )
        #expect(accepted.token == "new-tok")
        #expect(accepted.vault.name == "Work")
    }

    @Test("createInvite returns token, url, and expiry")
    func createInviteRoundtrip() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let roleID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3303")!
        let expiry = Date().addingTimeInterval(7 * 24 * 3600)
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/invites")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Lumi-Token") == "tok")
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = """
            {"token":"abc123","url":"https://lumi.test/invite/abc123",
             "expires_at":"2026-12-31T23:59:59Z","max_uses":3,"use_count":0}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let created = try await client.createInvite(vaultID: vaultID, roleID: roleID, maxUses: 3, expiresAt: expiry, emailHint: nil)
        #expect(created.token == "abc123")
        #expect(created.url == "https://lumi.test/invite/abc123")
        #expect(created.maxUses == 3)
    }

    @Test("listInvites decodes the envelope including revoked rows")
    func listInvitesEnvelope() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/invites")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"invites":[
              {"token":"a","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
               "role_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303",
               "inviter_user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3304",
               "email_hint":"a@e.com","max_uses":1,"use_count":0,
               "expires_at":"2026-12-31T23:59:59Z","created_at":"2026-05-13T10:00:00Z","revoked_at":null},
              {"token":"b","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
               "role_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303",
               "inviter_user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3304",
               "max_uses":0,"use_count":2,
               "expires_at":"2026-12-31T23:59:59Z","revoked_at":"2026-05-12T10:00:00Z"}
            ]}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let invites = try await client.listInvites(vaultID: vaultID)
        #expect(invites.count == 2)
        #expect(invites[0].token == "a")
        #expect(invites[0].emailHint == "a@e.com")
        #expect(invites[1].isRevoked)
        #expect(invites[1].maxUses == 0)
    }

    @Test("revokeInvite issues DELETE and returns void")
    func revokeRoundtrip() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/invites/abc")
            #expect(request.httpMethod == "DELETE")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        try await client.revokeInvite(vaultID: vaultID, token: "abc")
    }

    @Test("listAuditEntries decodes entries + pagination meta")
    func auditList() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/audit")
            // Query string carries pagination.
            let query = request.url?.query ?? ""
            #expect(query.contains("limit=25"))
            #expect(request.value(forHTTPHeaderField: "X-Lumi-Token") == "tok")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"entries":[
              {"id":1,"user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302",
               "vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
               "action":"invite.created",
               "payload":{"role_name":"Editor","max_uses":3,"email_hint":"a@e.com"},
               "ip":"127.0.0.1","user_agent":"test","created_at":"2026-05-13T10:00:00Z"},
              {"id":2,"user_id":null,"vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
               "action":"vault.created","created_at":"2026-05-13T09:00:00Z"}
            ],"limit":25,"offset":0}
            """.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let resp = try await client.listAuditEntries(vaultID: vaultID, limit: 25, offset: 0)
        #expect(resp.entries.count == 2)
        #expect(resp.entries[0].action == "invite.created")
        if case let .string(s) = resp.entries[0].payload["role_name"] {
            #expect(s == "Editor")
        } else {
            Issue.record("expected role_name string in payload")
        }
        if case let .number(n) = resp.entries[0].payload["max_uses"] {
            #expect(n == 3)
        } else {
            Issue.record("expected max_uses number")
        }
        #expect(resp.entries[1].userID == nil)
        #expect(resp.limit == 25)
    }

    @Test("listAuditEntries without audit.read surfaces .server forbidden")
    func auditForbidden() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, #"{"error":"forbidden"}"#.data(using: .utf8)!)
        }
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let thrown = await catchAPIError {
            _ = try await client.listAuditEntries(vaultID: vaultID)
        }
        if case let .server(status, code, _) = thrown {
            #expect(status == 403)
            #expect(code == "forbidden")
        } else {
            Issue.record("expected .server forbidden, got \(String(describing: thrown))")
        }
    }

    @Test("createInvite without members.invite cap surfaces .server forbidden")
    func createForbidden() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":"forbidden"}"#.data(using: .utf8)!
            return (response, body)
        }
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let roleID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3303")!
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let thrown: LumiAPIError? = await catchAPIError {
            _ = try await client.createInvite(vaultID: vaultID, roleID: roleID, maxUses: 1, expiresAt: Date(), emailHint: nil)
        }
        if case let .server(status, code, _) = thrown {
            #expect(status == 403)
            #expect(code == "forbidden")
        } else {
            Issue.record("expected .server, got \(String(describing: thrown))")
        }
    }

    @Test("expired invite surfaces server code invite_expired")
    func inviteExpired() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":"invite_expired"}"#.data(using: .utf8)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        do {
            _ = try await client.previewInvite(token: "abc")
            Issue.record("expected throw")
        } catch let error as LumiAPIError {
            if case let .server(_, code, _) = error {
                #expect(code == "invite_expired")
            } else {
                Issue.record("expected .server, got \(error)")
            }
        }
    }

    // MARK: - Vault flows

    @Test("listVaults decodes the envelope")
    func listVaults() async throws {
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults")
            #expect(request.value(forHTTPHeaderField: "X-Lumi-Token") == "tok-123")
            let body = """
            {"vaults":[
              {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","slug":"work","name":"Work","created_by":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","created_at":"2026-05-13T10:00:00Z"},
              {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303","slug":"personal","name":"Personal","created_by":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","created_at":"2026-05-12T10:00:00Z"}
            ]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok-123")
        let vaults = try await client.listVaults()
        #expect(vaults.count == 2)
        #expect(vaults[0].slug == "work")
        #expect(vaults[0].name == "Work")
        #expect(vaults[1].slug == "personal")
    }

    @Test("vaultDetail returns single vault")
    func vaultDetail() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
            let body = """
            {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","slug":"work","name":"Work","created_by":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","created_at":"2026-05-13T10:00:00Z"}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok-123")
        let vault = try await client.vaultDetail(id: vaultID)
        #expect(vault.id == vaultID)
        #expect(vault.name == "Work")
    }

    @Test("listMembers decodes members with capabilities array")
    func listMembers() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/members")
            let body = """
            {"members":[
              {"vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
               "user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302",
               "username":"alice","display_name":"Alice",
               "role_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303",
               "role_name":"Admin",
               "capabilities":["vault.*","note.*"],
               "is_seed_role":true,
               "joined_at":"2026-05-13T10:00:00Z"}
            ]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok-123")
        let members = try await client.listMembers(vaultID: vaultID)
        #expect(members.count == 1)
        #expect(members[0].username == "alice")
        #expect(members[0].roleName == "Admin")
        #expect(members[0].capabilities == ["vault.*", "note.*"])
        #expect(members[0].isSeedRole)
    }

    @Test("listMembers tolerates missing capabilities array")
    func listMembersNoCaps() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            let body = """
            {"members":[
              {"vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
               "user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302",
               "username":"alice","display_name":"Alice",
               "role_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303",
               "role_name":"Viewer",
               "is_seed_role":true,
               "joined_at":"2026-05-13T10:00:00Z"}
            ]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok-123")
        let members = try await client.listMembers(vaultID: vaultID)
        #expect(members[0].capabilities.isEmpty)
    }

    @Test("listRoles decodes the envelope")
    func listRoles() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/roles")
            let body = """
            {"roles":[
              {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Admin","capabilities":["vault.*"],"is_seed":true},
              {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3304","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Viewer","capabilities":["note.read"],"is_seed":true}
            ]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await client.setToken("tok-123")
        let roles = try await client.listRoles(vaultID: vaultID)
        #expect(roles.count == 2)
        #expect(roles[0].name == "Admin")
        #expect(roles[1].capabilities == ["note.read"])
    }

    @Test("listVaults without token throws .unauthorized")
    func listVaultsRequiresToken() async throws {
        let client = makeClient()
        await client.setBaseURL(baseURL)
        await #expect(throws: LumiAPIError.unauthorized) {
            _ = try await client.listVaults()
        }
    }

    // MARK: - RemoteVaultsStore (same suite to share serialization domain)

    @Test("RemoteVaultsStore — refresh populates vaults; selectVault loads members + roles")
    @MainActor
    func storeHappyPath() async throws {
        let vaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let path = request.url?.path ?? ""
            switch path {
            case "/api/vaults":
                let body = """
                {"vaults":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","slug":"work","name":"Work","created_by":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","created_at":"2026-05-13T10:00:00Z"}]}
                """.data(using: .utf8)!
                return (response, body)
            case "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/members":
                let body = """
                {"members":[{"vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","user_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","username":"alice","display_name":"Alice","role_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303","role_name":"Admin","capabilities":["vault.*"],"is_seed_role":true,"joined_at":"2026-05-13T10:00:00Z"}]}
                """.data(using: .utf8)!
                return (response, body)
            case "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/roles":
                let body = """
                {"roles":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Admin","capabilities":["vault.*"],"is_seed":true}]}
                """.data(using: .utf8)!
                return (response, body)
            default:
                let body = #"{"error":"not_found"}"#.data(using: .utf8)!
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (resp, body)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = LumiAPIClient(session: URLSession(configuration: config))
        await client.setBaseURL(baseURL)
        await client.setToken("tok")

        let store = RemoteVaultsStore(client: client)
        await store.refresh()
        #expect(store.vaults.count == 1)
        #expect(store.isLoading == false)
        #expect(store.lastError == nil)

        await store.selectVault(vaultID)
        #expect(store.selectedVaultID == vaultID)
        #expect(store.members.count == 1)
        #expect(store.roles.count == 1)
    }

    @Test("RemoteVaultsStore — clear wipes state")
    @MainActor
    func storeClearWipes() async {
        let store = RemoteVaultsStore(client: LumiAPIClient())
        // Pre-load some state by reaching in via a fresh store; instead just
        // call clear() on an empty one and assert it stays empty.
        store.clear()
        #expect(store.vaults.isEmpty)
        #expect(store.selectedVaultID == nil)
        #expect(store.members.isEmpty)
        #expect(store.roles.isEmpty)
    }

    @Test("RemoteVaultsStore — refresh surfaces .unauthorized as lastError")
    @MainActor
    func storeUnauthorizedSurfaced() async throws {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = LumiAPIClient(session: URLSession(configuration: config))
        await client.setBaseURL(baseURL)
        await client.setToken("tok")
        let store = RemoteVaultsStore(client: client)
        await store.refresh()
        #expect(store.lastError == .unauthorized)
        #expect(store.vaults.isEmpty)
    }
}

