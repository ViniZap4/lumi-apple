import SwiftUI

// "The app should feel alive" (SPEC-PARTE2 §1): springs, staggered
// lists, hover lift / press scale, the shared-element open. Everything
// here is off when `lumiMotion` (system + app Reduce Motion) is false.

public extension View {
    /// List rows fade / slide in one after another when a list appears
    /// (capped, so long lists land fast). Off under Reduce Motion.
    func staggerIn(_ index: Int, active: Bool) -> some View {
        modifier(StaggerIn(index: index, active: active))
    }
}

private struct StaggerIn: ViewModifier {
    let index: Int
    let active: Bool
    @Environment(\.lumiMotionPolicy) private var motion

    func body(content: Content) -> some View {
        // A ripple, not a queue (§6.2.3): 18 ms steps, ≤ 14 items,
        // ≤ 160 ms; rows are interactive from frame 0.
        content.lumiEnter(active ? .rise : MotionFrom(), spring: .gentle, delay: motion.stagger(index))
    }
}

/// Hover lift and press scale for interactive chrome.
public struct LiftButtonStyle: ButtonStyle {
    var enabled: Bool

    public init(enabled: Bool = true) { self.enabled = enabled }

    public func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration, enabled: enabled)
    }

    private struct LiftBody: View {
        let configuration: Configuration
        let enabled: Bool
        @State private var hover = false

        var body: some View {
            // Press 0.96 at tap speed, release on snappy; hover lifts 1 pt.
            configuration.label
                .scaleEffect(enabled && configuration.isPressed ? 0.96 : 1)
                .offset(y: enabled && hover && !configuration.isPressed ? -1 : 0)
                .shadow(color: .black.opacity(enabled && hover ? 0.14 : 0), radius: 4, y: 2)
                .onHover { hover = $0 }
                .animation(enabled ? (configuration.isPressed ? .easeOut(duration: LumiDuration.tap) : LumiSpring.snappy.animation) : nil,
                           value: configuration.isPressed)
                .animation(enabled ? LumiSpring.snappy.animation : nil, value: hover)
        }
    }
}

/// The shared-element open: a row-shaped card interpolated between the
/// explorer row (`from`) and the note area (`to`) by `progress` (0…1).
/// The host animates `progress` with a spring.
public struct OpenMorphView: View, Animatable {
    let from: CGRect
    let to: CGRect
    var progress: CGFloat
    let title: String
    @Environment(\.theme) private var theme

    public init(from: CGRect, to: CGRect, progress: CGFloat, title: String) {
        self.from = from
        self.to = to
        self.progress = progress
        self.title = title
    }

    nonisolated public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    public var body: some View {
        let p = max(0, min(1.05, progress))
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let r = CGRect(x: lerp(from.minX, to.minX), y: lerp(from.minY, to.minY),
                       width: lerp(from.width, to.width), height: lerp(from.height, to.height))
        return RoundedRectangle(cornerRadius: lerp(4, 8), style: .continuous)
            .fill(theme.background)
            .overlay(RoundedRectangle(cornerRadius: lerp(4, 8), style: .continuous).fill(theme.selectionRow.opacity(Double(1 - p * 0.7))))
            .overlay(RoundedRectangle(cornerRadius: lerp(4, 8), style: .continuous).stroke(theme.accent.opacity(0.35), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: lerp(4, 14)) {
                    Text(title)
                        .font(.system(size: lerp(12.5, 26), weight: p > 0.5 ? .semibold : .regular))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    // The note's first lines, as the shape settles.
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.text.opacity(0.08))
                            .frame(width: lerp(40, [520, 470, 560, 300][i]), height: lerp(2, 10))
                    }
                    .opacity(Double(max(0, p - 0.25) / 0.75))
                }
                .padding(.leading, lerp(32, 56))
                .padding(.top, lerp(5, 40))
            }
            .clipped()
            .shadow(color: .black.opacity(0.18 * Double(1 - abs(p - 0.5) * 2)), radius: 18, y: 8)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
    }
}
