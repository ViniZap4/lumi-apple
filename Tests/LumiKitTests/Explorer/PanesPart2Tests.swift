import Foundation
import Testing
@testable import LumiKit

@Suite("Part 2 — splits, link routing, hover, session pool")
@MainActor
struct PanesPart2Tests {
    private let a = PaneContent.note(path: "a.md", view: .reading)
    private let b = PaneContent.note(path: "b.md", view: .reading)

    // MARK: Pane tree

    @Test("splitting a note with its preview splits the pair as one unit")
    func pairUnit() {
        var t = PaneTree(a)
        let one = t.focused
        t.setPreview(true)
        let prev = t.preview(of: one)!
        let two = t.split(.vertical, content: b, target: one)
        #expect(t.leaves == [one, prev, two])
        guard case let .split(.vertical, kids, _) = t.root, kids.count == 2,
              case .split(.vertical, _, _) = kids[0] else {
            Issue.record("the pair should stay nested"); return
        }
        #expect(t.mainLeaf == one && t.primary == one)
        #expect(t.notePanes == [one, two])
        // Hidden preview: geometry as the user sees it.
        let seen = t.withoutPreviews()
        #expect(seen.leaves == [one, two])
        #expect(seen.frames()[one]?.width == 0.5)
    }

    @Test("closing the primary promotes another note pane")
    func promote() {
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b)
        #expect(t.primary == one)
        t.close(one)
        #expect(t.primary == two && t.mainLeaf == two)
    }

    @Test("onlyNote keeps the focused note with its pair")
    func onlyNote() {
        var t = PaneTree(a)
        let one = t.focused
        t.setPreview(true)
        let two = t.split(.horizontal, content: b)
        t.focus(one)
        t.onlyNote()
        #expect(t.notePanes == [one] && t.preview(of: one) != nil)
        #expect(!t.leaves.contains(two))
    }

    @Test("divider drags and ⌃w < > + - keep the minimum size")
    func resize() {
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b)
        t.resizeDivider(at: [], index: 0, to: 0.7)
        #expect(abs((t.frames()[one]?.width ?? 0) - 0.7) < 1e-9)
        t.resizeDivider(at: [], index: 0, to: 0.99)
        #expect(abs((t.frames()[two]?.width ?? 0) - PaneTree.minSize) < 1e-9)
        t.equalize()
        t.nudge(one, axis: .vertical, by: 0.05)
        #expect(abs((t.frames()[one]?.width ?? 0) - 0.55) < 1e-9)
        // The last child pulls the divider before it.
        t.nudge(two, axis: .vertical, by: 0.05)
        #expect(abs((t.frames()[two]?.width ?? 0) - 0.5) < 1e-9)
        // No split on that axis: nothing happens.
        let before = t
        t.nudge(one, axis: .horizontal, by: 0.05)
        #expect(t == before)
    }

    @Test("nudging a note with a preview resizes the pair against its sibling")
    func nudgePair() {
        var t = PaneTree(a)
        let one = t.focused
        t.setPreview(true)
        let two = t.split(.vertical, content: b, target: one, focusNew: false)
        t.nudge(one, axis: .vertical, by: 0.1)
        #expect(abs((t.frames()[two]?.width ?? 0) - 0.4) < 1e-9)
    }

    @Test("prune closes secondary panes on deleted notes, never the primary")
    func prune() {
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b)
        let gone = t.prune { $0 == "a.md" }
        #expect(gone == [two] && t.leaves == [one])
        let none = t.prune { _ in false }
        #expect(none.isEmpty && t.leaves == [one])
    }

    @Test("older saved layouts (no primary) still decode")
    func decodeLegacy() throws {
        var t = PaneTree(a)
        t.setPreview(true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        json.removeValue(forKey: "primary")
        let back = try JSONDecoder().decode(PaneTree.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.primary == nil && back.mainLeaf == t.focused)
    }

    // MARK: Keys

    @Test("⌃w window commands in the shell and in the editor")
    func windowKeys() {
        var map = ShellKeymap()
        func w(_ k: KeyStroke) -> ShellAction? {
            _ = map.feed(.char("w", control: true), context: .reader, now: 0)
            return map.feed(k, context: .reader, now: 0.1)
        }
        #expect(w(.char("v")) == .pane(.split(.vertical)))
        #expect(w(.char("s")) == .pane(.split(.horizontal)))
        #expect(w(.char("f")) == .pane(.follow(.vsplit)))
        #expect(w(.char("F")) == .pane(.follow(.hsplit)))
        #expect(w(.key(.enter)) == .pane(.follow(.vsplit)))
        #expect(w(.char(">")) == .pane(.resize(.vertical, 1)))
        #expect(w(.char("<")) == .pane(.resize(.vertical, -1)))
        #expect(w(.char("+")) == .pane(.resize(.horizontal, 1)))
        #expect(w(.char("-")) == .pane(.resize(.horizontal, -1)))
        #expect(w(.char("c")) == .pane(.close))
        #expect(EditorPaneKeys.windowCommand(.character("v")) == .split(.vertical))
        #expect(EditorPaneKeys.windowCommand(.return) == .follow(.vsplit))
        #expect(EditorPaneKeys.windowCommand(.character("F")) == .follow(.hsplit))
    }

    @Test("reader: - floating explorer, K hover, gf follow; explorer keeps - as parent")
    func readerKeys() {
        var map = ShellKeymap()
        #expect(map.feed(.char("-"), context: .reader, now: 0) == .explore)
        #expect(map.feed(.char("K"), context: .reader, now: 0) == .hover)
        #expect(map.feed(.char("g"), context: .reader, now: 0) == .pending)
        #expect(map.feed(.char("f"), context: .reader, now: 0.1) == .follow)
        #expect(map.feed(.char("-"), context: .explorer, now: 0) == .parent)
    }

    // MARK: Link routing

    private let notes = [
        ExplorerNote(id: "notes/plan.md", path: "notes/plan.md", title: "Q3 Plan"),
        ExplorerNote(id: "plan.md", path: "plan.md", title: "Root plan"),
        ExplorerNote(id: "notes/ideas.md", path: "notes/ideas.md", title: "Ideas"),
    ]

    @Test("clicks: plain here, ⌘ vsplit, ⇧⌘ hsplit, ⌥ not ours")
    func clicks() {
        #expect(LinkOpenWhere.fromClick(command: false, shift: false) == .current)
        #expect(LinkOpenWhere.fromClick(command: true, shift: false) == .vsplit)
        #expect(LinkOpenWhere.fromClick(command: true, shift: true) == .hsplit)
        #expect(LinkOpenWhere.fromClick(command: false, shift: true) == nil)
        #expect(LinkOpenWhere.fromClick(command: true, shift: false, option: true) == nil)
    }

    @Test("classify: relative, absolute, wiki, external, anchors, unsafe")
    func classify() {
        #expect(LinkRouting.classify(notes, from: "notes/ideas.md", href: "plan.md") == .note(notes[0]))
        #expect(LinkRouting.classify(notes, from: "notes/ideas.md", href: "/plan.md") == .note(notes[1]))
        #expect(LinkRouting.classify(notes, from: "notes/ideas.md", href: "../plan") == .note(notes[1]))
        #expect(LinkRouting.classify(notes, from: "notes/ideas.md", href: "PLAN.MD") == .note(notes[0]))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "plan", wiki: true) == .note(notes[1]))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "q3 plan|alias", wiki: true) == .note(notes[0]))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "ideas#h", wiki: true) == .note(notes[2]))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "nope", wiki: true) == .missing("nope"))
        #expect(LinkRouting.classify(notes, from: "a/x.md", href: "new.md") == .missing("a/new.md"))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "https://example.com/a") == .external("https://example.com/a"))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "#top") == .anchor("top"))
        #expect(LinkRouting.classify(notes, from: "x.md", href: "javascript:alert(1)") == .unsafe)
        #expect(LinkRouting.classify(notes, from: "x.md", href: "//evil.com/x") == .unsafe)
        #expect(LinkRouting.classify(notes, from: "x.md", href: "../../etc/passwd") == .unsafe)
        #expect(LinkRouting.wikiTargets(in: "see [[Plan|p]] and [[a/b#c]]") == ["plan", "a/b"])
    }

    @Test("linkAt finds the link under the cursor on its line")
    func linkAt() {
        let text = "intro\nsee [the plan](plan.md) and [[Ideas|i]] or <https://x.io> ![img](a.png)\nend https://e.com/p."
        func at(_ needle: String, _ off: Int = 1) -> LinkAt? {
            let r = text.range(of: needle)!
            return LinkRouting.linkAt(text, text.distance(from: text.startIndex, to: r.lowerBound) + off)
        }
        #expect(at("[the")?.href == "plan.md")
        #expect(at("[the")?.wiki == false)
        #expect(at("[[Ideas")?.href == "Ideas|i")
        #expect(at("[[Ideas")?.wiki == true)
        #expect(at("<https")?.href == "https://x.io")
        #expect(at("![img")?.href == nil)
        #expect(at("https://e.com")?.href == "https://e.com/p")
        #expect(at("intro") == nil)
    }

    @Test("URL card: host and path, no fetch; unsafe schemes refused")
    func urlCard() {
        let c = LinkRouting.urlCard("https://example.com/docs/a?b=1")
        #expect(c?.host == "example.com" && c?.path == "/docs/a?b=1" && c?.secure == true)
        #expect(LinkRouting.urlCard("mailto:me@x.io")?.mail == true)
        #expect(LinkRouting.urlCard("javascript:alert(1)") == nil)
    }

    // MARK: Hover

    @Test("excerpt drops frontmatter, cuts at 40 lines and closes an open fence")
    func excerpt() {
        let body = "---\ntitle: x\n---\n\n# T\n```swift\n" + (0..<60).map { "l\($0)" }.joined(separator: "\n")
        let e = HoverPreview.excerpt(body)
        #expect(e.truncated)
        #expect(e.text.hasPrefix("# T"))
        #expect(e.text.hasSuffix("```"))
        #expect(e.text.split(separator: "\n", omittingEmptySubsequences: false).count == 41)
        #expect(HoverPreview.excerpt("a\nb").truncated == false)
    }

    @Test("updated label")
    func updated() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(HoverPreview.updatedLabel(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(HoverPreview.updatedLabel(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(HoverPreview.updatedLabel(now.addingTimeInterval(-86_400 * 3), now: now) == "3 days ago")
        #expect(HoverPreview.updatedLabel(nil) == "")
    }

    final class ManualTimers: HoverTimers {
        final class H { var fire: (@MainActor () -> Void)?; var due: TimeInterval = 0 }
        var pending: [H] = []
        var now: TimeInterval = 0
        func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> AnyObject {
            let h = H(); h.fire = fire; h.due = now + seconds; pending.append(h); return h
        }
        func cancel(_ handle: AnyObject) { pending.removeAll { $0 === handle } }
        func advance(_ s: TimeInterval) {
            now += s
            let due = pending.filter { $0.due <= now + 1e-9 }
            pending.removeAll { $0.due <= now + 1e-9 }
            for h in due { h.fire?() }
        }
    }

    @Test("hover intent: 350 ms to show, the card holds it, grace to hide, K shows at once")
    func intent() {
        let timers = ManualTimers()
        var shown: [String] = []
        var hides = 0
        let intent = HoverIntent<String>(timers: timers, onShow: { shown.append($0) }, onHide: { hides += 1 })
        intent.enter("a", key: "a")
        timers.advance(0.2)
        #expect(shown.isEmpty)
        timers.advance(0.2)
        #expect(shown == ["a"])
        intent.leave()
        intent.hold()
        timers.advance(1)
        #expect(hides == 0, "the pointer reached the card")
        intent.leave()
        timers.advance(0.3)
        #expect(hides == 1 && intent.shownKey == nil)
        intent.enter("b", key: "b")
        intent.leave()
        timers.advance(1)
        #expect(shown == ["a"], "left before the delay")
        intent.showNow("k", key: "k")
        #expect(shown == ["a", "k"])
    }

    // MARK: Session pool

    final class FakeSession: PoolableSession {
        var destroyed = false
        var isPoolUsable: Bool { !destroyed }
        func destroy() { destroyed = true }
    }

    @Test("pool: shared per key, last release destroys (after the grace when deferred)")
    func pool() {
        let timers = ManualTimers()
        let pool = SessionPool<String, FakeSession>(grace: 1.5, timers: timers)
        let s1 = pool.acquire("n") { FakeSession() }
        let s2 = pool.acquire("n") { FakeSession() }
        #expect(s1 === s2 && pool.refCount("n") == 2)
        pool.release("n")
        #expect(!s1.destroyed)
        pool.release("n", defer: true)
        #expect(!s1.destroyed && pool.peek("n") === s1)
        // Hand-off inside the grace keeps the same session.
        let s3 = pool.acquire("n") { FakeSession() }
        #expect(s3 === s1)
        pool.release("n", defer: true)
        timers.advance(2)
        #expect(s1.destroyed && pool.peek("n") == nil)
        // A dead session is never handed out again.
        let s4 = pool.acquire("m") { FakeSession() }
        s4.destroy()
        let s5 = pool.acquire("m") { FakeSession() }
        #expect(s4 !== s5)
        pool.clear()
        #expect(s5.destroyed)
    }

    // MARK: Fan-out

    final class FakeDoc: CollaborativeDocument {
        var text = ""
        var isEditable = true
        var changeHandler: ((DocumentChange) -> Void)?
        func applyLocal(_ edits: [TextEdit]) { text = TextEdit.apply(edits, to: text) }
        func undo() -> Bool { changeHandler?(.undo([TextEdit(location: 0, length: 0, replacement: "u")])); return true }
        func redo() -> Bool { false }
        func breakUndoGroup() {}
    }

    @Test("two editors on one document: local edits reach the sibling, undo only marks its originator")
    func fanout() {
        let doc = FakeDoc()
        let hub = DocumentFanout(document: doc)
        let v1 = hub.makeView(), v2 = hub.makeView()
        var got1: [DocumentChange] = [], got2: [DocumentChange] = []
        v1.changeHandler = { got1.append($0) }
        v2.changeHandler = { got2.append($0) }
        let e = TextEdit(location: 0, length: 0, replacement: "hi")
        v1.applyLocal([e])
        #expect(doc.text == "hi")
        #expect(got1.isEmpty && got2 == [.remote([e])])
        _ = v2.undo()
        #expect(got2.last.map { if case .undo = $0 { return true }; return false } == true)
        #expect(got1.last.map { if case .remote = $0 { return true }; return false } == true)
        hub.applyExternal([e])
        #expect(got1.count == 2 && got2.count == 3)
    }
}
