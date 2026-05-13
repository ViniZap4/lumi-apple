import Foundation
import Observation
import SwiftUI
import LumiKit
import LumiUI

@Observable
@MainActor
final class AppState {
    var theme: LumiTheme = .defaultDark

    var selectedVaultID: UUID?
    /// Path (vault-relative) of the currently selected note. Stored as a
    /// string so it survives across selection changes without holding a
    /// reference into the lazy folder tree. `nil` means no note open.
    var selectedNoteID: String?

    /// Lazy file-system root for the active vault. Folders enumerate their
    /// children on demand (FolderNode.loadIfNeeded) so vault-open stays
    /// cheap even when the vault has millions of notes.
    var rootFolder: FolderNode?

    /// Three-column browser state — drives the parent / current / preview
    /// columns when no note is open. Created fresh each time the active
    /// vault changes (so the cursor/path stack reset cleanly).
    var browserState: TreeBrowserState?

    /// Currently selected note's lightweight handle. Set by tree row taps
    /// (or quick-switcher selection); read by the detail view to drive the
    /// editor load. Holding the entry here means the detail view doesn't
    /// have to scan the lazy tree to resolve a selection.
    var selectedEntry: NoteEntry?

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

    /// Persisted user preferences (vim nav, jj/jk mappings, etc.). Read by
    /// views that gate features on user opt-in.
    let preferences = LumiPreferences()

    /// Whether the Settings sheet is presented. Lives on AppState so the
    /// Cmd+, keyboard shortcut (defined on the App-level Scene) and the
    /// toolbar button share state without dueling `@State` containers.
    var showSettings: Bool = false

    /// Quick-switcher modal visibility. ⌘O opens a floating tree-over-note
    /// overlay so users can jump notes without leaving the current one.
    var showQuickSwitcher: Bool = false

    /// Column visibility for the navigation split. Defaults to the full
    /// 3-column layout; auto-collapses to detail-only when a note opens so
    /// the reading area takes the full window. The "Back to vault" toolbar
    /// button restores the 3-column state.
    var columnVisibility: NavigationSplitViewVisibility = .all

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
