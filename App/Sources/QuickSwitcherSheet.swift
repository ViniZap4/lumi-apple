import SwiftUI
import LumiKit

/// Floating note picker. Opens over the current view (⌘O on macOS) so the
/// user can jump notes without leaving the editor. Modeled after web's
/// SearchModal / CommandModal — a single search field at the top with a
/// live-filtered flat list underneath, navigable with j/k or arrow keys.
///
/// We render a flat search-friendly list (not the recursive tree) because
/// the modal's purpose is fast lookup, not browsing. If the search field is
/// empty we show every note ordered by recency.
struct QuickSwitcherSheet: View {
    let notes: [Note]
    let onSelect: (Note) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return notes.sorted { $0.updatedAt > $1.updatedAt }
        }
        let q = trimmed.lowercased()
        return notes
            .filter { $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
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
                Text(query.isEmpty ? "no notes in this vault yet" : "no matches for \"\(query)\"")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(filtered.enumerated()), id: \.element.path) { idx, note in
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
                        case .downArrow:
                            move(by: 1, proxy: proxy)
                            return .handled
                        case .upArrow:
                            move(by: -1, proxy: proxy)
                            return .handled
                        case .return:
                            commitSelection()
                            return .handled
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
    private func row(note: Note, isSelected: Bool) -> some View {
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
            Text(note.path)
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

    private func commitSelection() {
        guard !filtered.isEmpty else { return }
        let target = filtered[selectedIndex]
        onSelect(target)
    }
}
