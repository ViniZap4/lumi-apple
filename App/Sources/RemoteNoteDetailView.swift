import SwiftUI
import LumiKit
import LumiUI

/// Read-only viewer for a server-vault note (E.1.2 slice 2). Renders the
/// markdown body via the shared `MarkdownView` pipeline. Editing, save, vim
/// mode, and reading-mode glide-scroll all stay opt-out for now — this view
/// is intentionally minimal so slice 2 ships as a small surface; slice 3
/// will refactor to share the local-vault `MarkdownReader`.
struct RemoteNoteDetailView: View {
    /// Server-vault row this note belongs to. Used for the breadcrumb and
    /// to know which list row's title/path to show in the header.
    let vault: RemoteVault
    /// The full row from the cached note list. Carries title + path which
    /// we don't have to re-extract from frontmatter for the header.
    let listRow: RemoteNote

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    /// Cached parsed AST — re-derives only when the body string changes.
    /// Without this the markdown reparse fires on every state churn (theme
    /// flips, error banners, etc.), which is wasteful on long notes.
    @State private var parsed: MarkdownDocument?
    @State private var parsedBody: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider().background(theme.border)

            content
        }
        .background(theme.background)
        .onAppear(perform: ensureLoaded)
        .onChange(of: appState.remoteVaultsStore.openNoteContent) { _, newContent in
            // Re-parse the AST whenever the body string changes (initial
            // load, or a future "refresh" action).
            guard let newContent else {
                parsed = nil
                parsedBody = nil
                return
            }
            if parsedBody != newContent.body {
                parsedBody = newContent.body
                parsed = MarkdownParser.parse(newContent.body, baseURL: nil)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
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

                Button {
                    refresh()
                } label: {
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
                Text("· read-only")
                    .font(.caption2)
                    .foregroundStyle(theme.textDim)
            }
        }
    }

    private var displayTitle: String {
        if !listRow.title.isEmpty { return listRow.title }
        return listRow.id
    }

    @ViewBuilder
    private var content: some View {
        if appState.remoteVaultsStore.openNoteIsLoading && parsed == nil {
            loadingState
        } else if let error = appState.remoteVaultsStore.openNoteError, parsed == nil {
            errorState(error)
        } else if let parsed {
            ScrollView {
                MarkdownView(parsed)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
        } else {
            // Initial state before the first task fires — show nothing
            // (the header is already visible so the user sees something).
            EmptyView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
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

    private func ensureLoaded() {
        let store = appState.remoteVaultsStore
        if let current = store.openNoteContent, current.id == listRow.id {
            // Hot path: row tap triggered the load before this view
            // appeared; just sync our parsed cache.
            if parsedBody != current.body {
                parsedBody = current.body
                parsed = MarkdownParser.parse(current.body, baseURL: nil)
            }
            return
        }
        Task { await store.loadOpenNote(vaultID: vault.id, noteID: listRow.id) }
    }

    private func refresh() {
        let store = appState.remoteVaultsStore
        Task { await store.loadOpenNote(vaultID: vault.id, noteID: listRow.id) }
    }

    private func close() {
        appState.selectedRemoteNoteID = nil
        appState.remoteVaultsStore.closeOpenNote()
        parsed = nil
        parsedBody = nil
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
