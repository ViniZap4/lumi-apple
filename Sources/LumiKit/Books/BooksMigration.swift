import Foundation

/// Snapshot of a SwiftData `VaultRecord`, taken by the app before import so
/// this module never touches live managed objects.
public struct LegacyVaultSnapshot: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let bookmark: Data?
    /// Folder path resolved from the bookmark, if any.
    public let resolvedPath: String?
    public let serverEndpoint: String?
    public let serverVaultSlug: String?
    public let serverAccountID: String?
    public let addedAt: Date
    public let lastOpenedAt: Date?

    public init(id: UUID, name: String, bookmark: Data?, resolvedPath: String?, serverEndpoint: String?,
                serverVaultSlug: String?, serverAccountID: String?, addedAt: Date, lastOpenedAt: Date?) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.resolvedPath = resolvedPath
        self.serverEndpoint = serverEndpoint
        self.serverVaultSlug = serverVaultSlug
        self.serverAccountID = serverAccountID
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    @MainActor
    public init(record: VaultRecord, resolvedPath: String?) {
        self.init(id: record.id, name: record.name, bookmark: record.bookmarkData, resolvedPath: resolvedPath,
                  serverEndpoint: record.serverEndpoint, serverVaultSlug: record.serverVaultSlug,
                  serverAccountID: record.serverAccountID, addedAt: record.addedAt, lastOpenedAt: record.lastOpenedAt)
    }
}

public struct BooksMigrationResult: Sendable, Equatable {
    public var document: BooksDocument
    public var bookmarks: [String: Data]
    /// book id → server vault slug, resolved on the first `GET /api/vaults`.
    public var pendingSlugs: [String: String]
}

/// One-shot import into `books.yaml` (SPEC-LIVROS §2.5). Runs only when
/// `books.yaml` does not exist. `vaults.yaml` is read, never rewritten.
public enum BooksMigration {
    public static func migrate(
        records: [LegacyVaultSnapshot],
        vaultsYAML: [VaultRegistryEntry],
        readVaultID: (String) -> String?,
        now: Date
    ) -> BooksMigrationResult {
        var books: [Book] = []
        var bookmarks: [String: Data] = [:]
        var pending: [String: String] = [:]
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()

        func recency(_ last: Date?, _ added: Date) -> Date { last ?? added }

        let orderedRecords = records.sorted {
            let l = recency($0.lastOpenedAt, $0.addedAt), r = recency($1.lastOpenedAt, $1.addedAt)
            return l != r ? l > r : $0.id.uuidString < $1.id.uuidString
        }
        for r in orderedRecords {
            let id = r.id.uuidString.lowercased()
            if let bookmark = r.bookmark {
                let path = r.resolvedPath.map(encodeHomeRelative)
                books.append(Book(id: id, name: r.name, kind: .local, path: path, sort: 0,
                                  addedAt: r.addedAt, lastOpenedAt: r.lastOpenedAt))
                bookmarks[id] = bookmark
                if let p = r.resolvedPath { seenPaths.insert(p) }
            } else if let endpoint = r.serverEndpoint {
                books.append(Book(id: id, name: r.name, kind: .bound,
                                  serverURL: ServerURL.normalizedOrRaw(endpoint),
                                  account: r.serverAccountID, vaultID: nil, path: nil, sort: 0,
                                  addedAt: r.addedAt, lastOpenedAt: r.lastOpenedAt))
                if let slug = r.serverVaultSlug { pending[id] = slug }
            } else {
                continue
            }
            seenIDs.insert(id)
        }

        let orderedYAML = vaultsYAML.sorted {
            let l = recency($0.lastOpenedAt, $0.addedAt), r = recency($1.lastOpenedAt, $1.addedAt)
            return l != r ? l > r : $0.id.uuidString < $1.id.uuidString
        }
        for e in orderedYAML {
            let id = e.id.uuidString.lowercased()
            let absolute = expandHomeRelative(e.path)
            if seenIDs.contains(id) || seenPaths.contains(absolute) { continue }
            if let server = e.server {
                books.append(Book(id: id, name: e.name, kind: .bound,
                                  serverURL: ServerURL.normalizedOrRaw(server), account: e.account,
                                  vaultID: readVaultID(absolute).map(BooksFile.normalizeID),
                                  path: encodeHomeRelative(absolute), sort: 0,
                                  addedAt: e.addedAt, lastOpenedAt: e.lastOpenedAt))
            } else {
                books.append(Book(id: id, name: e.name, kind: .local, path: encodeHomeRelative(absolute),
                                  sort: 0, addedAt: e.addedAt, lastOpenedAt: e.lastOpenedAt))
            }
            seenIDs.insert(id)
            seenPaths.insert(absolute)
        }

        for i in books.indices { books[i].sort = (i + 1) * 10 }
        return BooksMigrationResult(document: BooksDocument(books: books), bookmarks: bookmarks, pendingSlugs: pending)
    }

    /// `server.vault_id` from `<folder>/.lumi/vault.yaml` (TUI `lumi vault
    /// link` writes it). Minimal reader: a `server:` block at column 0 with
    /// an indented `vault_id:` key.
    public static func serverVaultID(inFolder path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent(".lumi/vault.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return serverVaultID(fromVaultYAML: text)
    }

    public static func serverVaultID(fromVaultYAML text: String) -> String? {
        var inServer = false
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(raw)
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if content.isEmpty || content.first == "#" { continue }
            if content.count == line.count {
                inServer = content.hasPrefix("server:")
                continue
            }
            guard inServer, content.hasPrefix("vault_id:") else { continue }
            var v = content.dropFirst("vault_id:".count).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.first == "\"" && v.last == "\"") || (v.first == "'" && v.last == "'") {
                v = String(v.dropFirst().dropLast())
            }
            if v.isEmpty || v == "null" || v == "~" { return nil }
            return v
        }
        return nil
    }
}
