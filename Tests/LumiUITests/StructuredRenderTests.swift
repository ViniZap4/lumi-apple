#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Offscreen renders of the Board and Canvas views (no window, nothing
/// takes focus). PNGs land in `LUMI_RENDER_DIR` when set; the layout
/// assertions run always.
@Suite("Structured views (offscreen)", .serialized)
@MainActor
struct StructuredRenderTests {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func fixture(_ p: String) -> String {
        (try? String(contentsOf: fixtures.appendingPathComponent(p), encoding: .utf8)) ?? ""
    }

    static func host<V: View>(_ view: V, theme: LumiTheme, size: NSSize) -> NSHostingView<some View> {
        let root = view
            .environment(\.theme, theme.tokens)
            .environment(\.colorScheme, theme.tokens.isDark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let h = NSHostingView(rootView: root)
        h.appearance = NSAppearance(named: theme.tokens.isDark ? .darkAqua : .aqua)
        h.frame = NSRect(origin: .zero, size: size)
        return h
    }

    static func settle(_ v: NSView, _ seconds: Double = 0.25) {
        v.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        v.layoutSubtreeIfNeeded()
    }

    static func png(_ v: NSView, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMI_RENDER_DIR"] else { return }
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    @Test("board: focused card (dark) and a drag mid-state (light)", arguments: [LumiTheme.tokyoNight, .tokyoDay])
    func board(theme: LumiTheme) throws {
        let lt = MemoryLiveText(Self.fixture("kanban/basic.md"))
        let m = KanbanBoardModel(doc: lt)
        m.setCursor(KanbanCursor(lane: 0, card: 1))
        let size = NSSize(width: 1000, height: 560)
        let h = Self.host(KanbanBoardView(model: m, title: "Launch board", status: "2 editing", motion: false, onSource: {}), theme: theme, size: size)
        Self.settle(h)
        // Frames were measured by the layout pass.
        #expect(m.laneFrames.count == 3)
        #expect(m.cardFrames.count == 6)
        let mode = theme.tokens.isDark ? "dark" : "light"
        try Self.png(h, "board-focused-\(mode)")

        // Drag "Review #design tokens" over the second lane, below its card.
        let card = m.lanes[0].cards[1]
        let f = try #require(m.cardFrames[card.id])
        let lane1 = try #require(m.laneFrames[m.lanes[1].id])
        m.beginDrag(.init(kind: .card, key: card.id, fromLane: 0, fromIndex: 1, size: f.size,
                          grab: CGPoint(x: 40, y: 20), location: CGPoint(x: f.minX + 40, y: f.minY + 20)))
        m.updateDrag(to: CGPoint(x: lane1.midX + 30, y: lane1.minY + 140))
        #expect(m.drag?.toLane == 1 && m.drag?.toIndex == 1)
        Self.settle(h)
        try Self.png(h, "board-drag-\(mode)")
        m.endDrag()
        #expect(m.board.lanes[1].cards.map(\.text) == ["Kanban parser", "Review #design tokens @{2026-12-01}"])
        m.setCursor(KanbanCursor(lane: 0, card: 0))
        m.requestDelete(m.lanes[0].cards[0])
        Self.settle(h)
        try Self.png(h, "board-confirm-\(mode)")
    }

    @Test("canvas: groups, cards, edges, selection (dark + light)", arguments: [LumiTheme.tokyoNight, .tokyoDay])
    func canvas(theme: LumiTheme) throws {
        let lt = MemoryLiveText(Self.fixture("canvas/obsidian.canvas"))
        let m = CanvasBoardModel(doc: lt)
        m.setPreview("Projects/Roadmap.md", .ok("# Roadmap\n\n- [x] Kanban board\n- [ ] Canvas view\n- [ ] Hover preview\n\nShip **part 2** by December."))
        m.select(["b1c2d3e4f5a6b7c8"])
        let size = NSSize(width: 1100, height: 680)
        let h = Self.host(CanvasBoardView(model: m, title: "Launch plan", motion: false, onSource: {}), theme: theme, size: size)
        Self.settle(h, 0.4)
        #expect(m.size == CGSize(width: 1100, height: 680))
        #expect(m.viewport.zoom > 0.5)
        let mode = theme.tokens.isDark ? "dark" : "light"
        try Self.png(h, "canvas-\(mode)")
        // Invalid JSON mid-edit: banner + last good parse.
        lt.remote([TextEdit(from: 0, to: 1, insert: "")])
        Self.settle(h)
        #expect(m.invalid != nil && m.nodes.count == 5)
        try Self.png(h, "canvas-invalid-\(mode)")
    }
}
#endif
