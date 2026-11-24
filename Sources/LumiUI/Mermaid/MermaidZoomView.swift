import SwiftUI

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Full-size diagram viewer: pan (scroll), zoom (pinch, ⌘+ / ⌘- / ⌘0,
/// toolbar), copy PNG / SVG / source. Re-renders at a higher backing
/// scale on open so zoomed-in text stays crisp.
struct MermaidZoomView: View {
    let source: String
    let initial: MermaidDiagram
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var diagram: MermaidDiagram?
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var fitted = false
    @State private var copied: String?

    private static let range: ClosedRange<CGFloat> = 0.2...8

    private var shown: MermaidDiagram { diagram ?? initial }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.separator)
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: shown.bitmap.cgImage, scale: shown.scale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: shown.size.width * zoom, height: shown.size.height * zoom)
                        .padding(24)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        .accessibilityLabel(MermaidSource.accessibilityLabel(for: source))
                        .accessibilityAddTraits(.isImage)
                }
                .background(theme.background)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = pinchBase ?? zoom
                            pinchBase = base
                            zoom = clamp(base * value.magnification)
                        }
                        .onEnded { _ in pinchBase = nil }
                )
                .onAppear {
                    guard !fitted else { return }
                    fitted = true
                    zoom = fitZoom(in: geo.size)
                }
            }
        }
        .background(theme.background)
        .task {
            // Sharper pass for zooming; falls back to the inline bitmap.
            let hi = await MermaidRenderer.shared.render(
                source: source, theme: MermaidTheme(tokens: theme), scale: max(3, initial.scale * 2)
            )
            if case let .success(d) = hi { diagram = d }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(MermaidSource.diagramKind(of: source).displayName)
                .font(.headline)
                .foregroundStyle(theme.text)
            if let copied {
                Text(copied)
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
                    .transition(.opacity)
            }
            Spacer()
            Group {
                Button { zoom = clamp(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom out")
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .frame(minWidth: 44)
                Button { zoom = clamp(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Zoom in")
                Button("100%") { zoom = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Actual size")
            }
            Menu {
                Button("Copy Image") { MermaidExport.copyPNG(shown); flash("Image copied") }
                Button("Copy SVG") { MermaidExport.copySVG(shown); flash("SVG copied") }
                Button("Copy Mermaid Source") { MermaidExport.copySource(source); flash("Source copied") }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy")
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func clamp(_ z: CGFloat) -> CGFloat { min(Self.range.upperBound, max(Self.range.lowerBound, z)) }

    private func fitZoom(in size: CGSize) -> CGFloat {
        let s = initial.size
        guard s.width > 0, s.height > 0 else { return 1 }
        return clamp(min(1.5, (size.width - 48) / s.width, (size.height - 48) / s.height))
    }

    private func flash(_ message: String) {
        withAnimation { copied = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if copied == message { copied = nil } }
        }
    }
}

/// Presents `MermaidZoomView` from wherever the diagram lives. Diagrams
/// are hosted in platform views laid over TextKit (not inside a SwiftUI
/// presentation context), so presentation goes through the window /
/// view-controller hierarchy directly instead of `.sheet`.
@MainActor
enum MermaidZoomPresenter {
    static func present(source: String, diagram: MermaidDiagram, theme: ThemeTokens) {
        #if canImport(AppKit)
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil else { return }
        var sheet: NSWindow?
        let root = MermaidZoomView(source: source, initial: diagram) {
            if let sheet { parent.endSheet(sheet) }
        }
        .environment(\.theme, theme)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .resizable]
        let screen = parent.screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let want = CGSize(width: diagram.size.width + 80, height: diagram.size.height + 120)
        window.setContentSize(CGSize(
            width: min(max(want.width, 560), screen.width * 0.85),
            height: min(max(want.height, 380), screen.height * 0.85)
        ))
        window.contentMinSize = CGSize(width: 420, height: 300)
        sheet = window
        parent.beginSheet(window)
        #elseif canImport(UIKit)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            var top = scene.keyWindow?.rootViewController
        else { return }
        while let next = top.presentedViewController { top = next }
        weak var hostRef: UIViewController?
        let root = MermaidZoomView(source: source, initial: diagram) {
            hostRef?.dismiss(animated: true)
        }
        .environment(\.theme, theme)
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        hostRef = host
        top.present(host, animated: true)
        #endif
    }
}
