import Foundation
import Observation

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
    /// The currently-open server note's full content (body, etc.). Set by
    /// `loadOpenNote`; cleared by `closeOpenNote`. Slice 2 read-only — the
    /// editor wiring lands in slice 3.
    public private(set) var openNoteContent: RemoteNoteContent?
    public private(set) var openNoteIsLoading: Bool = false
    /// Non-nil when the most recent `loadOpenNote` failed. Cleared on a
    /// successful subsequent load or on `closeOpenNote`.
    public private(set) var openNoteError: LumiAPIError?
    public private(set) var isLoading: Bool = false
    public private(set) var lastError: LumiAPIError?

    private let auditPageSize: Int = 50
    private let notesPageSize: Int = 100

    private let client: LumiAPIClient

    public init(client: LumiAPIClient) {
        self.client = client
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
            openNoteContent = nil
            openNoteError = nil
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
        openNoteContent = nil
        openNoteError = nil
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

    /// Load the full content for a server note. Sets `openNoteContent` on
    /// success; surfaces failures via `openNoteError`. Idempotent — calling
    /// twice with the same arguments simply re-fetches.
    public func loadOpenNote(vaultID: UUID, noteID: String) async {
        openNoteIsLoading = true
        openNoteError = nil
        do {
            let content = try await client.getNoteContent(vaultID: vaultID, noteID: noteID)
            openNoteContent = content
        } catch {
            openNoteContent = nil
            openNoteError = error
        }
        openNoteIsLoading = false
    }

    /// Clear the currently-open server note. UI calls this when the user
    /// navigates back to the vault detail view.
    public func closeOpenNote() {
        openNoteContent = nil
        openNoteError = nil
        openNoteIsLoading = false
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
        if openNoteContent?.id == noteID {
            openNoteContent = nil
            openNoteError = nil
            openNoteIsLoading = false
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
        }
    }

    /// Wipe all state. Call on sign-out so the next sign-in starts clean.
    public func clear() {
        vaults = []
        selectedVaultID = nil
        members = []
        roles = []
        invites = []
        auditEntries = []
        auditHasMore = false
        notes = []
        notesHasMore = false
        openNoteContent = nil
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
