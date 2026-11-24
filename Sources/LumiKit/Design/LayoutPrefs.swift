import Foundation

/// "Largura de leitura" (web parity: `readingWidth` narrow | medium |
/// wide | full, default medium). The text column of the reader, Live
/// Preview and split preview. Widths are the web's character measures
/// converted for the 17 pt prose face (≈ 0.55 em per character).
public enum ReadingMeasure: String, CaseIterable, Identifiable, Sendable {
    case narrow, medium, wide, full

    public var id: String { rawValue }

    /// pt-BR label (Settings).
    public var label: String {
        switch self {
        case .narrow: return "Estreita"
        case .medium: return "Média"
        case .wide: return "Larga"
        case .full: return "Total"
        }
    }

    /// Characters per line on the web (`--md-measure`).
    public var characters: Int? {
        switch self {
        case .narrow: return 68
        case .medium: return 84
        case .wide: return 104
        case .full: return nil
        }
    }

    /// The reader's `readingWidth` (text column + both 48 pt gutters) at
    /// reading scale 1. `full` fills the pane.
    public var points: Double {
        guard let ch = characters else { return Self.fullWidth }
        return (Double(ch) * 0.55 * 17).rounded() + 2 * Self.gutter
    }

    /// The reader's side gutter on a wide pane (pt).
    public static let gutter: Double = 48

    /// Stand-in for "no limit" (the views clamp to their own width).
    public static let fullWidth: Double = 100_000

    /// Nearest measure for a legacy free-form width.
    public static func nearest(to width: Double) -> ReadingMeasure {
        if width >= 5_000 { return .full }
        return [ReadingMeasure.narrow, .medium, .wide].min { abs($0.points - width) < abs($1.points - width) } ?? .medium
    }
}

/// "Densidade" (web parity: comfortable | compact): row height of the
/// floating explorer and lists.
public enum ShellDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact

    public var id: String { rawValue }
    public var label: String { self == .comfortable ? "Confortável" : "Compacto" }
    /// Explorer / palette row height (pt).
    public var rowHeight: Double { self == .comfortable ? 28 : 22 }
    public var rowFont: Double { self == .comfortable ? 13 : 12 }
}

/// "Movimento" (DESIGN-LANGUAGE §7.4): full choreography, a softer one
/// (no overshoot, no parallax, shorter staggers), or reduced (instant
/// state changes; also forced by the system's Reduce Motion).
public enum MotionLevel: String, CaseIterable, Identifiable, Sendable {
    case full, gentle, reduced

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .full: return "Completo"
        case .gentle: return "Suave"
        case .reduced: return "Reduzido"
        }
    }

    /// The level that actually applies, given the system setting.
    public func effective(systemReduceMotion: Bool) -> MotionLevel {
        systemReduceMotion ? .reduced : self
    }
}
