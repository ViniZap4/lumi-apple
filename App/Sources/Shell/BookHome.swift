import SwiftUI
import LumiKit
import LumiUI

/// A book with no note open (SPEC-PARTE2 §2): calm — the book's name,
/// its sync state and recent notes. The floating explorer is the way in.
struct BookHome: View {
    let book: Book
    @Environment(AppState.self) private var appState

    var body: some View {
        let status = appState.sync.status(for: book)
        let recents = appState.homeRecents
        BookHomeView(
            name: book.name, status: status.label, location: location, noteCount: appState.explorer.tree.noteCount,
            recents: recents.map {
                .init(id: $0.key, name: $0.name, folder: NoteTree.dirOf($0.path),
                      updated: $0.note?.updatedAt.map { HoverPreview.updatedLabel($0) } ?? "")
            },
            cursor: appState.showFloatingExplorer ? nil : appState.homeCursor,
            loading: appState.explorer.isLoading,
            dot: { BookStatusDot(status: status, size: 7) },
            onOpen: { i in
                appState.homeCursor = i
                if recents.indices.contains(i) { appState.open(recents[i]) }
            }
        )
    }

    private var location: String {
        if book.kind == .local { return book.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "this device" }
        return "\(book.account ?? "")@\(book.serverURL.map(ServerURL.displayHost) ?? "")"
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
