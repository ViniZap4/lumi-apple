import Foundation
import Observation
import SwiftUI
import LumiKit
import LumiUI

/// What the user is doing with the active note — previewing or editing.
public enum NoteDisplayMode: Hashable, Sendable {
    case view
    case edit
}

@Observable
@MainActor
final class AppState {
    var theme: LumiTheme = .defaultDark

    /// Id of the open *local* book (folder session). Server books use
    /// `selectedRemoteVaultID`.
    var selectedVaultID: String?
    /// Path (vault-relative) of the currently selected note. Stored as a
    /// string so it survives across selection changes without holding a
    /// reference into the lazy folder tree. `nil` means no note open.
    var selectedNoteID: String?

    /// Currently selected note's lightweight handle. Set by tree row taps
    /// (or quick-switcher selection); read by the detail view to drive the
    /// editor load. Holding the entry here means the detail view doesn't
    /// have to scan the lazy tree to resolve a selection.
    var selectedEntry: NoteEntry?

    /// Read-vs-edit toggle for the currently open note. Lives on AppState
    /// so the global toolbar (RootView) and the note view share a single
    /// source of truth; opening a new note resets to `.view` so users
    /// always land in the preview pane first.
    var editorMode: NoteDisplayMode = .view

    /// Live vim engine mode for the currently open note. Surfaced to the
    /// toolbar's VimModeBadge so the user sees NORMAL / INSERT / VISUAL /
    /// COMMAND from anywhere in the chrome.
    var liveVimMode: VimMode = .normal

    /// Notes scanned from the currently selected vault. Cached here so the
    /// detail view can resolve a selection by id without re-walking the disk.
    /// (Legacy field — the lazy tree replaces it for new flows but a few
    /// places still read it; cleanup pending.)
    var notes: [Note] = []

    /// Active vault session — keeps security-scoped access alive while a vault
    /// is selected. Nil when no vault is open.
    var session: VaultSession?

    /// Editor state for the currently open note. Reused across notes; switching
    /// notes calls `load` to repopulate.
    let editor = EditorState()

    /// Every account this device is signed into, keyed by
    /// (server_url, username). One API client per account — there is no
    /// global "current session" (SPEC-LIVROS §2.2).
    let accounts: AccountsStore

    /// Shared book registry (`~/.config/lumi/books.yaml`).
    let books: BooksRegistry

    /// Per-account feeds, catch-up and per-book sync status.
    let sync: BooksSyncEngine

    /// Presentation flags for the books UI.
    var showAddServer: Bool = false
    var showManageBooks: Bool = false
    var showNewBook: Bool = false
    var showBookSwitcher: Bool = false
    /// Prefilled server for "Sign in" from a book row/status popover.
    var signInPrefill: AccountKey?

    /// Active book id (mirrors `books.activeBookID`, set by selection).
    var activeBookID: String? { books.activeBookID }

    /// The account the open server book syncs through.
    var activeAccountKey: AccountKey? {
        guard selectedRemoteVaultID != nil else { return nil }
        return books.activeBook?.accountKey
    }

    var activeAccount: Account? {
        activeAccountKey.flatMap { accounts.account($0) }
    }

    /// Stable per-app-launch identity used as the `clientID` for
    /// presence broadcasts. Different devices for the same user need
    /// distinct clientIDs so peers see them as separate viewers, so
    /// this is a fresh UUID per launch — not derived from the user.
    /// Phase H slice 4.
    let clientID: UUID = UUID()

    /// Server-vault discovery cache (E.1.1). Populated on sign-in via
    /// `remoteVaultsStore.refresh()`; cleared on sign-out.
    let remoteVaultsStore: RemoteVaultsStore

    /// Selection in the sidebar's "server" section. Independent of
    /// `selectedVaultID` (local) — selecting one clears the other so the
    /// detail panel doesn't conflict.
    var selectedRemoteVaultID: UUID?

    /// Slug id of the currently-open server-vault note. Set by tapping a
    /// row in `RemoteVaultDetailView.noteSection`; the content is fetched
    /// lazily into `remoteVaultsStore.openNoteContent`. Mirrors the local
    /// `selectedNoteID` for server notes. Independent of `selectedEntry`
    /// (which is local-vault only).
    var selectedRemoteNoteID: String?

    /// Editor state for the currently-open server note. Reused across
    /// notes — switching notes calls `load(_:)` to repopulate. Saves are
    /// PATCH calls (`LumiAPIClient.updateNote`) instead of atomic disk
    /// writes. Sibling of the local `editor`; the two are independent so
    /// dirty state can persist across local↔server vault switches.
    let remoteEditor = RemoteEditorState()

    /// View / edit toggle for the currently-open server note. Mirrors the
    /// local `editorMode` for server notes. Reset to `.view` on every
    /// note open so users land in preview first.
    var remoteEditorMode: NoteDisplayMode = .view

    /// Persisted user preferences (vim nav, jj/jk mappings, etc.). Read by
    /// views that gate features on user opt-in.
    let preferences = LumiPreferences()

    /// Whether the Settings sheet is presented. Lives on AppState so the
    /// Cmd+, keyboard shortcut (defined on the App-level Scene) and the
    /// toolbar button share state without dueling `@State` containers.
    var showSettings: Bool = false

    /// Column visibility for the navigation split. Default is
    /// `.detailOnly` so the app opens straight onto the home pane (ASCII
    /// logo + vault picker) like the TUI / web clients. Users can pop
    /// the sidebar open with the toolbar toggle or the standard
    /// ⌥⌘S shortcut.
    var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    /// Bumped by `performYank()` whenever `y` or ⌘C fires in read mode.
    /// The read pane observes this via `.onChange` and runs a brief
    /// flash animation so the user gets visual confirmation of the copy
    /// (mirrors Neovim's `vim.highlight.on_yank()`). `nil` means no yank
    /// has fired yet — the read pane treats nil → non-nil as the first
    /// flash trigger.
    var yankFlashAt: Date?

    /// Shared scroll coordinator for the read pane. Living here (rather
    /// than only inside ReadModeScroll's @State) gives the App-init
    /// NSEvent monitor a stable target to call into, even when the
    /// view tree hasn't constructed ReadModeScroll yet.
    let readCoordinator = ReadModeCoordinator()
    /// Permanent NSEvent monitor for read-mode scroll keys. Installed
    /// during AppState init — which is App-struct @State init time —
    /// so we beat SwiftUI's sidebar / List typeahead monitors into the
    /// NSEvent dispatch order. Marked private; only its lifetime
    /// matters here.
    #if canImport(AppKit)
    private var keyRouter: KeyRouter?
    #endif

    // MARK: Shell (explorer, palette, help, book settings)

    /// Explorer for the open book (miller columns over the note tree).
    let explorer = ExplorerModel()
    /// Command palette (⌘K, `space`, `:`).
    var showPalette = false
    /// `:` opened the palette: commands rank before notes.
    var paletteCommandMode = false
    /// Text the palette opens with ("book ", "theme ").
    var paletteSeed = ""
    /// Folder picker for "Link folder…".
    var showLinkFolder = false
    /// `?` keymap overlay.
    var showHelp = false
    /// Members / roles / invites / audit / rename / delete for the open book.
    var showBookSettings = false
    /// Small transient message (bottom of the window). Never wraps per
    /// syllable: one or two lines, fixed max width.
    var toast: ShellToast?
    /// Key → action reader for the explorer and reader.
    @ObservationIgnored var keymap = ShellKeymap()

    init() {
        let accounts = AccountsStore()
        let books = BooksRegistry(bookmarks: SwiftDataBookmarkStore(context: LumiApp.sharedContainer.mainContext))
        self.accounts = accounts
        self.books = books
        self.sync = BooksSyncEngine(accounts: accounts, registry: books)
        // Placeholder client until a bound book selects its account's.
        self.remoteVaultsStore = RemoteVaultsStore(client: LumiAPIClient())
        #if canImport(AppKit)
        // Silence the system beep app-wide. Method-swizzles
        // NSResponder.noResponderFor(_:) to a no-op so AppKit's
        // responder-chain dead-end doesn't ring NSBeep. The previous
        // attempts (NSEvent monitor returning nil) were racing
        // SwiftUI's internal monitors that beeped *before* yielding.
        BeepSilencer.install()
        keyRouter = KeyRouter(appState: self)
        #endif
        // Kick the math/diagram render service awake at launch so the
        // hidden KaTeX/Mermaid WebView finishes loading scripts in
        // the background while the user navigates. By the time the
        // first math note opens, the service is ready to render
        // immediately instead of paying ~150–300 ms of script-load
        // latency on the first request.
        MathRenderService.shared.prewarm()
    }

    // MARK: Books

    /// Load accounts, import legacy vaults once, reconcile and start feeds.
    /// Called once at launch from RootView.
    func bootstrapBooks(legacyRecords: [LegacyVaultSnapshot]) async {
        accounts.load()
        books.importIfNeeded(records: legacyRecords)
        books.reload()
        sync.onNotesChanged = { [weak self] bookID, outcome in
            guard let self, let book = self.books.book(bookID), let vault = book.vaultUUID else { return }
            Task { await self.remoteVaultsStore.applyCatchUp(outcome, vaultID: vault) }
        }
        if let active = books.activeBook {
            await selectBook(active, markOpened: false)
        }
        await sync.syncAccounts()
    }

    /// Accounts changed (sign in/out/remove): restart feeds and reconcile.
    func accountsChanged() async {
        await sync.syncAccounts()
        if let active = books.activeBook, active.kind == .bound, selectedRemoteVaultID == nil {
            await selectBook(active, markOpened: false)
        }
    }

    /// Open a book: local → folder session; bound → server vault through
    /// its own account's client.
    func selectBook(_ book: Book, markOpened: Bool = true) async {
        if editor.isDirty { editor.save() }
        selectedNoteID = nil
        selectedEntry = nil
        editor.reset()
        if selectedRemoteNoteID != nil {
            remoteVaultsStore.closeOpenNote()
            remoteEditor.reset()
            selectedRemoteNoteID = nil
        }
        keymap.reset()
        explorer.prompt = nil
        explorer.pendingDelete = nil
        if markOpened { books.setActive(book.id) } else if books.activeBookID == nil { books.setActive(book.id) }

        switch book.kind {
        case .local:
            selectedRemoteVaultID = nil
            guard let session = VaultSession.open(book: book, bookmark: books.bookmarks.bookmark(for: book.id)) else {
                setSession(nil)
                explorer.reset()
                selectedVaultID = book.id // shows the "folder unavailable" state
                return
            }
            setSession(session)
            selectedVaultID = book.id
            explorer.openLocal(root: session.rootURL, showHidden: preferences.explorerShowHidden)
        case .bound:
            setSession(nil)
            selectedVaultID = nil
            selectedRemoteVaultID = book.vaultUUID
            sync.openEditor = nil
            guard let key = book.accountKey, accounts.state(key).isSignedIn,
                  let client = accounts.client(for: key), let vault = book.vaultUUID else {
                explorer.reset()
                remoteVaultsStore.clear()
                return
            }
            explorer.openRemote(vaultID: vault)
            remoteVaultsStore.setClient(client)
            await remoteVaultsStore.refresh()
            await remoteVaultsStore.selectVault(vault)
            // The explorer needs the whole tree, not the first page.
            var pages = 0
            while remoteVaultsStore.notesHasMore, remoteVaultsStore.selectedVaultID == vault, pages < 200 {
                await remoteVaultsStore.loadMoreNotes()
                pages += 1
            }
            explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
        }
    }

    /// ⌃⌘1–9: n is 1-based, in switcher order.
    func selectBook(number n: Int) {
        let list = books.shortcutBooks
        guard n >= 1, n <= list.count else { return }
        let book = list[n - 1]
        Task { await selectBook(book) }
    }

    /// The registry row for whatever is open now.
    var openBook: Book? {
        if let id = selectedVaultID { return books.book(id) }
        if let remote = selectedRemoteVaultID { return books.book(vaultID: remote.uuidString.lowercased()) }
        return nil
    }

    /// Keep the sync engine informed of the open note's CRDT phase.
    func publishEditorPhase() {
        guard let book = openBook, book.kind == .bound, selectedRemoteNoteID != nil else {
            sync.openEditor = nil
            return
        }
        let phase = remoteVaultsStore.openNotePhase
        let pending = remoteVaultsStore.openSession?.hasPendingLocalChanges ?? remoteEditor.isDirty
        sync.openEditor = (book.id, EditorSnapshot(phase: phase, pending: pending && phase != .live))
    }

    /// Replace the active session, closing the previous one to release scope.
    func setSession(_ new: VaultSession?) {
        session?.close()
        session = new
    }

    /// Copy the current text selection to the pasteboard and trigger the
    /// read-mode yank flash. Driven by the `y` and ⌘C bindings installed
    /// by `ReadKeyMonitor` when read mode is active. Routes through
    /// `NSApp.sendAction(copy:)` so the standard responder-chain copy
    /// path runs (it picks up the active `.textSelection(.enabled)` Text
    /// view's selection — same code path Cmd-C in any other AppKit text
    /// view uses).
    func performYank() {
        #if canImport(AppKit)
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        #endif
        yankFlashAt = Date()
    }
}
