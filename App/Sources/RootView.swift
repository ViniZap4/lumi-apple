import SwiftUI
import SwiftData
import LumiKit
import LumiUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VaultRecord.lastOpenedAt, order: .reverse) private var vaults: [VaultRecord]

    var body: some View {
        @Bindable var bound = appState
        NavigationSplitView {
            VaultSidebar(
                vaults: vaults,
                selectedVaultID: $bound.selectedVaultID,
                onAdd: addVault,
                onSelect: selectLocalVault
            )
            .navigationTitle("Vaults")
        } content: {
            if let vaultID = appState.selectedVaultID,
               let vault = vaults.first(where: { $0.id == vaultID }) {
                NoteListView(
                    vault: vault,
                    notes: appState.notes,
                    selectedNoteID: $bound.selectedNoteID,
                    onSelect: selectNote
                )
            } else if let remoteID = appState.selectedRemoteVaultID,
                      let remote = appState.remoteVaultsStore.vaults.first(where: { $0.id == remoteID }) {
                RemoteVaultDetailView(vault: remote)
            } else {
                EmptyVaultPanel(onAdd: addVault)
            }
        } detail: {
            if let noteID = appState.selectedNoteID,
               let note = appState.notes.first(where: { $0.id == noteID }),
               let session = appState.session {
                NoteDetailView(
                    note: note,
                    baseURL: session.resolve(note).deletingLastPathComponent(),
                    vaultRoot: session.rootURL
                )
            } else {
                NoteDetailEmpty()
            }
        }
        .background(theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ServerMenu()
            }
            ToolbarItem(placement: .primaryAction) {
                ThemeMenu(selection: $bound.theme)
            }
        }
        .task { await appState.authService.restore() }
        // When sign-in lands a session, fetch the vault list. On sign-out,
        // wipe everything so the next sign-in starts clean.
        .onChange(of: appState.authService.currentSession) { _, new in
            if new != nil {
                Task { await appState.remoteVaultsStore.refresh() }
            } else {
                appState.selectedRemoteVaultID = nil
                appState.remoteVaultsStore.clear()
            }
        }
    }

    private func selectLocalVault(_ record: VaultRecord) {
        // Clear any active server-vault selection so the detail panel isn't
        // dual-bound. This is a no-op when no server selection is active.
        appState.selectedRemoteVaultID = nil
        selectVault(record)
    }

    private func selectVault(_ record: VaultRecord) {
        appState.selectedNoteID = nil
        appState.editor.reset()

        guard let session = VaultSession.open(record: record) else {
            appState.setSession(nil)
            appState.notes = []
            appState.selectedVaultID = nil
            return
        }
        appState.setSession(session)
        appState.notes = session.scan()
        appState.selectedVaultID = record.id
        record.lastOpenedAt = Date()
    }

    private func selectNote(_ note: Note) {
        guard let session = appState.session else { return }
        if appState.editor.isDirty {
            appState.editor.save()
        }
        let url = session.resolve(note)
        appState.editor.load(noteID: note.id, at: url, vaultRoot: session.rootURL)
        appState.selectedNoteID = note.id
    }

    private func addVault(url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? Bookmark.encode(url: url) else { return }
        let name = url.lastPathComponent
        let record = VaultRecord(name: name, bookmarkData: bookmark)
        modelContext.insert(record)
        try? modelContext.save()
        selectVault(record)
    }
}
