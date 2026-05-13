import Foundation
import Observation

/// Lazy directory node for the vault tree. Each `FolderNode` represents one
/// directory under the vault root; it knows where it is on disk and its
/// vault-relative path, but doesn't enumerate its children until asked.
///
/// `loadChildren()` reads only the immediate folder via
/// `FileManager.contentsOfDirectory` (one syscall per folder, no recursion).
/// Children are cached: subsequent reads are free. `reload()` forces a fresh
/// enumeration after external changes.
///
/// The node is a reference type so SwiftUI can keep a stable identity while
/// the children array fills in. `@Observable` so DisclosureGroups update
/// when load completes.
@Observable
@MainActor
public final class FolderNode: Identifiable {
    public let url: URL
    /// Path relative to the vault root. The root node uses "".
    public let relativePath: String
    public let name: String

    public private(set) var items: [Item]?
    public private(set) var isLoading: Bool = false

    public enum Item: Sendable, Hashable, Identifiable {
        case folder(FolderNode)
        case note(NoteEntry)

        public var id: String {
            switch self {
            case .folder(let f): return "folder:" + f.relativePath
            case .note(let n): return "note:" + n.relativePath
            }
        }

        public var name: String {
            switch self {
            case .folder(let f): return f.name
            case .note(let n): return n.title
            }
        }

        public static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    nonisolated public var id: String { relativePath.isEmpty ? "/" : relativePath }

    public init(url: URL, relativePath: String = "", name: String = "") {
        self.url = url
        self.relativePath = relativePath
        self.name = name.isEmpty ? url.lastPathComponent : name
    }

    /// Read the immediate children if not already loaded. Sorted with
    /// folders before notes, both alphabetical case-insensitive.
    public func loadIfNeeded() {
        guard items == nil, !isLoading else { return }
        reload()
    }

    /// Re-enumerate from disk, replacing any cached items.
    public func reload() {
        isLoading = true
        defer { isLoading = false }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .nameKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            items = []
            return
        }

        var folders: [Item] = []
        var notes: [Item] = []
        for entry in entries {
            let resources = try? entry.resourceValues(forKeys: Set(keys))
            let isDir = resources?.isDirectory ?? false
            let mtime = resources?.contentModificationDate ?? Date()
            let entryRel = relativePath.isEmpty
                ? entry.lastPathComponent
                : relativePath + "/" + entry.lastPathComponent
            if isDir {
                folders.append(.folder(FolderNode(
                    url: entry,
                    relativePath: entryRel,
                    name: entry.lastPathComponent
                )))
            } else if entry.pathExtension.lowercased() == "md" {
                notes.append(.note(NoteEntry(
                    url: entry,
                    relativePath: entryRel,
                    updatedAt: mtime
                )))
            }
        }
        folders.sort { lhs, rhs in
            guard case let .folder(lf) = lhs, case let .folder(rf) = rhs else { return false }
            return lf.name.localizedCaseInsensitiveCompare(rf.name) == .orderedAscending
        }
        notes.sort { lhs, rhs in
            guard case let .note(ln) = lhs, case let .note(rn) = rhs else { return false }
            return ln.title.localizedCaseInsensitiveCompare(rn.title) == .orderedAscending
        }
        items = folders + notes
    }

    /// Look up a note entry under this folder by relative path (depth-first
    /// through already-loaded children). Returns `nil` if the target hasn't
    /// been walked yet — caller should expand the path first.
    public func findNote(byRelativePath path: String) -> NoteEntry? {
        guard let items else { return nil }
        for item in items {
            switch item {
            case .note(let n) where n.relativePath == path:
                return n
            case .folder(let f):
                if let hit = f.findNote(byRelativePath: path) { return hit }
            default:
                continue
            }
        }
        return nil
    }
}
