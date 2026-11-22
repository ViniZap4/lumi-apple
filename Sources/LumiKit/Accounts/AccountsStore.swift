import Foundation
import Observation

/// Registry of every account this device is signed into (SPEC-LIVROS §2.2,
/// item A1). Keyed by `(server_url, username)`, several accounts per server
/// allowed. Owns exactly one `LumiAPIClient` per account — there is no
/// global base URL or "current session" anymore.
@Observable
@MainActor
public final class AccountsStore {
    public static let defaultsKey = "lumi.accounts.v1"
    /// Pre-books single-session sidecar (`AuthService`, v1).
    public static let legacySessionKey = "lumi.auth.session.v1"

    public private(set) var accounts: [Account] = []
    public private(set) var authState: [AccountKey: AccountAuthState] = [:]
    public private(set) var restHealth: [AccountKey: RestHealth] = [:]
    public private(set) var isBusy = false

    @ObservationIgnored private var clients: [AccountKey: LumiAPIClient] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: TokenStore
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        defaults: UserDefaults = .standard,
        tokens: TokenStore = KeychainTokenStore(),
        urlSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.tokens = tokens
        self.urlSession = urlSession
        self.now = now
    }

    // MARK: Lookup

    public func account(_ key: AccountKey) -> Account? {
        accounts.first { $0.key == key }
    }

    public func state(_ key: AccountKey) -> AccountAuthState {
        guard account(key) != nil else { return .needsSignIn(reason: "no account on this device") }
        return authState[key] ?? .needsSignIn(reason: "not signed in")
    }

    /// Session token for `key`, read from the token store each time (never
    /// cached outside the client actor).
    public func token(for key: AccountKey) -> String? {
        tokens.token(account: key.keychainAccount)
    }

    /// The account's REST client. Created lazily; the same instance is
    /// returned until the account signs out or is removed.
    public func client(for key: AccountKey) -> LumiAPIClient? {
        guard account(key) != nil, let base = URL(string: key.serverURL) else { return nil }
        if let existing = clients[key] { return existing }
        let client = LumiAPIClient(baseURL: base, token: token(for: key), session: urlSession,
                                   outcomeObserver: { [weak self] outcome in
                                       Task { @MainActor in self?.record(outcome, for: key) }
                                   })
        clients[key] = client
        return client
    }

    /// Unauthenticated client for a server we have no account on yet
    /// (`/api/info`, invite preview, login).
    public func anonymousClient(serverURL: String) -> LumiAPIClient? {
        guard let base = URL(string: serverURL) else { return nil }
        return LumiAPIClient(baseURL: base, token: nil, session: urlSession)
    }

    public func accounts(on serverURL: String) -> [Account] {
        let n = ServerURL.normalizedOrRaw(serverURL)
        return accounts.filter { $0.serverURL == n }
    }

    // MARK: Load / migrate

    /// Load persisted accounts and run the one-time migration from the
    /// single-session store. Idempotent.
    public func load() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder.accounts.decode([Account].self, from: data) {
            accounts = decoded.sorted { $0.addedAt < $1.addedAt }
        }
        migrateLegacySession()
        for acc in accounts where authState[acc.key] == nil {
            authState[acc.key] = token(for: acc.key) == nil
                ? .needsSignIn(reason: "no token on this device")
                : .signedIn
        }
    }

    /// `lumi.auth.session.v1` + Keychain(account = serverURL) →
    /// `lumi.accounts.v1` + Keychain(`server#username`). On any failure
    /// the account is kept in "needs sign in" (SPEC-LIVROS §2.5).
    func migrateLegacySession() {
        guard let data = defaults.data(forKey: Self.legacySessionKey) else { return }
        defer { defaults.removeObject(forKey: Self.legacySessionKey) }
        guard let legacy = try? JSONDecoder().decode(AuthSession.self, from: data) else { return }
        let legacyKeychainAccount = legacy.serverURL.absoluteString
        let legacyToken = tokens.token(account: legacyKeychainAccount)
        guard !legacy.user.username.isEmpty else {
            try? tokens.deleteToken(account: legacyKeychainAccount)
            return
        }
        let acc = Account(
            serverURL: legacy.serverURL.absoluteString,
            username: legacy.user.username,
            userID: legacy.user.id,
            displayName: legacy.user.displayName,
            addedAt: now(),
            expiresAt: legacy.expiresAt
        )
        if account(acc.key) == nil {
            accounts.append(acc)
            persist()
        }
        if let legacyToken {
            do {
                try tokens.setToken(legacyToken, account: acc.key.keychainAccount)
                authState[acc.key] = .signedIn
            } catch {
                authState[acc.key] = .needsSignIn(reason: "could not migrate saved session")
            }
        } else {
            authState[acc.key] = .needsSignIn(reason: "saved session had no token")
        }
        if legacyKeychainAccount != acc.key.keychainAccount {
            try? tokens.deleteToken(account: legacyKeychainAccount)
        }
    }

    // MARK: Sign in / out

    @discardableResult
    public func signIn(serverURL: String, username: String, password: String) async throws(LumiAPIError) -> Account {
        let normalized = try Self.normalize(serverURL)
        guard let client = anonymousClient(serverURL: normalized) else { throw .network(message: "invalid server URL") }
        isBusy = true
        defer { isBusy = false }
        let resp = try await client.login(username: username, password: password)
        return try upsert(serverURL: normalized, response: resp)
    }

    @discardableResult
    public func register(serverURL: String, username: String, password: String, displayName: String,
                         tosVersion: String, privacyVersion: String) async throws(LumiAPIError) -> Account {
        let normalized = try Self.normalize(serverURL)
        guard let client = anonymousClient(serverURL: normalized) else { throw .network(message: "invalid server URL") }
        isBusy = true
        defer { isBusy = false }
        let resp = try await client.register(username: username, password: password, displayName: displayName,
                                             tosVersion: tosVersion, privacyVersion: privacyVersion)
        return try upsert(serverURL: normalized, response: resp)
    }

    public func previewInvite(serverURL: String, token inviteToken: String) async throws(LumiAPIError) -> InvitePreview {
        let normalized = try Self.normalize(serverURL)
        guard let client = anonymousClient(serverURL: normalized) else { throw .network(message: "invalid server URL") }
        return try await client.previewInvite(token: inviteToken)
    }

    @discardableResult
    public func acceptInviteAsExistingUser(_ key: AccountKey, token inviteToken: String) async throws(LumiAPIError) -> AcceptedVault {
        guard let client = client(for: key) else { throw .unauthorized }
        isBusy = true
        defer { isBusy = false }
        return try await client.acceptInviteAsExistingUser(token: inviteToken)
    }

    @discardableResult
    public func acceptInviteWithSignup(serverURL: String, token inviteToken: String, username: String, password: String,
                                       displayName: String, tosVersion: String, privacyVersion: String) async throws(LumiAPIError) -> Account {
        let normalized = try Self.normalize(serverURL)
        guard let client = anonymousClient(serverURL: normalized) else { throw .network(message: "invalid server URL") }
        isBusy = true
        defer { isBusy = false }
        let accepted = try await client.acceptInviteWithSignup(
            token: inviteToken, username: username, password: password, displayName: displayName,
            tosVersion: tosVersion, privacyVersion: privacyVersion)
        let user = UserDTO(id: "", username: username, displayName: displayName)
        return try upsert(serverURL: normalized,
                          response: SessionResponse(token: accepted.token, expiresAt: accepted.expiresAt, user: user))
    }

    public func serverInfo(serverURL: String) async throws(LumiAPIError) -> ServerInfo {
        let normalized = try Self.normalize(serverURL)
        guard let client = anonymousClient(serverURL: normalized) else { throw .network(message: "invalid server URL") }
        return try await client.serverInfo()
    }

    /// "Sair deste aparelho": revoke server-side (best effort), drop the
    /// token, keep the metadata so bound books show "Sign in".
    public func signOut(_ key: AccountKey) async {
        if let client = clients[key] { try? await client.logout() }
        try? tokens.deleteToken(account: key.keychainAccount)
        clients[key] = nil
        authState[key] = .needsSignIn(reason: "signed out")
        restHealth[key] = nil
    }

    /// "Remover conta neste aparelho": token and metadata gone (LGPD).
    public func remove(_ key: AccountKey) async {
        await signOut(key)
        accounts.removeAll { $0.key == key }
        authState[key] = nil
        persist()
    }

    /// 401 / `session.ended`: flip to needs-sign-in and drop the token so no
    /// further request leaks a dead credential.
    public func markNeedsSignIn(_ key: AccountKey, reason: String) {
        guard account(key) != nil else { return }
        authState[key] = .needsSignIn(reason: reason)
        restHealth[key] = .unauthorized
        try? tokens.deleteToken(account: key.keychainAccount)
        clients[key] = nil
    }

    /// Record a REST outcome (also wired automatically for clients handed
    /// out by `client(for:)`).
    public func record(_ outcome: Result<Void, LumiAPIError>, for key: AccountKey) {
        switch outcome {
        case .success:
            restHealth[key] = .ok
        case .failure(.unauthorized):
            markNeedsSignIn(key, reason: "session rejected (401)")
        case .failure(.network(let message)):
            restHealth[key] = .network(message)
        case .failure(let error) where error.isNonTransient:
            let prior: Int
            if case let .failing(count, _) = restHealth[key] { prior = count } else { prior = 0 }
            restHealth[key] = .failing(count: prior + 1, reason: "\(error)")
        case .failure:
            break // 4xx: a caller bug or permission issue, not health
        }
    }

    // MARK: Internals

    private func upsert(serverURL: String, response: SessionResponse) throws(LumiAPIError) -> Account {
        let key = AccountKey(serverURL: serverURL, username: response.user.username)
        do {
            try tokens.setToken(response.token, account: key.keychainAccount)
        } catch {
            throw .network(message: "keychain write failed: \(error)")
        }
        var acc = account(key) ?? Account(
            serverURL: serverURL, username: response.user.username, userID: response.user.id,
            displayName: response.user.displayName, addedAt: now(), expiresAt: response.expiresAt)
        if !response.user.id.isEmpty { acc.userID = response.user.id }
        if !response.user.displayName.isEmpty { acc.displayName = response.user.displayName }
        acc.expiresAt = response.expiresAt
        accounts.removeAll { $0.key == key }
        accounts.append(acc)
        accounts.sort { $0.addedAt < $1.addedAt }
        clients[key] = nil // rebuilt with the fresh token
        authState[key] = .signedIn
        restHealth[key] = .ok
        persist()
        return acc
    }

    private func persist() {
        if let data = try? JSONEncoder.accounts.encode(accounts) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    static func normalize(_ raw: String) throws(LumiAPIError) -> String {
        do {
            return try ServerURL.normalize(raw)
        } catch .insecurePublicHost {
            throw .network(message: "http:// is only allowed for localhost, private IPs and *.local")
        } catch {
            throw .network(message: "invalid server URL")
        }
    }
}

extension JSONEncoder {
    static var accounts: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var accounts: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
