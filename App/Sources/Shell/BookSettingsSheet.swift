import SwiftUI
import LumiKit
import LumiUI

/// Everything about a book that is not its notes: sync details, and for
/// server books members / roles / invites / audit / rename / delete —
/// each shown only when the member holds the capability.
struct BookSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("book settings")
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.textDim)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            Hairline()
            content
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
        .background(theme.background)
    }

    @ViewBuilder
    private var content: some View {
        if let book = appState.openBook {
            if book.kind == .bound,
               let id = appState.selectedRemoteVaultID,
               let remote = appState.remoteVaultsStore.vaults.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    BookDetailsPanel(book: book)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Hairline()
                    RemoteVaultDetailView(vault: remote)
                }
            } else {
                ScrollView {
                    BookDetailsPanel(book: book)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #if os(macOS)
                    if let path = book.path {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #endif
                }
            }
        } else {
            Text("no book open")
                .font(ShellFont.chrome)
                .foregroundStyle(theme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
