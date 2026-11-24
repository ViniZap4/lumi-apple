import SwiftUI
import LumiKit
import LumiUI

/// One palette row.
struct PaletteItem: Identifiable {
    enum Kind { case note, book, command, theme }
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String = ""
    var shortcut: String = ""
    /// Extra words the fuzzy matcher sees (`:book`, `q`, …).
    var aliases: String = ""
    let run: @MainActor () -> Void

    var icon: String {
        switch kind {
        case .note: return "doc.text"
        case .book: return "books.vertical"
        case .command: return "chevron.right"
        case .theme: return "paintpalette"
        }
    }

    var matchKey: String { [title, subtitle, aliases].joined(separator: " ") }
}

/// ⌘K / `space` / `:` — open notes, switch books and run every command
/// that used to live in the toolbar.
struct CommandPalette: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(appState.paletteCommandMode ? ":" : "›")
                    .font(ShellFont.palette)
                    .foregroundStyle(theme.accent)
                TextField("", text: $query, prompt: Text(appState.paletteCommandMode ? "command" : "open a note, book or command")
                    .foregroundStyle(theme.textDim.opacity(0.8)))
                    .textFieldStyle(.plain)
                    .font(ShellFont.palette)
                    .foregroundStyle(theme.text)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(.downArrow) { move(1, items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
                    .onKeyPress(keys: ["n", "j"]) { press in
                        guard press.modifiers.contains(.control) else { return .ignored }
                        move(1, items.count); return .handled
                    }
                    .onKeyPress(keys: ["p", "k"]) { press in
                        guard press.modifiers.contains(.control) else { return .ignored }
                        move(-1, items.count); return .handled
                    }
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            Hairline()
            if items.isEmpty {
                Text("no match")
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.textDim)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selection = i
                                        run(items)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: selection) { _, s in
                        if s < items.count { proxy.scrollTo(items[s].id) }
                    }
                }
            }
        }
        .frame(width: 620)
        .background(ElevatedSurface())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            query = appState.paletteSeed
            appState.paletteSeed = ""
            focused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundStyle(selected ? theme.accent : theme.textDim)
                .frame(width: 16)
            Text(item.title)
                .font(ShellFont.row)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !item.shortcut.isEmpty { KeyCap(item.shortcut) }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? theme.primary.opacity(theme.isDark ? 0.18 : 0.12) : Color.clear)
        )
        .animation(appState.animation(.fast), value: selected)
    }

    private func move(_ d: Int, _ n: Int) {
        guard n > 0 else { return }
        selection = ((selection + d) % n + n) % n
    }

    private func close() {
        appState.showPalette = false
    }

    private func run(_ items: [PaletteItem]) {
        guard selection < items.count else { return }
        let item = items[selection]
        close()
        DispatchQueue.main.async { item.run() }
    }

    // MARK: Items

    private var results: [PaletteItem] {
        var q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(":") { q.removeFirst() }
        let commands = commandItems
        let books = bookItems
        if q.isEmpty {
            return appState.paletteCommandMode ? commands : commands + books
        }
        let themes = themeItems
        let notes = noteItems
        let pool = appState.paletteCommandMode ? commands + books + themes + notes : notes + books + commands + themes
        return Array(FuzzyMatch.rank(pool, query: q, key: \.matchKey).prefix(80))
    }

    private var noteItems: [PaletteItem] {
        appState.explorer.tree.allNotes.map { entry in
            PaletteItem(id: "n:" + entry.key, kind: .note, title: entry.name,
                        subtitle: NoteTree.dirOf(entry.path)) {
                appState.explorer.nav.reveal(noteID: entry.note?.id ?? entry.path)
                if appState.isNoteOpen {
                    // Into the focused pane (⌘↩ would be a split: use :vsplit).
                    appState.openNoteIn(entry.path, where: .current, from: appState.focusedLeaf)
                } else {
                    appState.open(entry)
                }
            }
        }
    }

    private var bookItems: [PaletteItem] {
        let flat = BookSwitcherOrder.flattened(appState.books.books)
        return flat.enumerated().map { i, book in
            let host = book.serverURL.map(ServerURL.displayHost) ?? "this device"
            return PaletteItem(id: "b:" + book.id, kind: .book, title: book.name,
                               subtitle: host, shortcut: i < 9 ? "⌃\(i + 1)" : "", aliases: "book switch") {
                Task { await appState.selectBook(book) }
            }
        }
    }

    private var themeItems: [PaletteItem] {
        LumiTheme.allCases.map { t in
            PaletteItem(id: "t:" + t.rawValue, kind: .theme, title: "Theme: " + t.tokens.name,
                        subtitle: t == appState.theme ? "current" : "", aliases: "colorscheme") {
                appState.theme = t
            }
        }
    }

    private var commandItems: [PaletteItem] {
        var out: [PaletteItem] = []
        func cmd(_ id: String, _ title: String, _ shortcut: String = "", aliases: String = "", _ run: @escaping @MainActor () -> Void) {
            out.append(PaletteItem(id: "c:" + id, kind: .command, title: title, shortcut: shortcut, aliases: aliases, run: run))
        }
        let open = appState.openBook != nil
        if open {
            if appState.can("note.create") {
                cmd("new-note", "New note", "a", aliases: "create add") { appState.beginCreate() }
            }
            cmd("book-settings", "Book settings", "⌥⌘,", aliases: "book members roles invites audit rename delete") {
                appState.showBookSettings = true
            }
            cmd("sync", "Sync now", "R", aliases: "refresh reload") { appState.refreshBook() }
            cmd("hidden", appState.preferences.explorerShowHidden ? "Hide hidden files" : "Show hidden files", ".", aliases: "dotfiles") {
                appState.preferences.explorerShowHidden.toggle()
                appState.explorer.setShowHidden(appState.preferences.explorerShowHidden)
            }
            cmd("preview", appState.preferences.explorerShowPreview ? "Hide preview column" : "Show preview column", "zp") {
                appState.preferences.explorerShowPreview.toggle()
            }
        }
        if open {
            cmd("explorer", "Explorer", "-", aliases: "files browse navigate floating yazi :explore") {
                appState.openFloatingExplorer()
            }
        }
        if appState.isNoteOpen {
            cmd("vsplit", "Split vertically (:vsplit)", "⌃w v", aliases: "pane window side by side") { appState.splitPane(.vertical) }
            cmd("hsplit", "Split horizontally (:split)", "⌃w s", aliases: "pane window stacked below") { appState.splitPane(.horizontal) }
            if appState.isSplit {
                cmd("close-pane", "Close pane", "⌃w q", aliases: "pane window :close") { appState.closeFocusedPane() }
                cmd("only-pane", "Keep only this pane", "⌃w o", aliases: "pane window :only") { appState.onlyPane() }
                cmd("equal-panes", "Equalize panes", "⌃w =", aliases: "pane window resize") { appState.performLayout(.equalize) }
            }
            cmd("lumi-link", "Copy lumi:// link to this note", aliases: "deep link url share open copy") { appState.copyLumiLink() }
            cmd("edit", appState.isEditing ? "Read mode" : "Edit mode", "⌘E", aliases: "toggle") { appState.toggleEditing() }
            cmd("close", "Back to explorer", "q", aliases: "close quit") { appState.closeNote() }
            cmd("live", "Live Preview", ":live", aliases: "wysiwyg render inline edit mode") { appState.setNoteViewMode(.live) }
            cmd("source", "Source mode", ":source", aliases: "raw markdown edit mode") { appState.setNoteViewMode(.source) }
            cmd("split-preview", appState.splitPreviewShown ? "Hide split preview" : "Show split preview",
                "\\p", aliases: "preview split side by side render :preview") { appState.toggleSplitPreview() }
        }
        if appState.surface == .reader {
            cmd("hints", "Click by label (hints)", "F", aliases: "hint mode vimium mouse") {
                // After the palette closes, so its rows aren't labelled.
                Task { @MainActor in appState.startHints() }
            }
        }
        cmd("switch-book", "Switch book…", "gb", aliases: "book open accounts") {
            appState.openFloatingExplorer(level: .books)
        }
        cmd("hover", appState.preferences.hoverPreviews ? "Turn off hover link previews" : "Turn on hover link previews", "K",
            aliases: "preview link card popover") {
            appState.preferences.hoverPreviews.toggle()
        }
        cmd("new-book", "New book…", aliases: "create book vault") { appState.showNewBook = true }
        cmd("link-folder", "Link folder…", aliases: "local folder open add") { appState.showLinkFolder = true }
        cmd("manage-books", "Manage books…", aliases: "books remove reorder") { appState.showManageBooks = true }
        cmd("add-server", "Add server / account…", aliases: "sign in login account") {
            appState.signInPrefill = nil
            appState.showAddServer = true
        }
        cmd("theme", "Theme…", aliases: "colorscheme appearance") { appState.query(paletteFor: .themes) }
        cmd("settings", "Settings", "⌘,", aliases: "preferences vim escape vimrc :settings") { appState.showSettings = true }
        cmd("legend", appState.preferences.showKeybindsBar ? "Hide command legend" : "Show command legend", aliases: "view keys hints which-key") {
            appState.preferences.showKeybindsBar.toggle()
        }
        cmd("keys", "Keyboard shortcuts", "?", aliases: "help keymap") { appState.showHelp = true }
        cmd("offline-copies", "Offline copies…", aliases: "recover conflict pending export offline") {
            appState.showRecoveredNotes()
        }
        for acc in appState.accounts.accounts where appState.accounts.state(acc.key).isSignedIn {
            cmd("signout-" + acc.key.description, "Sign out \(acc.key.description)", aliases: "logout account") {
                appState.requestSignOut(acc.key)
            }
        }
        for acc in appState.accounts.accounts where !appState.accounts.state(acc.key).isSignedIn {
            cmd("signin-" + acc.key.description, "Sign in \(acc.key.description)", aliases: "login account") {
                appState.signInPrefill = acc.key
                appState.showAddServer = true
            }
        }
        for acc in appState.accounts.accounts {
            cmd("remove-" + acc.key.description, "Remove account \(acc.key.description) from this device", aliases: "account forget delete") {
                appState.requestRemoveAccount(acc.key)
            }
        }
        return out
    }
}

extension AppState {
    enum PaletteSeed { case books, themes }

    /// Re-open the palette pre-filtered (used by "Switch book…", "Theme…").
    func query(paletteFor seed: PaletteSeed) {
        paletteSeed = seed == .books ? "book " : "theme "
        paletteCommandMode = true
        showPalette = true
    }

    func closeNoteIfOpen() {
        if isNoteOpen { closeNote() }
    }

    func toggleFloatingExplorer() {
        if showFloatingExplorer { closeFloatingExplorer() } else { openFloatingExplorer() }
    }
}
