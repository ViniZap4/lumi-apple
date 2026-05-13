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
        NavigationSplitView(columnVisibility: $bound.columnVisibility) {
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
                    vaultRoot: appState.session?.rootURL,
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
            if let notePath = appState.selectedNoteID,
               // Selection uses note.path (unique per file), not note.id
               // (title slug, may collide). Match by path here so the
               // detail view picks the *clicked* note, not whichever happens
               // to slug-collide first.
               let note = appState.notes.first(where: { $0.path == notePath }),
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
            // "Back to navigation" appears only when we've collapsed away
            // from the 3-column layout (i.e. a note is open full-screen).
            #if os(macOS)
            if appState.columnVisibility == .detailOnly {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appState.columnVisibility = .all
                    } label: {
                        Label("Back to vault", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.showQuickSwitcher = true
                } label: {
                    Label("Quick switcher", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(appState.notes.isEmpty)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                ServerMenu()
            }
            ToolbarItem(placement: .primaryAction) {
                ThemeMenu(selection: $bound.theme)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $bound.showQuickSwitcher) {
            QuickSwitcherSheet(
                notes: appState.notes,
                onSelect: { note in
                    appState.showQuickSwitcher = false
                    selectNote(note)
                }
            )
            .environment(appState)
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $bound.showSettings) {
            SettingsSheet()
                .environment(appState)
                .environment(\.theme, theme)
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
        // Track the *path*, not the id — see RootView.detail lookup for why.
        appState.selectedNoteID = note.path
        // Yazi-style focus: opening a note collapses the navigation columns
        // so the read/edit pane fills the window. The "Back to vault"
        // toolbar entry or `⎋` restores the 3-column layout.
        #if os(macOS)
        appState.columnVisibility = .detailOnly
        #endif
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
