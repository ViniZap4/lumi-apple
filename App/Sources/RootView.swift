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
                onSelect: selectVault
            )
            .navigationTitle("Vaults")
        } content: {
            if let vaultID = appState.selectedVaultID,
               let vault = vaults.first(where: { $0.id == vaultID }) {
                NoteListView(
                    vault: vault,
                    notes: appState.notes,
                    selectedNoteID: $bound.selectedNoteID
                )
            } else {
                EmptyVaultPanel(onAdd: addVault)
            }
        } detail: {
            if let noteID = appState.selectedNoteID,
               let note = appState.notes.first(where: { $0.id == noteID }) {
                NoteDetailView(note: note, baseURL: appState.activeVaultURL)
            } else {
                NoteDetailEmpty()
            }
        }
        .background(theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ThemeMenu(selection: $bound.theme)
            }
        }
    }

    private func selectVault(_ record: VaultRecord) {
        appState.selectedVaultID = record.id
        appState.selectedNoteID = nil
        if let loaded = VaultLoader.load(record: record) {
            appState.notes = loaded.notes
            appState.activeVaultURL = loaded.vaultURL
            record.lastOpenedAt = Date()
        } else {
            appState.notes = []
            appState.activeVaultURL = nil
        }
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
