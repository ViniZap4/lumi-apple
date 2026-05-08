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

    var body: some View {
        Group {
            if let url = embed.iframeURL {
                EmbedWebViewRepresentable(url: url)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                Color.clear.frame(height: 1)
            }
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
