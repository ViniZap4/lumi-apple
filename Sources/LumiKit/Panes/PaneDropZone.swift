import Foundation

/// Where a note dragged from the explorer lands on a pane (SPEC-PARTE2
/// §3 "Opening in a split from the explorer by mouse"): one of the four
/// edges splits the pane on that side; the middle opens the note in the
/// pane itself. Pure — the views only draw what it says.
public enum PaneDropZone: String, Sendable, Hashable, CaseIterable {
    case left, right, top, bottom, center

    /// Share of the pane's width / height, from each edge, that counts as
    /// "the edge". The rest is the centre.
    public static let edgeBand = 0.3

    /// The zone under `point` in a pane of `size` (top-left origin).
    public static func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        let fx = Double(point.x / size.width), fy = Double(point.y / size.height)
        // Distance to each edge in pane fractions; the nearest edge inside
        // the band wins.
        let candidates: [(PaneDropZone, Double)] = [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < edgeBand else { return .center }
        return nearest.0
    }

    /// The split this zone makes; nil for the centre (open here).
    public var axis: SplitAxis? {
        switch self {
        case .left, .right: return .vertical
        case .top, .bottom: return .horizontal
        case .center: return nil
        }
    }

    /// The new pane goes before (left / above) the target.
    public var before: Bool { self == .left || self == .top }

    /// The part of the pane the highlight covers, in unit space.
    public var highlight: PaneRect {
        switch self {
        case .left: return PaneRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return PaneRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: return PaneRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: return PaneRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .center: return PaneRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    public var label: String {
        switch self {
        case .left: return "Open left"
        case .right: return "Open right"
        case .top: return "Open above"
        case .bottom: return "Open below"
        case .center: return "Open here"
        }
    }
}
