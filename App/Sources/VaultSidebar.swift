import SwiftUI
import UniformTypeIdentifiers
import LumiKit
import LumiUI

/// Sidebar: book switcher at the top (SPEC-LIVROS §5), then every book
/// grouped by server (local first) with its status dot and ⌃⌘ number.
struct VaultSidebar: View {
    let onAdd: (URL) -> Void

    @State private var showImporter = false
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bound = appState
        VStack(spacing: 0) {
            BookSwitcherButton()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            if let reason = appState.books.readOnlyReason {
                banner(reason, systemImage: "lock", color: theme.warning) {}
            }
            if !appState.books.onboardingShown {
                onboardingCard
            }
            if let notice = appState.sync.pendingNotices.first {
                federationBanner(notice)
            }
            if let added = appState.sync.addedBanner {
                banner(added, systemImage: "books.vertical", color: theme.info) { appState.sync.addedBanner = nil }
            }
            bookList
        }
        .background(theme.overlayBackground)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                onAdd(url)
            }
        }
    }

    private var bookList: some View {
        List {
            if appState.books.books.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("no books yet")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                    Button("New book…") { appState.showNewBook = true }
                    Button("Add server…") { appState.showAddServer = true }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.primary)
                .font(.system(.callout, design: .monospaced))
                .padding(.vertical, 6)
            }
            let flat = BookSwitcherOrder.flattened(appState.books.books)
            ForEach(appState.books.switcherGroups) { group in
                Section {
                    ForEach(group.books) { book in
                        BookRow(book: book,
                                shortcut: flat.firstIndex(of: book).map { $0 + 1 }.flatMap { $0 <= 9 ? $0 : nil },
                                isActive: appState.openBook?.id == book.id)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await appState.selectBook(book) } }
                    }
                } header: {
                    Text(group.serverURL.map(ServerURL.displayHost) ?? "this device")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            }
            Section {
                sidebarButton("New book…", systemImage: "plus.circle") { appState.showNewBook = true }
                sidebarButton("Link folder…", systemImage: "folder.badge.plus") { showImporter = true }
                sidebarButton("Add server…", systemImage: "server.rack") { appState.showAddServer = true }
                sidebarButton("Manage books…", systemImage: "list.bullet") { appState.showManageBooks = true }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func sidebarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(.callout, design: .monospaced))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("books")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            Text("Each book is a separate space of notes. It can live only on this device or be linked to a server, and each linked book syncs with a single server.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it") { appState.books.onboardingShown = true }
                .buttonStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.primary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.background))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func federationBanner(_ notice: FederationNotice) -> some View {
        let also = notice.alsoOn.map { ServerURL.displayHost($0.serverURL) }.joined(separator: ", ")
        let via = ServerURL.displayHost(notice.syncsVia.serverURL)
        return VStack(alignment: .leading, spacing: 6) {
            Text("This book is also on \(also). It syncs through \(via).")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
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
            .font(.system(.caption, design: .monospaced))
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.background))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func banner(_ text: String, systemImage: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textDim)
        }
        .padding(8)
        .padding(.horizontal, 10)
    }
}

/// Button at the top of the sidebar: active book + its status; opens the
/// grouped list with the management entries at the bottom.
struct BookSwitcherButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var bound = appState
        let active = appState.openBook ?? appState.books.activeBook
        Button {
            appState.showBookSwitcher.toggle()
        } label: {
            HStack(spacing: 8) {
                if let active {
                    BookStatusDot(status: appState.sync.status(for: active))
                    Text(active.name)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                } else {
                    Text("no book")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch book (⌃⌘0)")
        .popover(isPresented: $bound.showBookSwitcher, arrowEdge: .bottom) {
            BookSwitcherList()
                .environment(appState)
                .environment(\.theme, theme)
        }
    }
}

struct BookSwitcherList: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let flat = BookSwitcherOrder.flattened(appState.books.books)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(appState.books.switcherGroups) { group in
                Text(group.serverURL.map(ServerURL.displayHost) ?? "this device")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .padding(.top, 6)
                ForEach(group.books) { book in
                    Button {
                        appState.showBookSwitcher = false
                        Task { await appState.selectBook(book) }
                    } label: {
                        BookRow(book: book,
                                shortcut: flat.firstIndex(of: book).map { $0 + 1 }.flatMap { $0 <= 9 ? $0 : nil },
                                isActive: appState.openBook?.id == book.id)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().padding(.vertical, 4)
            entry("New book…") { appState.showNewBook = true }
            entry("Link folder…") { appState.showNewBook = true }
            entry("Add server…") { appState.showAddServer = true }
            entry("Manage books…") { appState.showManageBooks = true }
        }
        .padding(12)
        .frame(width: 300)
        .background(theme.background)
    }

    private func entry(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            appState.showBookSwitcher = false
            action()
        } label: {
            Text(title)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            BookStatusDot(status: appState.sync.status(for: book))
            VStack(alignment: .leading, spacing: 1) {
                Text(book.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isActive ? theme.accent : theme.text)
                    .lineLimit(1)
                if let account = book.account {
                    Text(account)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            }
            Spacer()
            if let shortcut {
                Text("⌃⌘\(shortcut)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.vertical, 2)
    }
}
