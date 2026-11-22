import Foundation
import Observation

/// REST-only editor state for server notes on platforms without a local
/// CRDT (visionOS: yswift ships no visionOS slice). macOS and iOS edit
/// server notes through `NoteSyncSession` instead and never bind this.
///
/// Saves use the 3-way form of `POST …/diff` (CRDT-CLIENT-PROTOCOL §7.2):
/// `{text, base_state}` where `base_state` is the snapshot `state` the
/// edit started from, so the server merges instead of overwriting
/// (vector V9b). Without a base the server answers `409 base_required`.
/// After every successful save the baseline (text + state) is refetched
/// so the next save's base matches what the user is looking at.
///
/// Lives in LumiKit (not the App target) so the save lifecycle is unit
/// testable. Uses Observation only — no SwiftUI.
@Observable
@MainActor
public final class RemoteEditorState {
    public enum Status: Sendable, Equatable {
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

    public private(set) var noteID: String?
    public private(set) var vaultID: UUID?
    /// Vault-relative path as reported by the server. Useful for chrome
    /// (breadcrumbs) and for future "rename" support.
    public private(set) var path: String?

    /// Base64-encoded lib0-v1 state vector of the baseline.
    public private(set) var vectorClock: String?
    /// Base64 full state of the baseline (snapshot `state`): the
    /// `base_state` of the next 3-way save. Always describes exactly
    /// `originalText`.
    public private(set) var baseState: String?

    public var originalText: String = ""
    public var currentText: String = ""

    public private(set) var status: Status = .idle

    public var isDirty: Bool { currentText != originalText }

    public init() {}

    /// Seed the editor from a freshly-fetched snapshot. Replaces any
    /// prior state (text + clock), regardless of dirty.
    public func load(_ snapshot: RemoteNoteSnapshot, vaultID: UUID) {
        self.noteID = snapshot.id
        self.vaultID = vaultID
        self.path = snapshot.path
        self.vectorClock = snapshot.vectorClock
        self.baseState = snapshot.state
        self.originalText = snapshot.text
        self.currentText = snapshot.text
        self.status = .loaded
    }

    /// Seed the editor for a fresh-create case where no server snapshot
    /// exists yet (first save will happen with `base_clock` nil). The
    /// server's first applyDiff response populates `vectorClock`.
    public func loadFresh(vaultID: UUID, noteID: String, path: String) {
        self.noteID = noteID
        self.vaultID = vaultID
        self.path = path
        self.vectorClock = nil
        self.baseState = nil
        self.originalText = ""
        self.currentText = ""
        self.status = .loaded
    }

    /// Everything a commit needs, captured synchronously from the editor
    /// at the moment the user asked to save. Holding this (instead of
    /// re-reading editor properties after an `await`) is what lets a
    /// close/Esc path call `reset()` right after kicking off the save.
    public struct SaveRequest: Sendable, Equatable {
        public let vaultID: UUID
        public let noteID: String
        public let text: String
        public let baseClock: String?
        public let baseState: String?

        public init(vaultID: UUID, noteID: String, text: String, baseClock: String?, baseState: String? = nil) {
            self.vaultID = vaultID
            self.noteID = noteID
            self.text = text
            self.baseClock = baseClock
            self.baseState = baseState
        }
    }

    /// Snapshot the current binding + text. nil when not bound to a note.
    public func makeSaveRequest() -> SaveRequest? {
        guard let vaultID, let noteID else { return nil }
        return SaveRequest(vaultID: vaultID, noteID: noteID, text: currentText, baseClock: vectorClock, baseState: baseState)
    }

    /// Capture-then-commit in one main-actor step. The request is
    /// captured synchronously before this returns, so callers may
    /// `reset()` / switch notes immediately afterwards without losing
    /// the save (the bug where close/Esc spawned `Task { saveViaDiff }`
    /// and then reset the editor, making the task's guard fail).
    /// Returns nil when the editor isn't bound to a note.
    @discardableResult
    public func beginSave(via client: LumiAPIClient) -> Task<RemoteNoteSnapshot?, Never>? {
        guard let request = makeSaveRequest() else { return nil }
        return Task { @MainActor in
            await self.commit(request, via: client)
        }
    }

    /// Convenience: capture now and await the commit.
    @discardableResult
    public func saveViaDiff(via client: LumiAPIClient) async -> RemoteNoteSnapshot? {
        guard let request = makeSaveRequest() else { return nil }
        return await commit(request, via: client)
    }

    /// 3-way commit of a captured `request`. Returns the post-merge
    /// snapshot on success regardless of whether the editor is still
    /// showing that note, so the caller can refresh caches.
    ///
    /// Editor state is only touched if the editor is still bound to the
    /// request's (vault, note) when the response lands:
    /// - the baseline is refetched (`GET /snapshot`) so `baseState`
    ///   matches `originalText` again — a stale base would make the next
    ///   save re-apply this one;
    /// - `currentText` adopts the fresh text only if the user hasn't
    ///   typed since the request was captured. Text typed during the
    ///   round-trip is kept, and stays dirty against the new baseline.
    @discardableResult
    public func commit(_ request: SaveRequest, via client: LumiAPIClient) async -> RemoteNoteSnapshot? {
        if isBound(to: request) { status = .saving }
        do {
            let merged = try await client.applyNoteDiff(
                vaultID: request.vaultID,
                noteID: request.noteID,
                baseClock: request.baseClock,
                baseState: request.baseState,
                text: request.text,
                origin: "apple"
            )
            guard isBound(to: request) else { return merged }
            let fresh = (try? await client.getNoteSnapshot(vaultID: request.vaultID, noteID: request.noteID))
            guard isBound(to: request) else { return merged }
            let baseline = fresh ?? merged
            originalText = baseline.text
            if currentText == request.text {
                currentText = baseline.text
            }
            vectorClock = baseline.vectorClock
            baseState = fresh?.state
            path = baseline.path
            status = .saved(at: Date())
            return merged
        } catch {
            guard isBound(to: request) else { return nil }
            // 409 base_required / base_mismatch / conflict: refetch the
            // baseline and *preserve* the user's currentText.
            if error.isApplyDiffConflict {
                await handleStrictConflict(via: client, request: request)
                return nil
            }
            status = .error(message: describe(error))
            return nil
        }
    }

    private func isBound(to request: SaveRequest) -> Bool {
        isBound(toVaultID: request.vaultID, noteID: request.noteID)
    }

    /// Refetch the snapshot, install it as the new baseline, and leave
    /// `currentText` alone. Sets `status = .conflict(serverText:)`. If
    /// the refetch itself fails, fall back to a plain `.error` so the
    /// user at least sees something actionable.
    private func handleStrictConflict(via client: LumiAPIClient, request: SaveRequest) async {
        do {
            let fresh = try await client.getNoteSnapshot(vaultID: request.vaultID, noteID: request.noteID)
            guard isBound(to: request) else { return }
            originalText = fresh.text
            vectorClock = fresh.vectorClock
            baseState = fresh.state
            path = fresh.path
            // Intentionally leave currentText untouched.
            status = .conflict(serverText: fresh.text)
        } catch {
            // `getNoteSnapshot` throws typed `LumiAPIError`.
            guard isBound(to: request) else { return }
            status = .error(message: describe(error))
        }
    }

    /// Discard in-memory edits, restoring the loaded baseline.
    public func discard() {
        currentText = originalText
        if case .error = status { status = .loaded }
        if case .conflict = status { status = .loaded }
    }

    /// Drop all editor state. Call when the open note changes or the
    /// session is signed out.
    public func reset() {
        noteID = nil
        vaultID = nil
        path = nil
        vectorClock = nil
        baseState = nil
        originalText = ""
        currentText = ""
        status = .idle
    }

    /// `true` when the editor is currently bound to the given (vault,
    /// noteID) pair. Used by the host to decide whether `load` is
    /// necessary or the existing state is already valid.
    public func isBound(toVaultID v: UUID, noteID n: String) -> Bool {
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
