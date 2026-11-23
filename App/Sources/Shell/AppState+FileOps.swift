import Foundation
import LumiKit

/// Explorer file operations (`a` create, `r` rename, `d` delete, `y`/`p`).
/// Local books act on the folder; server books go through REST metadata
/// calls only — bodies stay in the CRDT and are never seeded locally.
extension AppState {
    func beginCreate() {
        guard requireOnline("creating notes") else { return }
        guard can("note.create") else {
            showToast("you can't create notes in this book (note.create)", tone: .warning)
            return
        }
        explorer.prompt = .init(kind: .create, text: "")
    }

    func beginRename() {
        guard let cur = explorer.nav.current else { return }
        if !explorer.isLocal {
            guard requireOnline("renaming notes") else { return }
            guard cur.kind == .note else {
                showToast("folders on a server book are renamed through their notes", tone: .warning)
                return
            }
            guard can("note.write") else {
                showToast("you can't rename notes in this book (note.write)", tone: .warning)
                return
            }
        }
        let prefill = cur.kind == .folder ? cur.name : (explorer.isLocal ? NoteTree.stem(cur.path) : cur.name)
        explorer.prompt = .init(kind: .rename(cur), text: prefill)
    }

    func beginDelete() {
        guard let cur = explorer.nav.current else { return }
        if !explorer.isLocal {
            guard requireOnline("deleting notes") else { return }
            guard cur.kind == .note else {
                showToast("delete the notes inside to remove a folder", tone: .warning)
                return
            }
            guard can("note.delete") else {
                showToast("you can't delete notes in this book (note.delete)", tone: .warning)
                return
            }
        }
        explorer.pendingDelete = cur
    }

    /// Enter in the bottom prompt.
    func commitPrompt() {
        guard let prompt = explorer.prompt else { return }
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt.kind {
        case .filter:
            explorer.nav.setFilter(prompt.text)
            explorer.prompt = nil
        case .create:
            explorer.prompt = nil
            guard !text.isEmpty else { return }
            Task { await create(text) }
        case let .rename(entry):
            explorer.prompt = nil
            guard !text.isEmpty else { return }
            Task { await rename(entry, to: text) }
        }
    }

    func cancelPrompt() {
        if case .filter = explorer.prompt?.kind { explorer.nav.setFilter("") }
        explorer.prompt = nil
    }

    // MARK: Create

    private func create(_ input: String) async {
        let dir = explorer.nav.dir
        let isFolder = input.hasSuffix("/")
        let rel = NoteTree.normalizePath(dir.isEmpty ? input : dir + "/" + input)
        guard !rel.isEmpty else { return }
        switch explorer.source {
        case .local:
            guard let target = explorer.localDirURL(isFolder ? rel : NoteTree.dirOf(rel)) else { return }
            do {
                if isFolder {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    explorer.rescanLocal()
                    explorer.nav.goTo(rel)
                    return
                }
                let url = try FileOperations.createNote(in: target, title: NoteTree.baseName(rel))
                let created = NoteTree.normalizePath((NoteTree.dirOf(rel).isEmpty ? "" : NoteTree.dirOf(rel) + "/") + url.lastPathComponent)
                explorer.rescanLocal(reveal: created)
                let entry = ExplorerEntry(kind: .note, key: NoteTree.noteKey(created), name: NoteTree.stem(created),
                                          path: created, count: 0, note: ExplorerNote(id: created, path: created, updatedAt: Date()))
                open(entry, edit: true)
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .remote:
            if isFolder {
                showToast("server books have no empty folders — create a note inside: \(rel)/name", tone: .warning)
                return
            }
            do {
                let title = NoteTree.baseName(rel)
                var created = try await remoteVaultsStore.createNote(title: title)
                let folder = NoteTree.dirOf(rel)
                if !folder.isEmpty {
                    let file = NoteTree.baseName(created.path.isEmpty ? created.id + ".md" : created.path)
                    created = try await remoteVaultsStore.updateNoteMeta(noteID: created.id, path: folder + "/" + file)
                }
                explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
                explorer.nav.reveal(noteID: created.id)
                if let entry = explorer.nav.current, entry.note?.id == created.id {
                    open(entry, edit: true)
                }
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .none:
            break
        }
    }

    // MARK: Rename

    private func rename(_ entry: ExplorerEntry, to input: String) async {
        switch explorer.source {
        case .local:
            guard let url = explorer.localURL(for: entry) else { return }
            do {
                let newURL = try FileOperations.rename(at: url, to: input)
                let dir = NoteTree.dirOf(entry.path)
                let newRel = (dir.isEmpty ? "" : dir + "/") + newURL.lastPathComponent
                if selectedEntry?.relativePath == entry.path { closeNote() }
                explorer.rescanLocal(reveal: newRel)
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .remote:
            guard let note = entry.note else { return }
            // `r` renames the title; a `/` in the input also moves the
            // note (relative to its folder), like yazi.
            let dir = NoteTree.dirOf(entry.path)
            var path: String?
            var title = input
            if input.contains("/") {
                let rel = NoteTree.normalizePath(dir.isEmpty ? input : dir + "/" + input)
                title = NoteTree.stem(rel)
                path = (NoteTree.dirOf(rel).isEmpty ? "" : NoteTree.dirOf(rel) + "/") + NoteTree.baseName(entry.path)
            }
            do {
                let updated = try await remoteVaultsStore.updateNoteMeta(noteID: note.id, title: title, path: path)
                explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
                explorer.nav.reveal(noteID: updated.id)
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .none:
            break
        }
    }

    // MARK: Delete

    func confirmDelete() {
        guard let entry = explorer.pendingDelete else { return }
        explorer.pendingDelete = nil
        switch explorer.source {
        case .local:
            guard let url = explorer.localURL(for: entry) else { return }
            do {
                if let open = selectedEntry?.relativePath,
                   open == entry.path || open.hasPrefix(entry.path + "/") {
                    closeNote()
                }
                try FileOperations.delete(at: url)
                explorer.rescanLocal()
                showToast("moved \(entry.name) to the Trash")
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .remote:
            guard let note = entry.note else { return }
            Task {
                do {
                    if selectedRemoteNoteID == note.id { closeNote() }
                    try await remoteVaultsStore.deleteNote(noteID: note.id)
                    explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
                    showToast("deleted \(entry.name)")
                } catch {
                    showToast(describe(error), tone: .error)
                }
            }
        case .none:
            break
        }
    }

    // MARK: Paste

    func paste() {
        guard requireOnline("duplicating notes") else { return }
        guard let yanked = explorer.yanked, let note = yanked.note else {
            showToast("nothing yanked — y on a note first")
            return
        }
        let dir = explorer.nav.dir
        switch explorer.source {
        case .local:
            guard let src = explorer.localURL(for: yanked), let destDir = explorer.localDirURL(dir) else { return }
            do {
                var copy = try FileOperations.duplicateNote(at: src)
                if copy.deletingLastPathComponent().standardizedFileURL != destDir.standardizedFileURL {
                    copy = try FileOperations.move(copy, into: destDir)
                }
                let rel = (dir.isEmpty ? "" : dir + "/") + copy.lastPathComponent
                explorer.rescanLocal(reveal: rel)
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .remote:
            guard can("note.create") else {
                showToast("you can't create notes in this book (note.create)", tone: .warning)
                return
            }
            Task {
                do {
                    let body = try await remoteVaultsStore.noteBody(noteID: note.id)
                    var created = try await remoteVaultsStore.createNote(title: yanked.name + " copy", body: body)
                    if !dir.isEmpty {
                        let file = NoteTree.baseName(created.path.isEmpty ? created.id + ".md" : created.path)
                        created = try await remoteVaultsStore.updateNoteMeta(noteID: created.id, path: dir + "/" + file)
                    }
                    explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
                    explorer.nav.reveal(noteID: created.id)
                } catch {
                    showToast(describe(error), tone: .error)
                }
            }
        case .none:
            break
        }
    }

    func describe(_ error: Error) -> String {
        if let e = error as? FileOperations.Error { return e.errorDescription ?? "\(e)" }
        if let e = error as? LumiAPIError {
            switch e {
            case .unauthorized: return "session expired — sign in again"
            case .network(let m): return "network: \(m)"
            case .server(_, let code, let detail): return detail ?? code
            case .invalidResponse(let s): return "unexpected response (HTTP \(s))"
            case .decoding(let m): return "decode failed: \(m)"
            }
        }
        return error.localizedDescription
    }
}
