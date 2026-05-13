import SwiftUI
import UniformTypeIdentifiers
import LumiKit
import LumiUI

struct VaultSidebar: View {
    let vaults: [VaultRecord]
    @Binding var selectedVaultID: UUID?
    let onAdd: (URL) -> Void
    let onSelect: (VaultRecord) -> Void

    @State private var showImporter = false
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    var body: some View {
        List(selection: $selectedVaultID) {
            Section {
                if vaults.isEmpty {
                    Text("no vaults yet")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                        .padding(.vertical, 6)
                } else {
                    ForEach(vaults) { vault in
                        VaultRow(vault: vault)
                            .tag(Optional(vault.id))
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(vault) }
                    }
                }
            } header: {
                Text("vaults")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }

            if appState.authService.currentSession != nil {
                Section {
                    if appState.remoteVaultsStore.vaults.isEmpty {
                        Text(appState.remoteVaultsStore.isLoading ? "loading…" : "no server vaults")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(appState.remoteVaultsStore.vaults) { vault in
                            RemoteVaultRow(vault: vault, isSelected: appState.selectedRemoteVaultID == vault.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await selectRemote(vault) }
                                }
                        }
                    }
                    Button {
                        Task { await appState.remoteVaultsStore.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(.callout, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.primary)
                } header: {
                    Text("server")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                        .font(.system(.callout, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.primary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.overlayBackground)
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

    private func selectRemote(_ vault: RemoteVault) async {
        // Selecting a server vault deselects any local vault so the detail
        // panel doesn't try to show both. Note sync isn't wired up yet —
        // E.1.2 will do that.
        selectedVaultID = nil
        appState.selectedRemoteVaultID = vault.id
        await appState.remoteVaultsStore.selectVault(vault.id)
    }
}

private struct RemoteVaultRow: View {
    let vault: RemoteVault
    let isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.fill")
                .foregroundStyle(theme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                Text(vault.slug)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.accent)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct VaultRow: View {
    let vault: VaultRecord
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vault.bookmarkData != nil ? "folder" : "cloud")
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                if let last = vault.lastOpenedAt {
                    Text(last.formatted(.relative(presentation: .named)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
