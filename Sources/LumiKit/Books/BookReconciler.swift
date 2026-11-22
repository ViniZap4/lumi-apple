import Foundation

/// One successful `GET /api/vaults` for one account.
public struct AccountListing: Sendable, Equatable {
    public let key: AccountKey
    public let accountAddedAt: Date
    public let vaults: [RemoteVault]

    public init(key: AccountKey, accountAddedAt: Date, vaults: [RemoteVault]) {
        self.key = key
        self.accountAddedAt = accountAddedAt
        self.vaults = vaults
    }
}

/// "This book is also on X. It syncs through Y." — shown once per book.
public struct FederationNotice: Sendable, Equatable {
    public let bookID: String
    public let syncsVia: AccountKey
    public let alsoOn: [AccountKey]
}

public struct ReconcileResult: Sendable, Equatable {
    public var books: [Book]
    /// Ids of books created by this pass (rule 2/3).
    public var added: [String] = []
    /// Other accounts where the same vault_id is reachable (rule 4).
    public var alternates: [String: [AccountKey]] = [:]
    public var notices: [FederationNotice] = []
    /// Bound books whose account listed successfully but no longer sees
    /// the vault (`revoked`, same as a missing row in `hello`).
    public var revoked: Set<String> = []
    /// Pending-slug books whose `vault_id` was resolved (VaultRecord
    /// migration, SPEC-LIVROS §2.5).
    public var resolvedSlugs: [String] = []
    /// The server row backing each bound book (role, can_edit, head).
    public var remote: [String: RemoteVault] = [:]
}

/// Pure implementation of the federation dedupe rule (SPEC-LIVROS §2.4).
public enum BookReconciler {
    public static func reconcile(
        books input: [Book],
        listings: [AccountListing],
        pendingSlugs: [String: String] = [:],
        dismissedVaultIDs: Set<String> = [],
        now: Date
    ) -> ReconcileResult {
        var books = input.sorted(by: Book.registryOrder)

        struct Source { let key: AccountKey; let addedAt: Date; let vault: RemoteVault }
        var sources: [String: [Source]] = [:]
        var listedKeys = Set<AccountKey>()
        for listing in listings {
            listedKeys.insert(listing.key)
            for v in listing.vaults {
                sources[v.id.uuidString.lowercased(), default: []]
                    .append(Source(key: listing.key, addedAt: listing.accountAddedAt, vault: v))
            }
        }

        var result = ReconcileResult(books: [])

        // Migration: resolve `vault_id` by slug for VaultRecord-derived rows.
        for i in books.indices where books[i].kind == .bound && books[i].vaultID == nil {
            guard let slug = pendingSlugs[books[i].id], let server = books[i].serverURL else { continue }
            let onServer = listings.filter { $0.key.serverURL == ServerURL.normalizedOrRaw(server) }
            let preferred = onServer.first { $0.key.username == books[i].account } ?? onServer.first
            guard let listing = preferred, let match = listing.vaults.first(where: { $0.slug == slug }) else { continue }
            books[i].vaultID = match.id.uuidString.lowercased()
            books[i].account = listing.key.username
            books[i].serverURL = listing.key.serverURL
            result.resolvedSlugs.append(books[i].id)
        }

        // Rule 1: at most one bound book per vault_id. Path-less duplicates
        // (e.g. hand edits) collapse into the first in registry order.
        var seenVaults = Set<String>()
        books = books.filter { b in
            guard b.kind == .bound, let vid = b.vaultID else { return true }
            if seenVaults.contains(vid) { return b.path != nil }
            seenVaults.insert(vid)
            return true
        }

        // Existing bound books: refresh name, collect alternates, detect revoked.
        for i in books.indices {
            guard books[i].kind == .bound, let vid = books[i].vaultID, let key = books[i].accountKey else { continue }
            let srcs = sources[vid] ?? []
            if let mine = srcs.first(where: { $0.key == key }) {
                result.remote[books[i].id] = mine.vault
                if !mine.vault.name.isEmpty { books[i].name = mine.vault.name }
                let others = srcs.filter { $0.key != key }.map(\.key).sorted()
                if !others.isEmpty { result.alternates[books[i].id] = others }
            } else if listedKeys.contains(key) {
                result.revoked.insert(books[i].id)
                let others = srcs.map(\.key).sorted()
                if !others.isEmpty { result.alternates[books[i].id] = others }
            }
        }

        // Rules 2/3: new vault ids become books bound to home, else oldest account.
        let known = Set(books.compactMap { $0.kind == .bound ? $0.vaultID : nil })
        var nextSort = (books.map(\.sort).max() ?? 0) + 10
        let fresh = sources
            .filter { !known.contains($0.key) && !dismissedVaultIDs.contains($0.key) }
            .map { (vid: $0.key, srcs: $0.value) }
            .sorted { lhs, rhs in
                let ln = lhs.srcs[0].vault.name.lowercased(), rn = rhs.srcs[0].vault.name.lowercased()
                return ln != rn ? ln < rn : lhs.vid < rhs.vid
            }
        for (vid, srcs) in fresh {
            let ordered = srcs.sorted { a, b in
                let ah = a.vault.federation?.isHome == true, bh = b.vault.federation?.isHome == true
                if ah != bh { return ah }
                if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
                return a.key < b.key
            }
            let chosen = ordered[0]
            let book = Book(
                id: vid,
                name: chosen.vault.name,
                kind: .bound,
                serverURL: chosen.key.serverURL,
                account: chosen.key.username,
                vaultID: vid,
                path: nil,
                sort: nextSort,
                addedAt: now,
                lastOpenedAt: nil
            )
            nextSort += 10
            books.append(book)
            result.added.append(book.id)
            result.remote[book.id] = chosen.vault
            let others = ordered.dropFirst().map(\.key).sorted()
            if !others.isEmpty {
                result.alternates[book.id] = others
                result.notices.append(FederationNotice(bookID: book.id, syncsVia: chosen.key, alsoOn: others))
            }
        }

        result.books = books.sorted(by: Book.registryOrder)
        return result
    }
}

/// Switcher layout (SPEC-LIVROS §5): local books first, then one group per
/// server; groups ordered by their smallest `sort`, rows by `sort`/`id`.
/// ⌃⌘1–9 index into the flattened result, so the shortcut numbers always
/// match what the switcher shows.
public enum BookSwitcherOrder {
    public struct Group: Sendable, Equatable, Identifiable {
        /// nil = local books.
        public let serverURL: String?
        public let books: [Book]
        public var id: String { serverURL ?? "local" }
    }

    public static func groups(_ books: [Book]) -> [Group] {
        let sorted = books.sorted(by: Book.registryOrder)
        let local = sorted.filter { $0.kind == .local }
        var servers: [String] = []
        var byServer: [String: [Book]] = [:]
        for b in sorted where b.kind == .bound {
            let s = b.serverURL ?? ""
            if byServer[s] == nil { servers.append(s) }
            byServer[s, default: []].append(b)
        }
        var out: [Group] = []
        if !local.isEmpty { out.append(Group(serverURL: nil, books: local)) }
        for s in servers { out.append(Group(serverURL: s, books: byServer[s] ?? [])) }
        return out
    }

    public static func flattened(_ books: [Book]) -> [Book] {
        groups(books).flatMap(\.books)
    }
}
