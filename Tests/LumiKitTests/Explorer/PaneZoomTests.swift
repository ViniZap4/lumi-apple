import Foundation
import Testing
@testable import LumiKit

@Suite("Pane zoom (⌃w z) and drop-to-edge splits")
struct PaneZoomTests {
    private let a = PaneContent.note(path: "a.md", view: .reading)
    private let b = PaneContent.note(path: "b.md", view: .reading)
    private let c = PaneContent.note(path: "c.md", view: .source)

    private func three() -> (PaneTree, PaneLeafID, PaneLeafID, PaneLeafID) {
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b)
        let three = t.split(.horizontal, content: c, target: two)
        return (t, one, two, three)
    }

    @Test("zoom hides the others, keeps the layout, unzoom restores it exactly")
    func toggle() {
        var (t, one, two, three) = three()
        t.setRatio(0.7, for: one)
        let before = t
        let r1 = t.toggleZoom(two)
        #expect(r1)
        #expect(t.zoomedLeaf == two && t.isZoomed)
        #expect(t.focused == two)
        #expect(t.visibleLeaves == [two])
        // Hidden, not closed.
        #expect(t.leaves == [one, two, three])
        #expect(t.root == before.root)
        let r2 = t.toggleZoom()
        #expect(r2)
        #expect(!t.isZoomed && t.visibleLeaves == [one, two, three])
        #expect(t.root == before.root)
    }

    @Test("one pane (or only a source + preview pair) has nothing to zoom")
    func nothingToZoom() {
        var t = PaneTree(a)
        let r3 = t.toggleZoom()
        #expect(!r3)
        t.setPreview(true)
        let r4 = t.toggleZoom()
        #expect(!r4)
        #expect(!t.isZoomed)
    }

    @Test("a zoomed note keeps its preview; zooming the preview zooms its note")
    func pair() {
        var t = PaneTree(a)
        let one = t.focused
        t.setPreview(true)
        let prev = t.preview(of: one)!
        let two = t.split(.vertical, content: b, target: one)
        let r5 = t.toggleZoom(prev)
        #expect(r5)
        #expect(t.zoomedLeaf == one)
        #expect(t.visibleLeaves == [one, prev])
        #expect(!t.visibleLeaves.contains(two))
    }

    @Test("moving to another pane, splitting, closing or only unzoom first")
    func unzoomOnChange() {
        var (t, one, two, _) = three()
        t.toggleZoom(two)
        let r6 = t.move(.left)
        #expect(r6)
        #expect(!t.isZoomed && t.focused == one)

        t.toggleZoom(two)
        t.cycle(1)
        #expect(!t.isZoomed)

        t.toggleZoom(two)
        _ = t.split(.vertical, content: a, target: two)
        #expect(!t.isZoomed)

        t.toggleZoom(two)
        t.close(one)
        #expect(!t.isZoomed)

        var (u, _, two2, _) = three()
        u.toggleZoom(two2)
        u.onlyNote()
        #expect(!u.isZoomed)
    }

    @Test("focusing the zoomed pane again keeps the zoom")
    func refocus() {
        var (t, _, two, _) = three()
        t.toggleZoom(two)
        t.focus(two)
        t.equalize()
        #expect(t.zoomedLeaf == two)
    }

    @Test("zoom is never persisted")
    func notPersisted() throws {
        var (t, _, two, _) = three()
        t.toggleZoom(two)
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(PaneTree.self, from: data)
        #expect(!back.isZoomed)
        #expect(back.root == t.root)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-zoom-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PaneLayoutStore(url: url)
        store.save(t, forBook: "b")
        #expect(store.layout(forBook: "b")?.isZoomed == false)
        #expect(PaneLayoutStore(url: url).layout(forBook: "b")?.isZoomed == false)
    }

    @Test("⌃w z in the shell and the editor; :zoom")
    func keys() {
        #expect(PaneCommand.windowLetter("z") == .zoom)
        #expect(PaneCommand.zoom.isLayout)
        var k = EditorPaneKeys()
        let s = VimState.initial
        let f3931 = k.feed(.ctrl("w"), state: s)
        #expect(f3931 == .consume)
        let r7 = k.feed(.character("z"), state: s) == .pane(.zoom, passIfUnhandled: false)
        #expect(r7)
        #expect(PaneGraph.target(from: .reader, .zoom, layout: PaneLayout(main: .reader)) == nil)
        #expect(CommandLegend.windowCommands.contains { $0.keys == "z" })
    }

    // MARK: Split before (drop on the left / top edge)

    @Test("split before puts the new pane left / above the target")
    func splitBefore() {
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b, before: true)
        #expect(t.leaves == [two, one])
        let three = t.split(.horizontal, content: c, target: one, before: true)
        #expect(t.leaves == [two, three, one])
        let four = t.split(.vertical, content: a, target: one, before: true)
        // Same axis as the root: a sibling right before `one`'s unit.
        if case let .split(.vertical, kids, w) = t.root {
            #expect(kids.count == 3 || kids.count == 2)
            #expect(abs(w.reduce(0, +) - 1) < 1e-9)
        }
        #expect(t.leaves.contains(four))
    }

    // MARK: Drop zones

    @Test("drop zones: nearest edge within the band, centre opens here")
    func zones() {
        let size = CGSize(width: 1000, height: 600)
        #expect(PaneDropZone.zone(at: CGPoint(x: 20, y: 300), in: size) == .left)
        #expect(PaneDropZone.zone(at: CGPoint(x: 980, y: 300), in: size) == .right)
        #expect(PaneDropZone.zone(at: CGPoint(x: 500, y: 10), in: size) == .top)
        #expect(PaneDropZone.zone(at: CGPoint(x: 500, y: 590), in: size) == .bottom)
        #expect(PaneDropZone.zone(at: CGPoint(x: 500, y: 300), in: size) == .center)
        // A corner: the nearer edge wins.
        #expect(PaneDropZone.zone(at: CGPoint(x: 10, y: 50), in: size) == .left)
        #expect(PaneDropZone.zone(at: CGPoint(x: 100, y: 5), in: size) == .top)
        #expect(PaneDropZone.zone(at: CGPoint(x: -1, y: 5), in: size) == nil)
        #expect(PaneDropZone.zone(at: .zero, in: .zero) == nil)
        #expect(PaneDropZone.left.axis == .vertical && PaneDropZone.left.before)
        #expect(PaneDropZone.bottom.axis == .horizontal && !PaneDropZone.bottom.before)
        #expect(PaneDropZone.center.axis == nil)
        #expect(PaneDropZone.right.highlight == PaneRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }
}
