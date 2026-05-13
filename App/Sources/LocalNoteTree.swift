import Foundation
import LumiKit

/// One node in the recursive vault tree: either a folder (with children) or
/// a leaf note. Built from a flat `[Note]` + the vault's root URL by
/// `LocalNoteTree.build(...)`.
///
/// `id` is stable enough for SwiftUI `List(selection:)` — folders use their
/// relative path string ("a/b/c"), notes use their `Note.id`. The two
/// namespaces don't collide in practice (folder ids contain `/`, note ids
/// are slug-derived from titles), and the `kind` discriminator lets the
/// row renderer branch on shape.
struct LocalTreeItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case note(Note)
    }

    let id: String
    let name: String
    let kind: Kind
    /// Children. Folders have a (possibly empty) array; notes have `nil`
    /// (so `OutlineGroup` treats them as leaves).
    let children: [LocalTreeItem]?
}

enum LocalNoteTree {
    /// Build a sorted tree from a flat note list. `Note.path` is already
    /// relative to the vault root, so we just split on `/` to derive the
    /// folder hierarchy.
    static func build(notes: [Note]) -> [LocalTreeItem] {
        var byFolder: [[String]: [Note]] = [:]
        for note in notes {
            let parts = note.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            // Path components include the file name at the end; the folder
            // is everything before it.
            let folder = Array(parts.dropLast())
            byFolder[folder, default: []].append(note)
        }

        // Recurse from the root, building folders depth-first. We discover
        // the *set* of folder paths by walking from each note path's prefix.
        var folderSet: Set<[String]> = []
        for parts in byFolder.keys {
            for i in 0...parts.count {
                folderSet.insert(Array(parts.prefix(i)))
            }
        }
        return childrenAt(prefix: [], folderSet: folderSet, notes: byFolder)
    }

    /// Backward-compat overload (some early callsites used a `vaultRoot:` arg).
    static func build(notes: [Note], vaultRoot: URL?) -> [LocalTreeItem] {
        build(notes: notes)
    }

    private static func childrenAt(
        prefix: [String],
        folderSet: Set<[String]>,
        notes: [[String]: [Note]]
    ) -> [LocalTreeItem] {
        // Sub-folders: those whose parent path equals `prefix`.
        let subFolders = folderSet
            .filter { $0.count == prefix.count + 1 && $0.dropLast() == ArraySlice(prefix) }
            .sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }

        let folderItems: [LocalTreeItem] = subFolders.map { path in
            let children = childrenAt(prefix: path, folderSet: folderSet, notes: notes)
            return LocalTreeItem(
                id: "folder:" + path.joined(separator: "/"),
                name: path.last ?? "",
                kind: .folder,
                children: children
            )
        }

        // Notes directly in this folder, sorted by title.
        let folderNotes = (notes[prefix] ?? []).sorted { $0.title.lowercased() < $1.title.lowercased() }
        let noteItems: [LocalTreeItem] = folderNotes.map { note in
            LocalTreeItem(
                id: "note:" + note.id,
                name: note.title,
                kind: .note(note),
                children: nil
            )
        }

        return folderItems + noteItems
    }
}

extension LocalTreeItem {
    /// Walk the tree depth-first, returning every node in display order.
    /// Used by vim navigation to compute next/prev selection targets.
    static func flatten(_ items: [LocalTreeItem], expanded: Set<String>) -> [LocalTreeItem] {
        var result: [LocalTreeItem] = []
        for item in items {
            result.append(item)
            if let children = item.children, expanded.contains(item.id) {
                result.append(contentsOf: flatten(children, expanded: expanded))
            }
        }
        return result
    }
}
