import Foundation
import Observation

/// Glue between accounts, the book registry and the per-account feeds
/// (SPEC-LIVROS A3). One `FeedConnection` per signed-in account — never per
/// book. Owns cursors/heads, catch-up, reconcile-on-connect, and exposes
/// `status(for:)` for the UI.
@Observable
@MainActor
public final class BooksSyncEngine {
    public static let cursorsKey = "lumi.books.cursors.v1"

    public private(set) var feedState: [AccountKey: AccountFeedState] = [:]
    public private(set) var catchUp: [String: CatchUpSnapshot] = [:]
    public private(set) var revoked: Set<String> = []
    public private(set) var remote: [String: RemoteVault] = [:]
    public private(set) var canEdit: [String: Bool] = [:]
    public private(set) var alternates: [String: [AccountKey]] = [:]
    public private(set) var lastSyncedAt: [String: Date] = [:]
    /// Last 5 errors per book (for the details popover).
    public private(set) var recentErrors: [String: [String]] = [:]
    /// Federation notices not yet acknowledged by the user.
    public var pendingNotices: [FederationNotice] = []
    /// "3 books added from lumi.work.com" banner.
    public var addedBanner: String?
    /// Editor phase for the book whose note is open (set by the host).
    public var openEditor: (bookID: String, snapshot: EditorSnapshot)?
    /// Called after a catch-up for a book; `nil` outcome = "refetch the
    /// list" (server without `/changes`).
    @ObservationIgnored public var onNotesChanged: ((String, CatchUpOutcome?) -> Void)?

    @ObservationIgnored public let accounts: AccountsStore
    @ObservationIgnored public let registry: BooksRegistry
    @ObservationIgnored private let feedSession: URLSession
    @ObservationIgnored private let feedConfig: FeedConnection.Config
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var feeds: [AccountKey: FeedConnection] = [:]
    @ObservationIgnored private var feedTasks: [AccountKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var changesUnsupported: Set<AccountKey> = []
    @ObservationIgnored private var cursors: [String: Int64]

    public init(accounts: AccountsStore, registry: BooksRegistry, defaults: UserDefaults = .standard,
                feedSession: URLSession = .shared, feedConfig: FeedConnection.Config = .init()) {
        self.accounts = accounts
        self.registry = registry
        self.defaults = defaults
        self.feedSession = feedSession
        self.feedConfig = feedConfig
        let raw = defaults.dictionary(forKey: Self.cursorsKey) as? [String: NSNumber] ?? [:]
        self.cursors = raw.mapValues(\.int64Value)
    }

    // MARK: Status

    public func cursor(_ bookID: String) -> Int64 { cursors[bookID] ?? 0 }

    public func status(for book: Book) -> BookSyncStatus {
        let key = book.accountKey
        let snapshot = BookStatusBook(
            kind: book.kind,
            hasAccount: key.flatMap { accounts.account($0) } != nil,
            hasToken: key.map { accounts.state($0).isSignedIn } ?? false,
            hasVaultID: book.vaultID != nil,
            revoked: revoked.contains(book.id),
            canEdit: canEdit[book.id] ?? true
        )
        var cu = catchUp[book.id] ?? CatchUpSnapshot()
        cu.cursor = cursor(book.id)
        let editor = openEditor?.bookID == book.id ? openEditor!.snapshot : EditorSnapshot()
        let status = bookStatus(book: snapshot, accountFeed: key.flatMap { feedState[$0] }, catchUp: cu,
                                editor: editor, restHealth: key.flatMap { accounts.restHealth[$0] })
        return status
    }

    // MARK: Lifecycle

    /// Start/stop feeds to match the signed-in accounts, then reconcile.
    public func syncAccounts() async {
        let live = Set(accounts.accounts.map(\.key).filter { accounts.state($0).isSignedIn })
        for key in feeds.keys where !live.contains(key) { await stopFeed(key) }
        for key in live where feeds[key] == nil { startFeed(key) }
        await refreshListings()
    }

    public func stopAll() async {
        for key in Array(feeds.keys) { await stopFeed(key) }
    }

    /// "Tentar agora".
    public func retryNow(_ book: Book) async {
        if let key = book.accountKey, let feed = feeds[key] { await feed.retryNow() }
        if let key = book.accountKey, feeds[key] == nil, accounts.state(key).isSignedIn { startFeed(key) }
        await refreshListings()
        if var cu = catchUp[book.id], case .failed = cu.phase { cu.phase = .idle; catchUp[book.id] = cu }
        await runCatchUp(book.id)
    }

    /// "Trocar servidor": rebind, reset the per-server cursor, drop list
    /// caches. Local Y.Docs are kept (CRDT §10 S5).
    public func switchServer(_ bookID: String, to key: AccountKey) async {
        guard registry.switchServer(bookID, to: key) else { return }
        setCursor(bookID, 0)
        catchUp[bookID] = nil
        revoked.remove(bookID)
        remote[bookID] = nil
        await refreshListings()
        await runCatchUp(bookID)
    }

    public func forgetBook(_ bookID: String) {
        revoked.remove(bookID)
        catchUp[bookID] = nil
        remote[bookID] = nil
        setCursor(bookID, nil)
    }

    // MARK: Listings + reconcile (§2.4)

    public func refreshListings() async {
        let keys = accounts.accounts.filter { accounts.state($0.key).isSignedIn }
        var listings: [AccountListing] = []
        for acc in keys {
            guard let client = accounts.client(for: acc.key) else { continue }
            if let vaults = try? await client.listVaults() {
                listings.append(AccountListing(key: acc.key, accountAddedAt: acc.addedAt, vaults: vaults))
            }
        }
        guard !listings.isEmpty else { return }
        let result = BookReconciler.reconcile(
            books: registry.books, listings: listings, pendingSlugs: registry.pendingSlugs,
            dismissedVaultIDs: registry.dismissedVaultIDs, now: Date())
        let fresh = registry.apply(result)
        pendingNotices.append(contentsOf: fresh)
        if !result.added.isEmpty {
            let byServer = Dictionary(grouping: result.added.compactMap { registry.book($0)?.serverURL }, by: { $0 })
            addedBanner = byServer.map { "\($0.value.count) book\($0.value.count == 1 ? "" : "s") added from \(ServerURL.displayHost($0.key))" }
                .sorted().joined(separator: " · ")
        }
        for (id, vault) in result.remote {
            remote[id] = vault
            if let ce = vault.canEdit { canEdit[id] = ce }
            if let head = vault.head { setHead(id, head) }
        }
        alternates = result.alternates
        for id in result.revoked { markRevoked(id, reason: "removed") }
        for id in result.remote.keys { revoked.remove(id) }
        for b in registry.books where b.kind == .bound { await runCatchUpIfBehind(b.id) }
    }

    // MARK: Feed handling

    private func startFeed(_ key: AccountKey) {
        guard let base = URL(string: key.serverURL) else { return }
        let accounts = self.accounts
        let feed = FeedConnection(baseURL: base, session: feedSession, config: feedConfig,
                                  tokenProvider: { await accounts.token(for: key) })
        feeds[key] = feed
        feedState[key] = .connecting
        feedTasks[key] = Task { [weak self] in
            await feed.start()
            for await output in feed.outputs {
                guard let self else { return }
                await self.handle(output, from: key)
            }
        }
    }

    private func stopFeed(_ key: AccountKey) async {
        feedTasks[key]?.cancel()
        feedTasks[key] = nil
        if let feed = feeds.removeValue(forKey: key) { await feed.stop() }
        feedState[key] = nil
    }

    /// Book bound to `vaultID` *through this account*. Events for a vault
    /// that the book syncs via another server (an alternate) are ignored.
    private func boundBook(_ vaultID: String, via key: AccountKey) -> Book? {
        guard let b = registry.book(vaultID: vaultID), b.accountKey == key else { return nil }
        return b
    }

    func handle(_ output: FeedConnection.Output, from key: AccountKey) async {
        switch output {
        case .state(let s):
            feedState[key] = s
            if s == .authDead { accounts.markNeedsSignIn(key, reason: "session ended") }
        case .problem(let message):
            for b in registry.books where b.accountKey == key { logError(b.id, message) }
        case .event(let event):
            await handle(event, from: key)
        }
    }

    private func handle(_ event: FeedEvent, from key: AccountKey) async {
        switch event {
        case .hello(let hello):
            let listed = Set(hello.vaults.map(\.vaultID))
            let unknown = hello.vaults.contains { registry.book(vaultID: $0.vaultID) == nil }
            for v in hello.vaults {
                guard let b = boundBook(v.vaultID, via: key) else { continue }
                canEdit[b.id] = v.canEdit
                revoked.remove(b.id)
                setHead(b.id, v.seq)
            }
            for b in registry.books where b.accountKey == key {
                if let vid = b.vaultID, !listed.contains(vid) { markRevoked(b.id, reason: "removed") }
            }
            if unknown { await refreshListings() }
            for b in registry.books where b.accountKey == key { await runCatchUpIfBehind(b.id) }
        case .vaultHead(let vid, let seq):
            guard let b = boundBook(vid, via: key) else { return }
            setHead(b.id, seq)
            await runCatchUpIfBehind(b.id)
        case .vaultAccess(let vid, _, let ce):
            if let b = boundBook(vid, via: key) {
                canEdit[b.id] = ce
                revoked.remove(b.id)
            } else if registry.book(vaultID: vid) == nil {
                await refreshListings()
            }
        case .vaultUpdated(let vid, _):
            guard let b = boundBook(vid, via: key), let uuid = b.vaultUUID,
                  let client = accounts.client(for: key) else { return }
            if let detail = try? await client.vaultDetail(id: uuid) {
                remote[b.id] = detail
                registry.updateCachedName(b.id, to: detail.name)
                if let ce = detail.canEdit { canEdit[b.id] = ce }
            }
        case .vaultRevoked(let vid, let reason):
            guard let b = boundBook(vid, via: key) else { return }
            markRevoked(b.id, reason: reason)
        case .sessionEnded:
            accounts.markNeedsSignIn(key, reason: "session ended")
        case .reconnect, .unknown:
            break
        }
    }

    // MARK: Catch-up

    private func runCatchUpIfBehind(_ bookID: String) async {
        guard let cu = catchUp[bookID], let head = cu.head, head > cursor(bookID) else {
            markSyncedIfCurrent(bookID)
            return
        }
        await runCatchUp(bookID)
    }

    public func runCatchUp(_ bookID: String) async {
        guard let book = registry.book(bookID), let key = book.accountKey, let vault = book.vaultUUID,
              accounts.state(key).isSignedIn, let client = accounts.client(for: key) else { return }
        var cu = catchUp[bookID] ?? CatchUpSnapshot()
        if cu.phase == .running { return }
        if changesUnsupported.contains(key) {
            // Degraded server: no `/changes`. Accept the head and let the
            // host refetch the visible list.
            if let head = cu.head { setCursor(bookID, head) }
            onNotesChanged?(bookID, nil)
            markSyncedIfCurrent(bookID)
            return
        }
        let priorFailures: Int
        if case let .failed(n, _) = cu.phase { priorFailures = n } else { priorFailures = 0 }
        cu.phase = .running
        catchUp[bookID] = cu
        do {
            let outcome = try await CatchUp.run(client: client, vaultID: vault, cursor: cursor(bookID))
            setCursor(bookID, outcome.newCursor)
            var done = catchUp[bookID] ?? cu
            done.phase = .idle
            if done.head.map({ $0 < outcome.newCursor }) ?? true { done.head = outcome.newCursor }
            catchUp[bookID] = done
            onNotesChanged?(bookID, outcome)
            markSyncedIfCurrent(bookID)
            if let head = done.head, head > outcome.newCursor { await runCatchUp(bookID) }
        } catch let error where error.isEndpointMissing {
            changesUnsupported.insert(key)
            var done = catchUp[bookID] ?? cu
            done.phase = .idle
            catchUp[bookID] = done
            if let head = done.head { setCursor(bookID, head) }
            onNotesChanged?(bookID, nil)
            markSyncedIfCurrent(bookID)
        } catch {
            var failed = catchUp[bookID] ?? cu
            if error.isNonTransient {
                failed.phase = .failed(count: priorFailures + 1, reason: "\(error)")
            } else {
                failed.phase = .idle
            }
            catchUp[bookID] = failed
            logError(bookID, "catch-up: \(error)")
        }
    }

    // MARK: Helpers

    private func setHead(_ bookID: String, _ head: Int64) {
        var cu = catchUp[bookID] ?? CatchUpSnapshot()
        cu.head = head
        catchUp[bookID] = cu
    }

    private func setCursor(_ bookID: String, _ value: Int64?) {
        cursors[bookID] = value
        defaults.set(cursors.mapValues { NSNumber(value: $0) }, forKey: Self.cursorsKey)
    }

    private func markRevoked(_ bookID: String, reason: String) {
        if !revoked.contains(bookID) { logError(bookID, "access revoked (\(reason))") }
        revoked.insert(bookID)
    }

    private func markSyncedIfCurrent(_ bookID: String) {
        guard let b = registry.book(bookID), status(for: b) == .upToDate || status(for: b) == .readOnly else { return }
        lastSyncedAt[bookID] = Date()
    }

    private func logError(_ bookID: String, _ message: String) {
        var list = recentErrors[bookID] ?? []
        list.append("\(Date().formatted(date: .omitted, time: .standard)) \(message)")
        recentErrors[bookID] = Array(list.suffix(5))
    }
}
