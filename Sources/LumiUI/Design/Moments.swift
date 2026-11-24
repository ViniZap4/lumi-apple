import SwiftUI
import LumiKit

// The motion vocabulary of the shell (DESIGN-LANGUAGE §6). Every piece
// here:
//  - decorates state that is already final (input never waits);
//  - is a spring, so a new change mid-flight retargets (interruptible);
//  - animates transform / opacity / small blur only (120 Hz friendly);
//  - collapses to the final frame under `LumiMotion.reduced`;
//  - honours `lumiMotionClock`, so offscreen tests can render any frame.

/// Where an entering element starts. Identity is `MotionFrom()`.
public struct MotionFrom: Hashable, Sendable {
    public var scale: Double = 1
    public var x: Double = 0
    public var y: Double = 0
    public var opacity: Double = 1
    public var blur: Double = 0
    /// Degrees around the y axis (a cover opening), anchored at `anchor`.
    public var turn: Double = 0
    public var anchor: UnitPoint = .center

    public init(scale: Double = 1, x: Double = 0, y: Double = 0, opacity: Double = 1, blur: Double = 0,
                turn: Double = 0, anchor: UnitPoint = .center) {
        self.scale = scale
        self.x = x
        self.y = y
        self.opacity = opacity
        self.blur = blur
        self.turn = turn
        self.anchor = anchor
    }

    /// Floating panels: up from 10 pt, 0.965 → 1 (§8 #1).
    public static func overlay(from anchor: UnitPoint = .center) -> MotionFrom {
        MotionFrom(scale: 0.94, y: 10, opacity: 0, anchor: anchor)
    }
    /// List rows / blocks: 6 pt rise + fade.
    public static let rise = MotionFrom(y: 6, opacity: 0)
    /// Content resolving out of loading: 3 pt rise, 2 pt blur clearing.
    public static let resolve = MotionFrom(y: 3, opacity: 0, blur: 2)
    /// Folder travel: the column slides 14 pt from the side it came from.
    public static func travel(forward: Bool) -> MotionFrom { MotionFrom(x: forward ? 14 : -14, opacity: 0.2) }
    /// Badges, nodes, avatars: pop from 0.92.
    public static let pop = MotionFrom(scale: 0.92, opacity: 0)
    /// A new split pane unfolding from its divider.
    public static func unfold(edge: Edge) -> MotionFrom {
        switch edge {
        case .leading: return MotionFrom(scale: 0.985, x: -18, opacity: 0, anchor: .leading)
        case .trailing: return MotionFrom(scale: 0.985, x: 18, opacity: 0, anchor: .leading)
        case .top: return MotionFrom(scale: 0.985, y: -18, opacity: 0, anchor: .top)
        case .bottom: return MotionFrom(scale: 0.985, y: 18, opacity: 0, anchor: .top)
        }
    }
    /// Switching books: the new book opens like a cover from its spine.
    public static let cover = MotionFrom(scale: 0.97, opacity: 0, turn: -18, anchor: .leading)
}

/// Applies `from` at progress `p` (0 = start, 1 = rest; springs overshoot
/// past 1, which is what makes things feel weighted).
struct MotionFromEffect: ViewModifier, Animatable {
    var from: MotionFrom
    var p: Double

    nonisolated var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        let q = 1 - p
        let opacity = min(1, max(0, from.opacity + (1 - from.opacity) * min(1, max(0, p) * 1.7)))
        content
            .scaleEffect(1 + (from.scale - 1) * q, anchor: from.anchor)
            .offset(x: from.x * q, y: from.y * q)
            .rotation3DEffect(.degrees(from.turn * q), axis: (0, 1, 0), anchor: from.anchor, perspective: 0.6)
            .blur(radius: max(0, from.blur * q))
            .opacity(opacity)
    }
}

struct LumiEnter<Trigger: Equatable>: ViewModifier {
    let from: MotionFrom
    let spring: LumiSpring
    let delay: Double
    let trigger: Trigger
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var p: Double = 0

    func body(content: Content) -> some View {
        let progress: Double = clock.map { motion.value(spring, at: $0 - delay) } ?? (motion.allowed ? p : 1)
        content
            .modifier(MotionFromEffect(from: from, p: progress))
            .onAppear(perform: run)
            .onChange(of: trigger) { _, _ in
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { p = 0 }
                run()
            }
    }

    private func run() {
        guard clock == nil else { return }
        guard let a = motion.animation(spring) else { p = 1; return }
        withAnimation(a.delay(delay)) { p = 1 }
    }
}

public extension View {
    /// Enter from `from` on `spring` (after `delay`), replaying whenever
    /// `trigger` changes.
    func lumiEnter<T: Equatable>(_ from: MotionFrom, spring: LumiSpring = .gentle, delay: Double = 0, trigger: T) -> some View {
        modifier(LumiEnter(from: from, spring: spring, delay: delay, trigger: trigger))
    }

    func lumiEnter(_ from: MotionFrom, spring: LumiSpring = .gentle, delay: Double = 0) -> some View {
        modifier(LumiEnter(from: from, spring: spring, delay: delay, trigger: 0))
    }

    /// The content behind a floating panel recedes: a touch smaller,
    /// dimmer and out of focus (depth, not glass: §3 forbids stacking).
    func lumiRecede(_ active: Bool) -> some View {
        modifier(Recede(active: active))
    }

    /// Opacity breathing (presence, sync, the focused pane's edge).
    func lumiBreathing(low: Double = 0.55, period: Double = 5.2, active: Bool = true) -> some View {
        modifier(Breathing(low: low, period: period, active: active))
    }

    /// One damped shake (§6.5 error), replayed when `trigger` changes.
    func lumiShake<T: Equatable>(trigger: T, onAppear: Bool = false) -> some View {
        modifier(Shake(trigger: trigger, onAppear: onAppear))
    }

    /// Hover lift + press scale for cards and rows.
    func lumiHoverLift(_ lift: Double = 1.5) -> some View { modifier(HoverLift(lift: lift)) }
}

struct Recede: ViewModifier {
    let active: Bool
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock

    func body(content: Content) -> some View {
        let p: Double = clock.map { motion.value(.soft, at: $0) * (active ? 1 : 0) } ?? (active ? 1 : 0)
        let deep = motion.ambient
        content
            .modifier(RecedeEffect(p: p, blur: deep ? 2.5 : 0, scale: motion.allowed ? 0.985 : 1))
            .animation(active ? motion.animation(.soft) : motion.exit, value: active)
    }
}

struct RecedeEffect: ViewModifier, Animatable {
    var p: Double
    let blur: Double
    let scale: Double
    nonisolated var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + (scale - 1) * p)
            .blur(radius: blur * p)
            .saturation(1 - 0.15 * p)
    }
}

struct Breathing: ViewModifier {
    let low: Double
    let period: Double
    let active: Bool
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var exhale = false

    func body(content: Content) -> some View {
        let on = active && motion.ambient
        let opacity: Double
        if let t = clock, on {
            opacity = low + (1 - low) * (0.5 + 0.5 * cos(2 * .pi * t / period))
        } else {
            opacity = on && exhale ? low : 1
        }
        return content
            .opacity(opacity)
            .onAppear { start(on) }
            .onChange(of: on) { _, v in start(v) }
    }

    private func start(_ on: Bool) {
        guard clock == nil else { return }
        if on {
            withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) { exhale = true }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { exhale = false }
        }
    }
}

struct Shake<T: Equatable>: ViewModifier {
    let trigger: T
    let onAppear: Bool
    @Environment(\.lumiMotionPolicy) private var motion
    @State private var phase: Double = 1

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(phase: phase))
            .onAppear { if onAppear { run() } }
            .onChange(of: trigger) { _, _ in run() }
    }

    private func run() {
        guard motion.allowed else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { phase = 0 }
        withAnimation(.linear(duration: 0.36)) { phase = 1 }
    }
}

/// 5 → 4 → 2.5 → 1 px, damped.
struct ShakeEffect: GeometryEffect {
    var phase: Double
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = 5 * sin(phase * .pi * 8) * (1 - phase)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

struct HoverLift: ViewModifier {
    let lift: Double
    @Environment(\.lumiMotionPolicy) private var motion
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .offset(y: hover && motion.allowed ? -lift : 0)
            .onHover { hover = $0 }
            .animation(motion.animation(.snappy), value: hover)
    }
}

// MARK: - Sync dot

/// The sync dot: breathes while syncing, sends one ripple on a remote
/// change (`pulse` changes), steady otherwise.
public struct SyncPulseDot: View {
    let color: Color
    let size: CGFloat
    let syncing: Bool
    let pulse: Int
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var ripple: Double = 1

    public init(color: Color, size: CGFloat = 7, syncing: Bool, pulse: Int) {
        self.color = color
        self.size = size
        self.syncing = syncing
        self.pulse = pulse
    }

    public var body: some View {
        let r: Double = clock.map { pulse > 0 ? min(1, max(0, $0 / LumiDuration.flash)) : 1 } ?? ripple
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.5)
                .scaleEffect(1 + 1.6 * r)
                .opacity(motion.allowed ? 0.9 * (1 - r) : 0)
            Circle()
                .fill(color)
                .lumiBreathing(low: 0.35, period: 1.6, active: syncing)
        }
        .frame(width: size, height: size)
        .onChange(of: pulse) { _, _ in
            guard motion.allowed, clock == nil else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { ripple = 0 }
            withAnimation(.easeOut(duration: LumiDuration.flash)) { ripple = 1 }
        }
    }
}

// MARK: - Vim mode edge

/// The editing pane's 2 pt left edge in the mode colour (§6.7). On a
/// mode change the new colour sweeps down the edge (fade 140 ms + a
/// 260 ms glide of the front), so the change is seen, not just noticed.
public struct ModeEdge: View {
    let color: Color
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var previous: Color?
    @State private var sweep: Double = 1

    /// `from`: the colour the sweep starts over (frame renders; live,
    /// it is whatever the edge showed before the change).
    public init(color: Color, from: Color? = nil) {
        self.color = color
        _previous = State(initialValue: from)
    }

    public var body: some View {
        let s: Double = clock.map { motion.value(.glide, at: $0) } ?? sweep
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [previous ?? color, (previous ?? color).opacity(0.15)], startPoint: .top, endPoint: .bottom))
                Rectangle()
                    .fill(LinearGradient(colors: [color, color.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                    .frame(height: geo.size.height * max(0, min(1.05, s)))
                    .shadow(color: color.opacity(0.55 * (1 - min(1, s))), radius: 6)
                    .overlay(alignment: .bottom) {
                        // The sweep's bright front, fading as it lands.
                        Capsule().fill(color)
                            .frame(width: 4, height: 28)
                            .blur(radius: 3)
                            .opacity(s < 1 ? 0.9 * (1 - s) + 0.2 : 0)
                    }
            }
        }
        .frame(width: 2)
        .allowsHitTesting(false)
        .onChange(of: color) { old, _ in
            guard motion.allowed, clock == nil else { previous = nil; return }
            previous = old
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { sweep = 0 }
            withAnimation(motion.animation(.glide)) { sweep = 1 }
        }
    }
}

// MARK: - Ambient home light

/// Two very soft blooms of primary and secondary drifting on 48 s / 61 s
/// cycles (transform only), with a gentle pointer parallax. Off (static)
/// unless motion is "completo".
public struct LivingGradient: View {
    @Environment(\.theme) private var theme
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var drift = false
    @State private var pointer: CGPoint?

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let m = max(w, h)
            // Same curve as the 48 s autoreversing ease (for frame renders).
            let phase: Double = clock.map { 0.5 - 0.5 * cos(.pi * $0 / LumiDuration.ambient) } ?? (drift ? 1 : 0)
            let par = parallax(in: geo.size)
            ZStack {
                bloom(theme.primary, diameter: m * 0.78, alpha: theme.isDark ? 0.20 : 0.16)
                    .offset(x: -w * 0.22 + w * 0.10 * phase + par.width * 1.4, y: -h * 0.28 + h * 0.06 * phase + par.height * 1.4)
                    .rotationEffect(.degrees(8 * phase))
                    .animation(drift && clock == nil ? .easeInOut(duration: LumiDuration.ambient).repeatForever(autoreverses: true) : nil, value: drift)
                bloom(theme.secondary, diameter: m * 0.64, alpha: theme.isDark ? 0.16 : 0.12)
                    .offset(x: w * 0.26 - w * 0.08 * phase - par.width, y: h * 0.18 - h * 0.08 * phase - par.height)
                    .animation(drift && clock == nil ? .easeInOut(duration: 61).repeatForever(autoreverses: true) : nil, value: drift)
            }
            .frame(width: w, height: h)
            .animation(motion.animation(.soft), value: pointer)
            .onContinuousHover { phase in
                guard motion.ambient else { return }
                switch phase {
                case let .active(p): pointer = p
                case .ended: pointer = nil
                }
            }
        }
        .clipped()
        .allowsHitTesting(motion.ambient)
        .onAppear { if motion.ambient, clock == nil { drift = true } }
        .accessibilityHidden(true)
    }

    private func parallax(in size: CGSize) -> CGSize {
        guard let p = pointer, motion.ambient else { return .zero }
        return CGSize(width: (p.x / max(1, size.width) - 0.5) * 24, height: (p.y / max(1, size.height) - 0.5) * 16)
    }

    private func bloom(_ c: Color, diameter: CGFloat, alpha: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [c.opacity(alpha), c.opacity(alpha * 0.35), .clear], center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Focus light

/// The lit pane (§6.3): accent ring, a top edge that breathes, an accent
/// wash fading down 90 pt. Lives in one place per layout and travels
/// between panes through `matchedGeometryEffect`, so focus is seen
/// moving.
public struct FocusLight: View {
    @Environment(\.theme) private var theme
    let radius: CGFloat

    public init(radius: CGFloat = 0) { self.radius = radius }

    public var body: some View {
        let ramp = theme.ramp
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(ramp.accentLine, lineWidth: 1)
            LinearGradient(colors: [ramp.accentWash, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, theme.primary, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
                .shadow(color: ramp.accentGlow, radius: 6, y: 1)
                .lumiBreathing(low: 0.55, period: 5.2)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Content reveal

/// Real content resolving in by bands, top first (§6.8, "note content
/// rising in by blocks"): a soft mask edge travels down while the text
/// rises 4 pt. Works over any view, including TextKit hosts.
public struct RevealByBlocks: ViewModifier {
    let trigger: AnyHashable
    @Environment(\.lumiMotionPolicy) private var motion
    @Environment(\.lumiMotionClock) private var clock
    @State private var p: Double = 1

    public init(trigger: AnyHashable) { self.trigger = trigger }

    public func body(content: Content) -> some View {
        let q: Double = clock.map { motion.value(.gentle, at: $0 / 1.6) } ?? (motion.allowed ? p : 1)
        content
            .modifier(RevealEffect(p: q))
            .onAppear { run() }
            .onChange(of: trigger) { _, _ in run() }
    }

    private func run() {
                guard motion.allowed, clock == nil else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { p = 0 }
                // Leave first, then arrive (§6.2.6): 70 ms behind the exit.
                withAnimation(LumiSpring.gentle.animation.speed(0.6).delay(0.07)) { p = 1 }
    }
}

struct RevealEffect: ViewModifier, Animatable {
    var p: Double
    nonisolated var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        let front = max(0, min(1.2, p)) * 1.25 // band edge, 0…1.5 of the height
        content
            .offset(y: 4 * (1 - min(1, p)))
            .mask {
                GeometryReader { geo in
                    let solid = min(0.999, max(0, front - 0.18))
                    let edge = min(1, max(solid + 0.001, front))
                    // Past the bottom the fading stop turns opaque: at rest
                    // the mask is fully black (no structural change, so a
                    // hosted TextKit view is never rebuilt).
                    let tail = front > 1 ? min(1, (front - 1) / 0.18) : 0
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: solid),
                        .init(color: .black.opacity(tail), location: edge),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height)
                }
            }
    }
}

public extension View {
    func lumiReveal(trigger: AnyHashable) -> some View { modifier(RevealByBlocks(trigger: trigger)) }
}

public extension EnvironmentValues {
    /// The namespace a list's cursor slab travels in (matched geometry).
    @Entry var lumiSlab: Namespace.ID? = nil
    /// "Densidade" of rows.
    @Entry var lumiDensity: ShellDensity = .comfortable
}
