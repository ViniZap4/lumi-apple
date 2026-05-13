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

    /// Select a vault by id and load its members + roles. Passing `nil` clears
    /// the selection and the cached member/role arrays.
    public func selectVault(_ id: UUID?) async {
        guard let id else {
            selectedVaultID = nil
            members = []
            roles = []
            return
        }
        selectedVaultID = id
        isLoading = true
        lastError = nil
        members = []
        roles = []
        // Sequential rather than `async let` — Swift 6 typed throws don't
        // propagate through `async let` bindings, and serializing two short
        // requests is fine for the UI flow.
        do {
            members = try await client.listMembers(vaultID: id)
            roles = try await client.listRoles(vaultID: id)
        } catch {
            lastError = error
        }
        isLoading = false
    }

    /// Wipe all state. Call on sign-out so the next sign-in starts clean.
    public func clear() {
        vaults = []
        selectedVaultID = nil
        members = []
        roles = []
        lastError = nil
        isLoading = false
    }
}
