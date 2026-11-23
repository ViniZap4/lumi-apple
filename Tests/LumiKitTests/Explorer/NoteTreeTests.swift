import Testing
import Foundation
@testable import LumiKit

private func note(_ id: String, _ path: String, _ title: String = "") -> ExplorerNote {
    ExplorerNote(id: id, path: path, title: title)
}

@Suite("Explorer — NoteTree")
struct NoteTreeTests {
    @Test("folders come first, natural case-insensitive order")
    func ordering() {
        let tree = NoteTree.build([
            note("b", "b.md", "beta"),
            note("n10", "note10.md"),
            note("n2", "note2.md"),
            note("x", "zeta/x.md"),
            note("y", "Alpha/y.md"),
        ])
        let root = tree.entries(in: NoteTree.root)
        #expect(root.map(\.name) == ["Alpha", "zeta", "beta", "note2", "note10"])
        #expect(root[0].kind == .folder)
        #expect(root[0].count == 1)
    }

    @Test("intermediate folders are created and linked")
    func nested() {
        let tree = NoteTree.build([note("deep", "a/b/c/deep.md")])
        #expect(tree.entries(in: "").map(\.path) == ["a"])
        #expect(tree.entries(in: "a").map(\.path) == ["a/b"])
        #expect(tree.entries(in: "a/b/c").map(\.name) == ["deep"])
        #expect(tree.noteDir["deep"] == "a/b/c")
    }

    @Test("hostile paths cannot climb above the root")
    func normalize() {
        #expect(NoteTree.normalizePath("./a//b\\c.md") == "a/b/c.md")
        #expect(NoteTree.normalizePath("../../etc/passwd") == "etc/passwd")
        let tree = NoteTree.build([note("p", "../x.md")])
        #expect(tree.noteDir["p"] == "")
    }

    @Test("empty path falls back to id.md; title falls back to stem")
    func fallbacks() {
        let tree = NoteTree.build([note("slug", "")])
        let e = tree.entries(in: "")
        #expect(e.first?.path == "slug.md")
        #expect(e.first?.name == "slug")
    }

    @Test("hidden entries are filtered unless asked for")
    func hidden() {
        let tree = NoteTree.build([note("h", ".trash/old.md"), note("v", "visible.md")])
        #expect(tree.entries(in: "", showHidden: false).map(\.name) == ["visible"])
        #expect(tree.entries(in: "", showHidden: true).count == 2)
    }

    @Test("extra folders appear even without notes")
    func extraFolders() {
        let tree = NoteTree.build([], extraFolders: ["drafts/2026"])
        #expect(tree.entries(in: "").map(\.path) == ["drafts"])
        #expect(tree.entries(in: "drafts").map(\.path) == ["drafts/2026"])
    }

    @Test("filter matches names and note file names")
    func filter() {
        let tree = NoteTree.build([note("a", "groceries.md", "Shopping"), note("b", "todo.md")])
        let all = tree.entries(in: "")
        #expect(NoteTree.filter(all, query: "groc").map(\.name) == ["Shopping"])
        #expect(NoteTree.filter(all, query: "TODO").map(\.name) == ["todo"])
        #expect(NoteTree.filter(all, query: "  ").count == 2)
    }

    @Test("breadcrumb and nearestExisting")
    func breadcrumb() {
        let crumbs = NoteTree.breadcrumb("a/b")
        #expect(crumbs.map(\.name) == ["/", "a", "b"])
        #expect(crumbs.map(\.path) == ["", "a", "a/b"])
        let tree = NoteTree.build([note("x", "a/x.md")])
        #expect(tree.nearestExisting("a/gone/deeper") == "a")
    }
}

@Suite("Explorer — MillerNav")
struct MillerNavTests {
    private func sample() -> NoteTree {
        NoteTree.build([
            note("r1", "readme.md"),
            note("p1", "projects/alpha.md"),
            note("p2", "projects/beta.md"),
            note("p3", "projects/web/gamma.md"),
            note("j1", "journal/2026.md"),
        ])
    }

    @Test("j/k move and clamp; gg/G jump")
    func moves() {
        var nav = MillerNav(tree: sample())
        #expect(nav.entries.map(\.name) == ["journal", "projects", "readme"])
        #expect(nav.cursor == 0)
        nav.move(1)
        #expect(nav.current?.name == "projects")
        nav.move(10)
        #expect(nav.current?.name == "readme")
        nav.move(-10)
        #expect(nav.cursor == 0)
        nav.bottom()
        #expect(nav.cursor == 2)
        nav.top()
        #expect(nav.cursor == 0)
    }

    @Test("l descends, h ascends landing on the folder we came from")
    func descendAscend() {
        var nav = MillerNav(tree: sample())
        nav.move(1) // projects
        #expect(nav.previewEntries?.map(\.name) == ["web", "alpha", "beta"])
        let r1 = nav.right()
        #expect(r1 == nil)
        #expect(nav.dir == "projects")
        #expect(nav.parentEntries.map(\.name) == ["journal", "projects", "readme"])
        #expect(nav.parentCursor == 1)
        nav.move(2) // beta
        let opened = nav.right()
        #expect(opened?.note?.id == "p2")
        let r2 = nav.left()
        #expect(r2)
        #expect(nav.dir == "")
        #expect(nav.current?.name == "projects")
        let r3 = nav.left()
        #expect(!r3)
    }

    @Test("each folder remembers its own cursor")
    func memory() {
        var nav = MillerNav(tree: sample())
        nav.move(1)
        _ = nav.right()
        nav.move(2)
        nav.left()
        _ = nav.right()
        #expect(nav.current?.name == "beta")
    }

    @Test("H / L walk folder history; home goes to root")
    func history() {
        var nav = MillerNav(tree: sample())
        nav.goTo("projects/web")
        #expect(nav.dir == "projects/web")
        nav.home()
        #expect(nav.dir == "")
        let r4 = nav.historyBack()
        #expect(r4)
        #expect(nav.dir == "projects/web")
        let r5 = nav.historyForward()
        #expect(r5)
        #expect(nav.dir == "")
        let r6 = nav.historyForward()
        #expect(!r6)
    }

    @Test("filter narrows the current column; n/N cycle with wrap")
    func filterCycle() {
        var nav = MillerNav(tree: sample())
        nav.goTo("projects")
        nav.setFilter("a")
        #expect(nav.entries.map(\.name) == ["alpha", "beta"])
        nav.cycle(1)
        #expect(nav.current?.name == "beta")
        nav.cycle(1)
        #expect(nav.current?.name == "alpha")
        nav.cycle(-1)
        #expect(nav.current?.name == "beta")
        nav.left()
        #expect(nav.filter.isEmpty)
    }

    @Test("reveal jumps to a note's folder and selects it")
    func reveal() {
        var nav = MillerNav(tree: sample())
        let r7 = nav.reveal(noteID: "p3")
        #expect(r7)
        #expect(nav.dir == "projects/web")
        #expect(nav.current?.note?.id == "p3")
        let r8 = nav.reveal(noteID: "nope")
        #expect(!r8)
    }

    @Test("a vanished folder resolves to its nearest ancestor")
    func vanished() {
        var nav = MillerNav(tree: sample())
        nav.goTo("projects/web")
        nav.tree = NoteTree.build([note("p1", "projects/alpha.md")])
        #expect(nav.dir == "projects")
        #expect(nav.current?.name == "alpha")
    }

    @Test("hidden toggle")
    func hiddenToggle() {
        var nav = MillerNav(tree: NoteTree.build([note("h", ".git/x.md"), note("a", "a.md")]))
        #expect(nav.entries.map(\.name) == ["a"])
        nav.showHidden = true
        #expect(nav.entries.map(\.name) == [".git", "a"])
    }
}
