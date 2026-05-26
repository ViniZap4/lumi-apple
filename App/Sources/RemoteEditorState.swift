import Foundation
import Observation
import LumiKit

/// Tracks the open server-note's load/edit/save lifecycle. Sibling of the
/// local-vault `EditorState`; same dirty / save-status shape, but commits
/// land via `POST /api/vaults/:vault/notes/:id/diff` (CRDT-aware) instead
/// of an atomic disk write or a PATCH replace. One instance lives on
/// `AppState`; switching notes calls `load(_:)` again, which discards
/// prior in-memory edits unless the caller saves first.
///
/// Slice 4d migrated the wire from PATCH to `applyDiff`. The server
/// computes the minimal (remove, insert) op against its CRDT, preserves
/// concurrent edits from other clients, and returns the post-merge
/// snapshot. We track the base64 state vector so successive diffs anchor
/// against the right CRDT history position.
///
/// Slice 4c adds strict-conflict handling: when the server rejects a
/// stale `base_clock` with `{"error":"conflict"}` (HTTP 409), the editor
/// auto-refetches the latest snapshot, replaces the baseline with the
/// server's new text + clock, but **preserves `currentText`** so the
/// user's in-flight edits aren't lost. The UI surfaces a `.conflict`
/// status carrying the server's text so the user can review and resave.
/// The server currently treats `base_clock` as advisory; once it ships
/// strict-conflict enforcement this plumbing activates automatically.
@Observable
@MainActor
final class RemoteEditorState {
    enum Status: Sendable, Equatable {
        case idle
        case loaded
        case saving
        case saved(at: Date)
        case error(message: String)
        /// Server refused the diff because our `base_clock` was stale.
        /// The editor has refetched the latest snapshot and restored the
        /// baseline to `serverText`; `currentText` still holds the user's
        /// edits. The next save will diff against the fresh clock.
        case conflict(serverText: String)
    }

    private(set) var noteID: String?
    private(set) var vaultID: UUID?
    /// Vault-relative path as reported by the server. Useful for chrome
    /// (breadcrumbs) and for future "rename" support.
    private(set) var path: String?

    /// Base64-encoded lib0-v1 state vector. Carried back to the server as
    /// `base_clock` on the next diff. Advisory in server slice 2.2 but
    /// load-bearing once 4c's strict-conflict mode lands.
    private(set) var vectorClock: String?

    var originalText: String = ""
    var currentText: String = ""

    private(set) var status: Status = .idle

    var isDirty: Bool { currentText != originalText }

    /// Seed the editor from a freshly-fetched snapshot. Replaces any
    /// prior state (text + clock), regardless of dirty.
    func load(_ snapshot: RemoteNoteSnapshot, vaultID: UUID) {
        self.noteID = snapshot.id
        self.vaultID = vaultID
        self.path = snapshot.path
        self.vectorClock = snapshot.vectorClock
        self.originalText = snapshot.text
        self.currentText = snapshot.text
        self.status = .loaded
    }

    /// Seed the editor for a fresh-create case where no server snapshot
    /// exists yet (first save will happen with `base_clock` nil). The
    /// server's first applyDiff response populates `vectorClock`.
    func loadFresh(vaultID: UUID, noteID: String, path: String) {
        self.noteID = noteID
        self.vaultID = vaultID
        self.path = path
        self.vectorClock = nil
        self.originalText = ""
        self.currentText = ""
        self.status = .loaded
    }

    /// CRDT-aware save: POSTs the current text + last-known clock to the
    /// server's diff endpoint, receives the post-merge snapshot, and
    /// accepts it as the new baseline (both `originalText` and
    /// `currentText`). Returns the new snapshot on success so the caller
    /// can refresh its `RemoteVaultsStore` caches.
    ///
    /// Accepting the merge into `currentText` means a concurrent edit
    /// from another client lands on screen the moment the user saves —
    /// not ideal UX, but the user's in-flight edits already round-tripped
    /// to the server in this same call, and the CRDT merged them
    /// non-destructively. Slice 4e (WS Yjs) will make concurrent edits
    /// visible live so this doesn't surface as a jump-on-save.
    @discardableResult
    func saveViaDiff(via client: LumiAPIClient, crdt: LumiCRDT? = nil) async -> RemoteNoteSnapshot? {
        guard let vaultID, let noteID else { return nil }
        status = .saving
        do {
            let merged: RemoteNoteSnapshot
            if let crdt {
                // Phase H slice 3: encode the user's edit as a Yjs update
                // locally and POST raw bytes. The CRDT's pre-edit state
                // vector captures "everything the server told us about";
                // applying setText then encoding against that SV yields
                // exactly the user's delta.
                let svBefore = await crdt.stateVector()
                await crdt.setText(currentText)
                let update = try await crdt.encodeDiff(againstStateVector: svBefore)
                merged = try await client.applyNoteUpdate(
                    vaultID: vaultID,
                    noteID: noteID,
                    update: update,
                    origin: "apple-diff"
                )
            } else {
                merged = try await client.applyNoteDiff(
                    vaultID: vaultID,
                    noteID: noteID,
                    baseClock: vectorClock,
                    text: currentText,
                    origin: "apple-diff"
                )
            }
            // Accept the server's post-merge view as the new baseline.
            // currentText is also overwritten — concurrent edits from
            // another client land on screen the moment we save, but the
            // user's edits already round-tripped non-destructively
            // through the CRDT.
            originalText = merged.text
            currentText = merged.text
            vectorClock = merged.vectorClock
            path = merged.path
            status = .saved(at: Date())
            return merged
        } catch let error as LumiAPIError {
            // Strict-conflict: server rejected our diff because our
            // base_clock was stale. Refetch the latest snapshot, restore
            // the baseline from it, and *preserve* the user's currentText
            // so their edits survive. The next save will diff against
            // the fresh clock. Slice 4c.
            if error.isApplyDiffConflict {
                await handleStrictConflict(via: client, vaultID: vaultID, noteID: noteID)
                return nil
            }
            status = .error(message: describe(error))
            return nil
        } catch {
            status = .error(message: error.localizedDescription)
            return nil
        }
    }

    /// Refetch the snapshot, install it as the new baseline, and leave
    /// `currentText` alone. Sets `status = .conflict(serverText:)`. If
    /// the refetch itself fails, fall back to a plain `.error` so the
    /// user at least sees something actionable.
    private func handleStrictConflict(
        via client: LumiAPIClient,
        vaultID: UUID,
        noteID: String
    ) async {
        do {
            let fresh = try await client.getNoteSnapshot(vaultID: vaultID, noteID: noteID)
            originalText = fresh.text
            vectorClock = fresh.vectorClock
            path = fresh.path
            // Intentionally leave currentText untouched.
            status = .conflict(serverText: fresh.text)
        } catch let error as LumiAPIError {
            status = .error(message: describe(error))
        } catch {
            status = .error(message: error.localizedDescription)
        }
    }

    /// Discard in-memory edits, restoring the loaded baseline.
    func discard() {
        currentText = originalText
        if case .error = status { status = .loaded }
        if case .conflict = status { status = .loaded }
    }

    /// Drop all editor state. Call when the open note changes or the
    /// session is signed out.
    func reset() {
        noteID = nil
        vaultID = nil
        path = nil
        vectorClock = nil
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
            case "validation_failed", "validation": return detail ?? "validation failed"
            case "crdt_unavailable": return "the server's CRDT service is offline — try again shortly"
            case "conflict": return detail ?? "another device saved first — refetch and resave"
            default: return detail ?? code
            }
        case .invalidResponse(let s): return "unexpected response (HTTP \(s))"
        case .decoding(let m): return "decode failed: \(m)"
        }
    }
}
