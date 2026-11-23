import SwiftUI
import LumiKit
import LumiUI

/// Yazi-style explorer: parent | current | preview. Keys come from the
/// shell key router (`AppState.handleShellKey`); the mouse still works
/// (click selects / enters, double-click opens, parent rows jump).
struct ExplorerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    private var explorer: ExplorerModel { appState.explorer }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let showPreview = appState.preferences.explorerShowPreview
                let parentW = max(150, min(240, geo.size.width * 0.2))
                let currentW = showPreview ? max(220, min(360, geo.size.width * 0.3)) : geo.size.width - parentW
                HStack(spacing: 0) {
                    parentColumn
                        .frame(width: parentW)
                    Hairline(vertical: true)
                    currentColumn
                        .frame(width: currentW)
                    if showPreview {
                        Hairline(vertical: true)
                        PreviewColumn(entry: explorer.nav.current)
                            .frame(maxWidth: .infinity)
                    }
                }
                .onAppear { updatePageRows(geo.size.height) }
                .onChange(of: geo.size.height) { _, h in updatePageRows(h) }
            }
            ExplorerPromptBar()
        }
        .background(theme.background)
        #if !os(macOS)
        .focusable()
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let k = KeyStroke(press: press) else { return .ignored }
            return appState.handleShellKey(k) ? .handled : .ignored
        }
        #endif
    }

    private func updatePageRows(_ height: CGFloat) {
        explorer.pageRows = max(1, Int(height / ShellMetrics.rowHeight))
    }

    // MARK: Columns

    private var parentColumn: some View {
        Group {
            if explorer.nav.parent != nil {
                ExplorerColumn(
                    entries: explorer.nav.parentEntries,
                    cursor: explorer.nav.parentCursor,
                    active: false,
                    emptyText: ""
                ) { _, entry in
                    if entry.kind == .folder {
                        explorer.nav.goTo(entry.path)
                    } else {
                        explorer.nav.goTo(explorer.nav.parent ?? "", select: entry.key)
                    }
                } onOpen: { _, entry in
                    if entry.kind == .note { appState.open(entry) }
                }
            } else {
                // At the book root the parent column names the book.
                VStack(alignment: .leading, spacing: 6) {
                    if let book = appState.openBook {
                        HStack(spacing: 6) {
                            BookStatusDot(status: appState.sync.status(for: book), size: 6)
                            Text(book.name)
                                .font(ShellFont.rowBold)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                        }
                        Text(bookSubtitle(book))
                            .font(ShellFont.small)
                            .foregroundStyle(theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("\(explorer.tree.noteCount) notes")
                        .font(ShellFont.small)
                        .foregroundStyle(theme.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.overlayBackground.opacity(0.35))
    }

    private var currentColumn: some View {
        ZStack(alignment: .topLeading) {
            ExplorerColumn(
                entries: explorer.nav.entries,
                cursor: explorer.nav.cursor,
                active: true,
                openKey: openKey,
                emptyText: emptyText
            ) { i, entry in
                explorer.nav.setCursor(i)
                if entry.kind == .folder { _ = explorer.nav.right() }
            } onOpen: { i, entry in
                explorer.nav.setCursor(i)
                if entry.kind == .note { appState.open(entry) }
            }
            if explorer.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("loading…")
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.textDim)
                }
                .padding(12)
            }
        }
    }

    private var openKey: String? {
        if let p = appState.selectedEntry?.relativePath { return NoteTree.noteKey(p) }
        if let id = appState.selectedRemoteNoteID { return NoteTree.noteKey(id) }
        return nil
    }

    private var emptyText: String {
        if explorer.isLoading { return "" }
        if !explorer.nav.filter.isEmpty { return "no match for “\(explorer.nav.filter)”" }
        if explorer.tree.noteCount == 0, explorer.nav.dir.isEmpty {
            return appState.can("note.create") ? "empty book · a to create a note" : "empty book"
        }
        return "empty folder"
    }

    private func bookSubtitle(_ book: Book) -> String {
        if book.kind == .local { return book.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "this device" }
        let host = book.serverURL.map(ServerURL.displayHost) ?? ""
        return [book.account, host].compactMap { $0 }.joined(separator: "@")
    }
}

// MARK: - Column

/// One miller column: a lazy single-select list with a fixed row height.
/// The cursor row is kept in view.
struct ExplorerColumn: View {
    let entries: [ExplorerEntry]
    let cursor: Int
    let active: Bool
    var openKey: String?
    var emptyText: String = "empty"
    let onPick: (Int, ExplorerEntry) -> Void
    let onOpen: (Int, ExplorerEntry) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if entries.isEmpty {
            Text(emptyText)
                .font(ShellFont.chrome)
                .foregroundStyle(theme.textDim)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.key) { i, entry in
                            row(entry, index: i)
                                .id(entry.key)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onOpen(i, entry) }
                                .onTapGesture { onPick(i, entry) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .onAppear { scrollToCursor(proxy, animated: false) }
                .onChange(of: cursor) { _, _ in scrollToCursor(proxy, animated: false) }
                .onChange(of: entries.first?.key) { _, _ in scrollToCursor(proxy, animated: false) }
            }
        }
    }

    private func scrollToCursor(_ proxy: ScrollViewProxy, animated: Bool) {
        guard cursor >= 0, cursor < entries.count else { return }
        proxy.scrollTo(entries[cursor].key, anchor: nil)
    }

    @ViewBuilder
    private func row(_ entry: ExplorerEntry, index: Int) -> some View {
        let isCursor = index == cursor
        let isFolder = entry.kind == .folder
        let isOpen = openKey != nil && entry.key == openKey
        HStack(spacing: 8) {
            Image(systemName: isFolder ? "folder" : "doc.text")
                .font(.system(size: 10.5))
                .foregroundStyle(isFolder ? theme.accent.opacity(0.9) : theme.textDim)
                .frame(width: 14)
            Text(entry.name)
                .font(isFolder ? ShellFont.rowBold : ShellFont.row)
                .foregroundStyle(nameColor(isFolder: isFolder, isOpen: isOpen, hidden: entry.isHidden))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isFolder {
                Text("\(entry.count)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: ShellMetrics.rowHeight)
        .background(alignment: .leading) {
            if isCursor {
                ZStack(alignment: .leading) {
                    Rectangle().fill(active ? theme.accent.opacity(0.16) : theme.text.opacity(0.06))
                    if active {
                        Rectangle().fill(theme.accent).frame(width: 2)
                    }
                }
            }
        }
    }

    private func nameColor(isFolder: Bool, isOpen: Bool, hidden: Bool) -> Color {
        if isOpen { return theme.primary }
        let base = isFolder ? theme.accent : theme.text
        return hidden ? base.opacity(0.55) : base
    }
}

// MARK: - Prompt bar

/// Bottom prompt of the explorer: filter, create, rename, delete confirm.
struct ExplorerPromptBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let ex = appState.explorer
        if let entry = ex.pendingDelete {
            HStack(spacing: 8) {
                Text("delete")
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.error)
                Text(entry.kind == .folder ? "\(entry.name)/ and everything inside?" : "\(entry.name)?")
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(ex.isLocal ? "(moves to the Trash)" : "(permanent on the server)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                Spacer()
                Text("y / ⏎ confirm · any key cancels")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(theme.error.opacity(0.08))
            .overlay(alignment: .top) { Hairline() }
        } else if let prompt = ex.prompt {
            @Bindable var bex = ex
            HStack(spacing: 8) {
                Text(prompt.label)
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.accent)
                Text("›")
                    .font(ShellFont.prompt)
                    .foregroundStyle(theme.textDim)
                TextField("", text: Binding(
                    get: { bex.prompt?.text ?? "" },
                    set: { new in
                        bex.prompt?.text = new
                        if case .filter = bex.prompt?.kind { bex.nav.setFilter(new) }
                    }
                ))
                .textFieldStyle(.plain)
                .font(ShellFont.prompt)
                .foregroundStyle(theme.text)
                .focused($focused)
                .onSubmit { appState.commitPrompt() }
                .onKeyPress(.escape) {
                    appState.cancelPrompt()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    bex.nav.move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    bex.nav.move(-1)
                    return .handled
                }
                Text(prompt.hint)
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(theme.overlayBackground.opacity(0.6))
            .overlay(alignment: .top) { Hairline() }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Preview

/// Right column: renders the note under the cursor with the reader's
/// TextKit 2 document view, or lists a folder's children.
struct PreviewColumn: View {
    let entry: ExplorerEntry?
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var loader = PreviewLoader()

    var body: some View {
        Group {
            if let entry {
                if entry.kind == .folder {
                    folderPreview(entry)
                } else {
                    notePreview(entry)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: taskKey) {
            guard let entry, entry.kind == .note else { return }
            await loader.load(entry, appState: appState)
        }
    }

    private var taskKey: String {
        guard let entry else { return "" }
        let stamp = entry.note?.updatedAt?.timeIntervalSince1970 ?? 0
        return entry.key + "@\(stamp)"
    }

    private func folderPreview(_ entry: ExplorerEntry) -> some View {
        let children = appState.explorer.nav.previewEntries ?? []
        return ExplorerColumn(
            entries: children,
            cursor: appState.explorer.nav.previewCursor,
            active: false,
            emptyText: "empty folder"
        ) { _, child in
            appState.explorer.nav.goTo(entry.path, select: child.key)
        } onOpen: { _, child in
            if child.kind == .note { appState.open(child) }
        }
    }

    @ViewBuilder
    private func notePreview(_ entry: ExplorerEntry) -> some View {
        if let doc = loader.text, loader.key == entry.key {
            MarkdownReader(
                title: loader.title ?? entry.name,
                tags: loader.tags,
                text: doc,
                noteURL: appState.explorer.localURL(for: entry),
                baseURL: appState.explorer.localURL(for: entry)?.deletingLastPathComponent(),
                vaultRoot: appState.session?.rootURL,
                scale: 0.88 * appState.preferences.readingScale,
                fontFamily: appState.preferences.readingFontFamily.markdownFamily,
                contentAnimations: false,
                readingWidth: 640
            )
            .environment(\.markdownLite, true)
            .allowsHitTesting(true)
        } else if let error = loader.error, loader.key == entry.key {
            Text(error)
                .font(ShellFont.chrome)
                .foregroundStyle(theme.textDim)
                .padding(16)
        } else {
            Color.clear
        }
    }
}

extension LumiPreferences.ReadingFontFamily {
    var markdownFamily: MarkdownFontFamily {
        switch self {
        case .system: return .system
        case .serif: return .serif
        case .monospace: return .monospace
        }
    }
}

/// Loads the body of the note under the cursor, debounced so holding `j`
/// through a folder does not read (or fetch) every note it passes.
@Observable
@MainActor
final class PreviewLoader {
    private(set) var key: String?
    private(set) var text: String?
    private(set) var title: String?
    private(set) var tags: [String] = []
    private(set) var error: String?

    nonisolated private static let softLimit = 512 * 1024

    func load(_ entry: ExplorerEntry, appState: AppState) async {
        try? await Task.sleep(nanoseconds: 110_000_000)
        if Task.isCancelled { return }
        switch appState.explorer.source {
        case .local:
            guard let url = appState.explorer.localURL(for: entry) else { return }
            let raw: String? = await Task.detached(priority: .userInitiated) {
                guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? h.close() }
                guard let data = try? h.read(upToCount: PreviewLoader.softLimit) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }.value
            if Task.isCancelled { return }
            apply(entry, raw: raw, error: raw == nil ? "can't read this file" : nil)
        case .remote:
            guard let note = entry.note else { return }
            do {
                let body = try await appState.remoteVaultsStore.noteBody(noteID: note.id)
                if Task.isCancelled { return }
                apply(entry, raw: body, error: nil)
            } catch {
                if Task.isCancelled { return }
                apply(entry, raw: nil, error: appState.describe(error))
            }
        case .none:
            break
        }
    }

    private func apply(_ entry: ExplorerEntry, raw: String?, error: String?) {
        key = entry.key
        self.error = error
        guard let raw else {
            text = nil
            return
        }
        let (fm, body) = FrontmatterParser.split(raw)
        title = fm.title ?? entry.note?.title.nilIfEmpty
        tags = fm.tags
        text = body
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
