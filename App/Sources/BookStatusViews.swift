import SwiftUI
import LumiKit
import LumiUI

/// Status glyph for one book (SPEC-LIVROS §4.1 "Indicador" column):
/// folder (local), amber dot (sign in), red dot (error), hollow grey dot
/// (offline), pulsing dot (syncing), lock (read-only), green dot (up to date).
struct BookStatusDot: View {
    let status: BookSyncStatus
    var size: CGFloat = 8
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        Group {
            switch status {
            case .local:
                Image(systemName: "folder")
                    .font(.system(size: size + 3))
                    .foregroundStyle(theme.textDim)
            case .readOnly:
                Image(systemName: "lock.fill")
                    .font(.system(size: size + 2))
                    .foregroundStyle(theme.textDim)
            case .offline:
                Circle().stroke(theme.textDim, lineWidth: 1.5).frame(width: size, height: size)
            case .needsSignIn:
                Circle().fill(theme.warning).frame(width: size, height: size)
            case .error:
                Circle().fill(theme.error).frame(width: size, height: size)
            case .syncing:
                Circle().fill(theme.info)
                    .frame(width: size, height: size)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            case .upToDate:
                Circle().fill(Color.green.opacity(0.85)).frame(width: size, height: size)
            }
        }
        .frame(width: size + 6, height: size + 6)
        .help(status.label)
        .accessibilityLabel(Text("sync status: \(status.label)"))
    }
}

/// Toolbar item: the open book's state + a details popover (§4.3).
struct SyncStatusIndicator: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var showDetails = false

    var body: some View {
        if let book = appState.openBook ?? appState.books.activeBook {
            let status = appState.sync.status(for: book)
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    BookStatusDot(status: status)
                    Text(status.label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                        .fixedSize()
                }
            }
            .buttonStyle(.plain)
            .help("Sync status for \(book.name)")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                BookDetailsPanel(book: book)
                    .environment(appState)
                    .environment(\.theme, theme)
            }
        }
    }
}

/// Details popover: server, account, role, state, last sync, cursor/head,
/// alternates, last 5 errors, actions.
struct BookDetailsPanel: View {
    let book: Book
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let status = appState.sync.status(for: book)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BookStatusDot(status: status, size: 10)
                Text(book.name).font(.system(.headline, design: .monospaced))
                Spacer()
                Text(status.label)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            if case let .needsSignIn(reason) = status { reasonLine(reason) }
            if case let .error(reason) = status { reasonLine(reason) }

            if book.kind == .bound {
                grid
            } else {
                row("folder", book.path ?? "(bookmark only)")
                Text("local books live only on this device — no server, no feed.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }

            if let alts = appState.sync.alternates[book.id], !alts.isEmpty {
                Divider()
                Text("also on").font(.system(.caption, design: .monospaced)).foregroundStyle(theme.textDim)
                ForEach(alts, id: \.self) { alt in
                    Text(alt.description).font(.system(.caption, design: .monospaced))
                }
            }

            if let errors = appState.sync.recentErrors[book.id], !errors.isEmpty {
                Divider()
                Text("recent errors").font(.system(.caption, design: .monospaced)).foregroundStyle(theme.textDim)
                ForEach(errors, id: \.self) { e in
                    Text(e).font(.system(.caption2, design: .monospaced)).foregroundStyle(theme.error)
                        .lineLimit(2)
                }
            }

            Divider()
            actions(status)
        }
        .padding(14)
        .frame(minWidth: 340, alignment: .leading)
        .background(theme.background)
    }

    @ViewBuilder
    private var grid: some View {
        let key = book.accountKey
        row("server", book.serverURL.map(ServerURL.displayHost) ?? "—")
        if let s = book.serverURL, ServerURL.isInsecure(s) {
            Text("⚠︎ plain http — traffic is not encrypted")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.warning)
        }
        row("account", book.account ?? "—")
        row("role", appState.sync.remote[book.id]?.role ?? "—")
        row("feed", key.flatMap { appState.sync.feedState[$0] }.map(feedLabel) ?? "not connected")
        row("last sync", appState.sync.lastSyncedAt[book.id].map { $0.formatted(.relative(presentation: .named)) } ?? "never")
        let cu = appState.sync.catchUp[book.id]
        row("cursor / head", "\(appState.sync.cursor(book.id)) / \(cu?.head.map(String.init) ?? "?")")
        let pending = appState.sync.pendingReplicas[book.id] ?? 0
        row("pending", pending == 0 ? "nothing unsent" : "\(pending) note\(pending == 1 ? "" : "s") with offline edits not sent yet")
    }

    private func feedLabel(_ s: AccountFeedState) -> String {
        switch s {
        case .connecting: return "connecting"
        case .open: return "open"
        case let .backoff(attempt, retry): return "retry #\(attempt) in \(Int(retry.rounded()))s"
        case .authDead: return "session ended"
        case .disabled: return "unavailable on this server (REST only)"
        }
    }

    @ViewBuilder
    private func actions(_ status: BookSyncStatus) -> some View {
        HStack(spacing: 10) {
            if book.kind == .bound {
                Button("Try now") { Task { await appState.sync.retryNow(book) } }
                if case .needsSignIn = status {
                    Button("Sign in") {
                        appState.signInPrefill = book.accountKey
                        appState.showAddServer = true
                    }
                }
                if let alts = appState.sync.alternates[book.id], !alts.isEmpty {
                    Menu("Switch server…") {
                        ForEach(alts, id: \.self) { alt in
                            Button(alt.description) { Task { await appState.sync.switchServer(book.id, to: alt) } }
                        }
                    }
                    .fixedSize()
                }
                Button("Unlink") {
                    appState.books.unlink(book.id)
                    appState.sync.forgetBook(book.id)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(.caption, design: .monospaced))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func reasonLine(_ reason: String) -> some View {
        Text(reason)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(theme.textDim)
    }
}

/// Shown in the content area when a bound book can't be opened (§5 empty
/// states: sign in / revoked / incomplete link).
struct BookUnavailableView: View {
    let book: Book
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let status = appState.sync.status(for: book)
        VStack(spacing: 14) {
            BookStatusDot(status: status, size: 14)
            Text(book.name).font(.system(.title3, design: .monospaced))
            switch status {
            case .needsSignIn:
                message("sign in to \(book.serverURL.map(ServerURL.displayHost) ?? "the server") to sync")
                Button("Sign in") {
                    appState.signInPrefill = book.accountKey
                    appState.showAddServer = true
                }
                .buttonStyle(.borderedProminent)
            case .error where appState.sync.revoked.contains(book.id):
                message("you no longer have access to this book")
                Button("Remove from list") {
                    appState.books.remove(book.id)
                    appState.sync.forgetBook(book.id)
                    appState.selectedRemoteVaultID = nil
                }
                .buttonStyle(.bordered)
            case .error where book.vaultID == nil:
                message("incomplete link: this book has no server vault id")
                Button("Relink…") { appState.showManageBooks = true }
                    .buttonStyle(.bordered)
            case .local:
                message("this folder isn't available on this device — open it again to restore access")
                Button("Open folder…") { appState.showNewBook = true }
                    .buttonStyle(.bordered)
            default:
                ProgressView().controlSize(.small)
                message(status.label)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(theme.textDim)
            .multilineTextAlignment(.center)
    }
}
