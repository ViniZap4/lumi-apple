import SwiftUI
import LumiKit

/// Renders a Mermaid diagram. Asks `MathRenderService` for the rendered
/// SVG (one-shot via the persistent mermaid-loaded WebView) and shows
/// the result in a script-less `StaticContentWebView`. The SVG is
/// cached by `(source, isDark)`, so flipping back to the same note —
/// or switching themes and flipping back again — never re-runs mermaid.
public struct MermaidView: View {
    public let code: String
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite
    @State private var rendered: MathRenderService.Rendered?
    @State private var failed: Bool = false

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        Group {
            if lite {
                litePlaceholder
            } else if let rendered {
                renderedBody(rendered)
            } else if failed {
                rawFallback
            } else {
                Color.clear.frame(height: 120)
            }
        }
        .task(id: renderTaskID) {
            await renderIfNeeded()
        }
    }

    private var renderTaskID: String {
        // Mermaid bakes theme colors into the SVG itself, so dark/light
        // flips invalidate the cached render — re-fire the task.
        "\(code)|\(theme.isDark ? "d" : "l")"
    }

    private func renderIfNeeded() async {
        guard !lite else { return }
        if let result = await MathRenderService.shared.render(
            .mermaid(source: code, isDark: theme.isDark)
        ) {
            rendered = result
            failed = false
        } else {
            failed = true
        }
    }

    @ViewBuilder
    private func renderedBody(_ rendered: MathRenderService.Rendered) -> some View {
        StaticContentWebView(
            payload: rendered.payload,
            role: .mermaid,
            intrinsicHeight: max(80, min(rendered.intrinsicHeight, 2000))
        )
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.overlayBackground.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border.opacity(0.5), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            Text("mermaid")
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.background.opacity(0.7)))
                .padding(8)
        }
    }

    @ViewBuilder
    private var litePlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.caption)
                .foregroundStyle(theme.accent)
            Text("mermaid diagram")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
            Spacer()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(theme.overlayBackground.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rawFallback: some View {
        // Render fell over (bad mermaid source / dead WebView). Show
        // the source so the user can correct it instead of staring at
        // a blank diagram.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                Text("mermaid render failed")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            Text(code)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.overlayBackground.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
