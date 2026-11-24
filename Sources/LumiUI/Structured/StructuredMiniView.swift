import SwiftUI
import LumiKit

/// Read-only thumbnail of a canvas or a board (explorer preview column,
/// hover cards). Never loads file nodes' contents.
public struct StructuredMiniView: View {
    let mini: StructuredMini
    public init(_ mini: StructuredMini) { self.mini = mini }

    public var body: some View {
        switch mini {
        case let .canvas(c): CanvasMiniView(mini: c)
        case let .board(b): KanbanMiniView(mini: b)
        }
    }
}

/// Fit-to-bounds mini canvas: groups, nodes, edges and colors.
public struct CanvasMiniView: View {
    let mini: CanvasMini
    @Environment(\.theme) private var theme

    public init(mini: CanvasMini) { self.mini = mini }

    public var body: some View {
        GeometryReader { geo in
            let fit = CanvasMini.fit(mini.bounds, into: geo.size, padding: 14)
            let theme = self.theme
            Canvas { ctx, _ in
                func map(_ r: CGRect) -> CGRect {
                    CGRect(x: r.minX * fit.scale + fit.offset.x, y: r.minY * fit.scale + fit.offset.y,
                           width: r.width * fit.scale, height: r.height * fit.scale)
                }
                func map(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: p.x * fit.scale + fit.offset.x, y: p.y * fit.scale + fit.offset.y)
                }
                // Groups under everything.
                for n in mini.nodes where n.type == .group {
                    let r = map(n.rect)
                    let tint = StructuredStyle.color(n.color) ?? theme.textDim
                    let path = Path(roundedRect: r, cornerRadius: 6)
                    ctx.fill(path, with: .color(tint.opacity(0.07)))
                    ctx.stroke(path, with: .color(tint.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if !n.title.isEmpty, r.width > 30 {
                        ctx.draw(Text(n.title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint),
                                 at: CGPoint(x: r.minX + 6, y: r.minY - 7), anchor: .leading)
                    }
                }
                // Edges.
                for e in mini.edges {
                    let a = map(e.from), b = map(e.to)
                    let tint = StructuredStyle.color(e.color) ?? theme.textDim.opacity(0.8)
                    var p = Path()
                    p.move(to: a)
                    p.addLine(to: b)
                    ctx.stroke(p, with: .color(tint), lineWidth: 1)
                    if e.arrow {
                        let ang = atan2(b.y - a.y, b.x - a.x), len: CGFloat = 6
                        var head = Path()
                        head.move(to: b)
                        head.addLine(to: CGPoint(x: b.x - len * cos(ang - 0.45), y: b.y - len * sin(ang - 0.45)))
                        head.addLine(to: CGPoint(x: b.x - len * cos(ang + 0.45), y: b.y - len * sin(ang + 0.45)))
                        head.closeSubpath()
                        ctx.fill(head, with: .color(tint))
                    }
                }
                // Nodes.
                for n in mini.nodes where n.type != .group {
                    let r = map(n.rect)
                    let tint = StructuredStyle.color(n.color)
                    let path = Path(roundedRect: r, cornerRadius: min(6, r.height / 4))
                    ctx.fill(path, with: .color(theme.background))
                    if let tint { ctx.fill(path, with: .color(tint.opacity(0.12))) }
                    ctx.stroke(path, with: .color((tint ?? theme.border).opacity(tint == nil ? 1 : 0.8)), lineWidth: 1)
                    guard r.width > 26, r.height > 12 else { continue }
                    let inner = r.insetBy(dx: 5, dy: 4)
                    var y = inner.minY
                    let symbol: String? = n.type == .file ? "doc.text" : (n.type == .link ? "link" : nil)
                    if let symbol {
                        let label = Text("\(Image(systemName: symbol)) \(n.title)")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(theme.text)
                        ctx.draw(ctx.resolve(label), in: CGRect(x: inner.minX, y: y, width: inner.width, height: 13))
                    } else {
                        for (i, line) in n.lines.enumerated() {
                            guard y + 11 <= inner.maxY + 2 else { break }
                            let t = Text(line).font(.system(size: i == 0 ? 9.5 : 8.5, weight: i == 0 ? .semibold : .regular))
                                .foregroundStyle(i == 0 ? theme.text : theme.textDim)
                            ctx.draw(ctx.resolve(t), in: CGRect(x: inner.minX, y: y, width: inner.width, height: 12))
                            y += i == 0 ? 13 : 11
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if mini.hiddenNodes > 0 {
                    Text("+\(mini.hiddenNodes) more")
                        .font(ShellFont.small)
                        .foregroundStyle(theme.textDim)
                        .padding(6)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Canvas preview, \(mini.nodes.count) nodes")
    }
}

/// Mini board: lanes with their first cards.
public struct KanbanMiniView: View {
    let mini: KanbanMini
    @Environment(\.theme) private var theme

    public init(mini: KanbanMini) { self.mini = mini }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(mini.lanes.enumerated()), id: \.offset) { _, lane in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(lane.title.isEmpty ? "Untitled" : lane.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(lane.count)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.textDim)
                    }
                    ForEach(Array(lane.cards.enumerated()), id: \.offset) { i, card in
                        HStack(alignment: .top, spacing: 4) {
                            if lane.checked.indices.contains(i), lane.checked[i] {
                                Image(systemName: "checkmark.square").font(.system(size: 8.5)).foregroundStyle(theme.textDim)
                            }
                            Text(card)
                                .font(.system(size: 9.5))
                                .foregroundStyle(theme.text.opacity(0.88))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.background))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(theme.border.opacity(0.7), lineWidth: 0.5))
                    }
                    if lane.count > lane.cards.count {
                        Text("+\(lane.count - lane.cards.count) more")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textDim)
                    }
                }
                .padding(6)
                .frame(minWidth: 70, maxWidth: 170, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.text.opacity(0.045)))
            }
            if mini.hiddenLanes > 0 {
                Text("+\(mini.hiddenLanes)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel("Board preview, \(mini.lanes.count) lists")
    }
}
