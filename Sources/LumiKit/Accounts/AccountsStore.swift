import Foundation
import Observation

/// Registry of every account this device is signed into (SPEC-LIVROS §2.2,
/// item A1; shared with the TUI since §8). Keyed by `(server_url,
/// username)`, several accounts per server allowed. Owns exactly one
/// `LumiAPIClient` per account — there is no global base URL or "current
/// session" anymore.
///
/// The account list lives in the shared `~/.config/lumi/accounts.yaml` v3
/// (no secrets); this client's session tokens stay in the Keychain. Changes
/// written by the TUI arrive through `reload()` (directory watcher + scene
/// activation): a removed row or a newer `signed_out_at` drops this app's
/// token too.
@Observable
@MainActor
public final class AccountsStore {
    /// Pre-§8 per-app list (JSON in UserDefaults). Migrated into the shared
    /// file once, then removed.
    public static let defaultsKey = "lumi.accounts.v1"
    /// Pre-books single-session sidecar (`AuthService`, v1).
    public static let legacySessionKey = "lumi.auth.session.v1"
    /// `[keychainAccount: Date]` — when this app obtained its session.
    public static let signedInAtKey = "lumi.accounts.signedInAt.v1"
    /// Accounts the user signed out of in this app only: never auto-link.
    public static let linkOptOutKey = "lumi.accounts.linkOptOut.v1"

    public private(set) var accounts: [Account] = []
    public private(set) var authState: [AccountKey: AccountAuthState] = [:]
    public private(set) var restHealth: [AccountKey: RestHealth] = [:]
    public private(set) var isBusy = false
    /// Non-nil when accounts.yaml can't be rewritten (newer format or
    /// unparseable). Sign-in still works in memory.
    public private(set) var readOnlyReason: String?
    /// Bumped whenever a reload changed the account list (the device-link
    /// broker re-scans on it).
    public private(set) var revision = 0

    @ObservationIgnored public let registry: AccountsRegistryFile
    @ObservationIgnored private var clients: [AccountKey: LumiAPIClient] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: TokenStore
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastFingerprint: FileFingerprint?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    /// Best-effort revocations started by reconcile (awaited by tests).
    @ObservationIgnored public private(set) var pendingRevocations: [Task<Void, Never>] = []

    public init(
        fileURL: URL = ConfigPaths.accounts,
        defaults: UserDefaults = .standard,
        tokens: TokenStore = KeychainTokenStore(),
        urlSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = AccountsRegistryFile(fileURL: fileURL)
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

    // MARK: Load / migrate / reload

    /// Load the shared registry and run the one-time migrations (pre-§8
    /// UserDefaults list, single-session sidecar). Idempotent.
    public func load() {
        migrateDefaultsList()
        migrateLegacySession()
        reload(force: true)
    }

    /// Re-read accounts.yaml when another process changed it (or `force`).
    /// Reconciles this app's tokens with the shared rows (§8.5).
    public func reload(force: Bool = false) {
        let snap = registry.read()
        if !force, snap.fingerprint == lastFingerprint, snap.fingerprint != nil { return }
        lastFingerprint = snap.fingerprint
        readOnlyReason = snap.readOnlyReason
        guard let doc = snap.document else {
            // Missing or unreadable file: never mass-drop sessions on a
            // parse error. Keep what we have in memory.
            if snap.readOnlyReason == nil && snap.fingerprint == nil && accounts.isEmpty { refreshStates() }
            return
        }
        let fresh = doc.accounts
        let freshKeys = Set(fresh.map(\.key))
        var signedIn = signedInMap
        // 1. Rows removed elsewhere: this app's session for them ends too.
        for keychainAccount in signedIn.keys.sorted() {
            guard let key = Self.key(fromKeychainAccount: keychainAccount), !freshKeys.contains(key) else { continue }
            dropLocalSession(key, reason: "account removed on this Mac")
            signedIn[keychainAccount] = nil
        }
        // 2. "Sair neste Mac" elsewhere: sessions older than signed_out_at end.
        for acc in fresh {
            guard let out = acc.signedOutAt, token(for: acc.key) != nil else { continue }
            let since = signedIn[acc.key.keychainAccount].map { floor($0.timeIntervalSince1970) } ?? -.infinity
            if floor(out.timeIntervalSince1970) >= since {
                dropLocalSession(acc.key, reason: "signed out on this Mac")
                signedIn[acc.key.keychainAccount] = nil
            }
        }
        signedInMap = signedIn
        if fresh != accounts { revision &+= 1 }
        accounts = fresh
        for key in Array(authState.keys) where !freshKeys.contains(key) {
            authState[key] = nil
            restHealth[key] = nil
            clients[key] = nil
        }
        refreshStates()
    }

    private func refreshStates() {
        for acc in accounts {
            if token(for: acc.key) == nil {
                if authState[acc.key]?.isSignedIn ?? true {
                    authState[acc.key] = .needsSignIn(reason: isLinkOptedOut(acc.key) ? "signed out" : "no token on this device")
                }
            } else if authState[acc.key] == nil || authState[acc.key]?.isSignedIn == false {
                authState[acc.key] = .signedIn
            }
        }
    }

    /// Watch `~/.config/lumi/` for rewrites by the TUI (macOS).
    public func startWatching() {
        try? registry.ensureDirectory()
        let w = DirectoryWatcher(url: registry.directory) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        w.start()
        watcher = w
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// `lumi.accounts.v1` (pre-§8, app-only JSON list) → shared file. The
    /// key is removed only after the rows are on disk.
    func migrateDefaultsList() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        // Undecodable: leave the key alone rather than lose the list.
        guard let rows = try? JSONDecoder.accounts.decode([Account].self, from: data) else { return }
        do {
            try registry.mutate { list in
                for row in rows where !list.contains(where: { $0.key == row.key }) { list.append(row) }
            }
            var signedIn = signedInMap
            for row in rows where tokens.token(account: row.key.keychainAccount) != nil && signedIn[row.key.keychainAccount] == nil {
                signedIn[row.key.keychainAccount] = now()
            }
            signedInMap = signedIn
            defaults.removeObject(forKey: Self.defaultsKey)
        } catch {
            readOnlyReason = "could not migrate accounts into accounts.yaml (\(error))"
        }
    }

    /// `lumi.auth.session.v1` + Keychain(account = serverURL) →
    /// accounts.yaml + Keychain(`server#username`). On any failure the
    /// account is kept in "needs sign in" (SPEC-LIVROS §2.5).
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
        persistUpsert(acc)
        if !accounts.contains(where: { $0.key == acc.key }) { accounts.append(acc) }
        if let legacyToken {
            do {
                try tokens.setToken(legacyToken, account: acc.key.keychainAccount)
                markSignedIn(acc.key)
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

    /// "Sair deste app": revoke this app's session only (best effort),
    /// drop the token, keep the shared row. The TUI stays signed in, and
    /// the app won't ask it for a link again until the user signs in here.
    public func signOut(_ key: AccountKey) async {
        if let client = clients[key] ?? (token(for: key) != nil ? client(for: key) : nil) {
            try? await client.logout()
        }
        try? tokens.deleteToken(account: key.keychainAccount)
        forgetSignedIn(key)
        setLinkOptOut(key, true)
        clients[key] = nil
        authState[key] = .needsSignIn(reason: "signed out")
        restHealth[key] = nil
    }

    /// "Sair neste Mac": end this session and every session linked to it
    /// (`logout {scope: device}`), drop the token, and stamp
    /// `signed_out_at` so the TUI drops its own token even when the two
    /// sessions were never linked (§8.5).
    public func signOutEverywhereOnThisMac(_ key: AccountKey) async {
        await revokeDevice(key)
        let stamp = now()
        persist { list in
            if let i = list.firstIndex(where: { $0.key == key }) { list[i].signedOutAt = stamp }
        }
        if let i = accounts.firstIndex(where: { $0.key == key }) { accounts[i].signedOutAt = stamp }
        lastFingerprint = registry.read().fingerprint
    }

    /// "Remover conta": token, shared row and linked sessions gone (LGPD).
    public func remove(_ key: AccountKey) async {
        await revokeDevice(key)
        setLinkOptOut(key, false)
        persist { list in list.removeAll { $0.key == key } }
        accounts.removeAll { $0.key == key }
        authState[key] = nil
        lastFingerprint = registry.read().fingerprint
    }

    private func revokeDevice(_ key: AccountKey) async {
        if let client = clients[key] ?? (token(for: key) != nil ? client(for: key) : nil) {
            try? await client.logout(scope: .device)
        }
        try? tokens.deleteToken(account: key.keychainAccount)
        forgetSignedIn(key)
        clients[key] = nil
        authState[key] = .needsSignIn(reason: "signed out")
        restHealth[key] = nil
    }

    /// A row vanished or was signed out elsewhere: drop this app's token
    /// and revoke it server-side (best effort; usually already revoked).
    private func dropLocalSession(_ key: AccountKey, reason: String) {
        if let tok = token(for: key), let base = URL(string: key.serverURL) {
            let session = urlSession
            pendingRevocations.append(Task {
                let c = LumiAPIClient(baseURL: base, token: tok, session: session)
                try? await c.logout()
            })
        }
        try? tokens.deleteToken(account: key.keychainAccount)
        clients[key] = nil
        authState[key] = .needsSignIn(reason: reason)
        restHealth[key] = nil
    }

    /// Store a session obtained through a device link (§8.4). The username
    /// must match the account the link was requested for.
    @discardableResult
    public func adoptLinkedSession(_ key: AccountKey, response: SessionResponse) throws(LumiAPIError) -> Account {
        guard Account.normalizeUsername(response.user.username) == key.username else {
            throw .server(status: 0, code: "link_user_mismatch", detail: "the link signed in as a different user")
        }
        return try upsert(serverURL: key.serverURL, response: response)
    }

    // MARK: Link bookkeeping

    public func isLinkOptedOut(_ key: AccountKey) -> Bool {
        (defaults.stringArray(forKey: Self.linkOptOutKey) ?? []).contains(key.keychainAccount)
    }

    public func setLinkOptOut(_ key: AccountKey, _ on: Bool) {
        var set = Set(defaults.stringArray(forKey: Self.linkOptOutKey) ?? [])
        if on { set.insert(key.keychainAccount) } else { set.remove(key.keychainAccount) }
        defaults.set(set.sorted(), forKey: Self.linkOptOutKey)
    }

    /// When this app obtained its current session for `key`.
    public func signedInAt(_ key: AccountKey) -> Date? { signedInMap[key.keychainAccount] }

    private var signedInMap: [String: Date] {
        get { (defaults.dictionary(forKey: Self.signedInAtKey) as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.signedInAtKey) }
    }

    private func markSignedIn(_ key: AccountKey) {
        var m = signedInMap
        m[key.keychainAccount] = now()
        signedInMap = m
        setLinkOptOut(key, false)
    }

    private func forgetSignedIn(_ key: AccountKey) {
        var m = signedInMap
        m[key.keychainAccount] = nil
        signedInMap = m
    }

    static func key(fromKeychainAccount s: String) -> AccountKey? {
        guard let hash = s.lastIndex(of: "#") else { return nil }
        return AccountKey(serverURL: String(s[..<hash]), username: String(s[s.index(after: hash)...]))
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
        let key = AccountKey(serverURL: serverURL, username: Account.normalizeUsername(response.user.username))
        do {
            try tokens.setToken(response.token, account: key.keychainAccount)
        } catch {
            throw .network(message: "keychain write failed: \(error)")
        }
        markSignedIn(key)
        var acc = account(key) ?? Account(
            serverURL: serverURL, username: key.username, userID: response.user.id,
            displayName: response.user.displayName, addedAt: now(), expiresAt: response.expiresAt)
        if !response.user.id.isEmpty { acc.userID = response.user.id }
        if !response.user.displayName.isEmpty { acc.displayName = response.user.displayName }
        acc.expiresAt = response.expiresAt
        persistUpsert(acc)
        let stored = registry.read().document?.accounts.first(where: { $0.key == key }) ?? acc
        if let i = accounts.firstIndex(where: { $0.key == key }) { accounts[i] = stored } else { accounts.append(stored) }
        accounts = AccountsFile.canonicalOrder(accounts)
        acc = stored
        clients[key] = nil // rebuilt with the fresh token
        authState[key] = .signedIn
        restHealth[key] = .ok
        return acc
    }

    /// Upsert a row in the shared file, keeping fields another client set
    /// (added_at, web_origin, signed_out_at).
    private func persistUpsert(_ acc: Account) {
        persist { list in
            if let i = list.firstIndex(where: { $0.key == acc.key }) {
                var row = list[i]
                if !acc.userID.isEmpty { row.userID = acc.userID }
                if !acc.displayName.isEmpty { row.displayName = acc.displayName }
                if acc.expiresAt != nil { row.expiresAt = acc.expiresAt }
                list[i] = row
            } else {
                list.append(acc)
            }
        }
    }

    private func persist(_ body: (inout [Account]) -> Void) {
        do {
            try registry.mutate(body)
            lastFingerprint = registry.read().fingerprint
        } catch {
            readOnlyReason = "accounts.yaml not saved: \(error)"
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
