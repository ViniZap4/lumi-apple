import SwiftUI
import PDFKit

struct PDFMediaView: View {
    let url: URL
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite

    var body: some View {
        if lite {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                Text("pdf · \(url.lastPathComponent)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(theme.overlayBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            PDFRepresentable(url: url)
                .frame(minHeight: 400)
        }
    }
}

#if canImport(UIKit)
import UIKit

private struct PDFRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = PDFDocument(url: url)
    }
}
#elseif canImport(AppKit)
import AppKit

private struct PDFRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = PDFDocument(url: url)
    }
}
#endif
