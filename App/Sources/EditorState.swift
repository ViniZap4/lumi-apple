import Foundation
import Observation
import LumiKit

/// Tracks the open note's load/edit/save lifecycle. One instance lives in
/// `AppState`; switching notes calls `load` again, which discards prior in-memory
/// edits unless the caller saves first.
@Observable
@MainActor
final class EditorState {
    enum Status: Sendable, Hashable {
        case idle
        case loaded
        case saving
        case saved(at: Date)
        case conflict
        case error(message: String)
    }

    private(set) var noteID: String?
    private(set) var noteURL: URL?
    private(set) var frontmatter = Frontmatter()
    private(set) var loadedMTime: Date?

    var originalText: String = ""
    var currentText: String = ""

    private(set) var status: Status = .idle

    var isDirty: Bool { currentText != originalText }

    /// Read a note off disk and seed the editor. Replaces any prior state.
    func load(noteID: String, at url: URL, vaultRoot: URL) {
        do {
            let loaded = try NoteFile.load(at: url, vaultRoot: vaultRoot)
            self.noteID = noteID
            self.noteURL = url
            self.frontmatter = loaded.frontmatter
            self.originalText = loaded.note.content
            self.currentText = loaded.note.content
            self.loadedMTime = loaded.mtime
            self.status = .loaded
        } catch {
            self.status = .error(message: "could not read note: \(error.localizedDescription)")
        }
    }

    /// Persist current edits to disk. Detects external mtime changes since
    /// load and surfaces a conflict instead of clobbering. Caller can then
    /// choose to reload or force-save (`forceSave`).
    func save() {
        guard let url = noteURL, let mtime = loadedMTime else { return }
        if NoteFile.hasChangedExternally(at: url, sinceLoadedAt: mtime) {
            status = .conflict
            return
        }
        commit(to: url)
    }

    /// Save without honoring the conflict guard. Use after the user explicitly
    /// chooses to overwrite external changes.
    func forceSave() {
        guard let url = noteURL else { return }
        commit(to: url)
    }

    /// Discard in-memory edits, restoring the loaded baseline.
    func discard() {
        currentText = originalText
        if case .conflict = status { status = .loaded }
    }

    /// Re-read the file from disk. Use when the user resolves a conflict by
    /// taking the disk version.
    func reloadFromDisk(vaultRoot: URL) {
        guard let url = noteURL, let id = noteID else { return }
        load(noteID: id, at: url, vaultRoot: vaultRoot)
    }

    /// Drop all editor state. Call when the active vault changes or the app
    /// goes to a state where no note is selected.
    func reset() {
        noteID = nil
        noteURL = nil
        frontmatter = Frontmatter()
        loadedMTime = nil
        originalText = ""
        currentText = ""
        status = .idle
    }

    private func commit(to url: URL) {
        status = .saving
        do {
            let newMTime = try NoteFile.write(
                body: currentText,
                frontmatter: frontmatter,
                to: url
            )
            originalText = currentText
            loadedMTime = newMTime
            status = .saved(at: Date())
        } catch {
            status = .error(message: "could not write note: \(error.localizedDescription)")
        }
    }
}
