import Foundation
import Observation

/// Server calls the broker needs. Production goes through `AccountsStore`;
/// tests inject a stub.
public protocol DeviceLinkAPI: Sendable {
    /// Ask the server for a one-time code using this app's session.
    func issueDeviceLink(for account: AccountKey, challenge: String, label: String) async throws -> DeviceLinkCode
    /// Exchange a code + verifier for a new session of this app.
    func redeemDeviceLink(serverURL: String, code: String, verifier: String, label: String) async throws -> SessionResponse
}

/// A TUI request waiting for the user's decision. The app NEVER approves
/// on its own (SPEC-LIVROS §8.2): any process of this user can write a
/// request, and auto-approval would hand out sessions behind the Keychain.
public struct DeviceLinkApproval: Identifiable, Sendable, Equatable {
    public let id: String
    public let account: AccountKey
    public let label: String
    public let requestedAt: Date?

    /// "O lumi no Terminal quer entrar como alice em lumi.work.com".
    public var message: String {
        "O lumi no Terminal quer entrar como \(account.username) em \(ServerURL.displayHost(account.serverURL))."
    }
}

/// Device-link broker of the app (SPEC-LIVROS §8.4), over the drop box
/// shared with the TUI.
///
/// * **Requester:** for every registry account the app has no token for
///   (and the user didn't sign out of here), it leaves a `req-<id>.json`
///   for the TUI with a PKCE challenge; the verifier stays in memory. When
///   the TUI answers with a code, the app redeems it for its own session.
/// * **Holder:** TUI requests for accounts the app is signed into become
///   `pendingApprovals`; the UI asks the user, then `approve`/`deny`.
@Observable
@MainActor
public final class DeviceLinkBroker {
    public private(set) var pendingApprovals: [DeviceLinkApproval] = []
    /// Accounts with a request of ours outstanding.
    public private(set) var waitingFor: Set<AccountKey> = []
    public private(set) var lastError: String?

    @ObservationIgnored public let directory: DeviceLinkDirectory
    @ObservationIgnored private let store: AccountsStore
    @ObservationIgnored private let api: DeviceLinkAPI
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pid: Int32
    @ObservationIgnored private let isPIDAlive: (Int32) -> Bool
    @ObservationIgnored private let label: String
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var started: Date?
    /// Our outstanding requests: request id → (account, verifier).
    @ObservationIgnored private var outstanding: [String: (account: AccountKey, verifier: String)] = [:]
    /// Accounts whose last request ended without a session (no_session,
    /// failed, expired): not retried until the registry changes.
    @ObservationIgnored private var exhausted: Set<AccountKey> = []
    @ObservationIgnored private var exhaustedAtRevision = 0
    /// Request ids already answered or being answered by us (holder).
    @ObservationIgnored private var handled: Set<String> = []
    @ObservationIgnored private var redeeming: Set<String> = []

    public init(
        store: AccountsStore,
        directory: DeviceLinkDirectory = DeviceLinkDirectory(),
        api: DeviceLinkAPI? = nil,
        label: String = "Lumi.app",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        isPIDAlive: @escaping (Int32) -> Bool = DeviceLink.isProcessAlive,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.directory = directory
        self.api = api ?? AccountsStoreDeviceLinkAPI(store: store)
        self.label = label
        self.pid = pid
        self.isPIDAlive = isPIDAlive
        self.now = now
    }

    // MARK: Lifecycle

    /// Write the presence file, clear our requests from a previous run
    /// (their verifiers died with it) and scan. `watch` adds a directory
    /// watcher (off in tests, which call `scan()` directly).
    public func start(watch: Bool = true) {
        guard started == nil else { return }
        started = now()
        try? directory.ensure()
        try? directory.write(DeviceLink.Presence(pid: pid, startedAt: now()),
                             to: directory.presenceURL(DeviceLink.appClient))
        for id in directory.requestIDs() {
            let url = directory.requestURL(id)
            if let req = directory.read(DeviceLink.Request.self, from: url), req.from == DeviceLink.appClient {
                directory.remove(url)
                directory.remove(directory.responseURL(id))
            }
        }
        if watch {
            let w = DirectoryWatcher(url: directory.url) { [weak self] in
                Task { @MainActor in await self?.scan() }
            }
            w.start()
            watcher = w
        }
        Task { await scan() }
    }

    /// Remove the presence file and our pending requests.
    public func stop() {
        watcher?.stop()
        watcher = nil
        for id in outstanding.keys {
            directory.remove(directory.requestURL(id))
            directory.remove(directory.responseURL(id))
        }
        outstanding = [:]
        waitingFor = []
        directory.remove(directory.presenceURL(DeviceLink.appClient))
        started = nil
    }

    /// Is the TUI's interactive screen running right now?
    public var isTUIRunning: Bool {
        guard let p = directory.read(DeviceLink.Presence.self, from: directory.presenceURL(DeviceLink.tuiClient)) else {
            return false
        }
        return isPIDAlive(p.pid)
    }

    // MARK: Scan

    /// One pass over the drop box: GC, answers to our requests, TUI
    /// requests for us, and new requests for accounts we lack.
    public func scan() async {
        if store.revision != exhaustedAtRevision {
            exhausted = []
            exhaustedAtRevision = store.revision
        }
        garbageCollect()
        await handleResponses()
        handleIncomingRequests()
        requestMissingSessions()
    }

    private func garbageCollect() {
        let t = now()
        for id in directory.requestIDs() where outstanding[id] == nil {
            let url = directory.requestURL(id)
            let req = directory.read(DeviceLink.Request.self, from: url)
            let created = req?.created ?? directory.modified(url) ?? t
            let stale = t.timeIntervalSince(created) > DeviceLink.requestTTL && !(req.map { isPIDAlive($0.pid) } ?? false)
            if stale {
                directory.remove(url)
                directory.remove(directory.responseURL(id))
                pendingApprovals.removeAll { $0.id == id }
            }
        }
        let requests = Set(directory.requestIDs())
        for id in directory.responseIDs() where !requests.contains(id) {
            let url = directory.responseURL(id)
            if let m = directory.modified(url), t.timeIntervalSince(m) > DeviceLink.requestTTL { directory.remove(url) }
        }
    }

    // MARK: Requester

    private func requestMissingSessions() {
        guard started != nil else { return }
        let waiting = Set(outstanding.values.map(\.account))
        for acc in store.accounts {
            let key = acc.key
            guard store.token(for: key) == nil, !store.isLinkOptedOut(key),
                  !waiting.contains(key), !exhausted.contains(key) else { continue }
            let verifier = DeviceLink.makeVerifier()
            let req = DeviceLink.Request(from: DeviceLink.appClient, to: DeviceLink.tuiClient, account: key,
                                         challenge: DeviceLink.challenge(for: verifier), label: label,
                                         pid: pid, createdAt: now())
            do {
                try directory.write(req, to: directory.requestURL(req.id))
                outstanding[req.id] = (key, verifier)
            } catch {
                lastError = "could not write link request: \(error)"
            }
        }
        // Accounts that got a session another way: withdraw the request.
        for (id, entry) in outstanding where store.token(for: entry.account) != nil && !redeeming.contains(id) {
            finish(id)
        }
        waitingFor = Set(outstanding.values.map(\.account))
    }

    private func handleResponses() async {
        for (id, entry) in outstanding where !redeeming.contains(id) {
            guard let resp = directory.read(DeviceLink.Response.self, from: directory.responseURL(id)),
                  resp.v == DeviceLink.version, resp.id == id else { continue }
            if let err = resp.error {
                if err == DeviceLink.ErrorCode.denied {
                    store.setLinkOptOut(entry.account, true)
                } else {
                    exhausted.insert(entry.account)
                }
                finish(id)
                continue
            }
            guard let code = resp.code, !code.isEmpty else { finish(id); exhausted.insert(entry.account); continue }
            if let exp = resp.expires, exp <= now() {
                exhausted.insert(entry.account)
                finish(id)
                continue
            }
            redeeming.insert(id)
            do {
                let session = try await api.redeemDeviceLink(serverURL: entry.account.serverURL, code: code,
                                                             verifier: entry.verifier, label: label)
                try store.adoptLinkedSession(entry.account, response: session)
                lastError = nil
            } catch {
                exhausted.insert(entry.account)
                lastError = "link for \(entry.account) failed: \(error)"
            }
            redeeming.remove(id)
            finish(id)
        }
        waitingFor = Set(outstanding.values.map(\.account))
    }

    private func finish(_ id: String) {
        directory.remove(directory.requestURL(id))
        directory.remove(directory.responseURL(id))
        outstanding[id] = nil
    }

    // MARK: Holder

    private func handleIncomingRequests() {
        let t = now()
        var seen: Set<String> = []
        for id in directory.requestIDs() where outstanding[id] == nil {
            seen.insert(id)
            guard !handled.contains(id) else { continue }
            if FileManager.default.fileExists(atPath: directory.responseURL(id).path) { continue }
            guard let req = directory.read(DeviceLink.Request.self, from: directory.requestURL(id)),
                  req.v == DeviceLink.version, req.id == id,
                  req.to == DeviceLink.appClient, req.from == DeviceLink.tuiClient,
                  DeviceLink.isValidChallenge(req.challenge) else { continue }
            let created = req.created ?? .distantPast
            let fresh = t.timeIntervalSince(created) <= DeviceLink.requestTTL || isPIDAlive(req.pid)
            guard fresh else { continue }
            let key = req.account
            guard store.account(key) != nil, store.token(for: key) != nil else {
                respond(id, DeviceLink.Response(id: id, error: DeviceLink.ErrorCode.noSession))
                continue
            }
            if !pendingApprovals.contains(where: { $0.id == id }) {
                pendingApprovals.append(DeviceLinkApproval(id: id, account: key, label: req.label, requestedAt: req.created))
            }
        }
        // Requests withdrawn by the TUI disappear from the prompt.
        pendingApprovals.removeAll { !seen.contains($0.id) }
    }

    /// The user allowed the TUI to sign in: mint a code with our session.
    public func approve(_ id: String) async {
        guard let approval = pendingApprovals.first(where: { $0.id == id }) else { return }
        pendingApprovals.removeAll { $0.id == id }
        handled.insert(id) // a scan during the server call must not ask again
        guard let req = directory.read(DeviceLink.Request.self, from: directory.requestURL(id)),
              req.account == approval.account else { return }
        guard store.token(for: approval.account) != nil else {
            respond(id, DeviceLink.Response(id: id, error: DeviceLink.ErrorCode.noSession))
            return
        }
        do {
            let code = try await api.issueDeviceLink(for: approval.account, challenge: req.challenge, label: req.label)
            respond(id, DeviceLink.Response(id: id, code: code.code,
                                            expiresAt: code.expiresAt ?? now().addingTimeInterval(120)))
        } catch {
            lastError = "could not create a link for \(approval.account): \(error)"
            respond(id, DeviceLink.Response(id: id, error: DeviceLink.ErrorCode.failed))
        }
    }

    public func deny(_ id: String) {
        pendingApprovals.removeAll { $0.id == id }
        respond(id, DeviceLink.Response(id: id, error: DeviceLink.ErrorCode.denied))
    }

    private func respond(_ id: String, _ response: DeviceLink.Response) {
        handled.insert(id)
        do {
            try directory.write(response, to: directory.responseURL(id))
        } catch {
            lastError = "could not answer link request: \(error)"
        }
    }
}

/// Production `DeviceLinkAPI`: the account's own client to issue, an
/// anonymous one to redeem.
public struct AccountsStoreDeviceLinkAPI: DeviceLinkAPI {
    let store: AccountsStore

    public init(store: AccountsStore) { self.store = store }

    public func issueDeviceLink(for account: AccountKey, challenge: String, label: String) async throws -> DeviceLinkCode {
        guard let client = await store.client(for: account) else { throw LumiAPIError.unauthorized }
        return try await client.issueDeviceLink(challenge: challenge, label: label)
    }

    public func redeemDeviceLink(serverURL: String, code: String, verifier: String, label: String) async throws -> SessionResponse {
        guard let client = await store.anonymousClient(serverURL: serverURL) else {
            throw LumiAPIError.network(message: "invalid server URL")
        }
        return try await client.redeemDeviceLink(code: code, verifier: verifier, label: label)
    }
}
