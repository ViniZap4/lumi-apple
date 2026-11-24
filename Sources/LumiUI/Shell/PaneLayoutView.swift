import SwiftUI
import LumiKit
#if canImport(AppKit)
import AppKit
#endif

/// Renders a pane tree (SPEC-PARTE2 §3): splits side by side / stacked
/// with draggable hairline dividers, a focus ring on the focused pane
/// while several show, and an open / close transition per pane (instant
/// under Reduce Motion via `\.lumiMotion`). What a leaf shows is the
/// host's business (`leaf`).
public struct PaneLayoutView<Leaf: View>: View {
    let root: PaneNode
    let focused: PaneLeafID?
    let showsFocus: Bool
    /// tmux-style zoom (`⌃w z`): this pane (and its preview, if drawn)
    /// fills the area; the others stay mounted — sessions, cursors and
    /// scroll positions intact — but hidden and out of reach of the mouse.
    let zoomed: PaneLeafID?
    let onResize: ([Int], Int, Double) -> Void
    let leaf: (PaneLeafID, PaneContent) -> Leaf

    @Environment(\.lumiMotion) private var motion

    public init(root: PaneNode, focused: PaneLeafID?, showsFocus: Bool, zoomed: PaneLeafID? = nil,
                onResize: @escaping ([Int], Int, Double) -> Void,
                @ViewBuilder leaf: @escaping (PaneLeafID, PaneContent) -> Leaf) {
        self.root = root
        self.focused = focused
        self.showsFocus = showsFocus
        self.zoomed = zoomed
        self.onResize = onResize
        self.leaf = leaf
    }

    /// Spring for the zoom grow / shrink (instant under Reduce Motion).
    public static var zoomAnimation: Animation { .spring(response: 0.3, dampingFraction: 0.84) }

    public var body: some View {
        render(root, path: [], hidden: false)
            .animation(motion ? .smooth(duration: 0.18) : nil, value: root)
            .animation(motion ? .smooth(duration: 0.12) : nil, value: focused)
            .animation(motion ? Self.zoomAnimation : nil, value: zoomed)
    }

    private func render(_ node: PaneNode, path: [Int], hidden: Bool) -> AnyView {
        switch node {
        case let .leaf(id, content):
            return AnyView(
                leaf(id, content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay { PaneFocusRing(active: showsFocus && zoomed == nil && focused == id) }
                    // Hidden by zoom: moved out of the window (no clicks,
                    // scrolls, drops or hovers reach it) without a resize,
                    // so nothing reflows; the move itself never animates.
                    .offset(x: hidden ? Self.away : 0)
                    .animation(nil, value: hidden)
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
            )
        case let .split(axis, kids, weights):
            let zoomIndex = zoomed.flatMap { z in kids.firstIndex { Self.contains($0, z) } }
            return AnyView(
                PaneSplitStack(axis: axis, weights: weights, keys: kids.map(Self.key), path: path,
                               zoomIndex: zoomIndex, onResize: onResize) { i in
                    render(kids[i], path: path + [i], hidden: hidden || (zoomIndex != nil && zoomIndex != i))
                }
            )
        }
    }

    /// Far enough that no window is that wide.
    static var away: CGFloat { 40_000 }

    static func contains(_ n: PaneNode, _ id: PaneLeafID) -> Bool {
        switch n {
        case let .leaf(l, _): return l == id
        case let .split(_, kids, _): return kids.contains { contains($0, id) }
        }
    }

    /// Stable identity of a subtree: its first leaf.
    static func key(_ n: PaneNode) -> Int {
        switch n {
        case let .leaf(id, _): return id.raw
        case let .split(_, kids, _): return kids.first.map(key) ?? 0
        }
    }
}

/// Thin accent outline on the pane that has the keyboard.
struct PaneFocusRing: View {
    let active: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(theme.primary.opacity(active ? 0.75 : 0), lineWidth: 1.5)
            .padding(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One split: children sized by weight, hairline dividers between them.
/// Laid out in a ZStack with explicit frames so a zoomed child can grow
/// over its siblings while they keep their size (no reflow, same views).
struct PaneSplitStack: View {
    let axis: SplitAxis
    let weights: [Double]
    let keys: [Int]
    let path: [Int]
    var zoomIndex: Int?
    let onResize: ([Int], Int, Double) -> Void
    let child: (Int) -> AnyView

    @Environment(\.lumiMotion) private var motion

    var body: some View {
        GeometryReader { geo in
            let total = axis == .vertical ? geo.size.width : geo.size.height
            let frames = Self.frames(weights: weights, count: keys.count, size: geo.size, axis: axis)
            ZStack(alignment: .topLeading) {
                ForEach(Array(keys.enumerated()), id: \.element) { i, _ in
                    let f = (zoomIndex == i) ? CGRect(origin: .zero, size: geo.size) : frames.panes[i]
                    child(i)
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                        .zIndex(zoomIndex == i ? 1 : 0)
                        .transition(motion
                            ? .opacity.combined(with: .move(edge: axis == .vertical ? .trailing : .bottom))
                            : .identity)
                }
                ForEach(Array(frames.dividers.enumerated()), id: \.offset) { i, d in
                    PaneDivider(axis: axis, path: path) { location in
                        // The divider's position along the split, in 0…1.
                        guard total > 0 else { return }
                        let at = Double(location / total)
                        onResize(path, i, min(1, max(0, at)))
                    }
                    .frame(width: d.width, height: d.height)
                    .offset(x: d.minX, y: d.minY)
                    .opacity(zoomIndex == nil ? 1 : 0)
                    .allowsHitTesting(zoomIndex == nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(.named(PaneDivider.space(path)))
        }
    }

    /// Child and divider rects for a split of `size`.
    static func frames(weights: [Double], count: Int, size: CGSize, axis: SplitAxis) -> (panes: [CGRect], dividers: [CGRect]) {
        let total = axis == .vertical ? size.width : size.height
        let room = max(0, total - CGFloat(max(0, count - 1)) * PaneDivider.thickness)
        let sizes = Self.sizes(weights: weights, count: count, room: room)
        var panes: [CGRect] = [], dividers: [CGRect] = []
        var at: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if axis == .vertical {
                panes.append(CGRect(x: at, y: 0, width: s, height: size.height))
            } else {
                panes.append(CGRect(x: 0, y: at, width: size.width, height: s))
            }
            at += s
            if i < count - 1 {
                let t = PaneDivider.thickness
                dividers.append(axis == .vertical ? CGRect(x: at, y: 0, width: t, height: size.height)
                                                  : CGRect(x: 0, y: at, width: size.width, height: t))
                at += t
            }
        }
        return (panes, dividers)
    }

    static func sizes(weights: [Double], count: Int, room: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let w = weights.count == count ? weights : Array(repeating: 1 / Double(count), count: count)
        let sum = max(w.reduce(0, +), 1e-9)
        var out = w.map { CGFloat($0 / sum) * room }
        // The last child takes the remainder so edges meet exactly.
        out[count - 1] = max(0, room - out.dropLast().reduce(0, +))
        return out
    }
}

/// Hairline divider with a wider invisible grip; drag to resize.
struct PaneDivider: View {
    static let thickness: CGFloat = 1
    static func space(_ path: [Int]) -> String { "lumi.split." + path.map(String.init).joined(separator: ".") }

    let axis: SplitAxis
    let path: [Int]
    let onDrag: (CGFloat) -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(dragging || hover ? theme.primary.opacity(0.7) : theme.border.opacity(0.8))
            .frame(width: axis == .vertical ? Self.thickness : nil, height: axis == .horizontal ? Self.thickness : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 9 : nil, height: axis == .horizontal ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hover = inside
                        #if canImport(AppKit)
                        if inside { (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                        #endif
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space(path)))
                            .onChanged { v in
                                dragging = true
                                onDrag(axis == .vertical ? v.location.x : v.location.y)
                            }
                            .onEnded { _ in dragging = false }
                    )
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel(axis == .vertical ? "Vertical pane divider" : "Horizontal pane divider")
            .accessibilityHint("⌃w < > + - resize the focused pane")
    }
}
