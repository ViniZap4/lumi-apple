import SwiftUI
import LumiKit
import LumiUI

/// Minimal top line: `book / folder / note` breadcrumb and a tiny sync
/// dot. On macOS the two halves live in the (glass-free) window toolbar
/// band next to the traffic lights; elsewhere they form a line on top.
struct ShellTopLine: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ShellBreadcrumb()
            Spacer(minLength: 12)
            ShellSyncDot()
        }
        .padding(.horizontal, 14)
        .frame(height: ShellMetrics.topLineHeight)
        .background(theme.background)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

struct ShellBreadcrumb: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            let crumbs = segments
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, seg in
                if i > 0 {
                    Text("/")
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.textDim.opacity(0.6))
                }
                Text(seg)
                    .font(i == crumbs.count - 1 ? ShellFont.chromeBold : ShellFont.chrome)
                    .foregroundStyle(i == crumbs.count - 1 ? theme.text : theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(i == crumbs.count - 1 ? 1 : 0)
            }
            presence
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var segments: [String] {
        guard let book = appState.openBook else { return ["lumi"] }
        var out = [book.name]
        if appState.isNoteOpen {
            // The note bar shows the folder and the title.
            return out
        } else {
            let dir = appState.explorer.nav.dir
            if !dir.isEmpty { out += dir.split(separator: "/").map(String.init) }
        }
        return out
    }

    @ViewBuilder
    private var presence: some View {
        let peers = appState.selectedRemoteNoteID != nil ? appState.remoteVaultsStore.openNotePresence : []
        if !peers.isEmpty {
            HStack(spacing: 4) {
                ForEach(peers.prefix(3)) { peer in
                    Circle().fill(Color(hex: peer.color)).frame(width: 6, height: 6)
                        .help(peer.name)
                }
                Text(peers.count == 1 ? peers[0].name : "\(peers.count) here")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
        }
    }
}

struct ShellSyncDot: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var showDetails = false

    var body: some View {
        if let book = appState.openBook ?? appState.books.activeBook {
            Button {
                showDetails.toggle()
            } label: {
                BookStatusDot(status: appState.sync.status(for: book), size: 7)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(book.name): \(appState.sync.status(for: book).label)")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                BookDetailsPanel(book: book)
                    .environment(appState)
                    .environment(\.theme, theme)
            }
        }
    }
}

/// Thin modal-editor status line: mode, context, counts, sync.
struct ShellStatusLine: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            // Mode pill (web `.sb-mode`): the mode's colour on a 16% tint.
            Text(modeLabel)
                .font(ShellFont.mode)
                .tracking(0.6)
                .foregroundStyle(modeColor)
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(modeColor.opacity(0.16)))
                // The pill morphs between modes (width, colour, letters).
                .contentTransition(appState.motionEnabled ? .interpolate : .identity)
                .animation(appState.motionEnabled ? .spring(response: 0.2, dampingFraction: 0.8) : nil, value: modeLabel)
            Text(context)
                .font(ShellFont.small)
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ForEach(Array(right.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let book = appState.openBook {
                let status = appState.sync.status(for: book)
                HStack(spacing: 4) {
                    BookStatusDot(status: status, size: 6)
                    Text(syncLabel(status))
                        .font(ShellFont.small)
                        .foregroundStyle(statusColor(status))
                        .fixedSize()
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: ShellMetrics.statusLineHeight)
        .background(theme.overlayBackground.opacity(0.55))
        .overlay(alignment: .top) { Hairline() }
    }

    private var modeLabel: String {
        if appState.showFloatingExplorer { return appState.floatingLevel == .books ? "BOOKS" : "BROWSE" }
        if let leaf = appState.focusedSecondary {
            guard appState.paneView(leaf).isEditing else { return "READ" }
            guard appState.preferences.vimEnabled else { return "EDIT" }
            let s = appState.paneVim[leaf] ?? VimStatus()
            if s.mode == .normal, s.pending.op != nil { return "O-PENDING" }
            return s.mode.shortLabel
        }
        if appState.focusedPane == .preview { return "PREVIEW" }
        if appState.focusedPane == .sidebar { return "BOOKS" }
        switch appState.surface {
        case .empty: return "LUMI"
        case .explorer: return appState.explorer.prompt != nil ? "PROMPT" : "BROWSE"
        case .reader: return "READ"
        case .editor:
            guard appState.preferences.vimEnabled else { return "EDIT" }
            let s = appState.liveVimStatus
            if s.insertOneShot, s.mode == .normal { return "(INSERT)" }
            if s.mode == .normal, s.pending.op != nil { return "O-PENDING" }
            return s.mode.shortLabel
        }
    }

    private var modeColor: Color {
        if appState.showFloatingExplorer { return theme.accent }
        if let leaf = appState.focusedSecondary {
            guard appState.paneView(leaf).isEditing else { return theme.info }
            return (appState.paneVim[leaf]?.mode ?? .normal).chromeColor(theme)
        }
        if appState.focusedPane == .preview { return theme.info }
        if appState.focusedPane == .sidebar { return theme.accent }
        switch appState.surface {
        case .empty: return theme.textDim
        case .explorer: return theme.accent
        case .reader: return theme.info
        case .editor:
            return appState.liveVimMode.chromeColor(theme)
        }
    }

    private var context: String {
        if appState.showFloatingExplorer, appState.floatingLevel == .files {
            let nav = appState.explorer.nav
            let dir = nav.dir.isEmpty ? "/" : "/" + nav.dir
            return nav.filter.isEmpty ? dir : "\(dir)  filter: \(nav.filter)"
        }
        switch appState.surface {
        case .empty: return "no book open"
        case .explorer:
            return appState.openBook.map { "\($0.name) — - explorer · gb books" } ?? ""
        case .reader, .editor:
            let path = appState.panePath(appState.focusedLeaf) ?? ""
            return appState.isSplit ? "\(path)  · pane \(paneIndex)/\(appState.visibleLayout.notePanes.count)" : path
        }
    }

    private var paneIndex: Int {
        (appState.visibleLayout.leaves.firstIndex(of: appState.focusedLeaf) ?? 0) + 1
    }

    private var right: [String] {
        switch appState.surface {
        case .empty: return []
        case .explorer:
            let nav = appState.explorer.nav
            var out: [String] = []
            guard appState.showFloatingExplorer else {
                if appState.openBookPendingCount > 0 { out.append("\(appState.openBookPendingCount) pending") }
                return out
            }
            if let cached = appState.remoteVaultsStore.staleListingDate, appState.remoteVaultsStore.isOffline,
               !appState.explorer.isLocal {
                out.append("offline · list from \(cached.formatted(.relative(presentation: .named)))")
            }
            if appState.openBookPendingCount > 0 { out.append("\(appState.openBookPendingCount) pending") }
            if appState.explorer.yanked != nil { out.append("yanked") }
            if nav.showHidden { out.append("hidden") }
            let n = nav.entries.count
            out.append(n == 0 ? "0/0" : "\(nav.cursor + 1)/\(n)")
            return out
        case .reader, .editor:
            var out: [String] = []
            if appState.surface == .editor, let r = appState.liveVimStatus.recording {
                out.append("recording @\(r)")
            }
            if appState.selectedRemoteNoteID != nil {
                out.append(livePhase)
                if !appState.can("note.write") { out.append("read-only") }
            } else if appState.editor.isDirty {
                out.append("modified")
            }
            let words = MarkdownText.wordCount(appState.openNoteText)
            let minutes = MarkdownText.readingMinutes(words: words)
            out.append(minutes > 0 ? "\(words) words · \(minutes) min read" : "\(words) words")
            return out.filter { !$0.isEmpty }
        }
    }

    private var livePhase: String {
        guard let s = appState.remoteVaultsStore.openSession, !s.isDestroyed else { return "" }
        switch s.phase {
        case .live: return s.peers.isEmpty ? "live" : "live · \(s.peers.count + 1)"
        case .syncing: return "syncing"
        case .connecting: return "connecting"
        case .offline: return s.hasPendingLocalChanges ? "offline · pending" : "offline"
        case .closed: return "closed"
        }
    }

    private func syncLabel(_ s: BookSyncStatus) -> String { s.label }

    private func statusColor(_ s: BookSyncStatus) -> Color {
        switch s {
        case .error: return theme.error
        case .needsSignIn: return theme.warning
        default: return theme.textDim
        }
    }

}

extension VimMode {
    var shortLabel: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case let .visual(kind, _):
            switch kind {
            case .characterwise: return "VISUAL"
            case .linewise: return "V-LINE"
            case .block: return "V-BLOCK"
            }
        case .commandLine: return "COMMAND"
        }
    }

    /// Mode colour for the status pill (web `.sb-mode`): normal primary,
    /// insert accent, visual secondary, replace error, command warning.
    func chromeColor(_ theme: ThemeTokens) -> Color {
        switch self {
        case .insert: return theme.accent
        case .replace: return theme.error
        case .visual: return theme.secondary
        case .commandLine: return theme.warning
        case .normal: return theme.primary
        }
    }
}

/// Transient message + persistent decisions (federation) in the bottom
/// trailing corner. Fixed max width, at most two lines — never wraps one
/// syllable per line.
struct ShellToastOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let notice = appState.sync.pendingNotices.first {
                federation(notice)
            }
            if let toast = appState.toast {
                HStack(spacing: 8) {
                    Circle().fill(color(toast.tone)).frame(width: 6, height: 6)
                    Text(toast.text)
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 380, alignment: .leading)
                .background(card)
                .onTapGesture { appState.toast = nil }
                .transition(appState.transition(.opacity.combined(with: .move(edge: .bottom))))
                .id(toast.id)
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, ShellMetrics.statusLineHeight + 10)
        .animation(appState.animation(.standard), value: appState.toast)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.overlayBackground)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func color(_ tone: ShellToast.Tone) -> Color {
        switch tone {
        case .info: return theme.info
        case .success: return Color.green.opacity(0.85)
        case .warning: return theme.warning
        case .error: return theme.error
        }
    }

    private func federation(_ notice: FederationNotice) -> some View {
        let also = notice.alsoOn.map { ServerURL.displayHost($0.serverURL) }.joined(separator: ", ")
        let via = ServerURL.displayHost(notice.syncsVia.serverURL)
        return VStack(alignment: .leading, spacing: 8) {
            Text("This book is also on \(also). It syncs through \(via).")
                .font(ShellFont.chrome)
                .foregroundStyle(theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Keep") { appState.sync.pendingNotices.removeFirst() }
                Menu("Switch server…") {
                    ForEach(notice.alsoOn, id: \.self) { alt in
                        Button(alt.description) {
                            appState.sync.pendingNotices.removeFirst()
                            Task { await appState.sync.switchServer(notice.bookID, to: alt) }
                        }
                    }
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .font(ShellFont.chromeBold)
            .foregroundStyle(theme.primary)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(card)
    }
}
