import SwiftUI
import LumiKit
import LumiUI

/// Read + edit viewer for a server-vault note.
///
/// macOS / iOS: the note's live CRDT session (`store.openSession`, one
/// replica for as long as the note is open) drives both modes. The REST
/// snapshot is only a read-only preview while the session connects; the
/// editor mounts once the first SyncStep2 arrived, starting from the
/// replica text, and every keystroke goes out as a ranged op — there is
/// no Save step. visionOS (no local CRDT) keeps the REST editor
/// (`AppState.remoteEditor`, ⌘S → 3-way `/diff`).
struct RemoteNoteDetailView: View {
    /// Server-vault row this note belongs to. Used for the header chrome.
    let vault: RemoteVault
    /// The cached row from the note list. Carries title + path which we
    /// don't have to re-extract from frontmatter for the header.
    let listRow: RemoteNote

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        // Chrome lives in the shell: breadcrumb + presence in the top line,
        // live phase / read-only / words in the status line. Only banners
        // that need a decision render here.
        VStack(alignment: .leading, spacing: 6) {
            Group {
                errorBanner
                conflictBanner
                reconnectBanner
                sessionBanner
            }
            .padding(.horizontal, 16)
            content
        }
        .padding(.top, hasBanner ? 8 : 0)
        .background(theme.background)
        .background {
            // ⌘S for the REST fallback editor (visionOS: no live replica).
            if canEditNotes && liveSession == nil {
                Button("Save", action: requestSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .hidden()
            }
        }
        .onAppear(perform: ensureLoaded)
        .onChange(of: appState.remoteVaultsStore.openNoteSnapshot) { _, newSnapshot in
            handleSnapshotChange(newSnapshot)
        }
    }

    private var hasBanner: Bool {
        if case .conflict = appState.remoteEditor.status { return true }
        if case .error = appState.remoteEditor.status { return true }
        if appState.remoteVaultsStore.reconnectStatus != nil { return true }
        if let s = liveSession, s.termination != nil || s.connectionNotice != nil { return true }
        return false
    }

    /// `note.write` capability check. Mirrors the audit/invite checks in
    /// `RemoteVaultDetailView` — matches against the current session's
    /// member row inside the active vault.
    private var canEditNotes: Bool {
        guard let account = appState.activeAccount else { return false }
        let me = appState.remoteVaultsStore.members.first { $0.username == account.username }
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

    /// "Reconnecting in Ns…" hint — shown while the WS sync subscription
    /// is waiting out a backoff between attempts. Drives a per-second
    /// `TimelineView` so the countdown ticks without us managing a
    /// Timer. Slice 4f.3.
    @ViewBuilder
    private var reconnectBanner: some View {
        if let status = appState.remoteVaultsStore.reconnectStatus {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(theme.warning)
                    Text(status.formatHint(now: context.date))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Text("attempt \(status.attempt)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.textDim)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.warning.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(theme.warning.opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    /// Live-session notices: fatal closes (§5), "cannot reach live
    /// editing", and the legacy uninitialised-note recovery (§2.2.5).
    @ViewBuilder
    private var sessionBanner: some View {
        if let session = liveSession {
            if let termination = session.termination {
                bannerRow(icon: "lock", tint: theme.warning, message: describe(termination))
            } else if let notice = session.connectionNotice {
                bannerRow(icon: "wifi.exclamationmark", tint: theme.warning, message: notice)
            } else if session.hasSynced, session.emptyAtSync, session.text.isEmpty,
                      let body = appState.remoteVaultsStore.openNoteSnapshot?.text, !body.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.arrow.up")
                        .foregroundStyle(theme.info)
                    Text("the live document is empty but the file has content")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Button("Load file contents") { session.initialiseFromFile(body) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(theme.primary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.info.opacity(0.08))
                )
            }
        }
    }

    private func bannerRow(icon: String, tint: Color, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(tint.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    /// Strict-conflict banner — shown when `applyDiff` was rejected and
    /// the editor has already refetched the latest snapshot. The user's
    /// `currentText` is preserved; saving again will diff against the
    /// fresh clock. Slice 4c.
    @ViewBuilder
    private var conflictBanner: some View {
        if case .conflict = appState.remoteEditor.status {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(theme.warning)
                Text("another device saved first — your edits are preserved, save again to merge")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Dismiss") { appState.remoteEditor.discard() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textDim)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.warning.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.warning.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
    }

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
                text: readText,
                // Server notes have no on-disk URL → cache is disabled, but
                // MarkdownReader handles the nil path cleanly.
                noteURL: nil,
                baseURL: nil,
                vaultRoot: nil,
                isDirty: liveSession == nil && appState.remoteEditor.isDirty,
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
        if let session = liveSession {
            if session.isEditable {
                VimEditor(
                    document: session,
                    vimEnabled: appState.preferences.vimEnabled,
                    onModeChange: { appState.liveVimMode = $0 },
                    onEffect: handleVimEffect,
                    jjEscapeEnabled: appState.preferences.jjEscapeMapping,
                    showLineNumbers: appState.preferences.showLineNumbers,
                    relativeLineNumbers: appState.preferences.relativeLineNumbers,
                    options: appState.vimEditorOptions
                )
                .readableEditorWidth()
                // One editor per replica: a new session remounts it.
                .id(ObjectIdentifier(session))
            } else {
                // §2.2.3: read-only preview until the first SyncStep2.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if session.termination == nil { ProgressView().controlSize(.small) }
                        Text(session.termination.map(describe) ?? "connecting to live editing…")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                    }
                    ScrollView {
                        Text(readText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            @Bindable var editor = appState.remoteEditor
            Group {
                if appState.preferences.vimEnabled {
                    VimEditor(
                        text: $editor.currentText,
                        onModeChange: { appState.liveVimMode = $0 },
                        onEffect: handleVimEffect,
                        jjEscapeEnabled: appState.preferences.jjEscapeMapping,
                        showLineNumbers: appState.preferences.showLineNumbers,
                        relativeLineNumbers: appState.preferences.relativeLineNumbers,
                        options: appState.vimEditorOptions
                    )
                    .readableEditorWidth()
                } else {
                    PlainTextEditor(text: $editor.currentText)
                }
            }
        }
    }

    /// The open note's live session, when it belongs to this note.
    private var liveSession: OpenNoteSession? {
        guard let s = appState.remoteVaultsStore.openSession, s.noteID == listRow.id, !s.isDestroyed else { return nil }
        return s
    }

    /// Text for read mode: the live replica once synced, else the REST
    /// preview (or the REST editor's buffer on visionOS).
    private var readText: String {
        if let s = liveSession, s.hasSynced { return s.text }
        if LumiCRDT.isSupported {
            return appState.remoteVaultsStore.openNoteSnapshot.flatMap { $0.id == listRow.id ? $0.text : nil } ?? ""
        }
        return appState.remoteEditor.currentText
    }

    private func phaseLabel(_ session: OpenNoteSession) -> String {
        switch session.phase {
        case .live: return session.peers.isEmpty ? "live" : "live · \(session.peers.count + 1) editing"
        case .syncing: return "syncing…"
        case .connecting: return "connecting…"
        case .offline: return session.hasPendingLocalChanges ? "offline · edits pending" : "offline"
        case .closed: return "closed"
        }
    }

    private func describe(_ termination: SessionTermination) -> String {
        switch termination {
        case .unauthorized: return "session expired — sign in again to keep editing"
        case .forbidden: return "read-only — you don't have note.edit on this vault"
        case .notFound: return "this note was deleted on the server"
        case .policy: return "too many open live sessions — close another note and retry"
        case .notConfigured: return "no server session — sign in to edit live"
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
        let store = appState.remoteVaultsStore
        let vaultID = vault.id
        let noteID = listRow.id
        if LumiCRDT.isSupported && canEditNotes {
            // One replica per open note: joins empty, syncs, keeps the
            // doc across reconnects (CRDT-CLIENT-PROTOCOL §2, §5).
            store.openLiveSession(vaultID: vaultID, noteID: noteID, user: awarenessUser)
        }
        if let current = store.openNoteSnapshot, current.id == noteID {
            seedEditorIfNeeded(from: current)
            return
        }
        // REST snapshot: preview while connecting + "Load file contents".
        Task { await store.loadOpenNote(vaultID: vaultID, noteID: noteID) }
    }

    /// The local user as published over y-protocols awareness.
    private var awarenessUser: AwarenessUser? {
        guard let account = appState.activeAccount else { return nil }
        return AwarenessUser(username: account.username, displayName: account.displayName)
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
        // The REST editor exists only where there is no live replica.
        guard !LumiCRDT.isSupported, snapshot.id == listRow.id else { return }
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

    /// Pull to refresh: re-fetch the snapshot; with a live session its
    /// state is merged into the kept replica (never a fresh doc, V8).
    private func refresh() {
        let store = appState.remoteVaultsStore
        if LumiCRDT.isSupported && canEditNotes {
            store.openLiveSession(vaultID: vault.id, noteID: listRow.id, user: awarenessUser)
        }
        Task { await store.loadOpenNote(vaultID: vault.id, noteID: listRow.id) }
    }

    /// REST fallback save (visionOS). Live sessions have no save step.
    private func requestSave() {
        guard liveSession == nil, appState.remoteEditor.isDirty, !isSaving else { return }
        let editor = appState.remoteEditor
        let store = appState.remoteVaultsStore
        let client = appState.remoteVaultsStore.apiClient
        // `beginSave` captures vault/note/text synchronously, so a
        // caller (close()) may reset the editor right after this.
        guard let save = editor.beginSave(via: client) else { return }
        let vaultID = vault.id
        Task {
            if let snapshot = await save.value {
                // Mirror the post-merge snapshot into the store (only if
                // the note is still open) and bump the list row's
                // `updated_at`.
                store.recordSavedSnapshot(snapshot, vaultID: vaultID)
            }
        }
    }

    private func close() {
        // Auto-save dirty edits on back, matching the local-vault
        // `closeNote()` behavior. We don't block on completion — the user
        // can return to the vault detail immediately; the commit
        // completes in the background.
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
        if liveSession != nil {
            // Live edits are already shared: :w is a no-op, :q/:wq/:q!
            // just leave edit mode (there is nothing local to discard).
            switch effect {
            case .save: break
            case .saveAndClose, .close: appState.remoteEditorMode = .view
            }
            return
        }
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
