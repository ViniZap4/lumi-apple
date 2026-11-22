import Foundation
import Observation

/// Apple side of the shared book registry (SPEC-LIVROS §2.3, item A2).
///
/// `books.yaml` is the canonical list (shared with the TUI); folder
/// bookmarks live in a `BookBookmarkStore`; the active book is per device in
/// `UserDefaults['lumi.activeBookID']`. Every mutation re-reads the file
/// first so a concurrent TUI write is merged instead of clobbered, then
/// writes atomically.
@Observable
@MainActor
public final class BooksRegistry {
    public static let activeBookKey = "lumi.activeBookID"
    public static let pendingSlugsKey = "lumi.books.pendingSlugs.v1"
    public static let dismissedVaultsKey = "lumi.books.dismissedVaults.v1"
    public static let noticesShownKey = "lumi.books.federationNoticeShown.v1"
    public static let onboardingKey = "lumi.onboarding.books.v1"

    public private(set) var books: [Book] = []
    /// Non-nil when the file can't be safely rewritten (newer `version`, or
    /// unparseable). Mutations are refused while set.
    public private(set) var readOnlyReason: String?
    public private(set) var activeBookID: String?

    @ObservationIgnored public let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let bookmarks: BookBookmarkStore
    @ObservationIgnored private let now: () -> Date
    /// Preserved verbatim (TUI-only field).
    @ObservationIgnored private var tuiActive: String?
    @ObservationIgnored private var lastWrittenText: String?

    public init(
        fileURL: URL = ConfigPaths.books,
        defaults: UserDefaults = .standard,
        bookmarks: BookBookmarkStore,
        now: @escaping () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.now = now
        self.activeBookID = defaults.string(forKey: Self.activeBookKey)
    }

    // MARK: Read

    public var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Re-read `books.yaml`. Cheap; call on app activation.
    public func reload() {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else {
            if !fileExists { books = []; readOnlyReason = nil }
            return
        }
        do {
            let doc = try BooksFile.decode(text)
            books = doc.books
            tuiActive = doc.active
            readOnlyReason = nil
            lastWrittenText = text
        } catch .unsupportedVersion(let v) {
            readOnlyReason = "books.yaml uses format version \(v); update lumi to edit books"
            if let lenient = try? BooksFile.decode(text.replacingOccurrences(of: "version: \(v)", with: "version: 1")) {
                books = lenient.books
            }
        } catch {
            readOnlyReason = "books.yaml could not be read (\(error)); fix or remove it"
        }
    }

    public func book(_ id: String) -> Book? { books.first { $0.id == id } }

    public func book(vaultID: String) -> Book? {
        books.first { $0.kind == .bound && $0.vaultID == vaultID }
    }

    /// Active book; falls back to the lowest `sort` when unset or stale.
    public var activeBook: Book? {
        if let id = activeBookID, let b = book(id) { return b }
        return books.min(by: Book.registryOrder)
    }

    public var switcherGroups: [BookSwitcherOrder.Group] { BookSwitcherOrder.groups(books) }

    /// Books reachable by ⌃⌘1–9, in switcher order.
    public var shortcutBooks: [Book] { Array(BookSwitcherOrder.flattened(books).prefix(9)) }

    public var nextSort: Int { (books.map(\.sort).max() ?? 0) + 10 }

    // MARK: Migration

    /// Import VaultRecord rows + `vaults.yaml` into a fresh `books.yaml`.
    /// No-op when the file already exists. Returns true when it wrote.
    @discardableResult
    public func importIfNeeded(
        records: [LegacyVaultSnapshot],
        vaultsYAML: URL = ConfigPaths.vaults,
        readVaultID: (String) -> String? = BooksMigration.serverVaultID(inFolder:)
    ) -> Bool {
        guard !fileExists else { reload(); return false }
        let legacy = FileManager.default.fileExists(atPath: vaultsYAML.path)
            ? VaultRegistry(fileURL: vaultsYAML).entries() : []
        let result = BooksMigration.migrate(records: records, vaultsYAML: legacy, readVaultID: readVaultID, now: now())
        for (id, data) in result.bookmarks { bookmarks.setBookmark(data, for: id) }
        var pending = pendingSlugs
        pending.merge(result.pendingSlugs) { _, new in new }
        pendingSlugs = pending
        books = result.document.books
        guard write() else { return false }
        if activeBookID == nil, let first = books.first { setActiveID(first.id) }
        return true
    }

    // MARK: Mutations

    /// Re-read, mutate, write. Returns false (and changes nothing) when the
    /// registry is read-only or the write fails.
    @discardableResult
    public func mutate(_ body: (inout [Book]) -> Void) -> Bool {
        reload()
        guard readOnlyReason == nil else { return false }
        var copy = books
        body(&copy)
        let previous = books
        books = copy.sorted(by: Book.registryOrder)
        if write() { return true }
        books = previous
        return false
    }

    @discardableResult
    public func addLocal(name: String, path: String?, bookmark: Data?) -> Book? {
        let book = Book(id: UUID().uuidString.lowercased(), name: name, kind: .local,
                        path: path.map(encodeHomeRelative), sort: nextSort, addedAt: now())
        guard mutate({ $0.append(book) }) else { return nil }
        if let bookmark { bookmarks.setBookmark(bookmark, for: book.id) }
        return book
    }

    @discardableResult
    public func addBound(name: String, account: AccountKey, vaultID: UUID, path: String? = nil) -> Book? {
        let vid = vaultID.uuidString.lowercased()
        if let existing = book(vaultID: vid) { return existing }
        let book = Book(id: vid, name: name, kind: .bound, serverURL: account.serverURL, account: account.username,
                        vaultID: vid, path: path.map(encodeHomeRelative), sort: nextSort, addedAt: now())
        var dismissed = dismissedVaultIDs
        dismissed.remove(vid)
        dismissedVaultIDs = dismissed
        return mutate({ $0.append(book) }) ? book : nil
    }

    /// Local rename. Bound books are renamed on the server (PATCH, needs
    /// `vault.manage`) and the cache updated via `updateCachedName`.
    @discardableResult
    public func rename(_ id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mutate { books in
            if let i = books.firstIndex(where: { $0.id == id }) { books[i].name = trimmed }
        }
    }

    public func updateCachedName(_ id: String, to name: String) {
        guard let b = book(id), b.name != name, !name.isEmpty else { return }
        rename(id, to: name)
    }

    /// "Remover da lista": drops the row (and bookmark). Never touches the
    /// server. A bound book's vault is remembered as dismissed so the next
    /// listing doesn't re-add it.
    @discardableResult
    public func remove(_ id: String) -> Bool {
        let vid = book(id)?.vaultID
        guard mutate({ $0.removeAll { $0.id == id } }) else { return false }
        bookmarks.removeBookmark(for: id)
        if let vid {
            var dismissed = dismissedVaultIDs
            dismissed.insert(vid)
            dismissedVaultIDs = dismissed
        }
        var pending = pendingSlugs
        pending[id] = nil
        pendingSlugs = pending
        if activeBookID == id { setActiveID(nil) }
        return true
    }

    /// "Desligar": with a folder the book becomes local (server intact);
    /// without one it is removed from the list.
    @discardableResult
    public func unlink(_ id: String) -> Bool {
        guard let b = book(id), b.kind == .bound else { return false }
        if b.path == nil && bookmarks.bookmark(for: id) == nil { return remove(id) }
        return mutate { books in
            guard let i = books.firstIndex(where: { $0.id == id }) else { return }
            books[i].kind = .local
            books[i].serverURL = nil
            books[i].account = nil
            books[i].vaultID = nil
        }
    }

    /// Persist a new order (ids in desired order); sorts become 10, 20, …
    @discardableResult
    public func reorder(_ ids: [String]) -> Bool {
        mutate { books in
            var position: [String: Int] = [:]
            for (i, id) in ids.enumerated() { position[id] = (i + 1) * 10 }
            var tail = (ids.count + 1) * 10
            for i in books.indices.sorted(by: { Book.registryOrder(books[$0], books[$1]) }) {
                if let p = position[books[i].id] {
                    books[i].sort = p
                } else {
                    books[i].sort = tail
                    tail += 10
                }
            }
        }
    }

    /// "Trocar servidor": rebinding resets the per-server cursor (the
    /// caller's feed store drops it) but keeps any local Y.Docs.
    @discardableResult
    public func switchServer(_ id: String, to account: AccountKey) -> Bool {
        mutate { books in
            guard let i = books.firstIndex(where: { $0.id == id }), books[i].kind == .bound else { return }
            books[i].serverURL = account.serverURL
            books[i].account = account.username
        }
    }

    /// "Religar": attach a server vault id to an incomplete bound book.
    @discardableResult
    public func relink(_ id: String, to account: AccountKey, vaultID: UUID) -> Bool {
        let vid = vaultID.uuidString.lowercased()
        guard book(vaultID: vid) == nil || book(vaultID: vid)?.id == id else { return false }
        let ok = mutate { books in
            guard let i = books.firstIndex(where: { $0.id == id }) else { return }
            books[i].kind = .bound
            books[i].serverURL = account.serverURL
            books[i].account = account.username
            books[i].vaultID = vid
        }
        if ok {
            var pending = pendingSlugs
            pending[id] = nil
            pendingSlugs = pending
        }
        return ok
    }

    public func setActive(_ id: String) {
        setActiveID(id)
        mutate { books in
            if let i = books.firstIndex(where: { $0.id == id }) { books[i].lastOpenedAt = now() }
        }
    }

    private func setActiveID(_ id: String?) {
        activeBookID = id
        if let id { defaults.set(id, forKey: Self.activeBookKey) } else { defaults.removeObject(forKey: Self.activeBookKey) }
    }

    /// Apply a reconcile pass (new books, resolved slugs, cached names).
    /// Returns the result's notices that haven't been shown yet.
    @discardableResult
    public func apply(_ result: ReconcileResult) -> [FederationNotice] {
        if result.books != books {
            let target = result.books
            let targetIDs = Set(target.map(\.id))
            let dropped = Set(books.map(\.id)).subtracting(targetIDs)
            mutate { fresh in
                // Merge onto the freshly re-read list: rows produced by the
                // reconcile win, rows the TUI added meanwhile stay, rows the
                // reconcile collapsed (duplicates) go.
                var merged = fresh.filter { !targetIDs.contains($0.id) && !dropped.contains($0.id) }
                merged.append(contentsOf: target)
                fresh = merged
            }
        }
        if !result.resolvedSlugs.isEmpty {
            var pending = pendingSlugs
            for id in result.resolvedSlugs { pending[id] = nil }
            pendingSlugs = pending
        }
        var shown = Set(defaults.stringArray(forKey: Self.noticesShownKey) ?? [])
        let fresh = result.notices.filter { !shown.contains($0.bookID) }
        for n in fresh { shown.insert(n.bookID) }
        defaults.set(shown.sorted(), forKey: Self.noticesShownKey)
        return fresh
    }

    // MARK: Side state

    public var pendingSlugs: [String: String] {
        get { (defaults.dictionary(forKey: Self.pendingSlugsKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.pendingSlugsKey) }
    }

    public var dismissedVaultIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.dismissedVaultsKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.dismissedVaultsKey) }
    }

    public var onboardingShown: Bool {
        get { defaults.bool(forKey: Self.onboardingKey) }
        set { defaults.set(newValue, forKey: Self.onboardingKey) }
    }

    // MARK: Write

    @discardableResult
    private func write() -> Bool {
        let doc = BooksDocument(version: BooksFile.currentVersion, active: tuiActive, books: books)
        let text = BooksFile.encode(doc)
        if text == lastWrittenText && fileExists { return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastWrittenText = text
            return true
        } catch {
            return false
        }
    }
}
