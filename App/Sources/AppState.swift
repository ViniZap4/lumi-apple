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

    var selectedVaultID: UUID?
    /// Path (vault-relative) of the currently selected note. Stored as a
    /// string so it survives across selection changes without holding a
    /// reference into the lazy folder tree. `nil` means no note open.
    var selectedNoteID: String?

    /// Lazy file-system root for the active vault. Folders enumerate their
    /// children on demand (FolderNode.loadIfNeeded) so vault-open stays
    /// cheap even when the vault has millions of notes.
    var rootFolder: FolderNode?

    /// Three-column browser state — drives the parent / current / preview
    /// columns when no note is open. Created fresh each time the active
    /// vault changes (so the cursor/path stack reset cleanly).
    var browserState: TreeBrowserState?

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

    /// Server connection state. Empty `currentSession` means the app is
    /// running in local-only mode; later phases (vault discovery, note sync)
    /// gate themselves on this being populated.
    let authService: AuthService

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

    /// Quick-switcher modal visibility. ⌘O opens a floating tree-over-note
    /// overlay so users can jump notes without leaving the current one.
    var showQuickSwitcher: Bool = false

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
    private var readKeyMonitor: ReadKeyMonitor?
    #endif

    init() {
        let auth = AuthService()
        self.authService = auth
        self.remoteVaultsStore = RemoteVaultsStore(client: auth.apiClient)
        #if canImport(AppKit)
        // Silence the system beep app-wide. Method-swizzles
        // NSResponder.noResponderFor(_:) to a no-op so AppKit's
        // responder-chain dead-end doesn't ring NSBeep. The previous
        // attempts (NSEvent monitor returning nil) were racing
        // SwiftUI's internal monitors that beeped *before* yielding.
        BeepSilencer.install()
        installReadKeyMonitor()
        #endif
        // Kick the math/diagram render service awake at launch so the
        // hidden KaTeX/Mermaid WebView finishes loading scripts in
        // the background while the user navigates. By the time the
        // first math note opens, the service is ready to render
        // immediately instead of paying ~150–300 ms of script-load
        // latency on the first request.
        MathRenderService.shared.prewarm()
    }

    #if canImport(AppKit)
    private func installReadKeyMonitor() {
        let coord = readCoordinator
        readKeyMonitor = ReadKeyMonitor(
            isActive: { [weak self] in
                guard let self else { return false }
                return self.editorMode == .view
                    && self.selectedEntry != nil
                    && self.preferences.jkScrollInView
            },
            glide: { coord.glide(by: CGFloat($0)) },
            halfPage: { coord.scrollHalfPage(direction: CGFloat($0)) },
            fullPage: { coord.scrollFullPage(direction: CGFloat($0)) },
            scrollToEdge: { coord.scrollTo($0) },
            closeNote: { [weak self] in
                guard let self else { return }
                if self.editor.isDirty { self.editor.save() }
                self.selectedEntry = nil
                self.selectedNoteID = nil
            },
            yankSelected: { [weak self] in
                self?.performYank()
            }
        )
    }
    #endif

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
