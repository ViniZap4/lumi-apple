import SwiftUI
import LumiKit
import LumiUI

/// A book with no note open (SPEC-PARTE2 §2): calm — the book's name,
/// its sync state and recent notes. The floating explorer is the way in.
struct BookHome: View {
    let book: Book
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let status = appState.sync.status(for: book)
        let recents = appState.homeRecents
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(book.name)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    BookStatusDot(status: status, size: 7)
                    Text(status.label)
                    Text("·").opacity(0.5)
                    Text(where_)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·").opacity(0.5)
                    Text("\(appState.explorer.tree.noteCount) notes")
                }
                .font(ShellFont.chrome)
                .foregroundStyle(theme.textDim)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("RECENT")
                    .font(ShellFont.small)
                    .tracking(1.2)
                    .foregroundStyle(theme.textDim)
                    .padding(.bottom, 6)
                if recents.isEmpty {
                    Text(appState.explorer.isLoading ? "loading…" : "nothing opened here yet")
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.textDim)
                }
                ForEach(Array(recents.enumerated()), id: \.element.key) { i, entry in
                    Button {
                        appState.homeCursor = i
                        appState.open(entry)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textDim)
                            Text(entry.name)
                                .font(ShellFont.row)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(NoteTree.dirOf(entry.path))
                                .font(ShellFont.small)
                                .foregroundStyle(theme.textDim)
                                .lineLimit(1)
                            if let d = entry.note?.updatedAt {
                                Text(HoverPreview.updatedLabel(d))
                                    .font(ShellFont.small)
                                    .foregroundStyle(theme.textDim)
                                    .frame(width: 80, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(i == appState.homeCursor && !appState.showFloatingExplorer ? theme.selectionRow : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LiftButtonStyle(enabled: appState.motionEnabled))
                    .staggerIn(i, active: appState.motionEnabled)
                }
            }
            .frame(maxWidth: 560)
            HStack(spacing: 14) {
                hint("-", "explorer")
                hint("gb", "books")
                hint("space", "palette")
                hint("?", "keys")
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(book.name) home")
    }

    private var where_: String {
        if book.kind == .local { return book.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "this device" }
        return "\(book.account ?? "")@\(book.serverURL.map(ServerURL.displayHost) ?? "")"
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key)
            Text(label).font(ShellFont.small).foregroundStyle(theme.textDim)
        }
    }
}

/// Toolbar button that opens the floating explorer (the mouse way in).
struct ExplorerButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            if appState.showFloatingExplorer { appState.closeFloatingExplorer() } else { appState.openFloatingExplorer() }
        } label: {
            Image(systemName: "sidebar.squares.left")
                .font(.system(size: 13))
                .foregroundStyle(appState.showFloatingExplorer ? theme.primary : theme.textDim)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(LiftButtonStyle(enabled: appState.motionEnabled))
        .help("Explorer (- · <leader>e · :explore · ⌘\\)")
        .accessibilityLabel("Explorer")
    }
}
