import SwiftUI
import LumiKit

/// Dispatches a `MediaReference` to the appropriate media view based on its
/// detected kind. The renderer ensures media references are pre-resolved to
/// absolute URLs (file:// for local, https:// for remote and embeds).
public struct MediaView: View {
    public let reference: MediaReference
    @Environment(\.theme) private var theme

    public var body: some View {
        Group {
            switch reference.kind {
            case .image:
                ImageMediaView(url: reference.url, alt: reference.alt)
            case .video:
                VideoMediaView(url: reference.url)
            case .pdf:
                PDFMediaView(url: reference.url)
            case let .youtube(id):
                EmbedMediaView(embed: .youtube(id: id))
            case let .vimeo(id):
                EmbedMediaView(embed: .vimeo(id: id))
            case .unknown:
                UnknownMediaView(reference: reference)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

private struct ImageMediaView: View {
    let url: URL
    let alt: String
    @Environment(\.theme) private var theme

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                placeholder("loading…")
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                placeholder("image unavailable")
            @unknown default:
                placeholder(alt.isEmpty ? "image" : alt)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(theme.overlayBackground)
    }
}

private struct UnknownMediaView: View {
    let reference: MediaReference
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reference.alt.isEmpty ? "media" : reference.alt)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
            Text(reference.url.absoluteString)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.overlayBackground)
    }
}
