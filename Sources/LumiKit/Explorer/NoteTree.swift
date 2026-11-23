import Foundation

/// Folder tree derived from note paths (yazi / miller explorer).
///
/// Port of the web client's `notetree.ts` so both clients order and
/// name entries identically. The server has no folder objects: a folder
/// exists because some note path lives under it. `NoteTree.build` turns
/// the flat note list into one sorted entry list per folder — folders
/// first, then notes, both in natural, case-insensitive order.
///
/// Local books feed it the same way (a recursive scan of `*.md` files),
/// so the explorer has a single code path for both book kinds.
public struct ExplorerNote: Sendable, Hashable {
    /// Stable note identity: the server slug for bound books, the
    /// book-relative path for local ones.
    public var id: String
    /// Book-relative path (`a/b/note.md`). Empty → `<id>.md`.
    public var path: String
    /// Display title; empty falls back to the file stem.
    public var title: String
    public var updatedAt: Date?

    public init(id: String, path: String, title: String = "", updatedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.title = title
        self.updatedAt = updatedAt
    }
}

public struct ExplorerEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case folder, note }

    public var kind: Kind
    /// Unique within the tree: `d:<path>` for folders, `n:<id>` for notes.
    public var key: String
    public var name: String
    /// Folder path, or the normalised note path.
    public var path: String
    /// Direct children (folders only).
    public var count: Int
    /// The note (notes only).
    public var note: ExplorerNote?

    public var id: String { key }
    public var isFolder: Bool { kind == .folder }
    /// Dot-files / dot-folders, hidden unless the user toggles `.`.
    public var isHidden: Bool { NoteTree.baseName(path).hasPrefix(".") }
}

public struct NoteTree: Sendable, Equatable {
    /// Folder path (`""` = book root) → sorted entries.
    public private(set) var folders: [String: [ExplorerEntry]]
    /// Note id → folder path.
    public private(set) var noteDir: [String: String]
    public private(set) var noteCount: Int

    public static let root = ""
    public static let empty = NoteTree.build([])

    // MARK: Paths

    /// `./a//b\\c.md` → `a/b/c.md`. Drops empty, `.` and `..` segments so a
    /// hostile path can never climb above the book root in the UI.
    public static func normalizePath(_ p: String) -> String {
        p.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    public static func dirOf(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return root }
        return String(path[..<i])
    }

    /// Parent of a folder; nil for the root.
    public static func parentDir(_ dir: String) -> String? {
        dir == root ? nil : dirOf(dir)
    }

    public static func baseName(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: i)...])
    }

    public static func stem(_ path: String) -> String {
        let base = baseName(path)
        if base.lowercased().hasSuffix(".md") { return String(base.dropLast(3)) }
        return base
    }

    public static func folderKey(_ path: String) -> String { "d:" + path }
    public static func noteKey(_ id: String) -> String { "n:" + id }

    /// Breadcrumb segments from the root to `dir` (root first, named `/`).
    public static func breadcrumb(_ dir: String) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = [("/", root)]
        guard dir != root else { return out }
        let parts = dir.split(separator: "/").map(String.init)
        for i in parts.indices {
            out.append((parts[i], parts[0...i].joined(separator: "/")))
        }
        return out
    }

    // MARK: Build

    /// - Parameter extraFolders: folders that exist without notes (local
    ///   books can hold empty directories; server books cannot).
    public static func build(_ notes: [ExplorerNote], extraFolders: [String] = []) -> NoteTree {
        var subdirs: [String: Set<String>] = [root: []]
        var files: [String: [ExplorerEntry]] = [root: []]
        var noteDir: [String: String] = [:]

        func ensureDir(_ start: String) {
            var dir = start
            var child: String?
            while true {
                let known = subdirs[dir] != nil
                if !known {
                    subdirs[dir] = []
                    files[dir] = []
                }
                if let child { subdirs[dir]?.insert(child) }
                if known { return }
                child = dir
                dir = dirOf(dir)
            }
        }

        for folder in extraFolders {
            let dir = normalizePath(folder)
            if !dir.isEmpty { ensureDir(dir) }
        }

        for n in notes where noteDir[n.id] == nil {
            var path = normalizePath(n.path)
            if path.isEmpty { path = normalizePath(n.id + ".md") }
            let dir = dirOf(path)
            ensureDir(dir)
            noteDir[n.id] = dir
            let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            files[dir, default: []].append(ExplorerEntry(
                kind: .note,
                key: noteKey(n.id),
                name: title.isEmpty ? stem(path) : title,
                path: path,
                count: 0,
                note: n
            ))
        }

        var folders: [String: [ExplorerEntry]] = [:]
        for (dir, subs) in subdirs {
            var folderEntries = subs.map { sub in
                ExplorerEntry(
                    kind: .folder,
                    key: folderKey(sub),
                    name: baseName(sub),
                    path: sub,
                    count: (subdirs[sub]?.count ?? 0) + (files[sub]?.count ?? 0),
                    note: nil
                )
            }
            folderEntries.sort { naturalLess($0.name, $1.name) }
            var noteEntries = files[dir] ?? []
            noteEntries.sort {
                let c = naturalCompare($0.name, $1.name)
                return c == .orderedSame ? naturalLess($0.path, $1.path) : c == .orderedAscending
            }
            folders[dir] = folderEntries + noteEntries
        }
        return NoteTree(folders: folders, noteDir: noteDir, noteCount: noteDir.count)
    }

    static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
    }

    static func naturalLess(_ a: String, _ b: String) -> Bool {
        naturalCompare(a, b) == .orderedAscending
    }

    // MARK: Queries

    /// Entries of `dir`, optionally without dot-entries.
    public func entries(in dir: String, showHidden: Bool = true) -> [ExplorerEntry] {
        let all = folders[dir] ?? []
        return showHidden ? all : all.filter { !$0.isHidden }
    }

    /// Nearest folder that still exists (notes moved/deleted under us).
    public func nearestExisting(_ dir: String) -> String {
        var d: String? = dir
        while let cur = d, folders[cur] == nil { d = NoteTree.parentDir(cur) }
        return d ?? NoteTree.root
    }

    /// Every note in the tree (for the palette), unsorted.
    public var allNotes: [ExplorerEntry] {
        folders.values.flatMap { $0.filter { $0.kind == .note } }
    }

    /// Case-insensitive substring filter on the entry name (and, for
    /// notes, the file name). Empty query = identity.
    public static func filter(_ entries: [ExplorerEntry], query: String) -> [ExplorerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.name.lowercased().contains(q) ||
                ($0.kind == .note && baseName($0.path).lowercased().contains(q))
        }
    }
}
