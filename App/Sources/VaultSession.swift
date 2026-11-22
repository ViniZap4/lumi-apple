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
    let vaultID: String
    let rootURL: URL
    private let started: Bool
    private var isClosed = false

    private init(vaultID: String, rootURL: URL, started: Bool) {
        self.vaultID = vaultID
        self.rootURL = rootURL
        self.started = started
    }

    /// Open a local book's folder: the security-scoped bookmark when we
    /// have one, else (macOS, unsandboxed) the `path` from books.yaml —
    /// e.g. a book the TUI added.
    static func open(book: Book, bookmark: Data?) -> VaultSession? {
        if let bookmark, let resolved = try? Bookmark.decode(bookmark) {
            let url = resolved.url
            let started = url.startAccessingSecurityScopedResource()
            return VaultSession(vaultID: book.id, rootURL: url, started: started)
        }
        #if os(macOS)
        if let path = book.path {
            let url = URL(fileURLWithPath: expandHomeRelative(path), isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return VaultSession(vaultID: book.id, rootURL: url, started: false)
            }
        }
        #endif
        return nil
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
