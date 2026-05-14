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
    /// folders before notes, both alphabetical case-insensitive. Synchronous
    /// — only call from contexts where blocking the caller is acceptable
    /// (small directories, tests). Prefer `loadIfNeededAsync` from UI code.
    public func loadIfNeeded() {
        guard items == nil, !isLoading else { return }
        reload()
    }

    /// Like `loadIfNeeded` but performs the syscall + entry hydration off
    /// the main thread. The UI can render an empty / loading state while
    /// this runs; SwiftUI repaints automatically when `items` is set
    /// because the type is `@Observable`.
    public func loadIfNeededAsync() async {
        guard items == nil, !isLoading else { return }
        isLoading = true
        let url = self.url
        let relativePath = self.relativePath
        let entries: [LoadedEntry] = await Task.detached(priority: .userInitiated) {
            FolderNode.enumerateDisk(at: url, relativePath: relativePath)
        }.value
        applyEntries(entries)
    }

    /// Re-enumerate from disk synchronously, replacing any cached items.
    public func reload() {
        isLoading = true
        let url = self.url
        let relativePath = self.relativePath
        let entries = FolderNode.enumerateDisk(at: url, relativePath: relativePath)
        applyEntries(entries)
    }

    /// Re-enumerate asynchronously, replacing cached items. Used by the
    /// vault watcher / pull-to-refresh.
    public func reloadAsync() async {
        isLoading = true
        let url = self.url
        let relativePath = self.relativePath
        let entries: [LoadedEntry] = await Task.detached(priority: .userInitiated) {
            FolderNode.enumerateDisk(at: url, relativePath: relativePath)
        }.value
        applyEntries(entries)
    }

    /// Sendable snapshot of a single directory entry, produced off-main and
    /// rehydrated into `Item`s once we're back on the main actor.
    private struct LoadedEntry: Sendable {
        let url: URL
        let relativePath: String
        let name: String
        let isDirectory: Bool
        let mtime: Date
    }

    nonisolated private static func enumerateDisk(at url: URL, relativePath: String) -> [LoadedEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .nameKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [LoadedEntry] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            let resources = try? entry.resourceValues(forKeys: Set(keys))
            let isDir = resources?.isDirectory ?? false
            let mtime = resources?.contentModificationDate ?? Date()
            let last = entry.lastPathComponent
            let rel = relativePath.isEmpty ? last : relativePath + "/" + last
            if isDir {
                out.append(LoadedEntry(url: entry, relativePath: rel, name: last, isDirectory: true, mtime: mtime))
            } else if entry.pathExtension.lowercased() == "md" {
                out.append(LoadedEntry(url: entry, relativePath: rel, name: last, isDirectory: false, mtime: mtime))
            }
        }
        return out
    }

    private func applyEntries(_ entries: [LoadedEntry]) {
        var folders: [Item] = []
        var notes: [Item] = []
        for entry in entries {
            if entry.isDirectory {
                folders.append(.folder(FolderNode(
                    url: entry.url,
                    relativePath: entry.relativePath,
                    name: entry.name
                )))
            } else {
                notes.append(.note(NoteEntry(
                    url: entry.url,
                    relativePath: entry.relativePath,
                    updatedAt: entry.mtime
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
        isLoading = false
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
