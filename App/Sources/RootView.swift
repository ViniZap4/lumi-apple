import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LumiKit
import LumiUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var bound = appState
        // Sidebar is optional (⌘\, hidden by default). The main area swaps
        // between empty state, explorer, reader and editor; a top line and
        // a status line frame it like a modal editor — no toolbar pills.
        NavigationSplitView(columnVisibility: $bound.columnVisibility) {
            VaultSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
                .navigationTitle("Books")
        } detail: {
            ShellMain()
        }
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .background(theme.background)
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
        .sheet(isPresented: $bound.showBookSettings) {
            BookSettingsSheet()
                .environment(appState)
                .environment(\.theme, theme)
        }
        .fileImporter(
            isPresented: $bound.showLinkFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first { addVault(url: url) }
        }
        .task { await appState.bootstrapBooks(legacyRecords: legacySnapshots()) }
        .onChange(of: scenePhase) { _, phase in
            // Pick up books.yaml edits made by the TUI while we were away.
            if phase == .active { appState.books.reload() }
        }
        .onChange(of: appState.preferences.ctrlHJKLPanes) { _, on in
            appState.activeEditor?.paneKeys.ctrlHJKL = on
        }
        .onChange(of: appState.columnVisibility) { _, visibility in
            // The sidebar closed under the keyboard (⌘\, toolbar).
            if visibility == .detailOnly, appState.paneFocus == .sidebar { appState.notePaneFocus(nil) }
            if visibility == .detailOnly { appState.sidebarAutoShown = false }
        }
        .onChange(of: appState.remoteVaultsStore.openNotePhase) { _, _ in appState.publishEditorPhase() }
        .onChange(of: appState.remoteEditor.isDirty) { _, _ in appState.publishEditorPhase() }
        .onChange(of: appState.selectedRemoteNoteID) { _, _ in appState.publishEditorPhase() }
        .onChange(of: appState.remoteVaultsStore.notes) { _, notes in
            appState.explorer.updateRemote(notes: notes, loading: appState.remoteVaultsStore.isLoading)
        }
        .onChange(of: appState.remoteVaultsStore.isLoading) { _, loading in
            appState.explorer.updateRemote(notes: appState.remoteVaultsStore.notes, loading: loading)
        }
        .onChange(of: appState.sync.addedBanner) { _, banner in
            guard let banner else { return }
            appState.showToast(banner)
            appState.sync.addedBanner = nil
        }
        .onChange(of: appState.remoteVaultsStore.openSession?.hasPendingLocalChanges) { _, _ in
            appState.publishEditorPhase()
        }
        .onChange(of: appState.remoteVaultsStore.offlineNotice) { _, notice in
            guard let notice else { return }
            appState.showToast(notice, tone: .warning)
            appState.remoteVaultsStore.offlineNotice = nil
        }
        .modifier(OfflinePrompts())
    }

    /// VaultRecord rows for the one-shot books.yaml import.
    private func legacySnapshots() -> [LegacyVaultSnapshot] {
        let records = (try? modelContext.fetch(FetchDescriptor<VaultRecord>())) ?? []
        return records.map { record in
            let path = record.bookmarkData.flatMap { try? Bookmark.decode($0) }?.url.path
            return LegacyVaultSnapshot(record: record, resolvedPath: path)
        }
    }

    private func addVault(url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? Bookmark.encode(url: url) else { return }
        guard let book = appState.books.addLocal(name: url.lastPathComponent, path: url.path, bookmark: bookmark) else { return }
        Task { await appState.selectBook(book) }
    }
}

/// Main area: top line, content, status line, plus the palette, help and
/// toast overlays.
struct ShellMain: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Hairline()
            #else
            ShellTopLine()
            #endif
            if appState.isNoteOpen {
                NoteBar()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { mainPaneMarker }
                // Explorer ↔ reader ↔ editor: a short cross-fade with a
                // small lift (instant under Reduce Motion).
                .animation(appState.animation(.standard), value: appState.surface)
            if appState.preferences.showKeybindsBar {
                ShellLegendLine()
                    .transition(appState.transition(.opacity.combined(with: .move(edge: .bottom))))
            }
            ShellStatusLine()
        }
        .background(theme.background)
        .coordinateSpace(.named(shellHintSpace))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(shellHintSpace)) } action: { frame in
            appState.hintRegistry.bounds = frame
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
            appState.hintRegistry.globalOrigin = origin
        }
        .overlay {
            if let session = appState.hintSession {
                HintOverlay(session: session)
                    .transition(appState.transition(.opacity))
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ShellBreadcrumb().padding(.horizontal, 6)
            }
            .glassHidden()
            ToolbarItem(placement: .primaryAction) {
                ShellSyncDot()
            }
            .glassHidden()
        }
        #endif
        .overlay(alignment: .bottomTrailing) { ShellToastOverlay() }
        .overlay {
            ZStack(alignment: .top) {
                if appState.showPalette || appState.showHelp {
                    Color.black.opacity(theme.isDark ? 0.38 : 0.16)
                        .ignoresSafeArea()
                        .onTapGesture {
                            appState.showPalette = false
                            appState.showHelp = false
                        }
                        .transition(appState.transition(.opacity))
                }
                if appState.showPalette {
                    CommandPalette()
                        .padding(.top, 90)
                        .transition(appState.transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity)))
                } else if appState.showHelp {
                    KeymapHelpOverlay()
                        .padding(.top, 70)
                        .transition(appState.transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity)))
                }
            }
        }
        .animation(appState.animation(.fast), value: appState.showPalette)
        .animation(appState.animation(.fast), value: appState.showHelp)
        .animation(appState.animation(.fast), value: appState.hintSession != nil)
        .animation(appState.animation(.standard), value: appState.preferences.showKeybindsBar)
        .environment(\.lumiMotion, appState.motionEnabled)
        #if !os(macOS)
        .focusable()
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard appState.surface != .explorer, let k = KeyStroke(press: press) else { return .ignored }
            return appState.handleShellKey(k) ? .handled : .ignored
        }
        #endif
    }

    /// Thin accent line on the main area while it has the keyboard and
    /// another pane shows (the split marks its own sides).
    @ViewBuilder
    private var mainPaneMarker: some View {
        let pane = appState.focusedPane
        if appState.showsPaneMarker, let pane, pane == appState.mainPane, appState.splitFocusMarker == nil {
            Rectangle()
                .fill(theme.primary.opacity(0.85))
                .frame(height: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let entry = appState.selectedEntry, let session = appState.session {
            NoteDetailView(
                entry: entry,
                baseURL: entry.url.deletingLastPathComponent(),
                vaultRoot: session.rootURL
            )
            .transition(appState.transition(.opacity.combined(with: .offset(y: 8))))
        } else if let vaultID = appState.selectedVaultID,
                  let book = appState.books.book(vaultID) {
            if appState.session != nil {
                ExplorerView()
                    .transition(appState.transition(.opacity.combined(with: .offset(y: -6))))
            } else {
                BookUnavailableView(book: book)
            }
        } else if let remoteID = appState.selectedRemoteVaultID,
                  let remote = appState.remoteVaultsStore.vaults.first(where: { $0.id == remoteID }) {
            if let noteID = appState.selectedRemoteNoteID,
               let row = appState.remoteVaultsStore.notes.first(where: { $0.id == noteID }) {
                RemoteNoteDetailView(vault: remote, listRow: row)
                    .transition(appState.transition(.opacity.combined(with: .offset(y: 8))))
            } else {
                ExplorerView()
                    .transition(appState.transition(.opacity.combined(with: .offset(y: -6))))
            }
        } else if appState.selectedRemoteVaultID != nil, let book = appState.openBook {
            BookUnavailableView(book: book)
        } else {
            ShellEmptyState()
        }
    }
}


#if os(macOS)
extension ToolbarContent {
    /// Plain toolbar content on macOS 26 (no Liquid Glass capsule).
    @ToolbarContentBuilder
    func glassHidden() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
#endif

/// Decisions owed before offline data leaves the device: sign out /
/// remove an account with pending edits, and texts that can no longer be
/// synced (export or discard).
private struct OfflinePrompts: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                accountTitle,
                isPresented: Binding(get: { appState.accountActionPrompt != nil },
                                     set: { if !$0 { appState.accountActionPrompt = nil } }),
                titleVisibility: .visible,
                presenting: appState.accountActionPrompt
            ) { prompt in
                switch prompt.kind {
                case .signOut:
                    Button("Sign out") { Task { await appState.performSignOut(prompt.key) } }
                case .remove:
                    Button("Export, then remove") {
                        Task { await appState.performRemoveAccount(prompt.key, export: true) }
                    }
                    Button("Remove without exporting", role: .destructive) {
                        Task { await appState.performRemoveAccount(prompt.key, export: false) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                switch prompt.kind {
                case .signOut:
                    Text("\(prompt.pending) note\(prompt.pending == 1 ? " has" : "s have") offline edits not sent yet. They stay on this device and sync after you sign in again as \(prompt.key.description).")
                case .remove:
                    Text("\(prompt.pending) note\(prompt.pending == 1 ? " has" : "s have") offline edits not sent yet. Removing the account deletes every offline copy of its books from this device.")
                }
            }
            .confirmationDialog(
                "Offline edits",
                isPresented: Binding(get: { appState.recoveryPrompt != nil },
                                     set: { if !$0 { appState.recoveryPrompt = nil } }),
                titleVisibility: .visible,
                presenting: appState.recoveryPrompt
            ) { prompt in
                Button("Export to Documents") { appState.exportRecovered(prompt.notes) }
                Button("Discard", role: .destructive) { appState.discardRecovered(prompt.notes) }
                Button("Later", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message + " " + prompt.notes.map(\.conflictTitle).prefix(5).joined(separator: ", "))
            }
    }

    private var accountTitle: String {
        switch appState.accountActionPrompt?.kind {
        case .remove: return "Remove account?"
        default: return "Sign out?"
        }
    }
}
