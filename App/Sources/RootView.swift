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
        VStack(spacing: 0) {
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
            if appState.preferences.showKeybindsBar {
                KeybindsBar(context: keybindsContext)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.preferences.showKeybindsBar)
        .animation(.easeInOut(duration: 0.12), value: keybindsContext)
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
            // Read / edit toggle for the active note. Lives in the global
            // toolbar so all chrome is centralized at the top of the window;
            // hidden when no note is open. Cmd+E flips it from anywhere.
            if appState.selectedEntry != nil {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        Picker("Mode", selection: $bound.editorMode) {
                            Image(systemName: "doc.text").tag(NoteDisplayMode.view)
                            Image(systemName: "square.and.pencil").tag(NoteDisplayMode.edit)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                        .help("Read / edit mode (⌘E)")
                        if appState.editorMode == .edit {
                            ToolbarVimModeBadge(mode: appState.liveVimMode)
                        }
                    }
                }
            }
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
        if let entry = appState.selectedEntry, let session = appState.session {
            NoteDetailView(
                entry: entry,
                baseURL: entry.url.deletingLastPathComponent(),
                vaultRoot: session.rootURL
            )
        } else if let vaultID = appState.selectedVaultID,
                  let vault = vaults.first(where: { $0.id == vaultID }),
                  let browser = appState.browserState {
            TreeBrowserView(
                state: browser,
                vaultName: vault.name,
                onOpen: selectNote
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
            appState.browserState = nil
            appState.selectedVaultID = nil
            return
        }
        appState.setSession(session)
        let root = session.rootFolder()
        root.loadIfNeeded()
        appState.rootFolder = root
        appState.browserState = TreeBrowserState(root: root)
        appState.selectedVaultID = record.id
        record.lastOpenedAt = Date()
    }

    /// Tell the bottom keybinds bar which set of hints to show based on
    /// what's currently in the content area.
    private var keybindsContext: KeybindsBar.Context {
        if appState.selectedEntry != nil {
            return appState.editorMode == .edit ? .noteEdit : .noteView
        }
        return .tree
    }

    private func selectNote(_ entry: NoteEntry) {
        guard let session = appState.session else { return }
        if appState.editor.isDirty {
            appState.editor.save()
        }
        appState.editor.load(noteID: entry.relativePath, at: entry.url, vaultRoot: session.rootURL)
        appState.selectedNoteID = entry.relativePath
        appState.selectedEntry = entry
        // Always land in view mode when opening a new note — users tap
        // through the tree primarily to read; ⌘E (or the toolbar toggle)
        // jumps into edit when they actually want to write.
        appState.editorMode = .view
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

/// Compact vim mode label for the global toolbar — same color logic as the
/// in-pane badge but smaller padding so it doesn't bloat the title bar.
private struct ToolbarVimModeBadge: View {
    let mode: VimMode
    @Environment(\.theme) private var theme

    var body: some View {
        let (label, color) = parts
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
            )
            .foregroundStyle(theme.background)
            .help("Vim mode")
    }

    private var parts: (String, Color) {
        switch mode {
        case .normal: return ("NORMAL", theme.accent)
        case .insert: return ("INSERT", theme.primary)
        case .visual: return (mode.label, theme.warning)
        case let .commandLine(prefix, _): return (String(prefix), theme.accent)
        }
    }
}
