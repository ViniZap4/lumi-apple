import SwiftUI
import LumiKit
import LumiUI

/// Three-column file browser modeled on yazi / TUI's tree view.
///   ┌──────────┬────────────┬──────────┐
///   │ parent   │ current    │ preview  │
///   ├──────────┼────────────┼──────────┤
///   │ items    │ items+cur  │ details  │
///   └──────────┴────────────┴──────────┘
///
/// Keyboard nav (vim-style, gated on `preferences.vimNavigationInList`):
///   j / k                — move cursor in current column
///   l / Enter            — dive into folder OR open note
///   h / Esc              — back to parent column
///   gg / G               — top / bottom of current column
///
/// Mouse: tap a row to position the cursor; tap again to enter (or
/// double-click). The preview pane updates live as the cursor moves.
struct TreeBrowserView: View {
    @Bindable var state: TreeBrowserState
    let vaultName: String
    let onOpen: (NoteEntry) -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @FocusState private var focused: Bool

    /// User-resizable column widths. Persisted only for the session; if the
    /// user wants different defaults each launch we can stash these in
    /// LumiPreferences in a follow-up.
    @State private var parentColumnWidth: CGFloat = 220
    @State private var previewColumnWidth: CGFloat = 420
    /// Scroll coordinator for the preview column so uppercase J/K can
    /// glide the preview without the cursor leaving the current
    /// column. Same ReadModeCoordinator used by the note pane —
    /// shared smooth-scroll behaviour.
    @State private var previewCoord = ReadModeCoordinator()
    /// File-operation modal state. `nil` means no sheet; non-nil
    /// surfaces a single text-field input that handles create-note,
    /// create-folder, and rename in one place.
    @State private var fileOpInput: FileOpInput?
    /// Pending delete confirmation. Two-state model: nil = no prompt,
    /// otherwise the alert shows with the captured item.
    @State private var pendingDelete: FolderNode.Item?
    /// Surfaces filesystem errors from a failed op so the user gets
    /// feedback instead of silent failure.
    @State private var fileOpError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.border)
            HStack(spacing: 0) {
                parentColumn
                    .frame(width: parentColumnWidth)
                    .id("parent-\(state.pathStack.count)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                resizer(width: $parentColumnWidth, min: 160, max: 360)
                currentColumn
                    .frame(maxWidth: .infinity)
                    .id("current-\(state.pathStack.count)")
                resizer(width: $previewColumnWidth, min: 280, max: 700, dragFromRight: true)
                previewColumn
                    .frame(width: previewColumnWidth)
            }
            .animation(.easeInOut(duration: 0.16), value: state.pathStack.count)
        }
        .background(theme.background)
        .sheet(item: $fileOpInput) { op in
            FileOpInputSheet(op: op, onCommit: { applyFileOp(op, name: $0) })
                .environment(\.theme, theme)
        }
        .alert(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { performDelete(item) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            if case .folder = item {
                Text("This folder and all its contents will be moved to the Trash.")
            } else {
                Text("This note will be moved to the Trash.")
            }
        }
        .alert(
            "File operation failed",
            isPresented: Binding(get: { fileOpError != nil }, set: { if !$0 { fileOpError = nil } })
        ) {
            Button("OK", role: .cancel) { fileOpError = nil }
        } message: {
            Text(fileOpError ?? "")
        }
        #if os(macOS)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        // `.repeat` catches auto-fired keydowns when the user holds
        // j / k — without it, navigation steps once per discrete press
        // and the user has to mash the key to traverse a long folder.
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKey(press)
        }
        #endif
    }

    // MARK: - Columns

    @ViewBuilder
    private var parentColumn: some View {
        ColumnContainer(width: nil) {
            if let parent = state.parentFolder {
                ColumnList(
                    items: parent.items ?? [],
                    highlightedID: "folder:" + state.currentFolder.relativePath,
                    cursorIsActive: false,
                    cadence: .parent,
                    onTap: { item in
                        // Clicking a parent-column row navigates back to
                        // that folder. Lets users jump up the breadcrumb
                        // without keyboard.
                        if case .folder = item, item.id == "folder:" + state.currentFolder.relativePath {
                            _ = state.goBack()
                        }
                    }
                )
            } else {
                Text(vaultName)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var currentColumn: some View {
        ColumnContainer(width: nil) {
            ColumnList(
                items: state.currentItems,
                highlightedID: state.selectedItem?.id,
                cursorIsActive: true,
                onTap: { item in
                    // Single click moves cursor *and* activates — finder /
                    // yazi feel. For folders this means one click descends;
                    // for notes one click opens. Keyboard nav still uses
                    // l/Enter explicitly.
                    state.setCursor(toItemID: item.id)
                    activate(item)
                },
                onActivate: { item in
                    activate(item)
                }
            )
        }
    }

    @ViewBuilder
    private var previewColumn: some View {
        ColumnContainer(width: nil) {
            PreviewPane(
                item: state.selectedItem,
                baseURL: previewBaseURL,
                coordinator: previewCoord
            )
        }
    }

    /// For note previews, resolve relative markdown links/images against
    /// the note's own directory. nil for folders (they don't render bodies).
    private var previewBaseURL: URL? {
        guard let item = state.selectedItem, case let .note(n) = item else { return nil }
        return n.url.deletingLastPathComponent()
    }

    @ViewBuilder
    private func resizer(width: Binding<CGFloat>, min: CGFloat, max: CGFloat, dragFromRight: Bool = false) -> some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
            .overlay {
                // Wider invisible hit target around the hairline divider so
                // grabbing it isn't pixel-perfect work.
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    #endif
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let delta = dragFromRight
                                    ? -value.translation.width
                                    : value.translation.width
                                let next = width.wrappedValue + delta
                                if next >= min && next <= max {
                                    width.wrappedValue = next
                                }
                            }
                    )
            }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            // Breadcrumb starting at "vault / sub / sub". Skip the lumi
            // wordmark — the toolbar above already identifies the app.
            Text(vaultName)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            ForEach(Array(state.currentFolder.relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .enumerated()), id: \.offset) { _, comp in
                Text("›")
                    .foregroundStyle(theme.textDim)
                Text(String(comp))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text)
            }
            Spacer()
            Text("\(state.currentItems.count) items")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.overlayBackground)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    // MARK: - Key handling

    private func activate(_ item: FolderNode.Item) {
        switch item {
        case .folder(let f):
            state.pathStack.append(f)
            Task { await f.loadIfNeededAsync() }
            // Resets the cursor for the new folder unless we remembered it.
            // State.cursor getter/setter handles the lookup.
        case .note(let n):
            onOpen(n)
        }
    }

    #if os(macOS)
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard appState.preferences.vimNavigationInList else { return .ignored }
        // Uppercase variants (Shift + J/K) glide the preview column
        // without disturbing the cursor in the current column —
        // mirrors yazi's behaviour where you can peek deeper into a
        // long preview while still moving in the active list.
        if press.modifiers.contains(.shift) {
            switch press.characters {
            case "J":
                previewCoord.glide(by: 60); return .handled
            case "K":
                previewCoord.glide(by: -60); return .handled
            case "G":
                state.moveCursorToEnd(); return .handled
            default: break
            }
        }
        switch press.characters {
        case "j":
            state.moveCursor(by: 1); return .handled
        case "k":
            state.moveCursor(by: -1); return .handled
        case "l", "\r", " ":
            if let n = state.enterSelection() { onOpen(n) }
            return .handled
        case "h":
            goBackOrHome(); return .handled
        case "g":
            state.moveCursorToStart(); return .handled
        case "G":
            state.moveCursorToEnd(); return .handled
        // File ops (mirror TUI bindings)
        case "n":
            fileOpInput = FileOpInput(kind: .createNote, target: state.currentFolder.url, prefill: "")
            return .handled
        case "N":
            fileOpInput = FileOpInput(kind: .createFolder, target: state.currentFolder.url, prefill: "")
            return .handled
        case "r":
            if let item = state.selectedItem {
                fileOpInput = FileOpInput(kind: .rename, target: itemURL(item), prefill: item.name)
            }
            return .handled
        case "d":
            if let item = state.selectedItem { pendingDelete = item }
            return .handled
        case "D":
            if let item = state.selectedItem, case let .note(n) = item {
                performDuplicate(noteURL: n.url)
            }
            return .handled
        default:
            switch press.key {
            case .upArrow: state.moveCursor(by: -1); return .handled
            case .downArrow: state.moveCursor(by: 1); return .handled
            case .leftArrow: goBackOrHome(); return .handled
            case .rightArrow:
                if let n = state.enterSelection() { onOpen(n) }
                return .handled
            case .escape, .delete:
                // Both Esc and Backspace walk up the folder stack;
                // Backspace mirrors macOS Finder's "go to parent".
                goBackOrHome(); return .handled
            default: return .ignored
            }
        }
    }

    /// Walk up one folder; if already at the vault root, land on the
    /// home pane (clear the selected vault). Mirrors what users expect
    /// from a yazi-style back chain that ends at the home screen.
    private func goBackOrHome() {
        if !state.goBack() {
            appState.selectedVaultID = nil
            appState.selectedRemoteVaultID = nil
            appState.browserState = nil
            appState.rootFolder = nil
            appState.setSession(nil)
        }
    }

    // MARK: - File operations

    private func itemURL(_ item: FolderNode.Item) -> URL {
        switch item {
        case .folder(let f): return f.url
        case .note(let n): return n.url
        }
    }

    /// Dispatches the sheet's submitted name into the matching
    /// FileOperations call and refreshes the active folder so the
    /// browser reflects the change.
    private func applyFileOp(_ op: FileOpInput, name: String) {
        do {
            switch op.kind {
            case .createNote:
                let url = try FileOperations.createNote(in: op.target, title: name)
                reloadCurrent()
                selectByURL(url)
            case .createFolder:
                _ = try FileOperations.createFolder(in: op.target, name: name)
                reloadCurrent()
            case .rename:
                let stem = (op.target.pathExtension.lowercased() == "md")
                    ? op.target.deletingPathExtension().lastPathComponent
                    : op.target.lastPathComponent
                if name == stem || name == op.target.lastPathComponent {
                    fileOpInput = nil
                    return
                }
                let newURL = try FileOperations.rename(at: op.target, to: name)
                reloadCurrent()
                selectByURL(newURL)
            }
            fileOpInput = nil
        } catch {
            fileOpError = (error as? FileOperations.Error)?.errorDescription
                ?? error.localizedDescription
            fileOpInput = nil
        }
    }

    private func performDelete(_ item: FolderNode.Item) {
        defer { pendingDelete = nil }
        do {
            try FileOperations.delete(at: itemURL(item))
            reloadCurrent()
        } catch {
            fileOpError = (error as? FileOperations.Error)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func performDuplicate(noteURL: URL) {
        do {
            let newURL = try FileOperations.duplicateNote(at: noteURL)
            reloadCurrent()
            selectByURL(newURL)
        } catch {
            fileOpError = (error as? FileOperations.Error)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Drops the cached items on the current folder + re-walks disk so
    /// the browser shows the new state. Async-reload so the UI doesn't
    /// stutter on slow volumes.
    private func reloadCurrent() {
        let folder = state.currentFolder
        Task { await folder.reloadAsync() }
    }

    /// After a create / duplicate / rename, move the cursor onto the
    /// new (or renamed) item so the user sees what they just made.
    private func selectByURL(_ url: URL) {
        let folder = state.currentFolder
        Task {
            // Wait one runloop cycle for the reload to land.
            try? await Task.sleep(nanoseconds: 50_000_000)
            await folder.reloadAsync()
            if let items = folder.items {
                if let match = items.firstIndex(where: { itemMatchesURL($0, url: url) }) {
                    state.cursor = match
                }
            }
        }
    }

    private func itemMatchesURL(_ item: FolderNode.Item, url: URL) -> Bool {
        switch item {
        case .folder(let f): return f.url.standardizedFileURL == url.standardizedFileURL
        case .note(let n): return n.url.standardizedFileURL == url.standardizedFileURL
        }
    }
    #endif
}

// MARK: - Column container

private struct ColumnContainer<Content: View>: View {
    /// nil → expand to fill remaining space (used for the "current" column).
    let width: CGFloat?
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let width {
                content().frame(width: width)
            } else {
                content().frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.background)
    }
}

// MARK: - File operation input sheet

/// Sheet state for create-note / create-folder / rename. One struct
/// keeps the three flows in a single `.sheet(item:)` modifier and
/// drives the title prompt, prefill value, and target path.
struct FileOpInput: Identifiable {
    enum Kind { case createNote, createFolder, rename }
    let id = UUID()
    let kind: Kind
    /// For create flows this is the parent folder URL. For rename it's
    /// the item's own URL.
    let target: URL
    let prefill: String

    var title: String {
        switch kind {
        case .createNote: return "New note"
        case .createFolder: return "New folder"
        case .rename: return "Rename"
        }
    }

    var placeholder: String {
        switch kind {
        case .createNote: return "Title"
        case .createFolder: return "Folder name"
        case .rename: return "Name"
        }
    }

    var confirmLabel: String {
        switch kind {
        case .createNote, .createFolder: return "Create"
        case .rename: return "Rename"
        }
    }
}

/// Minimal text-field sheet for the three file-op flows. Returns the
/// trimmed name via `onCommit`; cancelled / empty inputs close the
/// sheet without dispatching.
private struct FileOpInputSheet: View {
    let op: FileOpInput
    let onCommit: (String) -> Void

    @State private var value: String
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    init(op: FileOpInput, onCommit: @escaping (String) -> Void) {
        self.op = op
        self.onCommit = onCommit
        _value = State(initialValue: op.prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(op.title)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            TextField(op.placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(op.confirmLabel) { submit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(theme.background)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

// MARK: - Generic column list

/// Cadence for a column's row mount cascade. Letting parent / current /
/// preview tune their own delays makes the navigation read as
/// "current column leads, parent and preview follow" instead of
/// "everything cascades at the same pace".
enum ColumnRowCadence {
    /// Active column — fastest cascade, leads the visual hierarchy.
    case current
    /// Parent column — secondary; longer per-row delay so it reads as
    /// "settling into place" behind the current column.
    case parent
    /// Preview pane — single block (not per-row) so use a tiny step.
    case preview

    var stepDelay: Double {
        switch self {
        case .current: return 0.010
        case .parent: return 0.022
        case .preview: return 0.0
        }
    }

    var initialDelay: Double {
        switch self {
        case .current: return 0.0
        case .parent: return 0.06
        case .preview: return 0.04
        }
    }

    var duration: Double {
        switch self {
        case .current: return 0.22
        case .parent: return 0.30
        case .preview: return 0.24
        }
    }

    var delayCap: Double {
        switch self {
        case .current: return 0.18
        case .parent: return 0.32
        case .preview: return 0.04
        }
    }
}

/// Per-row mount animation. Each row fades + slides into place when it
/// first appears in the LazyVStack, with a per-index delay so the
/// column reads as cascading in from the top. The cadence parameter
/// lets columns differentiate (parent column trails current, etc.).
/// Unmount (column swap on h / l navigation) is handled by SwiftUI's
/// implicit removal of the parent column under `.animation`.
private struct ColumnRowMount<Content: View>: View {
    let index: Int
    let animated: Bool
    var cadence: ColumnRowCadence = .current
    @ViewBuilder let content: () -> Content
    @State private var visible = false

    var body: some View {
        let delay = cadence.initialDelay + min(Double(index) * cadence.stepDelay, cadence.delayCap)
        content()
            .opacity(visible ? 1 : (animated ? 0 : 1))
            .offset(x: visible ? 0 : (animated ? -6 : 0))
            .onAppear {
                guard animated else { visible = true; return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: cadence.duration).delay(delay)) {
                        visible = true
                    }
                }
            }
    }
}

private struct ColumnList: View {
    let items: [FolderNode.Item]
    let highlightedID: String?
    let cursorIsActive: Bool
    var cadence: ColumnRowCadence = .current
    let onTap: (FolderNode.Item) -> Void
    var onActivate: ((FolderNode.Item) -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        if items.isEmpty {
            Text("(empty)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ColumnRowMount(index: index, animated: animateRows, cadence: cadence) {
                                row(item: item, isHighlighted: item.id == highlightedID)
                                    .onTapGesture(count: 2) {
                                        onTap(item)
                                        onActivate?(item)
                                    }
                                    .onTapGesture(count: 1) {
                                        onTap(item)
                                    }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlightedID) { _, newID in
                    if let newID {
                        withAnimation(.linear(duration: 0.04)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @Environment(AppState.self) private var appState
    /// Disable the cascade entirely when the user has turned content
    /// animations off in Settings — keeps the navigation snappy for
    /// users who prefer no motion.
    private var animateRows: Bool { appState.preferences.contentAnimations }

    @ViewBuilder
    private func row(item: FolderNode.Item, isHighlighted: Bool) -> some View {
        // When the row is "lit up" (active-column selection) the bg becomes
        // a strong accent fill, so text/icons need to flip to the background
        // color for legible contrast — same trick web/TUI use.
        let isActiveSelection = isHighlighted && cursorIsActive
        let primaryFg = isActiveSelection ? theme.background : theme.text
        let secondaryFg = isActiveSelection ? theme.background.opacity(0.85) : theme.textDim

        HStack(spacing: 8) {
            Image(systemName: icon(for: item))
                .foregroundStyle(isActiveSelection ? theme.background : iconColor(for: item))
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(primaryFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .note(let n) = item {
                    Text(n.updatedAt.formatted(.relative(presentation: .numeric)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(secondaryFg)
                }
            }
            Spacer(minLength: 0)
            if case .folder = item {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(isActiveSelection ? theme.background : theme.textDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            // Solid background pill for the active selection. The earlier
            // border-around-row look made the cursor read as outlined; a
            // filled bg matches the web/TUI feel where the cursor row is
            // the loudest thing on the screen.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHighlighted ? rowBackground : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func iconColor(for item: FolderNode.Item) -> Color {
        switch item {
        case .folder: return theme.accent.opacity(0.85)
        case .note: return theme.textDim
        }
    }

    private var rowAccent: Color {
        cursorIsActive ? theme.background : theme.textDim
    }

    private var rowBackground: Color {
        if cursorIsActive {
            // Strong tinted bg for the active-column selection — reads as
            // "you are here" without needing an outline.
            return theme.accent.opacity(0.85)
        }
        // Dim parent-column highlight so the eye lands on the active column.
        return theme.overlayBackground.opacity(0.6)
    }

    private func icon(for item: FolderNode.Item) -> String {
        switch item {
        case .folder: return "folder"
        case .note: return "doc.text"
        }
    }
}

// MARK: - Preview pane

private struct PreviewPane: View {
    let item: FolderNode.Item?
    let baseURL: URL?
    /// Driven by uppercase J/K in the parent browser so the user can
    /// glide the preview without leaving the active column.
    let coordinator: ReadModeCoordinator
    @Environment(\.theme) private var theme
    @State private var noteExcerpt: NoteExcerpt?
    /// Cached parse of the current excerpt. Body re-renders no longer
    /// pay the parse cost — that work happens once per selection on
    /// a detached task and is memoized here.
    @State private var previewDocument: MarkdownDocument?
    /// Identity token for the in-flight parse. Stale parses bail out
    /// when they finish so a fast cursor sweep doesn't flash older
    /// content onto a newer selection.
    @State private var previewToken: UUID = UUID()

    var body: some View {
        // Wrapped in NSScrollView via NativeScrollHost so the
        // ReadModeCoordinator can call `glide` / `scrollTo` against
        // it; SwiftUI's ScrollView has no equivalent programmatic
        // scroll API on macOS 15.
        NativeScrollHost(coordinator: coordinator) {
            VStack(alignment: .leading, spacing: 8) {
                switch item {
                case nil:
                    Text("(no selection)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                case .folder(let f):
                    folderPreview(f)
                case .note(let n):
                    notePreview(n)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: itemID) { _, _ in
            // Drop the previous note excerpt so we don't show stale content
            // while the new one loads.
            noteExcerpt = nil
            handleItemChange()
        }
        .onAppear {
            handleItemChange()
        }
    }

    /// Side-effects when the selected item changes: kick off a folder load
    /// or a note excerpt read. Folders auto-load so the user doesn't have
    /// to click "Peek into folder".
    private func handleItemChange() {
        let token = UUID()
        previewToken = token
        previewDocument = nil
        switch item {
        case .folder(let f):
            Task { await f.loadIfNeededAsync() }
        case .note(let n):
            // Two-stage debounce + async work so the cursor stays
            // responsive when the user holds j/k through a folder of
            // large notes:
            //   1. Sleep ~120 ms before touching disk. If the user
            //      moves on within that window, the token mismatches
            //      and we bail before doing any work — no thrashing
            //      I/O or AST parses on items the user skipped.
            //   2. Read + parse on a detached task so the main actor
            //      isn't held for the (up to) 1 MB file plus the
            //      markdown walk. Token-check again before publishing.
            let url = n.url
            let baseURL = self.baseURL
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                let stillCurrent = await MainActor.run { previewToken == token }
                guard stillCurrent else { return }
                let excerpt = NoteExcerpt.load(from: url)
                let document: MarkdownDocument?
                if let body = excerpt?.bodyExcerpt {
                    document = MarkdownParser.parse(body, baseURL: baseURL)
                } else {
                    document = nil
                }
                await MainActor.run {
                    guard previewToken == token else { return }
                    noteExcerpt = excerpt
                    previewDocument = document
                }
            }
        case nil:
            break
        }
    }

    private var itemID: String { item?.id ?? "" }

    @ViewBuilder
    private func folderPreview(_ f: FolderNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(theme.accent)
                    Text(f.name)
                        .font(.system(.title3, design: .default).weight(.semibold))
                        .foregroundStyle(theme.text)
                }
                Text("/" + f.relativePath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Rectangle().fill(theme.border).frame(height: 0.5)

            // Folders auto-load now (see PreviewPane.handleItemChange) —
            // no more "Peek into folder" button. While loading we show a
            // small ProgressView; once items are in we render them inline.
            if f.items == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("scanning…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            } else if let items = f.items {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                    Text("\(items.count) items")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items.prefix(30)) { sub in
                        HStack(spacing: 6) {
                            Image(systemName: sub.id.hasPrefix("folder:") ? "folder.fill" : "doc.text")
                                .font(.caption2)
                                .foregroundStyle(sub.id.hasPrefix("folder:") ? theme.accent : theme.textDim)
                                .frame(width: 12)
                            Text(sub.name)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if items.count > 30 {
                    Text("…and \(items.count - 30) more")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                }
            }
        }
    }

    @ViewBuilder
    private func notePreview(_ n: NoteEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(theme.primary)
                    // Allow the title to wrap to multiple lines so
                    // long names aren't cut with ellipsis in the
                    // narrow preview column.
                    Text(noteExcerpt?.title ?? n.title)
                        .font(.system(.title3, design: .default).weight(.semibold))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("/" + n.relativePath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(n.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.caption2)
                    .foregroundStyle(theme.textDim)
            }

            if let tags = noteExcerpt?.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(theme.overlayBackground)
                            .foregroundStyle(theme.accent)
                            .clipShape(Capsule())
                    }
                }
            }

            Rectangle().fill(theme.border).frame(height: 0.5)

            if let document = previewDocument {
                // Parse is memoized in `previewDocument` so flipping
                // through items doesn't re-walk the AST on every body
                // re-render. The work happens once in handleItemChange
                // on a detached task; we just hand the doc to
                // MarkdownView here.
                MarkdownView(document)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Metadata + body for the preview pane. Reads the file in full
/// (bounded by `softLimit` so a stray 50 MB markdown file doesn't blow
/// out memory) so the user can scroll through the entire note in the
/// preview column with J/K instead of being truncated to an excerpt.
private struct NoteExcerpt {
    let title: String?
    let tags: [String]
    let bodyExcerpt: String

    static func load(from url: URL) -> NoteExcerpt? {
        // 1 MB cap — plenty for any normal markdown note. Files larger
        // than this fall back to a leading slice + an ellipsis marker.
        let softLimit = 1 * 1024 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: softLimit),
              let text = String(data: chunk, encoding: .utf8)
        else { return nil }
        let (frontmatter, body) = FrontmatterParser.split(text)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Append an ellipsis marker only if we hit the soft limit and
        // truncated mid-file. Below that, show the full body.
        let truncated = (chunk.count == softLimit)
        let display = truncated ? trimmed + "\n\n…" : trimmed
        return NoteExcerpt(
            title: frontmatter.title,
            tags: frontmatter.tags,
            bodyExcerpt: display.isEmpty ? "(empty)" : display
        )
    }
}
