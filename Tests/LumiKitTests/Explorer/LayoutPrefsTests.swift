import Foundation
import Testing
@testable import LumiKit

@Suite("Layout + motion preferences (web parity)")
@MainActor
struct LayoutPrefsTests {
    @Test("Largura de leitura: narrow 68ch < medium 84ch (default) < wide 104ch < full")
    func measures() {
        #expect(ReadingMeasure.allCases.map(\.label) == ["Estreita", "Média", "Larga", "Total"])
        #expect(ReadingMeasure.narrow.points < ReadingMeasure.medium.points)
        #expect(ReadingMeasure.medium.points < ReadingMeasure.wide.points)
        #expect(ReadingMeasure.full.points == ReadingMeasure.fullWidth)
        #expect(ReadingMeasure.medium.characters == 84)
        #expect(ReadingMeasure.nearest(to: 760) == .narrow)
        #expect(ReadingMeasure.nearest(to: 880) == .medium)
        #expect(ReadingMeasure.nearest(to: 1_000_000) == .full)
    }

    @Test("prefs default to média / confortável / completo and persist; reduced ⇄ reduceMotion stay in sync")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("apple.yaml")
        let p = LumiPreferences(store: PreferencesStore(fileURL: url))
        #expect(p.readingMeasure == .medium)
        #expect(p.readingWidth == ReadingMeasure.medium.points)
        #expect(p.density == .comfortable)
        #expect(p.motionLevel == .full)
        p.readingMeasure = .full
        p.density = .compact
        p.motionLevel = .reduced
        #expect(p.reduceMotion)
        #expect(p.readingWidth == ReadingMeasure.fullWidth)
        let q = LumiPreferences(store: PreferencesStore(fileURL: url))
        #expect(q.readingMeasure == .full)
        #expect(q.density == .compact)
        #expect(q.motionLevel == .reduced)
        q.reduceMotion = false
        #expect(q.motionLevel == .full)
        q.motionLevel = .gentle
        #expect(!q.reduceMotion)
        #expect(MotionLevel.gentle.effective(systemReduceMotion: true) == .reduced)
    }
}
