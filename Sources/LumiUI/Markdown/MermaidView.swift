import SwiftUI
import LumiKit

/// Renders a ```mermaid fence. Thin entry point kept for the markdown
/// renderers; the work lives in `Sources/LumiUI/Mermaid/` — a locked-down
/// offscreen renderer (`MermaidRenderer`) producing a themed bitmap that
/// `MermaidDiagramView` shows natively (skeleton → image / error card,
/// click to zoom). In lite surfaces (kanban / canvas cards) it draws the
/// compact, non-interactive variant.
public struct MermaidView: View {
    public let code: String
    @Environment(\.markdownLite) private var lite

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        MermaidDiagramView(source: code, compact: lite)
    }
}
