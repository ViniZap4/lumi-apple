import SwiftUI
import LumiKit

/// The five named springs of DESIGN-LANGUAGE §6.1 (mass 1). Same numbers
/// as the web's `motion.ts` and the TUI's harmonica springs.
public enum LumiSpring: String, CaseIterable, Sendable {
    /// Press, small UI, anything near typing.
    case snappy
    /// Things that travel: list cursor, mode pill, kanban landing, zoom.
    case glide
    /// Panes, views, list entry, folder travel.
    case gentle
    /// Overlays settling, badges popping in, node spawn.
    case bouncy
    /// Large surfaces, the home entrance, focus veils.
    case soft

    public var stiffness: Double {
        switch self {
        case .snappy: return 820
        case .glide: return 600
        case .gentle: return 420
        case .bouncy: return 620
        case .soft: return 220
        }
    }

    public var damping: Double {
        switch self {
        case .snappy: return 50
        case .glide: return 40
        case .gentle: return 36
        case .bouncy: return 30
        case .soft: return 28
        }
    }

    /// ω0 = √k (mass 1).
    public var omega: Double { stiffness.squareRoot() }
    /// ζ = c / (2√k).
    public var dampingRatio: Double { damping / (2 * omega) }

    /// The exact SwiftUI equivalent.
    public var animation: Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: damping)
    }

    /// The calmer twin used by "Movimento: suave": same stiffness, no
    /// visible overshoot (ζ ≥ 0.95).
    public var gentled: (stiffness: Double, damping: Double) {
        (stiffness, max(damping, 0.95 * 2 * omega))
    }

    /// Normalised position (0 → 1) at time `t` seconds, from rest, for a
    /// unit step. Closed form for the under-damped (and critically
    /// damped) oscillator. Drives the offscreen frame renders and lets
    /// tests pin overshoot and settle times.
    public func value(at t: Double, stiffness k: Double? = nil, damping c: Double? = nil) -> Double {
        guard t > 0 else { return 0 }
        let w0 = (k ?? stiffness).squareRoot()
        let zeta = (c ?? damping) / (2 * w0)
        if zeta < 1 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + (zeta * w0 / wd) * sin(wd * t))
        }
        // Critically / over-damped: treat as critical (the calm twin).
        return 1 - exp(-w0 * t) * (1 + w0 * t)
    }

    /// Peak overshoot past 1 (fraction).
    public var overshoot: Double {
        let z = dampingRatio
        guard z < 1 else { return 0 }
        return exp(-z * Double.pi / (1 - z * z).squareRoot())
    }

    /// Time (s) after which the position stays within `tolerance` of 1.
    public func settleTime(tolerance: Double = 0.005) -> Double {
        var last = 0.0
        var t = 0.0
        while t < 3 {
            if abs(value(at: t) - 1) > tolerance { last = t }
            t += 1.0 / 240
        }
        return last
    }
}

/// Non-spring durations (§6.1), in seconds.
public enum LumiDuration {
    public static let tap = 0.09
    public static let fade = 0.14
    public static let exit = 0.12
    public static let flash = 0.70
    public static let breath = 2.4
    public static let ambient = 48.0
}

/// The motion policy for a view tree: one place that answers "may this
/// move, and how?" (DESIGN-LANGUAGE §7.4). Injected at the root from the
/// app setting + the system's Reduce Motion.
public struct LumiMotion: Hashable, Sendable {
    public var level: MotionLevel

    public init(level: MotionLevel = .full) { self.level = level }

    public static let full = LumiMotion(level: .full)
    public static let gentle = LumiMotion(level: .gentle)
    public static let reduced = LumiMotion(level: .reduced)

    /// From the app setting and the system flag (system wins).
    public static func resolve(setting: MotionLevel, systemReduceMotion: Bool, animationsOn: Bool = true) -> LumiMotion {
        LumiMotion(level: animationsOn ? setting.effective(systemReduceMotion: systemReduceMotion) : .reduced)
    }

    public var allowed: Bool { level != .reduced }
    /// Ambient effects (home light, parallax, breathing edges).
    public var ambient: Bool { level == .full }

    /// The animation for `spring`, nil (instant) when reduced. "Suave"
    /// removes overshoot but keeps the travel.
    public func animation(_ spring: LumiSpring) -> Animation? {
        switch level {
        case .reduced: return nil
        case .gentle:
            let g = spring.gentled
            return .interpolatingSpring(mass: 1, stiffness: g.stiffness, damping: g.damping)
        case .full: return spring.animation
        }
    }

    /// Exits: a short ease-out, always faster than the entrance.
    public var exit: Animation? { allowed ? .easeOut(duration: LumiDuration.exit) : nil }
    public var fade: Animation? { allowed ? .easeInOut(duration: LumiDuration.fade) : nil }

    /// Ripple stagger (§6.2.3): 18 ms steps (12 under "suave"), at most
    /// 14 items, at most 160 ms in total.
    public func stagger(_ index: Int, step: Double = 0.018) -> Double {
        guard allowed else { return 0 }
        let s = level == .gentle ? min(step, 0.012) : step
        return min(Double(min(max(0, index), 14)) * s, 0.16)
    }

    /// Normalised spring position at `t` for this level (frame renders).
    public func value(_ spring: LumiSpring, at t: Double) -> Double {
        switch level {
        case .reduced: return 1
        case .gentle:
            let g = spring.gentled
            return spring.value(at: t, stiffness: g.stiffness, damping: g.damping)
        case .full: return spring.value(at: t)
        }
    }

    /// A transition that becomes `.identity` when reduced.
    public func transition(_ t: AnyTransition) -> AnyTransition { allowed ? t : .identity }
}

public extension EnvironmentValues {
    /// The motion policy (see `LumiMotion`). `lumiMotion` (Bool) stays
    /// for older call sites and mirrors `lumiMotionPolicy.allowed`.
    @Entry var lumiMotionPolicy: LumiMotion = .full
    /// Test-only clock: when set, time-driven views (breathing, ambient
    /// light, sweeps) render at this time (s) instead of the wall clock,
    /// so offscreen renders capture deterministic frames.
    @Entry var lumiMotionClock: Double? = nil
}

public extension View {
    /// Sets both the policy and the legacy Bool.
    func lumiMotion(_ policy: LumiMotion) -> some View {
        environment(\.lumiMotionPolicy, policy)
            .environment(\.lumiMotion, policy.allowed)
    }
}

/// `withAnimation` through the policy.
@MainActor
public func withLumiAnimation<R>(_ spring: LumiSpring, _ motion: LumiMotion, _ body: () throws -> R) rethrows -> R {
    if let a = motion.animation(spring) { return try withAnimation(a, body) }
    return try body()
}
