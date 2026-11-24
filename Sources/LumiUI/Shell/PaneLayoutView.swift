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
    let onResize: ([Int], Int, Double) -> Void
    let leaf: (PaneLeafID, PaneContent) -> Leaf

    @Environment(\.lumiMotion) private var motion

    public init(root: PaneNode, focused: PaneLeafID?, showsFocus: Bool,
                onResize: @escaping ([Int], Int, Double) -> Void,
                @ViewBuilder leaf: @escaping (PaneLeafID, PaneContent) -> Leaf) {
        self.root = root
        self.focused = focused
        self.showsFocus = showsFocus
        self.onResize = onResize
        self.leaf = leaf
    }

    public var body: some View {
        render(root, path: [])
            .animation(motion ? .smooth(duration: 0.18) : nil, value: root)
            .animation(motion ? .smooth(duration: 0.12) : nil, value: focused)
    }

    private func render(_ node: PaneNode, path: [Int]) -> AnyView {
        switch node {
        case let .leaf(id, content):
            return AnyView(
                leaf(id, content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay { PaneFocusRing(active: showsFocus && focused == id) }
            )
        case let .split(axis, kids, weights):
            return AnyView(
                PaneSplitStack(axis: axis, weights: weights, keys: kids.map(Self.key), path: path, onResize: onResize) { i in
                    render(kids[i], path: path + [i])
                }
            )
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
struct PaneSplitStack: View {
    let axis: SplitAxis
    let weights: [Double]
    let keys: [Int]
    let path: [Int]
    let onResize: ([Int], Int, Double) -> Void
    let child: (Int) -> AnyView

    @Environment(\.lumiMotion) private var motion

    var body: some View {
        GeometryReader { geo in
            let total = axis == .vertical ? geo.size.width : geo.size.height
            let room = max(0, total - CGFloat(max(0, keys.count - 1)) * PaneDivider.thickness)
            let sizes = Self.sizes(weights: weights, count: keys.count, room: room)
            let stack = ForEach(Array(keys.enumerated()), id: \.element) { i, _ in
                Group {
                    if axis == .vertical {
                        child(i).frame(width: sizes[i])
                    } else {
                        child(i).frame(height: sizes[i])
                    }
                }
                .transition(motion
                    ? .opacity.combined(with: .move(edge: axis == .vertical ? .trailing : .bottom))
                    : .identity)
                if i < keys.count - 1 {
                    PaneDivider(axis: axis, path: path) { location in
                        // The divider's position along the split, in 0…1.
                        guard room > 0 else { return }
                        let at = Double(location / total)
                        onResize(path, i, min(1, max(0, at)))
                    }
                }
            }
            Group {
                if axis == .vertical {
                    HStack(spacing: 0) { stack }
                } else {
                    VStack(spacing: 0) { stack }
                }
            }
            .coordinateSpace(.named(PaneDivider.space(path)))
        }
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
