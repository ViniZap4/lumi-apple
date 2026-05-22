import SwiftUI
import LumiKit
import LumiUI

/// Read + edit viewer for a server-vault note (E.1.2 slices 2 + 3). View
/// mode renders the markdown body via the shared `MarkdownView` pipeline;
/// edit mode hosts `VimEditor` (or `PlainTextEditor` if vim is off) bound
/// to `AppState.remoteEditor.currentText`, with ⌘S → `PATCH .../notes/:id`.
/// Local-vault reading-mode glide-scroll + link tooltips are deferred to a
/// later slice that hoists `MarkdownReader` into LumiUI.
struct RemoteNoteDetailView: View {
    /// Server-vault row this note belongs to. Used for the header chrome.
    let vault: RemoteVault
    /// The cached row from the note list. Carries title + path which we
    /// don't have to re-extract from frontmatter for the header.
    let listRow: RemoteNote

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 12)

            errorBanner
                .padding(.horizontal, 32)
                .padding(.bottom, 8)

            Divider().background(theme.border)

            content
        }
        .background(theme.background)
        .onAppear(perform: ensureLoaded)
        .onChange(of: appState.remoteVaultsStore.openNoteSnapshot) { _, newSnapshot in
            handleSnapshotChange(newSnapshot)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        @Bindable var bound = appState
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: close) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(.body, design: .monospaced))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.textDim)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if canEditNotes {
                    Picker("", selection: $bound.remoteEditorMode) {
                        Image(systemName: "book").tag(NoteDisplayMode.view)
                        Image(systemName: "pencil").tag(NoteDisplayMode.edit)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .labelsHidden()
                }

                if appState.remoteEditor.isDirty {
                    Text("modified")
                        .font(.caption2)
                        .foregroundStyle(theme.warning)
                } else if case .saving = appState.remoteEditor.status {
                    Text("saving…")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                } else if case .saved = appState.remoteEditor.status {
                    Text("saved")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                }

                if canEditNotes {
                    Button(action: requestSave) {
                        Label("Save", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(appState.remoteEditor.isDirty ? theme.primary : theme.textDim)
                    .disabled(!appState.remoteEditor.isDirty || isSaving)
                    .keyboardShortcut("s", modifiers: .command)
                }

                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.textDim)
                .disabled(appState.remoteVaultsStore.openNoteIsLoading)
            }
            Text(displayTitle)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.text)
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(theme.textDim)
                Text("\(vault.name) · \(listRow.path)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !canEditNotes {
                    Text("· read-only (note.write required)")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                }
            }
        }
    }

    /// `note.write` capability check. Mirrors the audit/invite checks in
    /// `RemoteVaultDetailView` — matches against the current session's
    /// member row inside the active vault.
    private var canEditNotes: Bool {
        guard let session = appState.authService.currentSession else { return false }
        let me = appState.remoteVaultsStore.members.first { $0.username == session.user.username }
        guard let caps = me?.capabilities else { return false }
        return caps.contains { $0 == "*" || $0 == "note.*" || $0 == "note.write" || $0 == "vault.*" }
    }

    private var displayTitle: String {
        if !listRow.title.isEmpty { return listRow.title }
        return listRow.id
    }

    private var isSaving: Bool {
        if case .saving = appState.remoteEditor.status { return true }
        return false
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if case let .error(message) = appState.remoteEditor.status {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.error)
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.error)
                Spacer()
                Button("Dismiss") { appState.remoteEditor.discard() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textDim)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.error.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.error.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.remoteVaultsStore.openNoteIsLoading && appState.remoteEditor.status == .idle {
            loadingState
        } else if let error = appState.remoteVaultsStore.openNoteError, !appState.remoteEditor.isBound(toVaultID: vault.id, noteID: listRow.id) {
            errorState(error)
        } else {
            switch appState.remoteEditorMode {
            case .view:
                viewMode
            case .edit:
                editMode
            }
        }
    }

    @ViewBuilder
    private var viewMode: some View {
        ReadModeScroll(jkEnabled: appState.preferences.jkScrollInView) {
            MarkdownReader(
                title: displayTitle,
                tags: [],
                text: appState.remoteEditor.currentText,
                // Server notes have no on-disk URL → cache is disabled, but
                // MarkdownReader handles the nil path cleanly.
                noteURL: nil,
                baseURL: nil,
                vaultRoot: nil,
                isDirty: appState.remoteEditor.isDirty,
                scale: appState.preferences.readingScale,
                fontFamily: markdownFontFamilyFromPreferences,
                contentAnimations: appState.preferences.contentAnimations,
                readingWidth: appState.preferences.readingWidth,
                // No in-app link routing for server notes yet — the slug
                // resolution endpoint isn't wired up.
                onInAppLink: nil,
                yankFlashTrigger: appState.yankFlashAt
            )
        }
        .id(listRow.id)
    }

    /// Map the user's preference enum onto LumiUI's `MarkdownFontFamily`,
    /// mirroring the helper inside `NoteDetailView`.
    private var markdownFontFamilyFromPreferences: MarkdownFontFamily {
        switch appState.preferences.readingFontFamily {
        case .system: return .system
        case .serif: return .serif
        case .monospace: return .monospace
        }
    }

    @ViewBuilder
    private var editMode: some View {
        @Bindable var editor = appState.remoteEditor
        Group {
            if appState.preferences.vimEnabled {
                VimEditor(
                    text: $editor.currentText,
                    onModeChange: { appState.liveVimMode = $0 },
                    onEffect: handleVimEffect,
                    jjEscapeEnabled: appState.preferences.jjEscapeMapping,
                    showLineNumbers: appState.preferences.showLineNumbers,
                    relativeLineNumbers: appState.preferences.relativeLineNumbers
                )
                .overlay(alignment: .top) { editModeStripe }
            } else {
                PlainTextEditor(text: $editor.currentText)
            }
        }
    }

    @ViewBuilder
    private var editModeStripe: some View {
        Rectangle()
            .fill(editModeColor)
            .frame(height: 3)
    }

    private var editModeColor: Color {
        switch appState.liveVimMode {
        case .insert: return theme.primary
        case .visual: return theme.warning
        case .commandLine: return theme.accent
        case .normal: return theme.info
        }
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("loading note from server…")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    @ViewBuilder
    private func errorState(_ error: LumiAPIError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't load note", systemImage: "exclamationmark.triangle")
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(theme.error)
            Text(describe(error))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.textDim)
            HStack {
                Button("Retry") { refresh() }
                    .buttonStyle(.borderedProminent)
                Button("Back") { close() }
                    .buttonStyle(.borderless)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }

    // MARK: - Lifecycle / actions

    private func ensureLoaded() {
        appState.remoteEditorMode = .view
        let store = appState.remoteVaultsStore
        if let current = store.openNoteSnapshot, current.id == listRow.id {
            seedEditorIfNeeded(from: current)
            return
        }
        Task { await store.loadOpenNote(vaultID: vault.id, noteID: listRow.id) }
    }

    private func handleSnapshotChange(_ newSnapshot: RemoteNoteSnapshot?) {
        guard let newSnapshot else { return }
        seedEditorIfNeeded(from: newSnapshot)
    }

    /// Seed the editor state from a fetched payload — but only when this
    /// snapshot is for the currently-displayed note, and only if the
    /// editor isn't already holding dirty edits for this exact note.
    /// Avoids clobbering in-flight edits on an idempotent re-fetch (and
    /// also avoids overwriting a freshly-saved-merged baseline when the
    /// snapshot change fired from our own `applyDiff` response).
    private func seedEditorIfNeeded(from snapshot: RemoteNoteSnapshot) {
        guard snapshot.id == listRow.id else { return }
        let editor = appState.remoteEditor
        if !editor.isBound(toVaultID: vault.id, noteID: snapshot.id) {
            // Different note bound previously — replace state.
            editor.load(snapshot, vaultID: vault.id)
        } else if !editor.isDirty {
            // Same note, no in-progress edits — refresh from server.
            editor.load(snapshot, vaultID: vault.id)
        }
        // Else: same note, user has dirty edits — leave them be.
    }

    private func refresh() {
        let store = appState.remoteVaultsStore
        Task { await store.loadOpenNote(vaultID: vault.id, noteID: listRow.id) }
    }

    private func requestSave() {
        guard appState.remoteEditor.isDirty, !isSaving else { return }
        let editor = appState.remoteEditor
        let store = appState.remoteVaultsStore
        let client = appState.authService.apiClient
        Task {
            if let snapshot = await editor.saveViaDiff(via: client) {
                // Mirror the post-merge snapshot into the store so future
                // re-opens of this view don't refetch.
                store.setOpenNoteSnapshot(snapshot)
                // The list row's `updated_at` reflects the body change.
                // The snapshot doesn't carry created_at / title, so we
                // splice them onto the existing row in place.
                store.bumpNoteUpdatedAt(noteID: snapshot.id, path: snapshot.path)
            }
        }
    }

    private func close() {
        // Auto-save dirty edits on back, matching the local-vault
        // `closeNote()` behavior. We don't block on completion — the user
        // can return to the vault detail immediately; the PATCH completes
        // in the background and a failure surfaces on the next open.
        if appState.remoteEditor.isDirty, canEditNotes {
            requestSave()
        }
        appState.selectedRemoteNoteID = nil
        appState.remoteVaultsStore.closeOpenNote()
        appState.remoteEditor.reset()
        appState.remoteEditorMode = .view
    }

    private func handleVimEffect(_ effect: VimEffect) {
        let editor = appState.remoteEditor
        switch effect {
        case .save:
            // Server PATCH has no force/conflict distinction (last-write-
            // wins for now), so :w and :w! both just save.
            requestSave()
        case .saveAndClose:
            requestSave()
            appState.remoteEditorMode = .view
        case .close(force: false):
            // :q refuses a dirty buffer (matches local vim semantics).
            if !editor.isDirty { appState.remoteEditorMode = .view }
        case .close(force: true):
            editor.discard()
            appState.remoteEditorMode = .view
        }
    }

    private func describe(_ error: LumiAPIError) -> String {
        switch error {
        case .unauthorized: return "session expired — sign in again"
        case .network(let m): return "network error: \(m)"
        case .server(_, let code, let detail):
            switch code {
            case "forbidden": return "you don't have permission to read this note (note.read)"
            case "not_found": return "this note no longer exists on the server"
            default: return detail ?? code
            }
        case .invalidResponse(let s): return "unexpected response (HTTP \(s))"
        case .decoding(let m): return "decode failed: \(m)"
        }
    }
}
