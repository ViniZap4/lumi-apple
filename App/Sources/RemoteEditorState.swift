import Foundation
import Observation
import LumiKit

/// Tracks the open server-note's load/edit/save lifecycle. Sibling of the
/// local-vault `EditorState`; same dirty / save-status shape, but commits
/// land via `PATCH /api/vaults/:vault/notes/:id` instead of an atomic
/// disk write. One instance lives on `AppState`; switching notes calls
/// `load` again, which discards prior in-memory edits unless the caller
/// saves first.
@Observable
@MainActor
final class RemoteEditorState {
    enum Status: Sendable, Equatable {
        case idle
        case loaded
        case saving
        case saved(at: Date)
        case error(message: String)
    }

    private(set) var noteID: String?
    private(set) var vaultID: UUID?
    /// Vault-relative path as reported by the server. Useful for chrome
    /// (breadcrumbs) and for future "rename" support.
    private(set) var path: String?

    var originalText: String = ""
    var currentText: String = ""

    private(set) var status: Status = .idle

    var isDirty: Bool { currentText != originalText }

    /// Seed the editor from a freshly-fetched content response. Replaces
    /// any prior state, regardless of dirty.
    func load(_ content: RemoteNoteContent) {
        self.noteID = content.id
        self.vaultID = content.vaultID
        self.path = content.path
        self.originalText = content.body
        self.currentText = content.body
        self.status = .loaded
    }

    /// PATCH the current text to the server. Returns the updated row so
    /// the caller can refresh its list cache. On success the baseline is
    /// reset so `isDirty` reads false until the next keystroke.
    @discardableResult
    func save(via client: LumiAPIClient) async -> RemoteNote? {
        guard let vaultID, let noteID else { return nil }
        status = .saving
        do {
            let updated = try await client.updateNote(
                vaultID: vaultID,
                noteID: noteID,
                body: currentText
            )
            originalText = currentText
            status = .saved(at: Date())
            return updated
        } catch let error as LumiAPIError {
            status = .error(message: describe(error))
            return nil
        } catch {
            status = .error(message: error.localizedDescription)
            return nil
        }
    }

    /// Discard in-memory edits, restoring the loaded baseline.
    func discard() {
        currentText = originalText
        if case .error = status { status = .loaded }
    }

    /// Drop all editor state. Call when the open note changes or the
    /// session is signed out.
    func reset() {
        noteID = nil
        vaultID = nil
        path = nil
        originalText = ""
        currentText = ""
        status = .idle
    }

    /// `true` when the editor is currently bound to the given (vault,
    /// noteID) pair. Used by the host to decide whether `load` is
    /// necessary or the existing state is already valid.
    func isBound(toVaultID v: UUID, noteID n: String) -> Bool {
        vaultID == v && noteID == n
    }

    private func describe(_ error: LumiAPIError) -> String {
        switch error {
        case .unauthorized: return "session expired — sign in again"
        case .network(let m): return "network error: \(m)"
        case .server(_, let code, let detail):
            switch code {
            case "forbidden": return "you don't have permission to edit this note (note.write)"
            case "not_found": return "this note no longer exists on the server"
            case "validation_failed": return detail ?? "validation failed"
            default: return detail ?? code
            }
        case .invalidResponse(let s): return "unexpected response (HTTP \(s))"
        case .decoding(let m): return "decode failed: \(m)"
        }
    }
}
