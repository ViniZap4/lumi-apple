import SwiftUI
import SwiftData
import LumiKit
import LumiUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var bound = appState
        // Two-column layout (sidebar | content). The right pane swaps
        // between the tree-of-notes and the full-width note view based on
        // whether a note is open. No third "detail" column, so notes don't
        // sit beside the list — they replace it, matching the web / TUI
        // single-pane reading experience.
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $bound.columnVisibility) {
                VaultSidebar(onAdd: addVault)
                    .navigationTitle("Books")
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
            // Note chrome — read/edit picker, vim mode pill, status, save.
            // All collected in the .principal slot so the entire top bar
            // is the home for note controls; the in-pane status row is
            // gone.
            if appState.selectedEntry != nil {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
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
                        ToolbarStatusLabel(editor: appState.editor)
                        Button {
                            appState.editor.save()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!appState.editor.isDirty)
                        .help("Save (⌘S)")
                    }
                }
            }
            // Reading layout (font scale + max width). Only meaningful when
            // a note is open in read mode — hidden otherwise to keep the
            // toolbar quiet.
            if appState.selectedEntry != nil, appState.editorMode == .view {
                ToolbarItem(placement: .primaryAction) {
                    ReadingLayoutMenu(preferences: appState.preferences)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SyncStatusIndicator()
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
        .sheet(isPresented: $bound.showAddServer) {
            SignInSheet()
                .environment(appState)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $bound.showManageBooks) {
            ManageBooksSheet()
                .environment(appState)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $bound.showNewBook) {
            CreateVaultSheet(onAddFolder: addVault)
                .environment(appState)
                .environment(\.theme, theme)
        }
        .task { await appState.bootstrapBooks(legacyRecords: legacySnapshots()) }
        .onChange(of: scenePhase) { _, phase in
            // Pick up books.yaml edits made by the TUI while we were away.
            if phase == .active { appState.books.reload() }
        }
        .onChange(of: appState.remoteVaultsStore.openNotePhase) { _, _ in appState.publishEditorPhase() }
        .onChange(of: appState.remoteEditor.isDirty) { _, _ in appState.publishEditorPhase() }
        .onChange(of: appState.selectedRemoteNoteID) { _, _ in appState.publishEditorPhase() }
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
                  let book = appState.books.book(vaultID) {
            if let browser = appState.browserState {
                TreeBrowserView(
                    state: browser,
                    vaultName: book.name,
                    onOpen: selectNote
                )
            } else {
                BookUnavailableView(book: book)
            }
        } else if let remoteID = appState.selectedRemoteVaultID,
                  let remote = appState.remoteVaultsStore.vaults.first(where: { $0.id == remoteID }) {
            // Server-vault selected. If a note is also selected (via row
            // tap in the detail view), route to the read-only note viewer;
            // otherwise show the vault-management dashboard.
            if let remoteNoteID = appState.selectedRemoteNoteID,
               let row = appState.remoteVaultsStore.notes.first(where: { $0.id == remoteNoteID }) {
                RemoteNoteDetailView(vault: remote, listRow: row)
            } else {
                RemoteVaultDetailView(vault: remote)
            }
        } else if appState.selectedRemoteVaultID != nil, let book = appState.openBook {
            BookUnavailableView(book: book)
        } else {
            EmptyVaultPanel(
                vaults: BookSwitcherOrder.flattened(appState.books.books),
                onAdd: addVault,
                onSelect: { book in Task { await appState.selectBook(book) } },
                onAddServer: { appState.showAddServer = true }
            )
        }
    }

    /// VaultRecord rows for the one-shot books.yaml import.
    private func legacySnapshots() -> [LegacyVaultSnapshot] {
        let records = (try? modelContext.fetch(FetchDescriptor<VaultRecord>())) ?? []
        return records.map { record in
            let path = record.bookmarkData.flatMap { try? Bookmark.decode($0) }?.url.path
            return LegacyVaultSnapshot(record: record, resolvedPath: path)
        }
    }

    private func closeNote() {
        if appState.editor.isDirty {
            appState.editor.save()
        }
        appState.selectedEntry = nil
        appState.selectedNoteID = nil
    }

    /// Tell the bottom keybinds bar which set of hints to show based on
    /// what's currently in the content area. The four contexts mirror
    /// the four content branches in `mainContent`:
    ///   - note open → `.noteView` / `.noteEdit`
    ///   - vault picked + browsing tree → `.tree`
    ///   - landing pane (no vault selected) → `.home`
    private var keybindsContext: KeybindsBar.Context {
        if appState.selectedEntry != nil {
            return appState.editorMode == .edit ? .noteEdit : .noteView
        }
        if appState.selectedVaultID == nil && appState.selectedRemoteVaultID == nil {
            return .home
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
        guard let book = appState.books.addLocal(name: url.lastPathComponent, path: url.path, bookmark: bookmark) else { return }
        Task { await appState.selectBook(book) }
    }
}

/// Compact vim mode label for the global toolbar — same color logic as the
/// in-pane badge but smaller padding so it doesn't bloat the title bar.
/// Fully rounded (Capsule) for a pill look.
private struct ToolbarVimModeBadge: View {
    let mode: VimMode
    @Environment(\.theme) private var theme

    var body: some View {
        let (label, color) = parts
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
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

/// Read-mode appearance controls: font scale and column width. Lives in
/// the toolbar so users can tweak the layout without diving into Settings.
/// Bindings flow through `LumiPreferences` so the values persist.
private struct ReadingLayoutMenu: View {
    @Bindable var preferences: LumiPreferences

    var body: some View {
        Menu {
            // Each axis is its own labeled picker — checkmark indicates
            // the active option, so the user gets a state-aware menu
            // instead of a flat button list.
            Picker("Text size", selection: $preferences.readingScale) {
                Text("Small").tag(0.9)
                Text("Default").tag(1.0)
                Text("Large").tag(1.15)
                Text("Extra large").tag(1.3)
            }
            Picker("Width", selection: $preferences.readingWidth) {
                Text("Narrow").tag(640.0)
                Text("Default").tag(760.0)
                Text("Wide").tag(900.0)
                Text("Full").tag(1100.0)
            }
            Picker("Font", selection: $preferences.readingFontFamily) {
                ForEach(LumiPreferences.ReadingFontFamily.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            Divider()
            Toggle("Animate transitions", isOn: $preferences.contentAnimations)
            Toggle("j / k scrolls in read mode", isOn: $preferences.jkScrollInView)
        } label: {
            Image(systemName: "textformat.size")
        }
        .menuStyle(.button)
        .help("Reading layout (text size, width, font)")
    }
}

/// Inline editor-status indicator for the toolbar (modified / saved /
/// conflict / error). Smaller than the in-pane version since space is
/// tight up here; uses the same icon + color vocabulary.
private struct ToolbarStatusLabel: View {
    let editor: EditorState
    @Environment(\.theme) private var theme

    var body: some View {
        let (icon, label, color) = parts
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .imageScale(.small)
            }
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.overlayBackground))
    }

    private var parts: (icon: String?, label: String, color: Color) {
        if editor.isDirty {
            return ("circle.fill", "modified", theme.warning)
        }
        switch editor.status {
        case .saved: return ("checkmark.circle", "saved", theme.info)
        case .saving: return ("arrow.up.doc", "saving…", theme.textDim)
        case .conflict: return ("exclamationmark.triangle", "conflict", theme.error)
        case .error: return ("xmark.circle", "error", theme.error)
        case .idle, .loaded: return (nil, "ready", theme.textDim)
        }
    }
}
