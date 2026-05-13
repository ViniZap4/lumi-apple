import SwiftUI
import LumiKit
import LumiUI

/// Recursive folder tree of notes in a vault. Tracks expanded folder state
/// locally so collapse/expand survives selection changes. Selection is bound
/// to a parent-provided String? — when the user taps a note (or vim-opens
/// it), we call `onSelect`.
///
/// Vim navigation (j/k/h/l/Enter/gg/G) is gated on
/// `appState.preferences.vimNavigationInList`. Implementation uses a
/// macOS-friendly focusable + onKeyPress; iOS users navigate by tap.
struct NoteListView: View {
    let vault: VaultRecord
    let vaultRoot: URL?
    let notes: [Note]
    @Binding var selectedNoteID: String?
    let onSelect: (Note) -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var expanded: Set<String> = []
    @FocusState private var listFocused: Bool

    private var tree: [LocalTreeItem] {
        LocalNoteTree.build(notes: notes)
    }

    var body: some View {
        Group {
            if notes.isEmpty {
                emptyState
            } else {
                List(selection: $selectedNoteID) {
                    ForEach(tree) { item in
                        TreeRowView(
                            item: item,
                            expanded: $expanded,
                            selectedNoteID: $selectedNoteID,
                            onSelect: onSelect
                        )
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
                    // Auto-focus so vim keys work without a manual click.
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

        let visible = LocalTreeItem.flatten(tree, expanded: expanded)
        guard !visible.isEmpty else { return .ignored }

        let currentIndex = visible.firstIndex(where: { idMatchesSelection($0) }) ?? -1

        switch press.characters {
        case "j":
            let next = min(visible.count - 1, max(0, currentIndex) + (currentIndex < 0 ? 0 : 1))
            applySelection(visible[next])
            return .handled
        case "k":
            let prev = max(0, currentIndex - 1)
            applySelection(visible[prev])
            return .handled
        case "l", " ":
            if currentIndex >= 0 {
                openOrExpand(visible[currentIndex])
                return .handled
            }
            return .ignored
        case "h":
            if currentIndex >= 0 {
                collapseOrParent(visible[currentIndex], visible: visible)
                return .handled
            }
            return .ignored
        case "g":
            // Single-stroke 'g' alone won't trigger gg without a state machine;
            // implement plain G (last) and treat 'g' as no-op. Power users
            // can use g key chord by repeating.
            applySelection(visible[0])
            return .handled
        case "G":
            applySelection(visible[visible.count - 1])
            return .handled
        case "\r":
            if currentIndex >= 0, case .note(let note) = visible[currentIndex].kind {
                onSelect(note)
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }

    private func idMatchesSelection(_ item: LocalTreeItem) -> Bool {
        switch item.kind {
        case .folder: return selectedNoteID == item.id
        case .note: return selectedNoteID == item.id
        }
    }

    private func applySelection(_ item: LocalTreeItem) {
        selectedNoteID = item.id
        // If the new selection is a note, open it. Folders stay selected
        // without opening; l/Enter triggers their expand/open.
        if case .note(let note) = item.kind {
            onSelect(note)
        }
    }

    private func openOrExpand(_ item: LocalTreeItem) {
        switch item.kind {
        case .folder:
            expanded.insert(item.id)
        case .note(let note):
            onSelect(note)
        }
    }

    private func collapseOrParent(_ item: LocalTreeItem, visible: [LocalTreeItem]) {
        switch item.kind {
        case .folder where expanded.contains(item.id):
            expanded.remove(item.id)
        default:
            // Step up to the previous folder ancestor in the visible list.
            // Walk backwards finding a folder whose id is a path prefix.
            guard let idx = visible.firstIndex(where: { $0.id == selectedNoteID }) else { return }
            for i in stride(from: idx - 1, through: 0, by: -1) {
                if case .folder = visible[i].kind {
                    applySelection(visible[i])
                    return
                }
            }
        }
    }
    #endif
}

/// Recursive row renderer. Extracted into its own View so SwiftUI can resolve
/// the `some View` inference — a recursive `@ViewBuilder` function on
/// `NoteListView` itself trips the compiler because the opaque return type
/// references itself transitively.
private struct TreeRowView: View {
    let item: LocalTreeItem
    @Binding var expanded: Set<String>
    @Binding var selectedNoteID: String?
    let onSelect: (Note) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        switch item.kind {
        case .folder:
            DisclosureGroup(isExpanded: bindingForExpansion(of: item.id)) {
                if let children = item.children {
                    ForEach(children) { child in
                        TreeRowView(
                            item: child,
                            expanded: $expanded,
                            selectedNoteID: $selectedNoteID,
                            onSelect: onSelect
                        )
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(theme.accent)
                    Text(item.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.text)
                }
            }
            .tag(Optional(item.id))
        case .note(let note):
            NoteRow(note: note)
                .tag(Optional("note:" + note.id))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(note) }
        }
    }

    private func bindingForExpansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

private struct NoteRow: View {
    let note: Note
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(theme.textDim)
                Text(note.title)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                if !note.tags.isEmpty {
                    Text("·")
                        .foregroundStyle(theme.textDim)
                    Text(note.tags.joined(separator: " "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 2)
    }
}
