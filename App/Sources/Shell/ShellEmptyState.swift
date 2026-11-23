import SwiftUI
import LumiKit
import LumiUI

/// Main area with no book open: books by number, the few ways in, and a
/// one-time line about what a book is.
struct ShellEmptyState: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let books = BookSwitcherOrder.flattened(appState.books.books)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("lumi")
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                Text("local-first markdown notes")
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.textDim)
            }
            if !appState.books.onboardingShown {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("A book is a separate space of notes — on this device, or synced with one server.")
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.text.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("got it") { appState.books.onboardingShown = true }
                        .buttonStyle(.plain)
                        .font(ShellFont.chromeBold)
                        .foregroundStyle(theme.primary)
                }
            }
            if books.isEmpty {
                Text("no books yet")
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.textDim)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    section("books")
                    ForEach(Array(books.enumerated()), id: \.element.id) { i, book in
                        Button {
                            Task { await appState.selectBook(book) }
                        } label: {
                            HStack(spacing: 10) {
                                Text(i < 9 ? "\(i + 1)" : " ")
                                    .font(ShellFont.chromeBold)
                                    .foregroundStyle(theme.textDim)
                                    .frame(width: 14, alignment: .trailing)
                                BookStatusDot(status: appState.sync.status(for: book), size: 6)
                                Text(book.name)
                                    .font(ShellFont.row)
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(book.serverURL.map(ServerURL.displayHost) ?? "this device")
                                    .font(ShellFont.small)
                                    .foregroundStyle(theme.textDim)
                                    .lineLimit(1)
                            }
                            .frame(height: ShellMetrics.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                section("start")
                action("command palette", "⌘K") { appState.openPalette() }
                action("new book…", "") { appState.showNewBook = true }
                action("link a folder…", "") { appState.showLinkFolder = true }
                action("add a server…", "") {
                    appState.signInPrefill = nil
                    appState.showAddServer = true
                }
                action("keys", "?") { appState.showHelp = true }
            }
        }
        .frame(width: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(ShellFont.small)
            .foregroundStyle(theme.accent)
            .padding(.bottom, 4)
    }

    private func action(_ title: String, _ key: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Text(title)
                    .font(ShellFont.row)
                    .foregroundStyle(theme.primary)
                Spacer()
                if !key.isEmpty { KeyCap(key) }
            }
            .frame(height: ShellMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
