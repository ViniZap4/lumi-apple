import Foundation
import LumiKit

/// Resolves a vault binding to its filesystem root and scans notes from disk.
/// Wraps bookmark resolution and security scope handling in one place.
@MainActor
enum VaultLoader {
    struct Loaded {
        let vaultURL: URL
        let notes: [Note]
    }

    static func load(record: VaultRecord) -> Loaded? {
        guard let bookmark = record.bookmarkData else { return nil }
        guard let resolved = try? Bookmark.decode(bookmark) else { return nil }

        let vaultURL = resolved.url
        let started = vaultURL.startAccessingSecurityScopedResource()
        defer { if started { vaultURL.stopAccessingSecurityScopedResource() } }

        let notes = VaultScanner.scan(at: vaultURL)
        return Loaded(vaultURL: vaultURL, notes: notes)
    }
}
