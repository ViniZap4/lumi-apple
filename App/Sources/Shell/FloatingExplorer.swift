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
        if !local.isEmpty {
            out.append(BookGroup(id: "local", title: "Este Mac", subtitle: "pastas neste Mac", icon: "laptopcomputer",
                                 books: local, signedIn: true))
        }
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
            out.append(BookGroup(id: "other", title: "Outras contas", subtitle: "sem sessão neste Mac",
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

    /// The shelf cursor (AppState keeps it as column / group / row).
    var shelfCursor: BooksShelf.Cursor {
        get { BooksShelf.Cursor(level: booksColumn == 0 ? .accounts : .books, account: booksGroupCursor, book: booksCursor) }
        set {
            booksColumn = newValue.level == .accounts ? 0 : 1
            booksGroupCursor = newValue.account
            booksCursor = newValue.book
        }
    }

    /// Books level keys (SPEC-PARTE2 §2): one Livros list across
    /// accounts; the accounts layer only with many accounts.
    private func handleBooksKey(_ k: KeyStroke) -> Bool {
        let groups = bookGroups
        guard !groups.isEmpty else {
            if k.special == .escape || k.chars == "q" { closeFloatingExplorer() }
            return true
        }
        let sizes = groups.map(\.books.count)
        func apply(_ key: BooksShelf.Key) {
            let (c, outcome) = BooksShelf.step(sizes, shelfCursor, key)
            withMotion(.travel) { shelfCursor = c }
            switch outcome {
            case .none: break
            case let .open(a, b): openBookFromOverlay(groups[a].books[b])
            case .atTop: showToast("Livros é o topo — sem camada de contas")
            case let .emptyAccount(a):
                if !groups[a].signedIn {
                    closeFloatingExplorer(restore: false)
                    signInPrefill = accounts.accounts.first { $0.key.description == groups[a].id }?.key
                    showAddServer = true
                } else {
                    showToast("nenhum livro nesta conta ainda")
                }
            }
        }
        switch (k.chars, k.special) {
        case (_, .escape?), ("q", _): closeFloatingExplorer()
        case ("j", _), (_, .down?): apply(.move(1))
        case ("k", _), (_, .up?): apply(.move(-1))
        case ("g", _): apply(.top)
        case ("G", _): apply(.bottom)
        case ("h", _), (_, .left?), ("-", _): apply(.parent)
        case ("l", _), (_, .right?), (_, .enter?): apply(.open)
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
            FloatingPanel(title: title, path: path, hints: [], compact: compact, origin: UnitPoint(x: 0.12, y: 0),
                          icon: appState.floatingLevel == .books
                            ? BooksShelf.symbol(appState.booksColumn == 0 ? .server : .shelf) : BooksShelf.symbol(.book),
                          onDismiss: { appState.closeFloatingExplorer() }) {
                Group {
                    if appState.floatingLevel == .files {
                        ExplorerColumns(floating: true)
                    } else {
                        BooksColumns()
                    }
                }
                // A scope change, not a folder push: the camera pulls back
                // to the shelf (content settles from 1.05) or dives into
                // the book (from 0.95).
                .lumiEnter(appState.floatingLevel == .books ? MotionFrom(scale: 1.05, opacity: 0) : MotionFrom(scale: 0.95, opacity: 0),
                           spring: .gentle, trigger: appState.floatingLevel)
            } footer: {
                // The navigation legend: clickable, fitted, with the count.
                FloatingExplorerLegend()
            }
            // Dragging a note onto a pane edge: the panes underneath take
            // the drop, so the overlay steps aside.
            .opacity(appState.noteDrag == nil ? 1 : 0.1)
            .allowsHitTesting(appState.noteDrag == nil)
            .animation(appState.animation(.fast), value: appState.noteDrag == nil)
        }
    }

    private var title: String {
        if appState.floatingLevel == .books {
            return appState.booksColumn == 0 ? "Contas e servidores" : "Livros"
        }
        return appState.openBook?.name ?? "explorer"
    }

    /// Breadcrumb: Contas › user@host › Livros (each level its own icon
    /// in the header; the shelf is a scope, never a folder).
    private var path: String {
        if appState.floatingLevel == .books {
            let groups = appState.bookGroups
            let sizes = groups.map(\.books.count)
            let layer = BooksShelf.hasAccountsLayer(sizes)
            let g = groups.indices.contains(appState.booksGroupCursor) ? groups[appState.booksGroupCursor] : nil
            let acct = g.map { $0.id == "local" ? $0.title : "\($0.title)@\($0.subtitle)" }
            let crumbs = BooksShelf.crumbs(level: appState.booksColumn == 0 ? .accounts : .books, account: acct, hasLayer: layer)
            let all = groups.reduce(0) { $0 + $1.books.count }
            let tail = BooksShelf.plural(all, "livro", "livros") + " · " + BooksShelf.plural(groups.count, "conta", "contas")
            return crumbs.dropLast().map(\.1).joined(separator: " › ") + (crumbs.count > 1 ? "  ·  " : "") + tail
        }
        let dir = appState.explorer.nav.dir
        let filter = appState.explorer.nav.filter
        return "/" + dir + (filter.isEmpty ? "" : "  filter: \(filter)")
    }

}

/// The books level: the Livros shelf (LumiUI `BooksShelfView`).
struct BooksColumns: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let groups = appState.bookGroups
        let order = BookSwitcherOrder.flattened(appState.books.books)
        BooksShelfView(
            accounts: groups.map { g in
                ShelfAccount(id: g.id, user: g.title, host: g.subtitle, isLocal: g.id == "local", signedIn: g.signedIn,
                             books: g.books.map { book in shelfBook(book, number: order.firstIndex(of: book).map { $0 + 1 }) })
            },
            cursor: appState.shelfCursor,
            onPick: { c in appState.withMotion(.travel) { appState.shelfCursor = c } },
            onOpen: { c in
                appState.shelfCursor = c
                if c.level == .books, groups.indices.contains(c.account), groups[c.account].books.indices.contains(c.book) {
                    appState.openBookFromOverlay(groups[c.account].books[c.book])
                } else if c.level == .accounts {
                    appState.withMotion(.travel) { appState.shelfCursor = BooksShelf.Cursor(level: .books, account: c.account, book: 0) }
                }
            }
        )
    }

    private func shelfBook(_ book: Book, number: Int?) -> ShelfBook {
        let status = appState.sync.status(for: book)
        let open = book.id == appState.openBook?.id
        return ShelfBook(
            id: book.id, name: book.name, isLocal: book.kind == .local,
            noteCount: open ? appState.explorer.tree.noteCount : appState.bookNoteCounts[book.id],
            lastNote: appState.bookMemory.lastNote(forBook: book.id).map(NoteTree.stem),
            number: number.flatMap { $0 <= 9 ? $0 : nil }, isOpen: open,
            statusLabel: status.label, statusColor: Self.color(status, theme), syncing: status == .syncing
        )
    }

    static func color(_ s: BookSyncStatus, _ theme: ThemeTokens) -> Color {
        switch s {
        case .local, .readOnly, .offline: return theme.ramp.ink3
        case .needsSignIn: return theme.warning
        case .error: return theme.error
        case .syncing: return theme.info
        case .upToDate: return Color.green.opacity(0.85)
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
                // The row grows into the note on glide (1% overshoot reads
                // as weight); the ghost leaves at exit speed once the
                // note has arrived (70 ms behind, §6.2.6).
                withAnimation(LumiSpring.glide.animation) { progress = 1 }
                withAnimation(.easeOut(duration: LumiDuration.exit).delay(0.2)) { gone = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onDone() }
            }
    }
}
