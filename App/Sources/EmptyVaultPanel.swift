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
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 26) {
                ASCIILogo()
                Text("local-first markdown notes")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)

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
                ForEach(vaults) { vault in
                    vaultRow(vault)
                }
            }
            openFolderButton(label: "Open another folder…")
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func vaultRow(_ vault: VaultRecord) -> some View {
        let isHovered = highlightedID == vault.persistentModelID
        Button {
            onSelect(vault)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vault.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.text)
                    if let lastOpened = vault.lastOpenedAt {
                        Text(lastOpened.formatted(.relative(presentation: .numeric)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.accent.opacity(0.12) : theme.overlayBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            highlightedID = hovering ? vault.persistentModelID : nil
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
            hint(key: "↩", label: "open")
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
                        .fill(theme.background)
                )
                .foregroundStyle(theme.accent)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
    }
}

/// ASCII art LUMI wordmark, matching the TUI / web clients. Each character
/// column is rendered at its own theme color slot so the wordmark gets
/// the same rainbow gradient lumi uses everywhere else.
private struct ASCIILogo: View {
    @Environment(\.theme) private var theme

    private let lines = [
        "██╗     ██╗   ██╗███╗   ███╗██╗",
        "██║     ██║   ██║████╗ ████║██║",
        "██║     ██║   ██║██╔████╔██║██║",
        "██║     ██║   ██║██║╚██╔╝██║██║",
        "███████╗╚██████╔╝██║ ╚═╝ ██║██║",
        "╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.accent)
            }
        }
    }
}
