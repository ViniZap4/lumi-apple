import Foundation
import Observation

#if canImport(YSwift)
/// The live session type of the open note.
public typealias OpenNoteSession = NoteSyncSession
#else
/// visionOS: no local CRDT; server notes use the REST 3-way path.
public typealias OpenNoteSession = UnavailableNoteSession

/// Placeholder so `openSession` keeps one type on every platform. Never
/// instantiated.
@MainActor
public final class UnavailableNoteSession {
    public var phase: EditorSnapshot.Phase { .closed }
    public var reconnectStatus: ReconnectStatus? { nil }
    public var peers: [PeerPresence] { [] }
    public var noteID: String { "" }
    public var hasPendingLocalChanges: Bool { false }
    public func destroy() {}
    private init() {}
}
#endif

/// Coordinates server-vault state for the UI. Holds the list of vaults the
/// signed-in user belongs to plus the members/roles of whichever vault the
/// user has selected. Network failures are surfaced as `lastError`; transient
/// loading state via `isLoading`.
///
/// The store doesn't subscribe to `AuthService`; the host calls `refresh()`
/// at the right moments (post-sign-in, manual refresh button) and `clear()`
/// on sign-out. Keeping the wiring imperative makes the lifecycle easy to
/// reason about.
@Observable
@MainActor
public final class RemoteVaultsStore {
    public private(set) var vaults: [RemoteVault] = []
    public private(set) var selectedVaultID: UUID?
    public private(set) var members: [RemoteMember] = []
    public private(set) var roles: [RemoteRole] = []
    public private(set) var invites: [VaultInvite] = []
    public private(set) var auditEntries: [AuditEntry] = []
    /// True once we've loaded *less* than a full page — paginated views use
    /// this to decide whether to render a "Load more" button.
    public private(set) var auditHasMore: Bool = false
    public private(set) var notes: [RemoteNote] = []
    public private(set) var notesHasMore: Bool = false
    /// The currently-open server note's CRDT snapshot (body text + base64
    /// state vector). Set by `loadOpenNote`; cleared by `closeOpenNote`.
    /// Slice 4d migrated the underlying transport from `GET .../content`
    /// to `GET .../snapshot` so the same round-trip seeds the editor *and*
    /// arms the clock for the eventual `applyDiff` save.
    public private(set) var openNoteSnapshot: RemoteNoteSnapshot?
    public private(set) var openNoteIsLoading: Bool = false
    /// Non-nil when the most recent `loadOpenNote` failed. Cleared on a
    /// successful subsequent load or on `closeOpenNote`.
    public private(set) var openNoteError: LumiAPIError?

    /// The live CRDT session of the open server note
    /// (CRDT-CLIENT-PROTOCOL §2): one replica per open note, kept for
    /// the whole time the note stays open — reconnects reuse it, refetches
    /// merge into it. Destroyed when the note closes or another opens.
    /// nil when no note is open or the platform has no local CRDT
    /// (visionOS → REST 3-way `/diff`, see `RemoteEditorState`).
    public private(set) var openSession: OpenNoteSession?

    /// "Reconnecting in Ns…" while the live socket waits out a backoff.
    public var reconnectStatus: ReconnectStatus? { openSession?.reconnectStatus }

    /// Peers on the open note (y-protocols awareness; excludes us).
    public var openNotePresence: [PeerPresence] { openSession?.peers ?? [] }

    public private(set) var isLoading: Bool = false
    public private(set) var lastError: LumiAPIError?

    /// The cached row for the currently-selected vault, if any. Derived so
    /// it stays consistent with `vaults` after a transfer-ownership or
    /// rename replaces the row in place.
    public var selectedVault: RemoteVault? {
        guard let selectedVaultID else { return nil }
        return vaults.first { $0.id == selectedVaultID }
    }

    /// The selected vault's owner as a member row (SPEC-V3 ownership).
    /// nil when no vault is selected, when the server predates
    /// `owner_user_id`, or when the owner isn't in the loaded member list.
    public var selectedVaultOwner: RemoteMember? {
        guard let ownerID = selectedVault?.ownerUserID else { return nil }
        return members.first { $0.userID == ownerID }
    }

    private let auditPageSize: Int = 50
    private let notesPageSize: Int = 100

    @ObservationIgnored private var client: LumiAPIClient

    /// CRDT session phase of the open note (CRDT-CLIENT-PROTOCOL §2.1),
    /// fed into the book sync status (SPEC-LIVROS §4.2).
    public var openNotePhase: EditorSnapshot.Phase { openSession?.phase ?? .closed }

    /// Builds the connector for a new session. Test seam; production
    /// dials the account's server (ws-ticket first, `?token=` fallback).
    @ObservationIgnored public var makeConnector: (LumiAPIClient) -> any SyncConnector = { WebSocketConnector(client: $0) }

    public init(client: LumiAPIClient) {
        self.client = client
    }

    /// The account client this store talks through. Books bound to
    /// different accounts swap the client; state is cleared on change so
    /// nothing from one account leaks into another.
    public var apiClient: LumiAPIClient { client }

    public func setClient(_ newClient: LumiAPIClient) {
        guard newClient !== client else { return }
        clear()
        client = newClient
    }

    /// Merge a feed catch-up into the visible note list (only when that
    /// vault is the selected one). `nil` = server lacks `/changes`, refetch.
    public func applyCatchUp(_ outcome: CatchUpOutcome?, vaultID: UUID) async {
        guard selectedVaultID == vaultID else { return }
        guard let outcome else {
            if let resp = try? await client.listNotes(vaultID: vaultID, limit: notesPageSize, offset: 0) {
                notes = resp.notes
                notesHasMore = resp.notes.count >= notesPageSize
            }
            return
        }
        notes = CatchUp.apply(outcome, to: notes)
    }

    /// Pull the vault list from the server. Replaces the current `vaults`
    /// snapshot on success.
    public func refresh() async {
        isLoading = true
        lastError = nil
        do {
            vaults = try await client.listVaults()
        } catch {
            lastError = error
        }
        isLoading = false
    }

    /// Select a vault by id and load its members + roles + invites + audit
    /// entries. Passing `nil` clears the selection and the cached arrays.
    public func selectVault(_ id: UUID?) async {
        guard let id else {
            selectedVaultID = nil
            members = []
            roles = []
            invites = []
            auditEntries = []
            auditHasMore = false
            notes = []
            notesHasMore = false
            openNoteSnapshot = nil
            openNoteError = nil
            destroyOpenSession()
            return
        }
        selectedVaultID = id
        isLoading = true
        lastError = nil
        members = []
        roles = []
        invites = []
        auditEntries = []
        auditHasMore = false
        notes = []
        notesHasMore = false
        openNoteSnapshot = nil
        openNoteError = nil
        destroyOpenSession()
        // Sequential rather than `async let` — Swift 6 typed throws don't
        // propagate through `async let` bindings, and serializing a few short
        // requests is fine for the UI flow.
        do {
            members = try await client.listMembers(vaultID: id)
            roles = try await client.listRoles(vaultID: id)
            // Invite listing requires the `members.invite` capability; audit
            // listing requires `audit.read`. For members without either, the
            // server returns 403. Treat as "nothing visible to me" rather
            // than poisoning lastError.
            do {
                invites = try await client.listInvites(vaultID: id)
            } catch let error where isForbidden(error) {
                invites = []
                _ = error
            }
            do {
                let resp = try await client.listAuditEntries(vaultID: id, limit: auditPageSize, offset: 0)
                auditEntries = resp.entries
                auditHasMore = resp.entries.count >= auditPageSize
            } catch let error where isForbidden(error) {
                auditEntries = []
                auditHasMore = false
                _ = error
            }
            do {
                let resp = try await client.listNotes(vaultID: id, limit: notesPageSize, offset: 0)
                notes = resp.notes
                notesHasMore = resp.notes.count >= notesPageSize
            } catch let error where isForbidden(error) {
                notes = []
                notesHasMore = false
                _ = error
            }
        } catch {
            lastError = error
        }
        isLoading = false
    }

    /// Fetch the REST snapshot of a server note: the read-only preview
    /// shown while the session connects (§2.2.3) and the source of the
    /// "Load file contents" body. Never builds or seeds a replica. When a
    /// live session for the same note exists, its full `state` is merged
    /// into that replica instead (pull-to-refresh, §5 / V8).
    public func loadOpenNote(vaultID: UUID, noteID: String) async {
        openNoteIsLoading = true
        openNoteError = nil
        do {
            let snapshot = try await client.getNoteSnapshot(vaultID: vaultID, noteID: noteID)
            openNoteSnapshot = snapshot
            #if canImport(YSwift)
            if let session = openSession, session.vaultID == vaultID, session.noteID == noteID,
               let state = snapshot.stateData {
                session.mergeSnapshotState(state)
            }
            #endif
        } catch {
            openNoteSnapshot = nil
            openNoteError = error
        }
        openNoteIsLoading = false
    }

    /// Replace the cached snapshot in place.
    public func setOpenNoteSnapshot(_ snapshot: RemoteNoteSnapshot) {
        openNoteSnapshot = snapshot
    }

    /// Fold the result of a successful REST save into the caches. Safe to
    /// call after the note was closed.
    public func recordSavedSnapshot(_ snapshot: RemoteNoteSnapshot, vaultID: UUID) {
        guard selectedVaultID == vaultID else { return }
        if openNoteSnapshot?.id == snapshot.id {
            openNoteSnapshot = snapshot
        }
        bumpNoteUpdatedAt(noteID: snapshot.id, path: snapshot.path)
    }

    /// Clear the currently-open server note and destroy its session.
    public func closeOpenNote() {
        destroyOpenSession()
        openNoteSnapshot = nil
        openNoteError = nil
        openNoteIsLoading = false
    }

    // MARK: - Live session

    /// Open (or keep) the live session for a note. Switching notes
    /// destroys the previous session first — retargeting a replica is
    /// forbidden (§2.2.1, V16). No-op on platforms without a CRDT.
    public func openLiveSession(vaultID: UUID, noteID: String, user: AwarenessUser?) {
        #if canImport(YSwift)
        if let s = openSession, s.vaultID == vaultID, s.noteID == noteID, !s.isDestroyed {
            if s.termination == nil { s.start() }
            return
        }
        destroyOpenSession()
        let session = NoteSyncSession(vaultID: vaultID, noteID: noteID, connector: makeConnector(client), user: user)
        openSession = session
        session.start()
        #endif
    }

    /// Tear down the open note's session (if any).
    public func destroyOpenSession() {
        openSession?.destroy()
        openSession = nil
    }

    /// Bump the `updatedAt` of a cached note row to now. Used after a
    /// successful `applyDiff` — the server's response doesn't carry a
    /// full noteDTO (only the snapshot shape), so we synthesize the bump
    /// locally. Path is also accepted in case it ever changes (it
    /// shouldn't for body-only diffs, but the snapshot includes it for
    /// completeness). No-op when no row matches.
    public func bumpNoteUpdatedAt(noteID: String, path: String) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let existing = notes[idx]
        notes[idx] = RemoteNote(
            id: existing.id,
            vaultID: existing.vaultID,
            path: path,
            title: existing.title,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
    }

    /// Merge an updated note row (e.g. the response of a successful PATCH)
    /// into the cached `notes` list. Replaces the existing row by id if
    /// present; no-op otherwise (the row may have been paginated off).
    /// Used by the editor flow after `LumiAPIClient.updateNote` returns so
    /// the list reflects the new `updated_at` / title without a full refetch.
    public func updateNoteRowFromPATCH(_ updated: RemoteNote) {
        if let idx = notes.firstIndex(where: { $0.id == updated.id }) {
            notes[idx] = updated
        }
    }

    /// Create a new note in the currently-selected vault and prepend it to
    /// the cached `notes` list. Returns the new row on success so the host
    /// can navigate to it (e.g. auto-open in edit mode).
    @discardableResult
    public func createNote(title: String, body: String = "", tags: [String] = []) async throws(LumiAPIError) -> RemoteNote {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        let created = try await client.createNote(
            vaultID: id,
            title: title,
            body: body,
            tags: tags
        )
        if !notes.contains(where: { $0.id == created.id }) {
            notes.insert(created, at: 0)
        }
        return created
    }

    /// Delete a note in the currently-selected vault and drop it from the
    /// cache. If the deleted note was the currently-open one, clear the
    /// open-note state too so the caller's UI doesn't get stranded.
    public func deleteNote(noteID: String) async throws(LumiAPIError) {
        guard let vaultID = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        try await client.deleteNote(vaultID: vaultID, noteID: noteID)
        notes.removeAll { $0.id == noteID }
        if openNoteSnapshot?.id == noteID || openSession?.noteID == noteID {
            closeOpenNote()
        }
    }

    /// Append the next page of notes. Caller-driven via a "Load more" button
    /// on long vaults.
    public func loadMoreNotes() async {
        guard let id = selectedVaultID, notesHasMore else { return }
        do {
            let resp = try await client.listNotes(
                vaultID: id,
                limit: notesPageSize,
                offset: notes.count
            )
            notes.append(contentsOf: resp.notes)
            notesHasMore = resp.notes.count >= notesPageSize
        } catch let error where isForbidden(error) {
            notesHasMore = false
        } catch {
            lastError = error
            notesHasMore = false
        }
    }

    /// Append the next page of audit entries. Caller-driven — typically a
    /// "Load more" button hooked up to this method.
    public func loadMoreAudit() async {
        guard let id = selectedVaultID, auditHasMore else { return }
        do {
            let resp = try await client.listAuditEntries(
                vaultID: id,
                limit: auditPageSize,
                offset: auditEntries.count
            )
            auditEntries.append(contentsOf: resp.entries)
            auditHasMore = resp.entries.count >= auditPageSize
        } catch let error where isForbidden(error) {
            auditHasMore = false
        } catch {
            lastError = error
            auditHasMore = false
        }
    }

    /// Refresh just the invites list for the selected vault. Used after
    /// creating or revoking an invite to keep the displayed list current.
    public func refreshInvites() async {
        guard let id = selectedVaultID else { return }
        do {
            invites = try await client.listInvites(vaultID: id)
        } catch let error where isForbidden(error) {
            invites = []
        } catch {
            lastError = error
        }
    }

    /// Create an invite for the selected vault and prepend it to `invites`.
    /// Returns the full response (with the optional shareable `url`) so the
    /// UI can show / copy the link immediately.
    @discardableResult
    public func createInvite(
        roleID: UUID,
        maxUses: Int,
        expiresAt: Date,
        emailHint: String?
    ) async throws(LumiAPIError) -> CreatedInvite {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        let created = try await client.createInvite(
            vaultID: id,
            roleID: roleID,
            maxUses: maxUses,
            expiresAt: expiresAt,
            emailHint: emailHint
        )
        // Refresh the canonical list so newly-created rows include
        // server-assigned timestamps (created_at, vault_id, inviter_user_id).
        await refreshInvites()
        return created
    }

    /// Revoke an invite by token. Drops it from the local cache immediately
    /// on success so the UI updates without waiting for a list refresh.
    public func revokeInvite(token: String) async throws(LumiAPIError) {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        try await client.revokeInvite(vaultID: id, token: token)
        await refreshInvites()
    }

    /// Create a new vault server-side and prepend it to the local cache.
    /// Caller becomes Admin. Returns the created vault so the UI can select
    /// it without waiting for a full list refresh.
    @discardableResult
    public func createVault(name: String, slug: String? = nil) async throws(LumiAPIError) -> RemoteVault {
        let vault = try await client.createVault(name: name, slug: slug)
        // Server returns the canonical row; insert at the top so newest is
        // most visible. Avoid dupes if a refresh happens concurrently.
        if !vaults.contains(where: { $0.id == vault.id }) {
            vaults.insert(vault, at: 0)
        }
        return vault
    }

    /// Rename the given vault. Updates the cached row and (if it's the
    /// currently selected vault) keeps `selectedVaultID` intact.
    @discardableResult
    public func renameVault(vaultID: UUID, name: String) async throws(LumiAPIError) -> RemoteVault {
        let updated = try await client.renameVault(vaultID: vaultID, name: name)
        if let idx = vaults.firstIndex(where: { $0.id == vaultID }) {
            vaults[idx] = updated
        }
        return updated
    }

    /// Transfer ownership of the currently-selected vault to another member
    /// (owner-only server-side). Replaces the cached vault row with the
    /// returned DTO so `selectedVaultOwner` reflects the new owner
    /// immediately. Errors rethrow typed — an `owner_protected` /
    /// validation failure carries the server's readable message in the
    /// error's `detail` slot.
    @discardableResult
    public func transferOwnership(newOwnerUserID: UUID) async throws(LumiAPIError) -> RemoteVault {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        let updated = try await client.transferOwnership(vaultID: id, newOwnerUserID: newOwnerUserID)
        if let idx = vaults.firstIndex(where: { $0.id == id }) {
            vaults[idx] = updated
        }
        return updated
    }

    /// Fork the currently-selected vault to another user on this server
    /// (SPEC-V3 share-a-copy; capability `vault.export`). Returns the
    /// fork's vault DTO — owned by the recipient, so it is deliberately
    /// NOT inserted into our `vaults` cache (we're not a member of it).
    /// Unknown recipients rethrow with `isRecipientNotFound == true`.
    @discardableResult
    public func sendCopy(recipientUsername: String) async throws(LumiAPIError) -> RemoteVault {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        return try await client.copyVault(vaultID: id, recipientUsername: recipientUsername)
    }

    /// Delete the given vault server-side. Drops it from the cache; clears
    /// the active selection if it was that vault.
    public func deleteVault(vaultID: UUID) async throws(LumiAPIError) {
        try await client.deleteVault(vaultID: vaultID)
        vaults.removeAll { $0.id == vaultID }
        if selectedVaultID == vaultID {
            selectedVaultID = nil
            members = []
            roles = []
            invites = []
            auditEntries = []
            auditHasMore = false
            notes = []
            notesHasMore = false
            openNoteSnapshot = nil
            destroyOpenSession()
        }
    }

    /// Wipe all state. Call on sign-out so the next sign-in starts clean.
    public func clear() {
        destroyOpenSession()
        vaults = []
        selectedVaultID = nil
        members = []
        roles = []
        invites = []
        auditEntries = []
        auditHasMore = false
        notes = []
        notesHasMore = false
        openNoteSnapshot = nil
        openNoteError = nil
        openNoteIsLoading = false
        lastError = nil
        isLoading = false
    }
}

private func isForbidden(_ error: LumiAPIError) -> Bool {
    if case let .server(status, _, _) = error, status == 403 { return true }
    return false
}
