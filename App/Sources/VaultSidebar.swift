import SwiftUI
import UniformTypeIdentifiers
import LumiKit
import LumiUI

/// Optional sidebar (⌘\): accounts → books with status dots. No cards, no
/// toasts — those live in the main area.
struct VaultSidebar: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let reason = appState.books.readOnlyReason {
                        Label(reason, systemImage: "lock")
                            .font(ShellFont.small)
                            .foregroundStyle(theme.warning)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if appState.books.books.isEmpty {
                        Text("no books yet")
                            .font(ShellFont.chrome)
                            .foregroundStyle(theme.textDim)
                    }
                    let flat = BookSwitcherOrder.flattened(appState.books.books)
                    ForEach(appState.books.switcherGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(groupTitle(group))
                                .font(ShellFont.small)
                                .foregroundStyle(theme.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                            ForEach(group.books) { book in
                                BookRow(book: book,
                                        shortcut: flat.firstIndex(of: book).map { $0 + 1 }.flatMap { $0 <= 9 ? $0 : nil },
                                        isActive: appState.openBook?.id == book.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await appState.selectBook(book) } }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
            }
            Hairline()
            HStack(spacing: 12) {
                Menu {
                    Button("New book…") { appState.showNewBook = true }
                    Button("Link folder…") { appState.showLinkFolder = true }
                    Button("Add server…") {
                        appState.signInPrefill = nil
                        appState.showAddServer = true
                    }
                    Divider()
                    Button("Manage books…") { appState.showManageBooks = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textDim)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New book, link folder, add server")
                Spacer()
                Text("⌘\\")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: ShellMetrics.statusLineHeight + 4)
        }
        .background(theme.overlayBackground.opacity(0.5))
    }

    private func groupTitle(_ group: BookSwitcherOrder.Group) -> String {
        guard let url = group.serverURL else { return "this device" }
        let accounts = Set(group.books.compactMap(\.account)).sorted()
        let host = ServerURL.displayHost(url)
        return accounts.isEmpty ? host : accounts.joined(separator: ",") + "@" + host
    }
}

struct BookRow: View {
    let book: Book
    let shortcut: Int?
    let isActive: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            BookStatusDot(status: appState.sync.status(for: book), size: 6)
            Text(book.name)
                .font(isActive ? ShellFont.rowBold : ShellFont.row)
                .foregroundStyle(isActive ? theme.text : theme.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let shortcut {
                Text("⌃\(shortcut)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim.opacity(0.8))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ShellMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isActive ? theme.accent.opacity(0.14) : Color.clear)
        )
    }
}
