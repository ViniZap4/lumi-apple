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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.border)
            HStack(spacing: 0) {
                parentColumn
                    .id("parent-\(state.pathStack.count)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                Divider().background(theme.border)
                currentColumn
                    .id("current-\(state.pathStack.count)")
                Divider().background(theme.border)
                previewColumn
                    .id("preview-\(state.selectedItem?.id ?? "-")")
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.16), value: state.pathStack.count)
            .animation(.easeInOut(duration: 0.12), value: state.selectedItem?.id)
        }
        .background(theme.background)
        #if os(macOS)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        #endif
    }

    // MARK: - Columns

    @ViewBuilder
    private var parentColumn: some View {
        ColumnContainer(width: 220) {
            if let parent = state.parentFolder {
                ColumnList(
                    items: parent.items ?? [],
                    highlightedID: "folder:" + state.currentFolder.relativePath,
                    cursorIsActive: false,
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
        ColumnContainer(width: 320) {
            PreviewPane(item: state.selectedItem)
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
            f.loadIfNeeded()
            state.pathStack.append(f)
            // Resets the cursor for the new folder unless we remembered it.
            // State.cursor getter/setter handles the lookup.
        case .note(let n):
            onOpen(n)
        }
    }

    #if os(macOS)
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard appState.preferences.vimNavigationInList else { return .ignored }
        switch press.characters {
        case "j":
            state.moveCursor(by: 1); return .handled
        case "k":
            state.moveCursor(by: -1); return .handled
        case "l", "\r", " ":
            if let n = state.enterSelection() { onOpen(n) }
            return .handled
        case "h":
            _ = state.goBack(); return .handled
        case "g":
            state.moveCursorToStart(); return .handled
        case "G":
            state.moveCursorToEnd(); return .handled
        default:
            switch press.key {
            case .upArrow: state.moveCursor(by: -1); return .handled
            case .downArrow: state.moveCursor(by: 1); return .handled
            case .leftArrow: _ = state.goBack(); return .handled
            case .rightArrow:
                if let n = state.enterSelection() { onOpen(n) }
                return .handled
            case .escape:
                _ = state.goBack(); return .handled
            default: return .ignored
            }
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

// MARK: - Generic column list

private struct ColumnList: View {
    let items: [FolderNode.Item]
    let highlightedID: String?
    let cursorIsActive: Bool
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
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item: item, isHighlighted: item.id == highlightedID)
                                .id(item.id)
                                .onTapGesture(count: 2) {
                                    onTap(item)
                                    onActivate?(item)
                                }
                                .onTapGesture(count: 1) {
                                    onTap(item)
                                }
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
    @Environment(\.theme) private var theme
    @State private var noteExcerpt: NoteExcerpt?

    var body: some View {
        ScrollView {
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: itemID) { _, _ in
            // Drop the previous note excerpt so we don't show stale content
            // while the new one loads.
            noteExcerpt = nil
            if case .note(let n) = item {
                noteExcerpt = NoteExcerpt.load(from: n.url)
            }
        }
        .onAppear {
            if case .note(let n) = item {
                noteExcerpt = NoteExcerpt.load(from: n.url)
            }
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

            if f.items == nil {
                Button {
                    f.loadIfNeeded()
                } label: {
                    Label("Peek into folder", systemImage: "eye")
                        .font(.system(.caption, design: .monospaced))
                }
                .buttonStyle(.bordered)
            } else if let items = f.items {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                    Text("\(items.count) items")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items.prefix(14)) { sub in
                        HStack(spacing: 6) {
                            Image(systemName: sub.id.hasPrefix("folder:") ? "folder" : "doc.text")
                                .font(.caption2)
                                .foregroundStyle(sub.id.hasPrefix("folder:") ? theme.accent.opacity(0.7) : theme.textDim)
                                .frame(width: 12)
                            Text(sub.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if items.count > 14 {
                    Text("…and \(items.count - 14) more")
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
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(theme.primary)
                    Text(noteExcerpt?.title ?? n.title)
                        .font(.system(.title3, design: .default).weight(.semibold))
                        .foregroundStyle(theme.text)
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

            if let excerpt = noteExcerpt {
                Text(excerpt.bodyExcerpt)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Cheap-to-load metadata + first-N-bytes body excerpt. Only reads the
/// first ~8 KB of the file so preview is fast even on enormous notes.
private struct NoteExcerpt {
    let title: String?
    let tags: [String]
    let bodyExcerpt: String

    static func load(from url: URL) -> NoteExcerpt? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 8 * 1024
        guard let chunk = try? handle.read(upToCount: limit),
              let text = String(data: chunk, encoding: .utf8)
        else { return nil }
        let (frontmatter, body) = FrontmatterParser.split(text)
        // Trim trailing partial line if we cut mid-word.
        var excerpt = body
        if let lastNewline = excerpt.lastIndex(of: "\n") {
            excerpt = String(excerpt[..<lastNewline])
        }
        // Cap displayed excerpt to a sensible chunk so the column doesn't
        // overflow visually.
        let maxChars = 1200
        if excerpt.count > maxChars {
            excerpt = String(excerpt.prefix(maxChars)) + "…"
        }
        return NoteExcerpt(
            title: frontmatter.title,
            tags: frontmatter.tags,
            bodyExcerpt: excerpt.isEmpty ? "(empty)" : excerpt
        )
    }
}
