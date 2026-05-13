import Foundation
import Observation
import LumiKit
import LumiUI

@Observable
@MainActor
final class AppState {
    var theme: LumiTheme = .defaultDark

    var selectedVaultID: UUID?
    var selectedNoteID: String?

    /// Notes scanned from the currently selected vault. Cached here so the
    /// detail view can resolve a selection by id without re-walking the disk.
    var notes: [Note] = []

    /// Active vault session — keeps security-scoped access alive while a vault
    /// is selected. Nil when no vault is open.
    var session: VaultSession?

    /// Editor state for the currently open note. Reused across notes; switching
    /// notes calls `load` to repopulate.
    let editor = EditorState()

    /// Server connection state. Empty `currentSession` means the app is
    /// running in local-only mode; later phases (vault discovery, note sync)
    /// gate themselves on this being populated.
    let authService: AuthService

    /// Server-vault discovery cache (E.1.1). Populated on sign-in via
    /// `remoteVaultsStore.refresh()`; cleared on sign-out.
    let remoteVaultsStore: RemoteVaultsStore

    /// Selection in the sidebar's "server" section. Independent of
    /// `selectedVaultID` (local) — selecting one clears the other so the
    /// detail panel doesn't conflict.
    var selectedRemoteVaultID: UUID?

    init() {
        let auth = AuthService()
        self.authService = auth
        self.remoteVaultsStore = RemoteVaultsStore(client: auth.apiClient)
    }

    /// Replace the active session, closing the previous one to release scope.
    func setSession(_ new: VaultSession?) {
        session?.close()
        session = new
    }
}
