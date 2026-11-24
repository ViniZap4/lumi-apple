import Foundation
import CoreGraphics

// Canvas viewport + geometry math — port of web-client
// `lib/canvas/canvas-view.ts`. Pure.
//
// The viewport maps world → screen as `screen = world * zoom + (x, y)`.

public struct CanvasViewport: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var zoom: Double
    public init(x: Double = 0, y: Double = 0, zoom: Double = 1) { self.x = x; self.y = y; self.zoom = zoom }
}

public struct CanvasEdgeGeometry: Sendable, Equatable {
    /// SVG path (`M x y C …`), for parity tests and debugging.
    public var d: String
    public var from: CGPoint
    public var to: CGPoint
    public var c1: CGPoint
    public var c2: CGPoint
    /// Point at t = 0.5 (label anchor).
    public var mid: CGPoint
    /// Direction at the end (radians), for the arrow head.
    public var endAngle: Double
    public var startAngle: Double
}

public enum CanvasGeometry {
    public static let minZoom = 0.1
    public static let maxZoom = 4.0
    public static let zoomStep = 1.2

    public static func clampZoom(_ z: Double) -> Double { min(maxZoom, max(minZoom, z)) }

    public static func toScreen(_ v: CanvasViewport, _ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * v.zoom + v.x, y: p.y * v.zoom + v.y)
    }

    public static func toWorld(_ v: CanvasViewport, _ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - v.x) / v.zoom, y: (p.y - v.y) / v.zoom)
    }

    public static func toScreen(_ v: CanvasViewport, _ r: CGRect) -> CGRect {
        CGRect(origin: toScreen(v, r.origin), size: CGSize(width: r.width * v.zoom, height: r.height * v.zoom))
    }

    /// Zoom by `factor` keeping the screen point (sx, sy) fixed.
    public static func zoomAt(_ v: CanvasViewport, _ sx: Double, _ sy: Double, _ factor: Double) -> CanvasViewport {
        let zoom = clampZoom(v.zoom * factor)
        let k = zoom / v.zoom
        return CanvasViewport(x: sx - (sx - v.x) * k, y: sy - (sy - v.y) * k, zoom: zoom)
    }

    public static func panBy(_ v: CanvasViewport, _ dx: Double, _ dy: Double) -> CanvasViewport {
        CanvasViewport(x: v.x + dx, y: v.y + dy, zoom: v.zoom)
    }

    public struct Wheel: Sendable {
        public var deltaX: Double
        public var deltaY: Double
        /// 0 pixels, 1 lines, 2 pages (DOM `deltaMode`).
        public var deltaMode: Int
        public var ctrl: Bool
        public var meta: Bool
        public var shift: Bool
        public init(deltaX: Double, deltaY: Double, deltaMode: Int = 0, ctrl: Bool = false, meta: Bool = false, shift: Bool = false) {
            self.deltaX = deltaX; self.deltaY = deltaY; self.deltaMode = deltaMode
            self.ctrl = ctrl; self.meta = meta; self.shift = shift
        }
    }

    /// Wheel → viewport. Ctrl/Cmd+wheel (and trackpad pinch, which arrives
    /// as ctrl+wheel on the web) zooms; otherwise pans.
    public static func wheel(_ v: CanvasViewport, _ e: Wheel, at: CGPoint) -> CanvasViewport {
        let unit: Double = e.deltaMode == 1 ? 16 : e.deltaMode == 2 ? 400 : 1
        let dx = e.deltaX * unit
        let dy = e.deltaY * unit
        if e.ctrl || e.meta { return zoomAt(v, at.x, at.y, exp(-dy * 0.01)) }
        if e.shift && dx == 0 { return panBy(v, -dy, 0) }
        return panBy(v, -dx, -dy)
    }

    public static func bounds(_ rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        var x0 = first.minX, y0 = first.minY, x1 = first.maxX, y1 = first.maxY
        for r in rects.dropFirst() {
            x0 = min(x0, r.minX); y0 = min(y0, r.minY)
            x1 = max(x1, r.maxX); y1 = max(y1, r.maxY)
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Viewport that fits `r` into a w×h screen with padding (never zooms
    /// past `maxZoom`).
    public static func fit(_ r: CGRect?, _ w: Double, _ h: Double, pad: Double = 48, maxZoom: Double = 1) -> CanvasViewport {
        guard let r, w > 0, h > 0 else { return CanvasViewport(x: w / 2, y: h / 2, zoom: 1) }
        let zoom = clampZoom(min(maxZoom, (w - 2 * pad) / max(1, r.width), (h - 2 * pad) / max(1, r.height)))
        return CanvasViewport(x: w / 2 - (r.minX + r.width / 2) * zoom, y: h / 2 - (r.minY + r.height / 2) * zoom, zoom: zoom)
    }

    public static func sidePoint(_ n: CGRect, _ side: CanvasSide) -> CGPoint {
        switch side {
        case .top: return CGPoint(x: n.minX + n.width / 2, y: n.minY)
        case .bottom: return CGPoint(x: n.minX + n.width / 2, y: n.minY + n.height)
        case .left: return CGPoint(x: n.minX, y: n.minY + n.height / 2)
        case .right: return CGPoint(x: n.minX + n.width, y: n.minY + n.height / 2)
        }
    }

    static func normal(_ s: CanvasSide) -> CGPoint {
        switch s {
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: -1, y: 0)
        case .right: return CGPoint(x: 1, y: 0)
        }
    }

    /// Side of `n` closest to `p` (by distance to the side midpoints).
    public static func nearestSide(_ n: CGRect, _ p: CGPoint) -> CanvasSide {
        var best = CanvasSide.top
        var bd = Double.infinity
        for s in [CanvasSide.top, .right, .bottom, .left] {
            let q = sidePoint(n, s)
            let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if d < bd { best = s; bd = d }
        }
        return best
    }

    /// Sides facing each other, for edges that omit them.
    public static func autoSides(_ a: CGRect, _ b: CGRect) -> (CanvasSide, CanvasSide) {
        let dx = b.minX + b.width / 2 - (a.minX + a.width / 2)
        let dy = b.minY + b.height / 2 - (a.minY + a.height / 2)
        if abs(dx) >= abs(dy) { return dx >= 0 ? (.right, .left) : (.left, .right) }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }

    public static func cubicAt(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x,
            y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y
        )
    }

    static func r1(_ v: Double) -> String { JSNumber.format(JSNumber.round(v * 10) / 10) }

    /// Curved edge between two side points; control arms follow the side normals.
    public static func curve(_ from: CGPoint, _ fromSide: CanvasSide, _ to: CGPoint, _ toSide: CanvasSide?) -> CanvasEdgeGeometry {
        let dist = hypot(to.x - from.x, to.y - from.y)
        let arm = min(220, max(36, dist * 0.42))
        let n0 = normal(fromSide)
        let c1 = CGPoint(x: from.x + n0.x * arm, y: from.y + n0.y * arm)
        let dn = dist == 0 ? 1 : dist
        let n1 = toSide.map(normal) ?? CGPoint(x: (from.x - to.x) / dn, y: (from.y - to.y) / dn)
        let c2 = CGPoint(x: to.x + n1.x * arm, y: to.y + n1.y * arm)
        return CanvasEdgeGeometry(
            d: "M \(r1(from.x)) \(r1(from.y)) C \(r1(c1.x)) \(r1(c1.y)), \(r1(c2.x)) \(r1(c2.y)), \(r1(to.x)) \(r1(to.y))",
            from: from, to: to, c1: c1, c2: c2,
            mid: cubicAt(from, c1, c2, to, 0.5),
            endAngle: atan2(to.y - c2.y, to.x - c2.x),
            startAngle: atan2(from.y - c1.y, from.x - c1.x)
        )
    }

    public static func edgeGeometry(_ e: CanvasEdge, _ a: CGRect, _ b: CGRect) -> CanvasEdgeGeometry {
        let (fa, tb) = autoSides(a, b)
        let fs = e.fromSide ?? fa
        let ts = e.toSide ?? tb
        return curve(sidePoint(a, fs), fs, sidePoint(b, ts), ts)
    }

    /// Arrow head triangle at `p` pointing along `angle`.
    public static func arrowHead(_ p: CGPoint, _ angle: Double, size: Double = 10) -> [CGPoint] {
        let a1 = angle + .pi - 0.45
        let a2 = angle + .pi + 0.45
        return [p, CGPoint(x: p.x + cos(a1) * size, y: p.y + sin(a1) * size), CGPoint(x: p.x + cos(a2) * size, y: p.y + sin(a2) * size)]
    }

    public static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX && inner.minY >= outer.minY && inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
    }

    static func inside(_ n: CanvasNode, _ p: CGPoint) -> Bool {
        p.x >= n.x && p.y >= n.y && p.x <= n.x + n.width && p.y <= n.y + n.height
    }

    /// Topmost node under `p`; groups only when nothing else is hit.
    public static func hitNode(_ nodes: [CanvasNode], _ p: CGPoint) -> CanvasNode? {
        if let n = nodes.last(where: { $0.type != .group && inside($0, p) }) { return n }
        return nodes.last(where: { $0.type == .group && inside($0, p) })
    }

    /// Distance from `p` to the edge curve (sampled), for edge hit testing.
    public static func distance(_ p: CGPoint, to g: CanvasEdgeGeometry, samples: Int = 24) -> Double {
        var best = Double.infinity
        var prev = g.from
        for i in 1...samples {
            let q = cubicAt(g.from, g.c1, g.c2, g.to, Double(i) / Double(samples))
            best = min(best, segmentDistance(p, prev, q))
            prev = q
        }
        return best
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Reading order (top-to-bottom, then left-to-right) for Tab cycling;
    /// groups last. Stable.
    public static func readingOrder(_ nodes: [CanvasNode]) -> [CanvasNode] {
        nodes.enumerated().sorted { l, r in
            let a = l.element, b = r.element
            if (a.type == .group) != (b.type == .group) { return b.type == .group }
            let row = JSNumber.round(a.y / 40) - JSNumber.round(b.y / 40)
            if row != 0 { return row < 0 }
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return l.offset < r.offset
        }.map(\.element)
    }

    public static func snap(_ v: Double, grid: Double = 20) -> Double { JSNumber.round(v / grid) * grid }
}
