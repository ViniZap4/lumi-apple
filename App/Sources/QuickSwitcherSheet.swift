import SwiftUI
import LumiKit

/// Floating note picker (⌘O). Two surfaces in one view:
///
///   1. Empty query → list of recent NoteEntries from whatever the
///      vault tree has already lazily loaded. Same fast path as the
///      original quick-switcher.
///   2. Non-empty query → debounced call into `VaultSearch`, which
///      walks the ENTIRE vault filesystem (not just expanded folders)
///      and matches against filenames, paths, AND note bodies. Hits
///      carry an optional snippet centred on the first body match.
///
/// Cancellation: every keystroke cancels the in-flight search task so
/// stale results never overwrite fresh ones. Debounce is short (~180
/// ms) so the UX feels live without thrashing the FS while the user
/// types fast.
struct QuickSwitcherSheet: View {
    let rootFolder: FolderNode?
    let onSelect: (NoteEntry) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searcher = VaultSearch()
    @FocusState private var fieldFocused: Bool

    private let debounceMillis: Int = 180

    /// Recents from the in-memory tree, capped so we don't render
    /// thousands of rows on a big vault before the user has typed.
    /// Memoized via the @Observable FolderNode underneath.
    private var recentRows: [SearchHit] {
        guard let root = rootFolder else { return [] }
        var entries: [NoteEntry] = []
        collect(root, into: &entries)
        return entries
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(50)
            .map(Self.searchHit(fromEntry:))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rows the list renders. Empty query → recents; otherwise the
    /// debounced VaultSearch results.
    private var displayHits: [SearchHit] {
        trimmedQuery.isEmpty ? recentRows : searchHits
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

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(theme.border)

            if displayHits.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(minWidth: 540, minHeight: 380)
        .background(theme.background)
        .onAppear {
            fieldFocused = true
            selectedIndex = 0
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .onChange(of: query) { _, newQuery in
            selectedIndex = 0
            runSearch(for: newQuery)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textDim)
            TextField("Search notes by title or content…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { commitSelection() }
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.textDim)
            }
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
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if trimmedQuery.isEmpty {
                Text("type to search — title and body, across the whole vault")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else if isSearching {
                Text("searching…")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                Text("no matches for \"\(query)\"")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(displayHits.enumerated()), id: \.element.id) { idx, hit in
                    row(hit: hit, isSelected: idx == selectedIndex)
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

    @ViewBuilder
    private func row(hit: SearchHit, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(theme.textDim)
                Text(hit.title)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                if hit.lineNumber > 0 {
                    Text("line \(hit.lineNumber + 1)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.overlayBackground)
                        .foregroundStyle(theme.textDim)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            Text(hit.relativePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 22)
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 22)
            }
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
        let n = displayHits.count
        guard n > 0 else { return }
        let next = max(0, min(n - 1, selectedIndex + delta))
        selectedIndex = next
        withAnimation(.linear(duration: 0.05)) {
            proxy.scrollTo(next, anchor: .center)
        }
    }
    #endif

    private func commitSelection() {
        let hits = displayHits
        guard !hits.isEmpty, selectedIndex < hits.count else { return }
        let target = hits[selectedIndex]
        onSelect(Self.noteEntry(from: target))
    }

    // MARK: - Async search plumbing

    private func runSearch(for raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchHits = []
            isSearching = false
            searchTask = nil
            return
        }
        guard let vaultURL = rootFolder?.url else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        let captured = searcher
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceMillis) * 1_000_000)
                try Task.checkCancellation()
                let hits = try await captured.search(query: trimmed, vaultURL: vaultURL)
                try Task.checkCancellation()
                self.searchHits = hits
                self.isSearching = false
            } catch is CancellationError {
                // A newer keystroke superseded this search; drop silently.
            } catch {
                self.searchHits = []
                self.isSearching = false
            }
        }
    }

    // MARK: - Type bridges

    private static func searchHit(fromEntry e: NoteEntry) -> SearchHit {
        SearchHit(
            id: e.relativePath + ":0",
            url: e.url,
            relativePath: e.relativePath,
            title: e.title,
            lineNumber: 0,
            snippet: "",
            score: Int(e.updatedAt.timeIntervalSince1970)
        )
    }

    /// Construct a NoteEntry from a SearchHit so the caller's existing
    /// `onSelect(NoteEntry)` contract still works. We fetch mtime
    /// fresh from disk — the hit didn't carry one.
    private static func noteEntry(from hit: SearchHit) -> NoteEntry {
        let attrs = try? FileManager.default.attributesOfItem(atPath: hit.url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        return NoteEntry(url: hit.url, relativePath: hit.relativePath, updatedAt: mtime)
    }
}
