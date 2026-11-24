import SwiftUI
import LumiKit
import LumiUI

/// What the floating overlay shows (SPEC-PARTE2 §2).
enum FloatingLevel: Equatable {
    /// yazi Miller columns over the open book's notes.
    case files
    /// Accounts → books (`gb`, "Switch book").
    case books
}

/// The shared-element open: a ghost that grows from the explorer row into
/// the note area while the note fades in.
struct OpenMorph: Equatable, Identifiable {
    let id = UUID()
    var from: CGRect
    var title: String
}

/// One account (or this device) and its books.
struct BookGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let books: [Book]
    let signedIn: Bool
}

// MARK: - State and keys

extension AppState {
    var bookGroups: [BookGroup] {
        let all = BookSwitcherOrder.flattened(books.books)
        var out: [BookGroup] = []
        let local = all.filter { $0.kind == .local }
        out.append(BookGroup(id: "local", title: "This device", subtitle: "folders on this Mac", icon: "laptopcomputer",
                             books: local, signedIn: true))
        var seen = Set<String>()
        for acc in accounts.accounts {
            let key = acc.key
            seen.insert(key.description)
            let host = ServerURL.displayHost(key.serverURL)
            out.append(BookGroup(id: key.description, title: key.username, subtitle: host, icon: "person.crop.circle",
                                 books: all.filter { $0.kind == .bound && $0.accountKey == key },
                                 signedIn: accounts.state(key).isSignedIn))
        }
        let orphans = all.filter { $0.kind == .bound && !seen.contains($0.accountKey?.description ?? "") }
        if !orphans.isEmpty {
            out.append(BookGroup(id: "other", title: "Other accounts", subtitle: "not signed in on this device",
                                 icon: "person.crop.circle.badge.questionmark", books: orphans, signedIn: false))
        }
        return out
    }

    /// `-`, `<leader>e`, `:explore`, the toolbar button, the palette.
    /// Starts at the current note's folder.
    func openFloatingExplorer(level: FloatingLevel = .files) {
        if level == .files, openBook == nil || explorer.source == .none {
            openFloatingExplorer(level: .books)
            return
        }
        if !showFloatingExplorer { floatingReturnSlot = currentSlot }
        floatingLevel = level
        if level == .files {
            if let path = panePath(focusedLeaf) { explorer.revealPath(path) }
        } else {
            let groups = bookGroups
            if let book = openBook, let g = groups.firstIndex(where: { $0.books.contains(book) }) {
                booksGroupCursor = g
                booksCursor = groups[g].books.firstIndex(of: book) ?? 0
            } else {
                booksGroupCursor = groups.firstIndex { !$0.books.isEmpty } ?? 0
                booksCursor = 0
            }
            booksColumn = 1
        }
        hoverIntentStore?.hide()
        resignTextResponder()
        keymap.reset()
        withMotion(.standard) { showFloatingExplorer = true }
    }

    func closeFloatingExplorer(restore: Bool = true) {
        guard showFloatingExplorer else { return }
        if explorer.prompt != nil { cancelPrompt() }
        explorer.pendingDelete = nil
        keymap.reset()
        withMotion(.fast) { showFloatingExplorer = false }
        if restore, isNoteOpen { focusSlot(floatingReturnSlot) }
    }

    /// Open a note from the overlay: here, or in a split.
    func floatingOpen(_ entry: ExplorerEntry, _ target: LinkOpenWhere, edit: Bool = false) {
        guard entry.kind == .note else {
            _ = explorer.nav.right()
            return
        }
        let path = entry.path.isEmpty ? (entry.note?.id ?? entry.path) : entry.path
        if let frame = rowFrames[entry.key], target == .current {
            openMorph = OpenMorph(from: frame, title: entry.name)
        }
        closeFloatingExplorer(restore: true)
        if !isNoteOpen {
            open(entry, edit: edit)
            return
        }
        openNoteIn(path, where: target, from: focusedLeaf)
        if edit, target == .current { setPaneView(focusedLeaf, preferences.editMode == .live ? .live : .source) }
    }

    /// Keys while the overlay shows. Always consumes plain keys (it is
    /// modal); ⌘ shortcuts pass.
    func handleFloatingKey(_ k: KeyStroke) -> Bool {
        if k.command { return false }
        if explorer.pendingDelete != nil {
            if k.chars == "y" || k.chars == "Y" || k.special == .enter { confirmDelete() } else { explorer.pendingDelete = nil }
            return true
        }
        if explorer.prompt != nil { return false }
        if floatingLevel == .books { return handleBooksKey(k) }

        let ex = explorer
        if k.special == .escape {
            if !ex.nav.filter.isEmpty { ex.nav.setFilter("") } else { closeFloatingExplorer() }
            return true
        }
        if k.control, let c = k.chars?.lowercased() {
            switch c {
            case "v", "s":
                if let cur = ex.nav.current, cur.kind == .note { floatingOpen(cur, c == "v" ? .vsplit : .hsplit) }
                return true
            case "d": ex.nav.move(max(1, ex.pageRows / 2)); return true
            case "u": ex.nav.move(-max(1, ex.pageRows / 2)); return true
            default: return true
            }
        }
        if k.chars == "q", ex.nav.filter.isEmpty { closeFloatingExplorer(); return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard let action = keymap.feed(k, context: .explorer, now: now) else { return true }
        switch action {
        case .open:
            if let cur = ex.nav.current {
                if cur.kind == .note { floatingOpen(cur, .current) } else { _ = ex.nav.right() }
            }
        case .edit:
            if let cur = ex.nav.current, cur.kind == .note { floatingOpen(cur, .current, edit: true) }
        case .parent:
            // yazi: up from the book root is the books level.
            if ex.nav.dir.isEmpty { openFloatingExplorer(level: .books) } else { ex.nav.left() }
        case .books:
            openFloatingExplorer(level: .books)
        case .close, .clearOrBack:
            closeFloatingExplorer()
        case .palette, .command:
            closeFloatingExplorer(restore: false)
            _ = performShared(action)
        case .pane, .paneKey, .explore:
            break
        default:
            _ = performExplorer(action)
        }
        return true
    }

    private func handleBooksKey(_ k: KeyStroke) -> Bool {
        let groups = bookGroups
        guard !groups.isEmpty else {
            if k.special == .escape || k.chars == "q" { closeFloatingExplorer() }
            return true
        }
        booksGroupCursor = min(booksGroupCursor, groups.count - 1)
        let books = groups[booksGroupCursor].books
        func move(_ d: Int) {
            if booksColumn == 0 {
                booksGroupCursor = max(0, min(groups.count - 1, booksGroupCursor + d))
                booksCursor = 0
            } else if !books.isEmpty {
                booksCursor = max(0, min(books.count - 1, booksCursor + d))
            }
        }
        switch (k.chars, k.special) {
        case (_, .escape?), ("q", _):
            if openBook != nil, explorer.source != .none, floatingReturnSlot != nil, isNoteOpen == false {
                closeFloatingExplorer()
            } else {
                closeFloatingExplorer()
            }
        case ("j", _), (_, .down?): move(1)
        case ("k", _), (_, .up?): move(-1)
        case ("g", _): if booksColumn == 0 { booksGroupCursor = 0 } else { booksCursor = 0 }
        case ("G", _): if booksColumn == 0 { booksGroupCursor = groups.count - 1 } else { booksCursor = max(0, books.count - 1) }
        case ("h", _), (_, .left?), ("-", _): booksColumn = 0
        case ("l", _), (_, .right?), (_, .enter?):
            if booksColumn == 0 {
                if !books.isEmpty { booksColumn = 1; booksCursor = 0 } else if !groups[booksGroupCursor].signedIn {
                    closeFloatingExplorer(restore: false)
                    signInPrefill = accounts.accounts.first { $0.key.description == groups[booksGroupCursor].id }?.key
                    showAddServer = true
                }
            } else if books.indices.contains(booksCursor) {
                openBookFromOverlay(books[booksCursor])
            }
        case ("[", _): cycleBook(-1)
        case ("]", _): cycleBook(1)
        case (":", _), (" ", _):
            closeFloatingExplorer(restore: false)
            openPalette(commands: k.chars == ":")
        case ("?", _): showHelp = true
        default: break
        }
        return true
    }

    func openBookFromOverlay(_ book: Book) {
        closeFloatingExplorer(restore: false)
        if book.id == openBook?.id {
            openFloatingExplorer(level: .files)
            return
        }
        Task { await selectBook(book) }
    }

    /// After a book opened: its last note, else the empty home with the
    /// floating explorer open (SPEC-PARTE2 §2).
    func showLastNoteOrHome(_ book: Book) {
        homeCursor = 0
        if let last = bookMemory.lastNote(forBook: book.id) {
            if noteExists(last), openNote(atPath: last, edit: false) { return }
            if explorer.source != .none, !(book.kind == .bound && remoteVaultsStore.notes.isEmpty) {
                bookMemory.forget(last, inBook: book.id)
            }
        }
        if explorer.source != .none { openFloatingExplorer(level: .files) }
    }

    /// Recent notes of the open book that still exist.
    var homeRecents: [ExplorerEntry] {
        guard let book = openBook else { return [] }
        let all = explorer.tree.allNotes
        return bookMemory.recent(forBook: book.id).compactMap { p in
            all.first { $0.path == p || $0.note?.id == p }
        }
    }

    /// Keys on the empty book home: `-` / `l` / Enter explorer or the
    /// recent note, j/k move.
    func handleHomeKey(_ k: KeyStroke) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard let action = keymap.feed(k, context: .explorer, now: now) else { return false }
        let recents = homeRecents
        switch action {
        case let .move(n): homeCursor = max(0, min(max(0, recents.count - 1), homeCursor + n))
        case .top: homeCursor = 0
        case .bottom: homeCursor = max(0, recents.count - 1)
        case .open, .edit:
            if recents.indices.contains(homeCursor) { open(recents[homeCursor], edit: action == .edit) } else { openFloatingExplorer() }
        case .parent, .explore, .filter: openFloatingExplorer()
        case .books: openFloatingExplorer(level: .books)
        case .create: beginCreateFromHome()
        case .refresh: refreshBook()
        case let .pane(c): performPane(c)
        case let .paneKey(d): performPane(.move(d))
        default: return performShared(action)
        }
        return true
    }

    /// `a` on the home: the explorer with its create prompt.
    private func beginCreateFromHome() {
        openFloatingExplorer()
        beginCreate()
    }
}

// MARK: - Views

/// The floating overlay: files (Miller columns + preview) or books.
struct FloatingExplorerOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 720
            FloatingPanel(title: title, path: path, hints: hints(compact), compact: compact,
                          onDismiss: { appState.closeFloatingExplorer() }) {
                Group {
                    if appState.floatingLevel == .files {
                        ExplorerColumns(floating: true)
                    } else {
                        BooksColumns()
                    }
                }
                .transition(appState.transition(.opacity))
            } footer: {
                EmptyView()
            }
        }
    }

    private var title: String {
        if appState.floatingLevel == .books { return "books" }
        return appState.openBook?.name ?? "explorer"
    }

    private var path: String {
        if appState.floatingLevel == .books { return "accounts → books" }
        let dir = appState.explorer.nav.dir
        let filter = appState.explorer.nav.filter
        return "/" + dir + (filter.isEmpty ? "" : "  filter: \(filter)")
    }

    private func hints(_ compact: Bool) -> [(String, String)] {
        if compact { return [("esc", "close")] }
        if appState.floatingLevel == .books {
            return [("⏎", "open"), ("h l", "accounts / books"), ("esc", "close")]
        }
        return [("⏎", "open"), ("⌃v", "split"), ("⌃s", "stacked"), ("gb", "books"), ("esc", "close")]
    }
}

/// Accounts → books, with a details column.
struct BooksColumns: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let groups = appState.bookGroups
        let g = min(appState.booksGroupCursor, max(0, groups.count - 1))
        GeometryReader { geo in
            HStack(spacing: 0) {
                column(active: appState.booksColumn == 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                        ExplorerRowLabel(name: group.title, isFolder: true, count: group.books.count,
                                         isCursor: i == g, active: appState.booksColumn == 0, isOpen: false,
                                         hidden: !group.signedIn, icon: group.icon)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.booksGroupCursor = i
                                appState.booksCursor = 0
                                appState.booksColumn = 0
                            }
                            .staggerIn(i, active: appState.motionEnabled)
                    }
                }
                .frame(width: max(170, min(250, geo.size.width * 0.28)))
                Hairline(vertical: true)
                column(active: appState.booksColumn == 1) {
                    if groups.indices.contains(g) {
                        let books = groups[g].books
                        if books.isEmpty {
                            Text(groups[g].signedIn ? "no books on this account yet · palette: New book…" : "signed out · ⏎ to sign in")
                                .font(ShellFont.chrome)
                                .foregroundStyle(theme.textDim)
                                .padding(12)
                        }
                        ForEach(Array(books.enumerated()), id: \.element.id) { i, book in
                            HStack(spacing: 0) {
                                ExplorerRowLabel(name: book.name, isFolder: false, count: 0,
                                                 isCursor: i == appState.booksCursor && appState.booksColumn == 1,
                                                 active: true, isOpen: book.id == appState.openBook?.id, hidden: false,
                                                 icon: book.kind == .local ? "folder" : "cloud")
                                BookStatusDot(status: appState.sync.status(for: book), size: 6)
                                    .padding(.trailing, 12)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { appState.openBookFromOverlay(book) }
                            .onTapGesture {
                                appState.booksColumn = 1
                                appState.booksCursor = i
                            }
                            .staggerIn(i, active: appState.motionEnabled)
                        }
                    }
                }
                .frame(width: max(220, min(360, geo.size.width * 0.34)))
                Hairline(vertical: true)
                details(groups: groups, g: g)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func column<C: View>(active: Bool, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .background(active ? Color.clear : theme.overlayBackground.opacity(0.35))
    }

    @ViewBuilder
    private func details(groups: [BookGroup], g: Int) -> some View {
        if groups.indices.contains(g), groups[g].books.indices.contains(appState.booksCursor) {
            let book = groups[g].books[appState.booksCursor]
            let status = appState.sync.status(for: book)
            VStack(alignment: .leading, spacing: 10) {
                Text(book.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.text)
                HStack(spacing: 6) {
                    BookStatusDot(status: status, size: 7)
                    Text(status.label).font(ShellFont.chrome).foregroundStyle(theme.textDim)
                }
                Text(book.kind == .local ? (book.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "this device")
                                         : "\(book.account ?? "")@\(book.serverURL.map(ServerURL.displayHost) ?? "")")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let last = appState.bookMemory.lastNote(forBook: book.id) {
                    HStack(spacing: 6) {
                        Text("last note").font(ShellFont.small).foregroundStyle(theme.textDim)
                        Text(NoteTree.stem(last)).font(ShellFont.chromeBold).foregroundStyle(theme.text)
                    }
                }
                Text("⏎ open the book · [ ] cycle")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .padding(.top, 6)
            }
            .padding(18)
        } else {
            Color.clear
        }
    }
}

// MARK: - Shared-element ghost

/// The explorer row grows into the note area (≤ 220 ms, then fades);
/// nothing under Reduce Motion.
struct OpenMorphGhost: View {
    let morph: OpenMorph
    let target: CGRect
    let onDone: () -> Void
    @State private var progress: CGFloat = 0
    @State private var gone = false

    var body: some View {
        OpenMorphView(from: morph.from, to: target, progress: progress, title: morph.title)
            .opacity(gone ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { progress = 1 }
                withAnimation(.easeOut(duration: 0.14).delay(0.12)) { gone = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDone() }
            }
    }
}
