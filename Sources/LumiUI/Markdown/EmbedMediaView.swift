import SwiftUI
import WebKit

enum EmbedSource: Hashable, Sendable {
    case youtube(id: String)
    case vimeo(id: String)

    var iframeURL: URL? {
        switch self {
        case let .youtube(id):
            return URL(string: "https://www.youtube-nocookie.com/embed/\(id)")
        case let .vimeo(id):
            return URL(string: "https://player.vimeo.com/video/\(id)")
        }
    }
}

struct EmbedMediaView: View {
    let embed: EmbedSource
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite

    var body: some View {
        if lite {
            // Preview-pane fallback — no WebView spawn. Just a label so
            // the reader can tell the slot contains a YouTube/Vimeo embed
            // without paying the iframe-load cost on every selection.
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                Text(embed.shortLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(theme.overlayBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if let url = embed.iframeURL {
            EmbedWebViewRepresentable(url: url)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

extension EmbedSource {
    var shortLabel: String {
        switch self {
        case let .youtube(id): return "youtube · \(id)"
        case let .vimeo(id): return "vimeo · \(id)"
        }
    }
}

#if canImport(UIKit)
import UIKit

private struct EmbedWebViewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}
#elseif canImport(AppKit)
import AppKit

private struct EmbedWebViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
#endif
