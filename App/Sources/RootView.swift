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
        // Two-column layout (sidebar | content). The right pane swaps
        // between the tree-of-notes and the full-width note view based on
        // whether a note is open. No third "detail" column, so notes don't
        // sit beside the list — they replace it, matching the web / TUI
        // single-pane reading experience.
        NavigationSplitView(columnVisibility: $bound.columnVisibility) {
            VaultSidebar(
                vaults: vaults,
                selectedVaultID: $bound.selectedVaultID,
                onAdd: addVault,
                onSelect: selectLocalVault
            )
            .navigationTitle("Vaults")
        } detail: {
            mainContent
        }
        .background(theme.background)
        .toolbar {
            #if os(macOS)
            if appState.selectedEntry != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        closeNote()
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
                .disabled(appState.rootFolder == nil)
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
                rootFolder: appState.rootFolder,
                onSelect: { entry in
                    appState.showQuickSwitcher = false
                    selectNote(entry)
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
        .onChange(of: appState.authService.currentSession) { _, new in
            if new != nil {
                Task { await appState.remoteVaultsStore.refresh() }
            } else {
                appState.selectedRemoteVaultID = nil
                appState.remoteVaultsStore.clear()
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        @Bindable var bound = appState
        if let entry = appState.selectedEntry, let session = appState.session {
            NoteDetailView(
                entry: entry,
                baseURL: entry.url.deletingLastPathComponent(),
                vaultRoot: session.rootURL
            )
        } else if let vaultID = appState.selectedVaultID,
                  let vault = vaults.first(where: { $0.id == vaultID }),
                  let root = appState.rootFolder {
            NoteListView(
                vault: vault,
                rootFolder: root,
                selectedNoteID: $bound.selectedNoteID,
                onSelect: selectNote
            )
        } else if let remoteID = appState.selectedRemoteVaultID,
                  let remote = appState.remoteVaultsStore.vaults.first(where: { $0.id == remoteID }) {
            RemoteVaultDetailView(vault: remote)
        } else {
            EmptyVaultPanel(onAdd: addVault)
        }
    }

    private func closeNote() {
        if appState.editor.isDirty {
            appState.editor.save()
        }
        appState.selectedEntry = nil
        appState.selectedNoteID = nil
    }

    private func selectLocalVault(_ record: VaultRecord) {
        // Clear any active server-vault selection so the detail panel isn't
        // dual-bound. This is a no-op when no server selection is active.
        appState.selectedRemoteVaultID = nil
        selectVault(record)
    }

    private func selectVault(_ record: VaultRecord) {
        appState.selectedNoteID = nil
        appState.selectedEntry = nil
        appState.editor.reset()

        guard let session = VaultSession.open(record: record) else {
            appState.setSession(nil)
            appState.rootFolder = nil
            appState.selectedVaultID = nil
            return
        }
        appState.setSession(session)
        let root = session.rootFolder()
        // Load the immediate children synchronously so the tree shows
        // something the moment the user picks a vault. Subfolders stay
        // unloaded until expanded — the vault-open cost is one syscall,
        // independent of vault size.
        root.loadIfNeeded()
        appState.rootFolder = root
        appState.selectedVaultID = record.id
        record.lastOpenedAt = Date()
    }

    private func selectNote(_ entry: NoteEntry) {
        guard let session = appState.session else { return }
        if appState.editor.isDirty {
            appState.editor.save()
        }
        appState.editor.load(noteID: entry.relativePath, at: entry.url, vaultRoot: session.rootURL)
        appState.selectedNoteID = entry.relativePath
        appState.selectedEntry = entry
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
