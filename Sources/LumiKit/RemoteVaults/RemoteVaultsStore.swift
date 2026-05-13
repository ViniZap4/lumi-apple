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
    public private(set) var isLoading: Bool = false
    public private(set) var lastError: LumiAPIError?

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

    /// Select a vault by id and load its members + roles + invites. Passing
    /// `nil` clears the selection and the cached arrays.
    public func selectVault(_ id: UUID?) async {
        guard let id else {
            selectedVaultID = nil
            members = []
            roles = []
            invites = []
            return
        }
        selectedVaultID = id
        isLoading = true
        lastError = nil
        members = []
        roles = []
        invites = []
        // Sequential rather than `async let` — Swift 6 typed throws don't
        // propagate through `async let` bindings, and serializing a few short
        // requests is fine for the UI flow.
        do {
            members = try await client.listMembers(vaultID: id)
            roles = try await client.listRoles(vaultID: id)
            // Invite listing requires the `members.invite` capability; for
            // members without it the server returns 403. Treat that as
            // "no invites visible to me" rather than poisoning lastError.
            do {
                invites = try await client.listInvites(vaultID: id)
            } catch let error where isForbidden(error) {
                invites = []
                _ = error // explicit ignore
            }
        } catch {
            lastError = error
        }
        isLoading = false
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

    /// Wipe all state. Call on sign-out so the next sign-in starts clean.
    public func clear() {
        vaults = []
        selectedVaultID = nil
        members = []
        roles = []
        invites = []
        lastError = nil
        isLoading = false
    }
}

private func isForbidden(_ error: LumiAPIError) -> Bool {
    if case let .server(status, _, _) = error, status == 403 { return true }
    return false
}
