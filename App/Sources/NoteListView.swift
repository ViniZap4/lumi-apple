import SwiftUI
import LumiKit
import LumiUI

/// Single-pane recursive folder tree. Children of each folder load lazily
/// via `FolderNode.loadIfNeeded()` on first expansion, so opening a vault
/// is O(immediate-children) not O(total-files) — the 1M-note goal.
///
/// Vim navigation (j/k/Enter/l/h/g/G) is gated on
/// `appState.preferences.vimNavigationInList`. macOS-only via onKeyPress.
struct NoteListView: View {
    let vault: VaultRecord
    let rootFolder: FolderNode
    @Binding var selectedNoteID: String?
    let onSelect: (NoteEntry) -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @State private var expanded: Set<String> = []
    @FocusState private var listFocused: Bool

    var body: some View {
        Group {
            if let items = rootFolder.items, items.isEmpty {
                emptyState
            } else {
                List(selection: $selectedNoteID) {
                    if let items = rootFolder.items {
                        ForEach(items) { item in
                            TreeRowView(
                                item: item,
                                expanded: $expanded,
                                onSelect: onSelect
                            )
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding()
                    }
                }
                .scrollContentBackground(.hidden)
                .background(theme.background)
                #if os(macOS)
                .focusable()
                .focused($listFocused)
                .onKeyPress(phases: .down) { press in
                    handleKey(press)
                }
                .onAppear {
                    if appState.preferences.vimNavigationInList { listFocused = true }
                }
                #endif
            }
        }
        .navigationTitle(vault.name)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(vault.name)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(theme.text)
            Text("no markdown files in this vault yet")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    // MARK: - Vim navigation

    #if os(macOS)
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard appState.preferences.vimNavigationInList else { return .ignored }
        // For now: j/k navigate the immediate-root items only. Deeper
        // navigation can be added later once we wire a flattened "visible
        // rows" model that respects expansion state lazily — for 1M files
        // we can't precompute a flattened list.
        guard let items = rootFolder.items, !items.isEmpty else { return .ignored }
        let currentIdx = items.firstIndex(where: { isSelected($0) })

        switch press.characters {
        case "j":
            let next = items.index(after: currentIdx ?? -1)
            let bounded = min(next, items.count - 1)
            applySelection(items[bounded])
            return .handled
        case "k":
            let prev = max(0, (currentIdx ?? 0) - 1)
            applySelection(items[prev])
            return .handled
        case "l", " ", "\r":
            if let idx = currentIdx { openOrExpand(items[idx]) }
            return .handled
        case "g":
            applySelection(items[0])
            return .handled
        case "G":
            applySelection(items[items.count - 1])
            return .handled
        default:
            return .ignored
        }
    }

    private func isSelected(_ item: FolderNode.Item) -> Bool {
        switch item {
        case .note(let n): return selectedNoteID == n.relativePath
        case .folder(let f): return selectedNoteID == "folder:" + f.relativePath
        }
    }

    private func applySelection(_ item: FolderNode.Item) {
        switch item {
        case .note(let n):
            selectedNoteID = n.relativePath
            onSelect(n)
        case .folder(let f):
            selectedNoteID = "folder:" + f.relativePath
        }
    }

    private func openOrExpand(_ item: FolderNode.Item) {
        switch item {
        case .folder(let f):
            f.loadIfNeeded()
            expanded.insert("folder:" + f.relativePath)
        case .note(let n):
            onSelect(n)
        }
    }
    #endif
}

/// Recursive row renderer. Lazy: folders only call `loadIfNeeded()` when the
/// user expands them, so a million-note vault never enumerates its full tree
/// at startup.
private struct TreeRowView: View {
    let item: FolderNode.Item
    @Binding var expanded: Set<String>
    let onSelect: (NoteEntry) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        switch item {
        case .folder(let node):
            DisclosureGroup(
                isExpanded: bindingForExpansion(of: "folder:" + node.relativePath, node: node)
            ) {
                if node.isLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("loading…")
                            .font(.caption)
                    }
                    .padding(.leading, 8)
                } else if let children = node.items {
                    if children.isEmpty {
                        Text("(empty)")
                            .font(.caption)
                            .foregroundStyle(theme.textDim)
                            .padding(.leading, 8)
                    } else {
                        ForEach(children) { child in
                            TreeRowView(item: child, expanded: $expanded, onSelect: onSelect)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(theme.accent)
                    Text(node.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.text)
                }
            }
            .tag(Optional("folder:" + node.relativePath))
        case .note(let entry):
            NoteEntryRow(entry: entry)
                .tag(Optional(entry.relativePath))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(entry) }
        }
    }

    private func bindingForExpansion(of id: String, node: FolderNode) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(id)
                    node.loadIfNeeded()
                } else {
                    expanded.remove(id)
                }
            }
        )
    }
}

private struct NoteEntryRow: View {
    let entry: NoteEntry
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(theme.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                Text(entry.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.vertical, 2)
    }
}
