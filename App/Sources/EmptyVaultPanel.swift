import SwiftUI
import UniformTypeIdentifiers
import LumiKit
import LumiUI

struct EmptyVaultPanel: View {
    let onAdd: (URL) -> Void

    @State private var showImporter = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Logo()
            VStack(spacing: 4) {
                Text("no vault open")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(theme.text)
                Text("open a folder to start reading")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            Button {
                showImporter = true
            } label: {
                Label("Open folder…", systemImage: "folder.badge.plus")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.overlayBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.border, lineWidth: 1)
                            )
                    )
                    .foregroundStyle(theme.primary)
            }
            .buttonStyle(.plain)
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
}

private struct Logo: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array("lumi".enumerated()), id: \.offset) { index, char in
                Text(String(char))
                    .foregroundStyle(theme.logoColors[index % theme.logoColors.count])
            }
        }
        .font(.system(size: 56, weight: .light, design: .monospaced))
    }
}
