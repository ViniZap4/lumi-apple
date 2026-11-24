import SwiftUI

/// A Mermaid diagram as a native image: skeleton while the offscreen
/// renderer works, the themed bitmap when it lands, a readable error
/// card (with the source) when mermaid rejects it. Tap / Return opens
/// the zoom sheet; the context menu copies PNG, SVG or source.
///
/// `compact` is the kanban / canvas-card flavour: smaller, capped
/// height, no chrome, no interaction.
public struct MermaidDiagramView: View {
    public let source: String
    public let compact: Bool

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var result: MermaidRenderResult?
    @State private var resultKey: String = ""

    public init(source: String, compact: Bool = false) {
        self.source = source
        self.compact = compact
    }

    private var mermaidTheme: MermaidTheme { MermaidTheme(tokens: theme) }
    private var scale: CGFloat { min(3, max(1, displayScale)) }
    /// Changes whenever a re-render is needed (source, theme, scale).
    private var taskKey: String { "\(mermaidTheme.fingerprint)|\(scale)|\(source)" }

    public var body: some View {
        content
            .task(id: taskKey) {
                if resultKey == taskKey, result != nil { return }
                let theme = mermaidTheme
                if let hit = MermaidRenderer.shared.cached(source: source, theme: theme, scale: scale) {
                    result = hit
                } else {
                    result = nil
                    let rendered = await MermaidRenderer.shared.render(source: source, theme: theme, scale: scale)
                    guard !Task.isCancelled else { return }
                    result = rendered
                }
                resultKey = taskKey
            }
    }

    @ViewBuilder
    private var content: some View {
        // Ignore a result that belongs to a previous theme / source so a
        // theme flip never shows the stale palette; probe the cache so a
        // remount (TextKit overlays mount near the viewport) or a flip
        // back to a seen theme draws the diagram on its first frame.
        let current = (resultKey == taskKey ? result : nil)
            ?? MermaidRenderer.shared.cached(source: source, theme: mermaidTheme, scale: scale)
        switch current {
        case let .success(diagram)?:
            MermaidDiagramCard(source: source, diagram: diagram, compact: compact)
        case let .failure(error)?:
            MermaidErrorCard(source: source, error: error, compact: compact)
        case nil:
            MermaidSkeleton(height: Self.placeholderHeight(source, compact: compact))
                .accessibilityLabel("Rendering \(MermaidSource.diagramKind(of: source).displayName.lowercased())")
        }
    }

    nonisolated static func placeholderHeight(_ source: String, compact: Bool) -> CGFloat {
        if compact { return 96 }
        switch MermaidSource.diagramKind(of: source) {
        case .sequence, .classDiagram, .state, .entityRelationship, .mindmap: return 280
        case .gantt, .timeline, .gitGraph: return 200
        case .pie, .quadrant, .radar: return 300
        default: return 180
        }
    }
}

// MARK: - Rendered card

struct MermaidDiagramCard: View {
    let source: String
    let diagram: MermaidDiagram
    let compact: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var maxHeight: CGFloat { compact ? 180 : 900 }

    var body: some View {
        let image = Image(decorative: diagram.bitmap.cgImage, scale: diagram.scale)
            .resizable()
            .interpolation(.high)
            .aspectRatio(diagram.size, contentMode: .fit)
            // Cap the *width* so the aspect-fit height never exceeds the
            // cap; a flexible height frame would pad short diagrams.
            .frame(maxWidth: Self.maxWidth(for: diagram.size, maxHeight: maxHeight))
            .frame(maxWidth: .infinity)
            .padding(compact ? 6 : 14)

        if compact {
            image
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.overlayBackground.opacity(0.35)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MermaidSource.accessibilityLabel(for: source))
                .accessibilityAddTraits(.isImage)
        } else {
            image
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.overlayBackground.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border.opacity(0.5), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(Rectangle())
                .onTapGesture { MermaidZoomPresenter.present(source: source, diagram: diagram, theme: theme) }
                .onHover { hovering = $0 }
                .contextMenu { menu }
                .help("Click to zoom")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MermaidSource.accessibilityLabel(for: source))
                .accessibilityAddTraits([.isImage, .isButton])
                .accessibilityHint("Opens the diagram in a zoomable view")
                .accessibilityAction { MermaidZoomPresenter.present(source: source, diagram: diagram, theme: theme) }
                .accessibilityAction(named: "Copy source") { MermaidExport.copySource(source) }
                .accessibilityAction(named: "Copy image") { MermaidExport.copyPNG(diagram) }
        }
    }

    /// Natural width, shrunk so that the height stays within `maxHeight`.
    nonisolated static func maxWidth(for size: CGSize, maxHeight: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(size.width, maxHeight * size.width / size.height)
    }

    private var badge: some View {
        HStack(spacing: 4) {
            if hovering {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .transition(.opacity)
            }
            Text("mermaid")
                .font(.system(size: 10, design: .monospaced).weight(.medium))
        }
        .foregroundStyle(theme.textDim)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.background.opacity(0.7)))
        .padding(8)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open Diagram") { MermaidZoomPresenter.present(source: source, diagram: diagram, theme: theme) }
        Divider()
        Button("Copy Image") { MermaidExport.copyPNG(diagram) }
        Button("Copy SVG") { MermaidExport.copySVG(diagram) }
        Button("Copy Mermaid Source") { MermaidExport.copySource(source) }
    }
}

// MARK: - Error card

struct MermaidErrorCard: View {
    let source: String
    let error: MermaidRenderError
    let compact: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                Text(error.title)
                    .font(.system(compact ? .caption : .callout).weight(.semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                if !compact {
                    Button {
                        MermaidExport.copySource(source)
                    } label: {
                        Label("Copy source", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textDim)
                    .help("Copy the Mermaid source")
                }
            }
            if !compact {
                Text(error.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                sourceListing
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.background.opacity(0.6)))
            }
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: compact ? 6 : 10, style: .continuous).fill(theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 10, style: .continuous).stroke(theme.warning.opacity(0.45), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mermaid diagram error. \(error.title). \(error.detail)")
    }
}

extension MermaidErrorCard {
    /// The source with line numbers; the line mermaid blamed is tinted.
    private var sourceListing: some View {
        let lines = source.trimmingCharacters(in: .newlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let blamed = error.blamedLine
        let gutter = String(lines.count).count
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let number = index + 1
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(number).leftPadded(to: gutter))
                        .foregroundStyle(number == blamed ? theme.error : theme.textDim.opacity(0.8))
                    Text(line.isEmpty ? " " : String(line))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(number == blamed ? theme.error.opacity(0.12) : .clear)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - Skeleton

/// Theme-tinted placeholder with a slow shimmer (static under Reduce Motion).
struct MermaidSkeleton: View {
    let height: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(theme.overlayBackground.opacity(0.4))
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                        GeometryReader { geo in
                            LinearGradient(
                                colors: [.clear, theme.text.opacity(0.06), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: geo.size.width * 0.45)
                            .offset(x: (geo.size.width * 1.45) * phase - geo.size.width * 0.45)
                        }
                    }
                    .clipShape(shape)
                }
            }
            .overlay(shape.stroke(theme.border.opacity(0.35), lineWidth: 0.5))
            .overlay {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(theme.textDim.opacity(0.6))
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}
