import Foundation
import LumiKit

/// Holds a security-scoped resource open for the lifetime of an active vault.
///
/// `VaultLoader` previously opened scope, scanned, and closed in a single
/// call — which meant local image references couldn't be loaded later, since
/// no scope was active at render time. A `VaultSession` keeps the scope alive
/// from selection until the vault is deselected (or the app exits).
@MainActor
final class VaultSession {
    let vaultID: UUID
    let rootURL: URL
    private let started: Bool
    private var isClosed = false

    private init(vaultID: UUID, rootURL: URL, started: Bool) {
        self.vaultID = vaultID
        self.rootURL = rootURL
        self.started = started
    }

    static func open(record: VaultRecord) -> VaultSession? {
        guard let bookmark = record.bookmarkData else { return nil }
        guard let resolved = try? Bookmark.decode(bookmark) else { return nil }
        let url = resolved.url
        let started = url.startAccessingSecurityScopedResource()
        return VaultSession(vaultID: record.id, rootURL: url, started: started)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if started { rootURL.stopAccessingSecurityScopedResource() }
    }

    deinit {
        if !isClosed && started {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }

    /// Resolve a note's vault-relative path to an absolute URL inside the
    /// session's root.
    func resolve(_ note: Note) -> URL {
        rootURL.appending(path: note.path)
    }

    /// Resolve a NoteEntry to an absolute URL. NoteEntry already carries the
    /// URL, so this is a passthrough; provided for symmetry with `resolve(_:)`.
    func resolve(_ entry: NoteEntry) -> URL {
        entry.url
    }

    /// Build a `FolderNode` rooted at the vault. The node is empty until
    /// `loadIfNeeded()` is called — keeping vault-open cheap regardless of
    /// vault size.
    func rootFolder() -> FolderNode {
        FolderNode(url: rootURL, relativePath: "", name: rootURL.lastPathComponent)
    }
}
