import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LumiKit
import LumiUI

/// The home / landing pane. Renders the same ASCII LUMI logo the TUI and
/// web clients show, lists known vaults so the user can jump straight in,
/// and exposes "open another folder" + key hints. Lives in the detail
/// slot of the NavigationSplitView so it occupies the full window when
/// the sidebar is hidden (the default).
struct EmptyVaultPanel: View {
    let vaults: [VaultRecord]
    let onAdd: (URL) -> Void
    let onSelect: (VaultRecord) -> Void

    @State private var showImporter = false
    @State private var highlightedID: PersistentIdentifier?
    /// Keyboard cursor — index into `vaults`. j/k move it; ⏎ opens.
    /// Tracked separately from `highlightedID` (which mirrors mouse
    /// hover) so the two interaction modes don't fight when the user
    /// has the mouse parked over one row while pressing j/k.
    @State private var keyboardCursor: Int = 0
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 26) {
                ASCIILogo()
                // Subtitle uses `text` rather than `textDim` so it reads
                // cleanly on the lighter palettes (tokyo-day, catppuccin-
                // latte, lgbt-light, trans-light) where `textDim` slides
                // into the noise.
                Text("local-first markdown notes")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text.opacity(0.7))

                if vaults.isEmpty {
                    emptyState
                } else {
                    vaultsList
                }
            }
            .frame(maxWidth: 520)
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        #if os(macOS)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKey(press)
        }
        .onChange(of: vaults.count) { _, _ in
            keyboardCursor = min(keyboardCursor, max(0, vaults.count - 1))
        }
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                onAdd(url)
            }
        }
    }

    #if os(macOS)
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !vaults.isEmpty else { return .ignored }
        switch press.characters {
        case "j":
            keyboardCursor = min(keyboardCursor + 1, vaults.count - 1)
            return .handled
        case "k":
            keyboardCursor = max(keyboardCursor - 1, 0)
            return .handled
        case "g":
            keyboardCursor = 0
            return .handled
        case "G":
            keyboardCursor = vaults.count - 1
            return .handled
        case "\r", "l", " ":
            if vaults.indices.contains(keyboardCursor) {
                onSelect(vaults[keyboardCursor])
            }
            return .handled
        default:
            switch press.key {
            case .upArrow:
                keyboardCursor = max(keyboardCursor - 1, 0); return .handled
            case .downArrow:
                keyboardCursor = min(keyboardCursor + 1, vaults.count - 1); return .handled
            case .return:
                if vaults.indices.contains(keyboardCursor) {
                    onSelect(vaults[keyboardCursor])
                }
                return .handled
            default: return .ignored
            }
        }
    }
    #endif

    // MARK: - States

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("no vault yet")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.text)
            openFolderButton(label: "Open folder…")
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var vaultsList: some View {
        VStack(spacing: 10) {
            Text("vaults")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            VStack(spacing: 6) {
                ForEach(Array(vaults.enumerated()), id: \.element.id) { index, vault in
                    vaultRow(vault, index: index)
                }
            }
            openFolderButton(label: "Open another folder…")
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func vaultRow(_ vault: VaultRecord, index: Int) -> some View {
        let isHovered = highlightedID == vault.persistentModelID
        let isCursor = keyboardCursor == index
        let isActive = isHovered || isCursor
        Button {
            onSelect(vault)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(theme.accent)
                    .frame(width: 18)
                    .scaleEffect(isActive ? 1.08 : 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vault.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.text)
                    if let lastOpened = vault.lastOpenedAt {
                        // Same readability tweak as the subtitle: pulled
                        // up from textDim to ~70% text so light themes
                        // don't lose the timestamp.
                        Text(lastOpened.formatted(.relative(presentation: .numeric)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.text.opacity(0.65))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(isActive ? theme.accent : theme.textDim)
                    .offset(x: isActive ? 3 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? theme.accent.opacity(0.14) : theme.overlayBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? theme.accent.opacity(0.5) : theme.border.opacity(0.4), lineWidth: 0.5)
            )
            .scaleEffect(isActive ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .onHover { hovering in
            highlightedID = hovering ? vault.persistentModelID : nil
            // Mouse hover wins — sync the keyboard cursor so a follow-up
            // ⏎ opens the row the user is pointing at.
            if hovering {
                keyboardCursor = index
            }
        }
    }

    @ViewBuilder
    private func openFolderButton(label: String) -> some View {
        Button {
            showImporter = true
        } label: {
            Label(label, systemImage: "folder.badge.plus")
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.primary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.primary.opacity(0.4), lineWidth: 0.5)
                )
                .foregroundStyle(theme.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 18) {
            if !vaults.isEmpty {
                hint(key: "j/k", label: "move")
                hint(key: "↩", label: "open")
            }
            hint(key: "⌘O", label: "switcher")
            hint(key: "⌘,", label: "settings")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(theme.overlayBackground.opacity(0.4))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func hint(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        // Was `theme.background`; that's the same color
                        // as the home-pane base behind the footer, so on
                        // any theme where `overlayBackground.opacity(0.4)`
                        // doesn't differ enough from base (e.g. obsidian),
                        // the pill became invisible. `selectedBackground`
                        // is a guaranteed-distinct slot in all 12 themes.
                        .fill(theme.selectedBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(theme.border.opacity(0.5), lineWidth: 0.5)
                )
                .foregroundStyle(theme.accent)
            Text(label)
                // Bumped from `theme.textDim` to `theme.text` so the
                // descriptive label reads on light themes too (textDim
                // hits AA-fail territory against the footer's tinted
                // overlay on tokyo-day / catppuccin-latte).
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.text)
        }
    }
}

/// ASCII art LUMI wordmark, matching the TUI / web clients exactly.
///
/// The source-of-truth lines live in `web-client/src/lib/store.svelte.ts`
/// and `tui-client/ui/view_home.go`. The canonical pattern is:
///
///   - Line 0 has no leading space (it's the "top edge" of the wordmark)
///   - Lines 1…5 each carry a single leading space
///
/// The leading space on the lower rows is what gives the wordmark its
/// slight rightward shear under the top edge — the same shear the TUI
/// renders. Before this fix the Apple lines were flush-left across the
/// board, which made line 0 appear "stuck out to the left" since it has
/// 1-column-narrower decorations than the lower rows' bodies.
///
/// Per-line color uses `theme.logoColors[i]` so the wordmark gets the
/// same six-stop rainbow the TUI (`theme.Current.LogoColors[i]`) and
/// web (`var(--color-logo-i)`) clients use.
private struct ASCIILogo: View {
    @Environment(\.theme) private var theme

    /// Whitespace at the start is significant — keep these strings
    /// verbatim. Indices match the source-of-truth lists in the web
    /// store and TUI view_home.go.
    private let lines = [
        "██╗     ██╗   ██╗███╗   ███╗██╗",
        " ██║     ██║   ██║████╗ ████║██║",
        " ██║     ██║   ██║██╔████╔██║██║",
        " ██║     ██║   ██║██║╚██╔╝██║██║",
        " ███████╗╚██████╔╝██║ ╚═╝ ██║██║",
        " ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(colorForLine(index))
            }
        }
        // Belt and braces: SwiftUI's `Text` collapses leading whitespace
        // in some monospaced contexts when paired with default kerning.
        // Explicit identity tracking via index keeps the leading-space
        // distinction stable, and the .monospacedDigit() modifier ahead
        // of any future digit work isn't needed here — keep the layout
        // strict (kerning .monospaced is implied by the design).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LUMI")
    }

    private func colorForLine(_ index: Int) -> Color {
        let palette = theme.logoColors
        guard !palette.isEmpty else { return theme.accent }
        return palette[index % palette.count]
    }
}
