import SwiftUI
import LumiKit
#if canImport(AppKit)
import AppKit
#endif

/// JSON Canvas view (SPEC-PARTE2 §6) over a `CanvasBoardModel`.
///
/// Infinite board: pan by drag on empty space / space+drag / hjkl /
/// arrows / trackpad scroll; zoom by pinch, ⌘-scroll, `+ = zi ⌘+` /
/// `_ zo ⌘-`, `0 zf` fit (`-` is the floating explorer, SPEC-PARTE2 §5b).
/// Nodes are cards (text → compact prose, file → note preview, link → URL
/// card without fetching, group → labelled frame); edges are curved with
/// arrows, labels and colors. Node content is laid out at world size and
/// scaled on the GPU (`scaleEffect`), selection chrome is drawn in screen
/// space so it stays crisp.
public struct CanvasBoardView: View {
    @Bindable var model: CanvasBoardModel
    let title: String
    let status: String?
    let motion: Bool
    let onSource: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var focused: Bool
    @FocusState private var fieldFocused: Bool
    @State private var pinchOrigin: CanvasViewport?
    @State private var dragging = false

    public init(model: CanvasBoardModel, title: String = "", status: String? = nil, motion: Bool = true, onSource: (() -> Void)? = nil) {
        self.model = model
        self.title = title
        self.status = status
        self.motion = motion
        self.onSource = onSource
    }

    private var animates: Bool { motion && !systemReduceMotion }
    @Environment(\.lumiMotionPolicy) private var policy
    private var v: CanvasViewport { model.viewport }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                grid
                board
                    .animation(model.viewportCoasting && animates
                               ? .timingCurve(0.16, 0.72, 0.3, 1, duration: 3 * CanvasBoardModel.coastTau)
                               : model.viewportEased ? StructuredStyle.animation(animates) : nil,
                               value: model.viewport)
                chrome
                connectPreview
                VStack(spacing: 0) {
                    toolbar
                    if let invalid = model.invalid { invalidBanner(invalid) }
                    Spacer(minLength: 0)
                }
                if model.picker != nil { pickerView }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(pointer)
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { e in
                model.doubleClick(at: e.location, command: Self.commandDown)
            })
            .simultaneousGesture(pinch)
            .onContinuousHover { phase in
                if case let .active(p) = phase { model.hover(p) } else { model.hover(nil) }
            }
            #if canImport(AppKit)
            .background(ScrollWheelCatcher { e, p in model.wheel(e, at: p) })
            #endif
            .onAppear { model.setSize(geo.size) }
            .onChange(of: geo.size) { _, s in model.setSize(s) }
        }
        .overlay(alignment: .bottom) { noticeView }
        .background(theme.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .up]) { press in
            if press.key == .space {
                model.spaceDown = press.phase == .down
                return .handled
            }
            guard press.phase == .down, let k = StructuredKey(press: press) else { return .ignored }
            return model.handleKey(k) ? .handled : .ignored
        }
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in if model.editing == nil && model.picker == nil { focused = true } }
        .onChange(of: model.editing) { _, e in if e != nil { fieldFocused = true } }
    }

    // MARK: - Layers

    private var grid: some View {
        Canvas { ctx, size in
            let step = 24 * v.zoom
            guard step >= 6 else { return }
            let dot = theme.muted.opacity(theme.isDark ? 0.28 : 0.35)
            let r = max(0.6, min(1.4, v.zoom))
            var x = v.x.truncatingRemainder(dividingBy: step)
            if x < 0 { x += step }
            while x < size.width {
                var y = v.y.truncatingRemainder(dividingBy: step)
                if y < 0 { y += step }
                while y < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(dot))
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }

    private var board: some View {
        let nodes = model.nodes
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            ForEach(Array(nodes.filter { $0.type == .group }.enumerated()), id: \.element.id) { i, n in nodeView(n, order: i) }
            edgesLayer(nodes: byId)
            ForEach(Array(nodes.filter { $0.type != .group }.enumerated()), id: \.element.id) { i, n in nodeView(n, order: i + 1) }
            edgeLabels(nodes: byId)
        }
    }

    private func nodeView(_ n: CanvasNode, order: Int) -> some View {
        let s = CanvasGeometry.toScreen(v, n.rect)
        return CanvasNodeCard(node: n, preview: model.previews[n.file], editing: editingBinding(n), field: $fieldFocused,
                              onCommit: { model.finishEdit() })
            .frame(width: n.width, height: n.height, alignment: .topLeading)
            .scaleEffect(v.zoom, anchor: .topLeading)
            .frame(width: s.width, height: s.height, alignment: .topLeading)
            // Nodes pop in (0.92 → 1, bouncy) as a ripple when the canvas
            // opens, and on their own when created.
            .lumiEnter(.pop, spring: .bouncy, delay: policy.stagger(order))
            .offset(x: s.minX, y: s.minY)
    }

    private func editingBinding(_ n: CanvasNode) -> Binding<String>? {
        switch model.editing {
        case let .text(id, _) where id == n.id, let .label(id) where id == n.id:
            return Binding(get: { model.draft }, set: { model.draft = $0; model.draftChanged() })
        default: return nil
        }
    }

    private func edgeColor(_ e: CanvasEdge) -> Color {
        StructuredStyle.color(Canvas.color(e.color)) ?? theme.textDim
    }

    private func edgesLayer(nodes: [String: CanvasNode]) -> some View {
        let edges = model.edges
        let vp = v
        let selected = model.selectedEdge
        let accent = theme.accent
        let colors = Dictionary(edges.map { ($0.id, edgeColor($0)) }, uniquingKeysWith: { a, _ in a })
        return EdgeDraw(ids: edges.map(\.id)) { ctx, progress in
            for e in edges {
                guard let a = nodes[e.fromNode], let b = nodes[e.toNode] else { continue }
                let p = progress(e.id)
                guard p > 0.001 else { continue }
                let g = CanvasGeometry.edgeGeometry(e, a.rect, b.rect)
                func s(_ p: CGPoint) -> CGPoint { CanvasGeometry.toScreen(vp, p) }
                var path = Path()
                path.move(to: s(g.from))
                path.addCurve(to: s(g.to), control1: s(g.c1), control2: s(g.c2))
                // Edges draw from their source; the head fades in as the
                // line arrives (§6.5 canvas).
                if p < 1 { path = path.trimmedPath(from: 0, to: p) }
                let color = selected == e.id ? accent : colors[e.id] ?? .gray
                let width = (selected == e.id ? 2.5 : 1.8) * max(0.6, min(1.4, vp.zoom))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                let size = 11 * max(0.6, min(1.4, vp.zoom))
                let headAlpha = max(0, min(1, (p - 0.8) / 0.2))
                if e.arrowAtEnd, headAlpha > 0 {
                    let pts = CanvasGeometry.arrowHead(s(g.to), g.endAngle, size: size)
                    var head = Path(); head.addLines(pts); head.closeSubpath()
                    ctx.fill(head, with: .color(color.opacity(headAlpha)))
                }
                if e.arrowAtStart {
                    let pts = CanvasGeometry.arrowHead(s(g.from), g.startAngle, size: size)
                    var head = Path(); head.addLines(pts); head.closeSubpath()
                    ctx.fill(head, with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func edgeLabels(nodes: [String: CanvasNode]) -> some View {
        ForEach(model.edges) { e in
            if let a = nodes[e.fromNode], let b = nodes[e.toNode] {
                let mid = CanvasGeometry.toScreen(v, CanvasGeometry.edgeGeometry(e, a.rect, b.rect).mid)
                Group {
                    if model.editing == .edge(id: e.id) {
                        TextField("Label", text: $model.draft)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .frame(width: 140)
                            .focused($fieldFocused)
                            .onSubmit { model.finishEdit() }
                            .onKeyPress(.escape) { model.finishEdit(); return .handled }
                    } else if let label = e.label, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(theme.text)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.background))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.selectedEdge == e.id ? theme.accent : theme.border.opacity(0.6), lineWidth: 0.5))
                .fixedSize()
                .position(mid)
                .opacity(model.editing == .edge(id: e.id) || !(e.label ?? "").isEmpty ? 1 : 0)
                // Labels arrive with their edge (after it has drawn).
                .lumiEnter(MotionFrom(scale: 0.9, opacity: 0), spring: .soft, delay: 0.22)
            }
        }
    }

    /// Selection outline, side handles, resize corner — screen space.
    private var chrome: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.selection, id: \.self) { id in
                if let n = model.node(id) {
                    let r = CanvasGeometry.toScreen(v, n.rect)
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(theme.accent, lineWidth: 2)
                        .frame(width: r.width + 6, height: r.height + 6)
                        .offset(x: r.minX - 3, y: r.minY - 3)
                    if model.selection.count == 1 && model.isEditable {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.background)
                            .frame(width: 14, height: 14)
                            .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent))
                            .offset(x: r.maxX - 10, y: r.maxY - 10)
                    }
                }
            }
            if model.isEditable {
                ForEach(Array(Set([model.selectedNode?.id, model.hovered].compactMap { $0 })), id: \.self) { id in
                    if let n = model.node(id) {
                        ForEach(CanvasSide.allCases, id: \.self) { side in
                            let p = CanvasGeometry.toScreen(v, CanvasGeometry.sidePoint(n.rect, side))
                            Circle()
                                .fill(theme.background)
                                .overlay(Circle().stroke(theme.accent, lineWidth: 1.5))
                                .frame(width: 2 * CanvasBoardModel.handleRadius, height: 2 * CanvasBoardModel.handleRadius)
                                .position(p)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var connectPreview: some View {
        if case let .connect(from, side, to)? = model.gesture, let n = model.node(from) {
            let a = CanvasGeometry.sidePoint(n.rect, side)
            let target = CanvasGeometry.hitNode(model.nodes.filter { $0.id != from }, to)
            let g = CanvasGeometry.curve(a, side, target.map { CanvasGeometry.sidePoint($0.rect, CanvasGeometry.nearestSide($0.rect, to)) } ?? to,
                                         target.map { CanvasGeometry.nearestSide($0.rect, to) })
            let vp = v
            let accent = theme.accent
            Canvas { ctx, _ in
                func s(_ p: CGPoint) -> CGPoint { CanvasGeometry.toScreen(vp, p) }
                var path = Path()
                path.move(to: s(g.from))
                path.addCurve(to: s(g.to), control1: s(g.c1), control2: s(g.c2))
                ctx.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Toolbar / banners

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .foregroundStyle(theme.accent)
            Text(title.isEmpty ? "Canvas" : title)
                .font(.headline)
                .foregroundStyle(theme.text)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.muted.opacity(0.18)))
            }
            if let p = model.pending {
                Text(p == "C-w" ? "⌃w" : p)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.accent)
            }
            Spacer(minLength: 8)
            if model.hasSelection && model.isEditable { palette }
            HStack(spacing: 2) {
                iconButton("minus", help: "Zoom out (_ zo ⌘-)") { model.zoom(by: 1 / CanvasGeometry.zoomStep) }
                Text("\(Int((v.zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.textDim)
                    .frame(width: 42)
                iconButton("plus", help: "Zoom in (+ = zi ⌘+)") { model.zoom(by: CanvasGeometry.zoomStep) }
                iconButton("arrow.up.left.and.arrow.down.right", help: "Fit (0)") { model.fitAll() }
            }
            if let onSource { ViewToggle(selection: "Canvas", onSource: onSource) }
        }
        .padding(.horizontal, 14)
        .frame(height: CanvasBoardModel.topInset)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    private var palette: some View {
        HStack(spacing: 5) {
            ForEach(1...6, id: \.self) { n in
                Button { model.setColor(String(n)) } label: {
                    Circle().fill(StructuredStyle.preset(n)).frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .help("\(StructuredStyle.presetNames[n - 1]) (c\(n))")
            }
            Button { model.setColor(nil) } label: {
                Image(systemName: "circle.slash").font(.system(size: 12)).foregroundStyle(theme.textDim)
            }
            .buttonStyle(.plain)
            .help("No color (c0)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(theme.muted.opacity(0.14)))
    }

    private func iconButton(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func invalidBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text("Invalid JSON — read-only, showing the last good version.")
                .font(.callout)
                .foregroundStyle(theme.text)
            Text(message.replacingOccurrences(of: "Invalid JSON: ", with: ""))
                .font(.caption.monospaced())
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
            Spacer()
            if let onSource {
                Button("Fix in Source", action: onSource)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.warning.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.warning.opacity(0.4)).frame(height: 0.5) }
    }

    @ViewBuilder
    private var noticeView: some View {
        if let n = model.notice {
            Text(n)
                .font(.callout)
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(theme.overlayBackground))
                .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
                .padding(.bottom, 16)
        }
    }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(theme.textDim)
                TextField("Add a note to the canvas…", text: Binding(
                    get: { model.picker?.query ?? "" },
                    set: { q in model.picker?.query = q; model.picker?.cursor = 0 }
                ))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onKeyPress(phases: .down) { press in
                    guard let k = StructuredKey(press: press), ["Escape", "ArrowDown", "ArrowUp", "Enter"].contains(k.key) || (k.ctrl && (k.key == "n" || k.key == "p")) else { return .ignored }
                    return model.pickerKey(k) ? .handled : .ignored
                }
                .onAppear { fieldFocused = true }
            }
            .padding(10)
            Divider().overlay(theme.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let list = model.pickList
                    ForEach(Array(list.enumerated()), id: \.element.path) { i, n in
                        Button { model.pick(n) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(theme.textDim)
                                Text(n.title ?? (n.path as NSString).deletingPathExtension)
                                    .foregroundStyle(theme.text)
                                Spacer()
                                Text(n.path).font(.caption).foregroundStyle(theme.textDim).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(i == model.picker?.cursor ? theme.selectionRow : .clear)
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty {
                        Text("No notes").font(.callout).foregroundStyle(theme.textDim).padding(10)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.overlayBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Gestures

    private var pointer: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                // The toolbar strip and the picker own their clicks.
                if !dragging && (g.startLocation.y < CanvasBoardModel.topInset || model.picker != nil) { return }
                if !dragging {
                    dragging = true
                    model.pointerDown(at: g.startLocation, shift: Self.shiftDown, panning: Self.spaceHeld || model.spaceDown)
                }
                model.pointerMove(to: g.location)
            }
            .onEnded { g in
                guard dragging else { return }
                dragging = false
                model.pointerUp(velocity: CGVector(dx: g.velocity.width, dy: g.velocity.height), inertia: animates && policy.allowed)
                focused = model.editing == nil && model.picker == nil
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if pinchOrigin == nil { pinchOrigin = model.viewport }
                if let o = pinchOrigin { model.pinch(g.magnification, at: g.startLocation, origin: o) }
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    static var shiftDown: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    static var commandDown: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    /// Space held right now (space+drag pans). A read-only key-state query.
    static var spaceHeld: Bool {
        #if canImport(AppKit)
        CGEventSource.keyState(.combinedSessionState, key: 49)
        #else
        false
        #endif
    }
}

/// One canvas node at world size (the parent scales it).
struct CanvasNodeCard: View {
    let node: CanvasNode
    let preview: CanvasBoardModel.PreviewState?
    let editing: Binding<String>?
    var field: FocusState<Bool>.Binding
    let onCommit: () -> Void
    @Environment(\.theme) private var theme

    private var tint: Color? { StructuredStyle.color(Canvas.color(node.color)) }

    var body: some View {
        switch node.type {
        case .group: group
        default: card
        }
    }

    private var group: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((tint ?? theme.muted).opacity(theme.isDark ? 0.10 : 0.08))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((tint ?? theme.border).opacity(0.7), lineWidth: 1.5)
            Group {
                if let editing {
                    TextField("Group label", text: editing)
                        .textFieldStyle(.plain)
                        .focused(field)
                        .onSubmit(onCommit)
                        .onKeyPress(.escape) { onCommit(); return .handled }
                        .frame(width: 220)
                } else if let label = node.label, !label.isEmpty {
                    Text(label)
                        .foregroundStyle(theme.text)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill((tint ?? theme.muted).opacity(0.22)))
            .padding(8)
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.overlayBackground)
            if let tint {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.09))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint ?? theme.border, lineWidth: tint == nil ? 1 : 2)
        }
        .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.07), radius: 3, y: 1)
    }

    @ViewBuilder
    private var content: some View {
        switch node.type {
        case .text:
            if let editing {
                TextField("Text", text: editing, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused(field)
                    .onKeyPress(.escape) { onCommit(); return .handled }
                    .padding(12)
            } else {
                CompactProse(text: node.text, scale: 0.9)
                    .padding(12)
            }
        case .file:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text((node.file as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "", options: [.anchored, .backwards, .caseInsensitive]))
                        .lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.muted.opacity(0.12))
                switch preview {
                case let .ok(md)?:
                    CompactProse(text: md, scale: 0.8).padding(12)
                case .loading?:
                    ProgressView().controlSize(.small).padding(12)
                default:
                    Text(node.file.isEmpty ? "No file" : "Note not found: \(node.file)")
                        .font(.callout)
                        .foregroundStyle(theme.textDim)
                        .padding(12)
                }
            }
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text(URL(string: node.url)?.host ?? node.url)
                        .lineLimit(1)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                Text(node.url)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            .padding(12)
        case .group:
            EmptyView()
        }
    }
}

#if canImport(AppKit)
/// Catches scroll-wheel / trackpad scroll events over the canvas (SwiftUI
/// has no wheel API on macOS): plain scroll pans, ⌘/⌃-scroll zooms at the
/// pointer. A local event monitor scoped to this view's frame.
struct ScrollWheelCatcher: NSViewRepresentable {
    let onWheel: @MainActor (CanvasGeometry.Wheel, CGPoint) -> Void

    final class CatcherView: NSView {
        var onWheel: (@MainActor (CanvasGeometry.Wheel, CGPoint) -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let mods = event.modifierFlags
                let wheel = CanvasGeometry.Wheel(
                    deltaX: -event.scrollingDeltaX, deltaY: -event.scrollingDeltaY,
                    deltaMode: event.hasPreciseScrollingDeltas ? 0 : 1,
                    ctrl: mods.contains(.control), meta: mods.contains(.command), shift: mods.contains(.shift))
                self.onWheel?(wheel, p)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onWheel = onWheel
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onWheel = onWheel }
}
#endif

/// Draws edges with a per-edge progress: all edges draw in when the canvas
/// opens; an edge added later draws on its own (soft spring).
struct EdgeDraw: View {
    let ids: [String]
    let draw: (inout GraphicsContext, (String) -> Double) -> Void
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var known: Set<String> = []
    @State private var fresh: Set<String> = []
    @State private var all: Double = 0
    @State private var one: Double = 1

    var body: some View {
        let allP: Double = clock.map { motion.value(.soft, at: $0 - 0.08) } ?? (motion.allowed ? all : 1)
        let oneP: Double = clock == nil && motion.allowed ? one : 1
        EdgeDrawLayer(all: allP, one: oneP, fresh: fresh, draw: draw)
            .onAppear {
                known = Set(ids)
                guard clock == nil else { return }
                if let a = motion.animation(.soft) { withAnimation(a.delay(0.08)) { all = 1 } } else { all = 1 }
            }
            .onChange(of: ids) { _, now in
                let added = Set(now).subtracting(known)
                known = Set(now)
                guard !added.isEmpty, motion.allowed, clock == nil else { return }
                fresh = added
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { one = 0 }
                withAnimation(motion.animation(.soft)) { one = 1 }
            }
    }
}

private struct EdgeDrawLayer: View, Animatable {
    var all: Double
    var one: Double
    let fresh: Set<String>
    let draw: (inout GraphicsContext, (String) -> Double) -> Void

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(all, one) }
        set {
            all = newValue.first
            one = newValue.second
        }
    }

    var body: some View {
        let a = min(1, max(0, all)), o = min(1, max(0, one)), f = fresh
        Canvas { ctx, _ in
            draw(&ctx) { id in f.contains(id) ? min(a, o) : a }
        }
    }
}
