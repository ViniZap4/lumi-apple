import SwiftUI
import LumiKit
import LumiUI

/// The note area: one pane, or the split tree (SPEC-PARTE2 §3). The
/// primary pane keeps the full single-note machinery (note bar, banners,
/// split preview); the others are `SecondaryNotePane`s.
struct NoteArea: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let tree = appState.visibleLayout
        if tree.notePanes.count <= 1 {
            PrimaryNoteContent()
                .registerPaneFrame(tree.mainLeaf)
        } else {
            PaneLayoutView(root: tree.root, focused: appState.focusedLeaf, showsFocus: true,
                           onResize: { path, i, at in appState.resizeDivider(path: path, index: i, at: at) }) { id, content in
                if id == tree.mainLeaf {
                    VStack(spacing: 0) {
                        NoteBar()
                        PrimaryNoteContent()
                    }
                    .registerPaneFrame(id)
                } else if case let .note(path, view) = content {
                    SecondaryNotePane(leaf: id, path: path, view: view)
                        .registerPaneFrame(id)
                } else {
                    theme.background
                }
            }
        }
    }
}

extension View {
    /// Remember the pane's window frame: a click focuses the pane.
    func registerPaneFrame(_ id: PaneLeafID) -> some View {
        modifier(PaneFrameModifier(id: id))
    }
}

private struct PaneFrameModifier: ViewModifier {
    let id: PaneLeafID
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            appState.paneGlobalFrames[id] = frame
        }
    }
}

/// The primary pane's note (local or server), exactly as before splits.
struct PrimaryNoteContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let entry = appState.selectedEntry, let session = appState.session {
            NoteDetailView(entry: entry, baseURL: entry.url.deletingLastPathComponent(), vaultRoot: session.rootURL)
                .transition(appState.transition(.opacity.combined(with: .offset(y: 8))))
        } else if let remoteID = appState.selectedRemoteVaultID,
                  let remote = appState.remoteVaultsStore.vaults.first(where: { $0.id == remoteID }),
                  let noteID = appState.selectedRemoteNoteID,
                  let row = appState.remoteVaultsStore.notes.first(where: { $0.id == noteID }) {
            RemoteNoteDetailView(vault: remote, listRow: row)
                .id(noteID)
                .transition(appState.transition(.opacity.combined(with: .offset(y: 8))))
        } else {
            NoteSkeleton()
        }
    }
}

/// Shimmering placeholder lines while a note loads.
struct NoteSkeleton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.text.opacity(0.07))
                    .frame(width: i == 0 ? 260 : CGFloat([520, 480, 560, 300, 500, 420][(i - 1) % 6]), height: i == 0 ? 22 : 11)
            }
        }
        .overlay {
            if appState.motionEnabled {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, theme.text.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: phase * geo.size.width)
                }
                .mask(VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<7, id: \.self) { _ in RoundedRectangle(cornerRadius: 4).frame(height: 11) }
                })
                .allowsHitTesting(false)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard appState.motionEnabled else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.4 }
        }
        .accessibilityLabel("Loading note")
    }
}

/// A secondary pane: its own reader / editor / registered view of one
/// note, with the document (local buffer or live replica) from the pool —
/// two panes on one note share one.
struct SecondaryNotePane: View {
    let leaf: PaneLeafID
    let path: String
    let view: NoteViewMode

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var local: EditorState?
    @State private var session: OpenNoteSession?
    @State private var restText: String?
    @State private var restError: String?
    @State private var reader = ReadModeCoordinator()
    @State private var generation = 0

    private var row: RemoteNote? {
        appState.remoteVaultsStore.notes.first { $0.path == path || $0.id == path }
    }

    private var text: String {
        if let local { return local.currentText }
        if let s = session, s.hasSynced { return s.text }
        return restText ?? ""
    }

    private var title: String {
        if let t = local?.frontmatter.title, !t.isEmpty { return t }
        if let t = row?.title, !t.isEmpty { return t }
        return NoteTree.stem(path)
    }

    private var kind: NoteKind { NoteKind.detect(path: path, text: String(text.prefix(2048))) }
    private var focused: Bool { appState.focusedLeaf == leaf }
    private var canEdit: Bool { appState.canWritePane(path) }

    var body: some View {
        let resolution = AppState.noteViews.resolve(kind, view)
        VStack(spacing: 0) {
            PaneHeaderBar(title: title, folder: NoteTree.dirOf(path), views: AppState.noteViews.views(for: kind),
                          selection: resolution?.view ?? view, canEdit: canEdit, focused: focused,
                          badge: local?.isDirty == true ? "modified" : nil,
                          onSelect: { appState.setPaneView(leaf, $0) },
                          onClose: { appState.closeLeaf(leaf) })
            content(resolution?.route ?? .reader, resolved: resolution?.view ?? view)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .id("\(path)#\(resolution?.view.rawValue ?? "")")
                .transition(appState.transition(.opacity))
        }
        .background(theme.background)
        .task(id: "\(path)#\(generation)") { bind() }
        .onDisappear { unbind() }
        .onChange(of: session.map { $0.isDestroyed || $0.termination == .lineageChanged } ?? false) { _, dead in
            if dead { generation += 1 }
        }
        .animation(appState.animation(.fast), value: view)
    }

    @ViewBuilder
    private func content(_ route: NoteRoute, resolved: NoteViewMode) -> some View {
        switch route {
        case .reader:
            readerView
        case let .editor(live):
            editorView(live: live)
        case let .custom(mode):
            let ctx = appState.noteViewContext(view: mode, kind: kind, path: path, leaf: leaf, text: text)
            if let v = NoteViewHooks.view(ctx) { v } else { readerView }
        }
    }

    private var readerView: some View {
        Group {
            if text.isEmpty, local == nil, restError == nil, !(session?.hasSynced ?? false) {
                NoteSkeleton()
            } else if let restError, text.isEmpty {
                Text(restError)
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.textDim)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MarkdownReader(
                    title: title,
                    tags: local?.frontmatter.tags ?? [],
                    text: text,
                    noteURL: localURL,
                    baseURL: localURL?.deletingLastPathComponent(),
                    vaultRoot: appState.session?.rootURL,
                    isDirty: local?.isDirty ?? false,
                    scale: appState.preferences.readingScale,
                    fontFamily: appState.preferences.readingFontFamily.markdownFamily,
                    readingWidth: appState.preferences.readingWidth,
                    onInAppLink: { url in appState.routeReaderURL(url, from: leaf) },
                    onToggleTask: canEdit ? { appState.togglePaneTask($0, leaf: leaf, path: path) } : nil
                )
                .environment(\.markdownScrollViewSink, MarkdownScrollViewSink { scroll in
                    reader.attach(scrollView: scroll)
                    appState.paneReaders[leaf] = reader
                })
                .environment(\.markdownLinkHover, appState.linkHover(from: leaf))
            }
        }
    }

    @ViewBuilder
    private func editorView(live: Bool) -> some View {
        if let local {
            if appState.preferences.vimEnabled {
                VimEditor(
                    text: Binding(get: { local.currentText }, set: { local.currentText = $0 }),
                    onModeChange: { _ in },
                    onEffect: { appState.handlePaneEffect($0, leaf: leaf, path: path) },
                    jjEscapeEnabled: appState.preferences.jjEscapeMapping,
                    showLineNumbers: appState.preferences.showLineNumbers,
                    relativeLineNumbers: appState.preferences.relativeLineNumbers,
                    options: appState.vimEditorOptions,
                    vimrc: appState.preferences.parsedVimrc,
                    blockCursor: appState.preferences.vimBlockCursor,
                    fileName: path,
                    onStatusChange: { appState.paneVim[leaf] = $0 }
                )
                .presentation(live ? appState.livePresentation(baseURL: localURL?.deletingLastPathComponent(),
                                                               vaultRoot: appState.session?.rootURL, live: true) : .source,
                              onOpenLink: { appState.openLiveLink($0, from: leaf) })
                .onHoverLink { link, rect in appState.liveLinkHovered(link, rect: rect, from: leaf) }
                .readableEditorWidth(!live)
                .environment(\.vimControllerSink) { appState.adoptPaneEditor($0, leaf: leaf) }
            } else {
                PlainTextEditor(text: Binding(get: { local.currentText }, set: { local.currentText = $0 }))
            }
        } else if let s = session, s.isEditable {
            VimEditor(
                document: appState.docView(for: s, owner: "leaf\(leaf.raw)"),
                vimEnabled: appState.preferences.vimEnabled,
                onModeChange: { _ in },
                onEffect: { appState.handlePaneEffect($0, leaf: leaf, path: path) },
                jjEscapeEnabled: appState.preferences.jjEscapeMapping,
                showLineNumbers: appState.preferences.showLineNumbers,
                relativeLineNumbers: appState.preferences.relativeLineNumbers,
                options: appState.vimEditorOptions,
                vimrc: appState.preferences.parsedVimrc,
                blockCursor: appState.preferences.vimBlockCursor,
                fileName: path,
                onStatusChange: { appState.paneVim[leaf] = $0 }
            )
            .presentation(live ? appState.livePresentation(baseURL: nil, vaultRoot: nil, live: true) : .source,
                          onOpenLink: { appState.openLiveLink($0, from: leaf) })
            .onHoverLink { link, rect in appState.liveLinkHovered(link, rect: rect, from: leaf) }
            .readableEditorWidth(!live)
            .environment(\.vimControllerSink) { appState.adoptPaneEditor($0, leaf: leaf) }
            .id(ObjectIdentifier(s))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if session?.termination == nil, canEdit { ProgressView().controlSize(.small) }
                    Text(canEdit ? "connecting to live editing…" : "read-only — note.write required")
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.textDim)
                }
                readerView
            }
            .padding(.top, 10)
        }
    }

    private var localURL: URL? {
        guard case let .local(root) = appState.explorer.source else { return nil }
        return try? LumiOpenURL.localNoteURL(path, in: root)
    }

    // MARK: Documents

    private func bind() {
        unbind()
        switch appState.explorer.source {
        case let .local(root):
            guard let s = appState.session, let url = try? LumiOpenURL.localNoteURL(path, in: root) else { return }
            let p = path
            local = appState.localDocs.acquire(p) {
                let e = EditorState()
                e.load(noteID: p, at: url, vaultRoot: s.rootURL)
                return e
            }
        case let .remote(vault):
            guard let row else { return }
            if LumiCRDT.isSupported, appState.can("note.write") {
                session = appState.remoteVaultsStore.acquireSession(vaultID: vault, noteID: row.id, user: appState.awarenessUser)
            }
            if session?.hasSynced != true {
                let store = appState.remoteVaultsStore
                let id = row.id
                Task { @MainActor in
                    do {
                        restText = try await store.noteBody(noteID: id)
                    } catch {
                        restError = appState.describe(error)
                    }
                }
            }
        case .none:
            break
        }
    }

    private func unbind() {
        if let local, let id = local.noteID {
            appState.localDocs.release(id, session: local, defer: true)
        }
        local = nil
        if let s = session {
            appState.fanoutViews = appState.fanoutViews.filter { !$0.key.hasPrefix("leaf\(leaf.raw)#") }
            appState.remoteVaultsStore.releaseSession(s, defer: true)
        }
        session = nil
    }
}

// MARK: - Secondary pane behaviour

extension AppState {
    func adoptPaneEditor(_ controller: VimController, leaf: PaneLeafID) {
        paneEditors[leaf] = WeakVimController(controller)
        controller.paneKeys.ctrlHJKL = preferences.ctrlHJKLPanes
        controller.onPaneCommand = { [weak self] command in self?.performPane(command) ?? false }
        controller.onFocus = { [weak self] in self?.noteSecondaryFocus(leaf) }
        controller.onFollowLink = { [weak self] link in
            self?.openLink(link.href, where: .current, from: leaf, wiki: link.wiki)
            return true
        }
        if secondaryFocus == leaf { controller.focusTextView() }
    }

    /// `:w`, `:q`, `:wq`, ex host commands from a secondary pane's editor.
    func handlePaneEffect(_ effect: VimEffect, leaf: PaneLeafID, path: String) {
        let local = localDocs.peek(path)
        switch effect {
        case .save:
            local?.save()
        case let .saveAndClose(force):
            if force { local?.forceSave() } else { local?.save() }
            setPaneView(leaf, .reading)
        case let .close(force):
            // `:q` closes the pane (SPEC-PARTE2 §3); a dirty local buffer
            // another pane does not show refuses unless `:q!`.
            if !force, let local, local.isDirty, localDocs.refCount(path) <= 1 {
                showToast("unsaved changes — :w first, or :q! to discard", tone: .warning)
                return
            }
            if force, let local, localDocs.refCount(path) <= 1 { local.discard() }
            closeLeaf(leaf)
        case .scrollCursor, .scrollLines, .displayLines:
            break
        case let .host(command):
            noteSecondaryFocus(leaf)
            performHostCommand(command)
        }
    }

    /// Task checkbox in a secondary reader: one ranged edit.
    func togglePaneTask(_ index: Int, leaf: PaneLeafID, path: String) {
        if let editor = paneEditors[leaf]?.value, paneView(leaf).isEditing, editor.isEditable,
           let edit = MarkdownTasks.toggle(in: editor.buffer.text, index: index) {
            editor.applyProgrammaticEdit(edit)
            return
        }
        if let local = localDocs.peek(path) {
            guard let edit = MarkdownTasks.toggle(in: local.currentText, index: index) else { return }
            local.currentText = TextEdit.apply([edit], to: local.currentText)
            if !paneView(leaf).isEditing { local.save() }
            return
        }
        guard case let .remote(vault) = explorer.source,
              let row = remoteVaultsStore.notes.first(where: { $0.path == path || $0.id == path }),
              let s = remoteVaultsStore.pooledSession(vaultID: vault, noteID: row.id), s.isEditable,
              let edit = MarkdownTasks.toggle(in: s.text, index: index) else {
            showToast("not connected yet — try again in a moment", tone: .warning)
            return
        }
        fanout(for: s).applyExternal([edit])
    }

    /// Keys in a focused secondary reader.
    func performSecondaryReader(_ action: ShellAction, leaf: PaneLeafID) -> Bool {
        if performShared(action) { return true }
        let c = paneReaders[leaf] ?? readCoordinator
        let view = c.scrollView
        switch action {
        case let .move(n): c.glide(by: CGFloat(22 * n))
        case let .halfPage(d): c.scrollHalfPage(direction: CGFloat(d))
        case let .page(d): c.scrollFullPage(direction: CGFloat(d))
        case .top: c.scrollTo(.top)
        case .bottom: c.scrollTo(.bottom)
        case .nextHeading: jumpHeading(next: true, in: view, coordinator: c)
        case .prevHeading: jumpHeading(next: false, in: view, coordinator: c)
        case .find: MarkdownReading.find(.show, in: view)
        case .nextMatch: MarkdownReading.find(.next, in: view)
        case .prevMatch: MarkdownReading.find(.previous, in: view)
        case .edit: setPaneView(leaf, preferences.editMode == .live ? .live : .source)
        case .close: closeLeaf(leaf)
        case .clearOrBack, .parent: _ = MarkdownReading.closeFind(in: view)
        case .explore: openFloatingExplorer()
        case .books: openFloatingExplorer(level: .books)
        case .hover: hoverFromKeyboard()
        case .follow, .open: followLinkInFocusedPane(.current)
        case .yank:
            if !MarkdownReading.copySelection(in: view) { showToast("select text to copy") }
        default: return false
        }
        return true
    }
}
