import SwiftUI
import LumiKit

/// Floating note picker. Search field + live-filtered list. Walks the
/// currently-loaded portion of the vault tree to collect candidate notes
/// — does NOT eagerly load every subfolder, so opening this sheet stays
/// cheap on giant vaults. If the user types a query that matches a note
/// they haven't expanded into yet, we offer a "Load deeper folders" button
/// that walks one more depth level.
struct QuickSwitcherSheet: View {
    let rootFolder: FolderNode?
    let onSelect: (NoteEntry) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var fieldFocused: Bool

    /// All notes currently visible in the loaded tree, depth-first.
    /// Memoized on (query, root identity) — recomputed cheaply when the
    /// user types or expands a folder.
    private var allEntries: [NoteEntry] {
        guard let root = rootFolder else { return [] }
        var out: [NoteEntry] = []
        collect(root, into: &out)
        return out
    }

    private func collect(_ folder: FolderNode, into out: inout [NoteEntry]) {
        guard let items = folder.items else { return }
        for item in items {
            switch item {
            case .note(let n): out.append(n)
            case .folder(let f): collect(f, into: &out)
            }
        }
    }

    private var filtered: [NoteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = allEntries.sorted { $0.updatedAt > $1.updatedAt }
        guard !trimmed.isEmpty else { return base }
        let q = trimmed.lowercased()
        return base.filter {
            $0.title.lowercased().contains(q) || $0.relativePath.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textDim)
                TextField("Jump to note…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit { commitSelection() }
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button {
                    dismiss()
                } label: {
                    Text("Esc")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.overlayBackground)
                        .foregroundStyle(theme.textDim)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.overlayBackground)

            Divider().background(theme.border)

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Text(query.isEmpty ? "no notes loaded yet" : "no matches for \"\(query)\"")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                    if let root = rootFolder {
                        Button {
                            walkDepth(root, depth: 2)
                        } label: {
                            Label("Search deeper folders", systemImage: "arrow.down.to.line")
                                .font(.system(.caption, design: .monospaced))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(filtered.enumerated()), id: \.element.relativePath) { idx, note in
                            row(note: note, isSelected: idx == selectedIndex)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = idx
                                    commitSelection()
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(theme.background)
                    #if os(macOS)
                    .onKeyPress(phases: .down) { press in
                        switch press.key {
                        case .downArrow: move(by: 1, proxy: proxy); return .handled
                        case .upArrow: move(by: -1, proxy: proxy); return .handled
                        case .return: commitSelection(); return .handled
                        default: break
                        }
                        switch press.characters {
                        case "j": move(by: 1, proxy: proxy); return .handled
                        case "k": move(by: -1, proxy: proxy); return .handled
                        default: return .ignored
                        }
                    }
                    #endif
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(theme.background)
        .onAppear {
            fieldFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    @ViewBuilder
    private func row(note: NoteEntry, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(theme.textDim)
                Text(note.title)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(note.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.caption2)
                    .foregroundStyle(theme.textDim)
            }
            Text(note.relativePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 22)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? theme.overlayBackground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isSelected ? theme.accent : .clear, lineWidth: 1)
        )
    }

    #if os(macOS)
    private func move(by delta: Int, proxy: ScrollViewProxy) {
        guard !filtered.isEmpty else { return }
        let next = max(0, min(filtered.count - 1, selectedIndex + delta))
        selectedIndex = next
        withAnimation(.linear(duration: 0.05)) {
            proxy.scrollTo(next, anchor: .center)
        }
    }
    #endif

    /// One-shot recursive expansion up to `depth` levels. Used when the
    /// user wants to broaden the search beyond what they've already
    /// browsed. Bounded so a "Search deeper" tap on a million-note vault
    /// doesn't lock the UI.
    private func walkDepth(_ folder: FolderNode, depth: Int) {
        folder.loadIfNeeded()
        guard depth > 0, let items = folder.items else { return }
        for item in items {
            if case .folder(let f) = item { walkDepth(f, depth: depth - 1) }
        }
    }

    private func commitSelection() {
        guard !filtered.isEmpty else { return }
        let target = filtered[selectedIndex]
        onSelect(target)
    }
}
