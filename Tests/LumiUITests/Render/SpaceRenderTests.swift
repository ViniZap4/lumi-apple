#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Space pass before / after at 1440 × 900 and 1920 × 1080: the note
/// shell (chrome heights + reading measure), the book home and the
/// floating explorer. "Before" uses main's numbers (top 34, note bar 40,
/// legend 22, status 24, readingWidth 760, explorer 80%, the old home).
@Suite("Space pass renders (LUMI_RENDER_DIR)", .serialized)
@MainActor
struct SpaceRenderTests {
    struct Metrics {
        let top: CGFloat, bar: CGFloat, legend: CGFloat, status: CGFloat, reading: CGFloat, panel: CGFloat
        static let before = Metrics(top: 34, bar: 40, legend: 22, status: 24, reading: 760, panel: 0.8)
        static let after = Metrics(top: ShellMetrics.topLineHeight, bar: ShellMetrics.noteBarHeight, legend: ShellMetrics.legendHeight,
                                   status: ShellMetrics.statusLineHeight, reading: ReadingMeasure.medium.points, panel: 0.9)
    }

    static var dir: URL? {
        ProcessInfo.processInfo.environment["LUMI_RENDER_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("space") }
    }

    static func render<V: View>(_ v: V, size: CGSize, theme: LumiTheme, name: String) throws {
        guard let dir else { return }
        let host = NSHostingView(rootView: v.environment(\.theme, theme.tokens).lumiMotion(.reduced)
            .frame(width: size.width, height: size.height).background(theme.tokens.background))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: theme.tokens.isDark ? .darkAqua : .aqua)
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func chrome(_ h: CGFloat, _ label: String, _ theme: LumiTheme) -> some View {
        HStack { Text(label).font(ShellFont.small).foregroundStyle(theme.tokens.textDim); Spacer() }
            .padding(.horizontal, 12)
            .frame(height: h)
            .background(theme.tokens.overlayBackground.opacity(0.5))
            .overlay(alignment: .bottom) { Hairline() }
    }

    static func note(_ m: Metrics, _ theme: LumiTheme) -> some View {
        VStack(spacing: 0) {
            chrome(m.top, "top line \(Int(m.top)) pt", theme)
            chrome(m.bar, "note bar \(Int(m.bar)) pt", theme)
            PanesRenderTests.RenderReader(text: ProseSample.note, title: "", scale: 1, readingWidth: m.reading)
            chrome(m.legend, "legend \(Int(m.legend)) pt", theme)
            chrome(m.status, "status \(Int(m.status)) pt", theme)
        }
    }

    static func home(_ after: Bool) -> some View {
        let recents = (0..<12).map { i in
            (id: "\(i)", name: ["Q3 plan", "Routing notes", "Hover cards", "1:1 — Marta", "Kanban", "Canvas ideas", "Reading list", "Inbox",
                                "Retro", "Design tokens", "Interview notes", "Weekly"][i], folder: i % 3 == 0 ? "plans" : "", updated: "\(i + 1) h ago")
        }
        return Group {
            if after {
                BookHomeView(name: "Work", status: "up to date", location: "ana@lumi.example.com", noteCount: 128,
                             recents: recents.map { .init(id: $0.id, name: $0.name, folder: $0.folder, updated: $0.updated) },
                             cursor: 0, loading: false, dot: { Circle().fill(Color.green).frame(width: 7, height: 7) }, onOpen: { _ in })
            } else {
                LegacyBookHomeView(name: "Work", status: "up to date", location: "ana@lumi.example.com", noteCount: 128,
                                   recents: recents.prefix(4).map { .init(id: $0.id, name: $0.name, folder: $0.folder, updated: $0.updated) },
                                   cursor: 0, loading: false, dot: { Circle().fill(Color.green).frame(width: 7, height: 7) }, onOpen: { _ in })
            }
        }
    }

    static func explorer(_ m: Metrics, _ theme: LumiTheme) -> some View {
        GeometryReader { geo in
            ZStack {
                home(m.panel > 0.85)
                Color.black.opacity(0.3)
                VStack(spacing: 0) {
                    chrome(34, "floating explorer \(Int(m.panel * 100))%", theme)
                    PanesRenderTests.explorerColumns(theme)
                }
                .frame(width: geo.size.width * m.panel, height: geo.size.height * (m.panel > 0.85 ? 0.88 : 0.8))
                .background(theme.tokens.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @Test("note shell, home, explorer: before / after at 1440 and 1920")
    func space() throws {
        guard Self.dir != nil else { return }
        let theme = LumiTheme.tokyoNight
        for (w, h) in [(1440.0, 900.0), (1920.0, 1080.0)] {
            for (m, tag) in [(Metrics.before, "before"), (Metrics.after, "after")] {
                let size = CGSize(width: w, height: h)
                try Self.render(Self.note(m, theme), size: size, theme: theme, name: "note-\(Int(w))-\(tag)")
                try Self.render(Self.home(tag == "after"), size: size, theme: theme, name: "home-\(Int(w))-\(tag)")
                try Self.render(Self.explorer(m, theme), size: size, theme: theme, name: "explorer-\(Int(w))-\(tag)")
            }
        }
    }
}
#endif
