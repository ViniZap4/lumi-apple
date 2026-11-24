import Foundation
import SwiftUI
import LumiKit
import LumiUI

/// Note kinds for the explorer, the palette and the previews: canvas by
/// extension, boards by their frontmatter (learned lazily, a few KB per
/// file, never the whole note).
extension AppState {
    func entryKind(_ entry: ExplorerEntry) -> NoteKind {
        let path = entry.path.isEmpty ? (entry.note?.id ?? entry.path) : entry.path
        if NoteKind.isCanvasPath(path) { return .canvas }
        if let k = noteKindCache[path] { return k }
        if let doc = localDocs.peek(path), doc.isKanban { return .kanban }
        if !explorer.isLocal, let id = entry.note?.id, remoteVaultsStore.frontmatterHint(noteID: id) != nil { return .kanban }
        return .markdown
    }

    /// Read a local note's head once to learn whether it is a board.
    func learnKind(_ entry: ExplorerEntry) {
        guard entry.kind == .note, explorer.isLocal else { return }
        let path = entry.path
        guard !NoteKind.isCanvasPath(path), noteKindCache[path] == nil, !noteKindPending.contains(path),
              let url = explorer.localURL(for: entry) else { return }
        noteKindPending.insert(path)
        Task { @MainActor [weak self] in
            let head: String? = await Task.detached(priority: .utility) {
                guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? h.close() }
                return (try? h.read(upToCount: 4096)).map { String(decoding: $0, as: UTF8.self) }
            }.value
            guard let self else { return }
            self.noteKindPending.remove(path)
            let kind: NoteKind = head.map { NoteKind.resolve(path: path, text: $0) } ?? .markdown
            if self.noteKindCache[path] != kind { self.noteKindCache[path] = kind }
        }
    }

    /// Remember a kind learned from a full read (previews, hover cards).
    func noteKindLearned(_ path: String, text: String) {
        let k = NoteKind.resolve(path: path, text: text)
        if noteKindCache[path] != k { noteKindCache[path] = k }
    }
}
