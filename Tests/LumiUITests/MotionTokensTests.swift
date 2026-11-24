import Testing
import SwiftUI
import LumiKit
@testable import LumiUI

@Suite("Motion language: springs, policy, tokens (DESIGN-LANGUAGE §6)")
struct MotionTokensTests {
    @Test("the five springs keep the table's numbers (k, c, ζ)")
    func numbers() {
        let table: [(LumiSpring, Double, Double, Double)] = [
            (.snappy, 820, 50, 0.87), (.glide, 600, 40, 0.82), (.gentle, 420, 36, 0.88), (.bouncy, 620, 30, 0.60), (.soft, 220, 28, 0.94),
        ]
        for (s, k, c, z) in table {
            #expect(s.stiffness == k && s.damping == c)
            #expect(abs(s.dampingRatio - z) < 0.01, "\(s): ζ \(s.dampingRatio)")
        }
    }

    @Test("overshoot and settle match the table (bouncy ~9%, glide ~1%, soft none)")
    func behaviour() {
        #expect(abs(LumiSpring.bouncy.overshoot - 0.09) < 0.015)
        #expect(LumiSpring.glide.overshoot > 0.005 && LumiSpring.glide.overshoot < 0.02)
        #expect(LumiSpring.soft.overshoot < 0.001)
        // Sampled peak agrees with the closed form.
        let peak = stride(from: 0.0, through: 0.6, by: 1 / 480).map { LumiSpring.bouncy.value(at: $0) }.max() ?? 0
        #expect(abs((peak - 1) - LumiSpring.bouncy.overshoot) < 0.005)
        // Settle: every response spring is done well inside 450 ms.
        for s in LumiSpring.allCases { #expect(s.settleTime() < 0.45, "\(s) settles in \(s.settleTime())") }
        #expect(LumiSpring.snappy.settleTime() < LumiSpring.soft.settleTime())
        #expect(LumiSpring.gentle.value(at: 0) == 0)
        #expect(abs(LumiSpring.gentle.value(at: 2) - 1) < 1e-4)
    }

    @Test("Movimento gates every animation: completo, suave (no overshoot), reduzido (instant)")
    func policy() {
        #expect(LumiMotion.full.animation(.bouncy) != nil)
        #expect(LumiMotion.reduced.animation(.bouncy) == nil)
        #expect(LumiMotion.reduced.exit == nil && LumiMotion.reduced.fade == nil)
        #expect(LumiMotion.gentle.animation(.bouncy) != nil)
        // Suave keeps the travel but never overshoots.
        let g = LumiSpring.bouncy.gentled
        #expect(g.damping / (2 * g.stiffness.squareRoot()) >= 0.95)
        let gentlePeak = stride(from: 0.0, through: 0.8, by: 1 / 240).map { LumiMotion.gentle.value(.bouncy, at: $0) }.max() ?? 0
        #expect(gentlePeak <= 1.0005)
        // Reduced renders the final frame at any time.
        #expect(LumiMotion.reduced.value(.soft, at: 0) == 1)
        // Ambient only when completo.
        #expect(LumiMotion.full.ambient && !LumiMotion.gentle.ambient && !LumiMotion.reduced.ambient)
        // System Reduce Motion wins over the setting; the animate toggle too.
        #expect(LumiMotion.resolve(setting: .full, systemReduceMotion: true).level == .reduced)
        #expect(LumiMotion.resolve(setting: .full, systemReduceMotion: false, animationsOn: false).level == .reduced)
        #expect(LumiMotion.resolve(setting: .gentle, systemReduceMotion: false).level == .gentle)
    }

    @Test("stagger is a ripple: 18 ms steps, ≤ 14 items, ≤ 160 ms; none when reduced")
    func stagger() {
        #expect(abs(LumiMotion.full.stagger(1) - 0.018) < 1e-9)
        #expect(LumiMotion.full.stagger(100) <= 0.16)
        #expect(LumiMotion.full.stagger(14) == LumiMotion.full.stagger(40))
        #expect(abs(LumiMotion.gentle.stagger(3) - 0.036) < 1e-9)
        #expect(LumiMotion.reduced.stagger(5) == 0)
        #expect(LumiMotion.full.stagger(-3) == 0)
    }

    @Test("durations: exits faster than entrances; ambient periods ≥ 2.4 s")
    func durations() {
        #expect(LumiDuration.exit < LumiSpring.gentle.settleTime())
        #expect(LumiDuration.exit <= 0.12 && LumiDuration.tap < LumiDuration.fade)
        #expect(LumiDuration.breath >= 2.4 && LumiDuration.ambient >= 2.4)
    }

    @Test("ramps are ordered on every theme: surfaces climb, inks fade, mode colours map", arguments: LumiTheme.allCases)
    func ramps(theme: LumiTheme) {
        let t = theme.tokens
        let r = LumiRamp(t)
        let bg = RGB.of(t.background)
        func d(_ c: Color) -> Double { OKLab.contrast(RGB.of(c), bg) }
        #expect(d(r.surface1) <= d(r.surface2) + 1e-6 && d(r.surface2) <= d(r.surface3) + 1e-6)
        #expect(d(r.ink1) >= d(r.ink2) && d(r.ink2) >= d(r.ink3) && d(r.ink3) >= d(r.ink4))
        #expect(d(r.ink3) >= 2.4, "\(theme.rawValue) ink-3 too faint: \(d(r.ink3))")
        #expect(LumiRamp.modeColor("INSERT", theme: t) == t.accent)
        #expect(LumiRamp.modeColor("VISUAL", theme: t) == t.secondary)
        #expect(LumiRamp.modeColor("REPLACE", theme: t) == t.error)
        #expect(LumiRamp.modeColor("NORMAL", theme: t) == t.primary)
        #expect(LumiElevation.floating.layers.3 > LumiElevation.raised.layers.3)
    }
}
