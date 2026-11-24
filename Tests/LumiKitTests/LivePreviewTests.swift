import Foundation
import Testing
@testable import LumiKit

@Suite("Live Preview planning")
struct LivePreviewTests {
    private func plan(_ text: String, line: Int, active: Set<Int> = []) -> LiveLinePlan {
        let ns = text as NSString
        let lines = LivePreview.scan(ns)
        let revealed = LivePreview.revealedGroups(active, in: lines)
        return LivePreview.plan(line, lines: lines, text: ns, active: active.contains(line),
                                groupRevealed: lines[line].group.map(revealed.contains) ?? false)
    }

    private func hidden(_ p: LiveLinePlan, in text: String, line: Int) -> [String] {
        let ns = text as NSString
        let start = LivePreview.scan(ns)[line].start
        return p.spans.filter { $0.style == .hide }.map { ns.substring(with: NSRange(location: start + $0.range.location, length: $0.range.length)) }
    }

    private func styled(_ p: LiveLinePlan, _ style: LiveInline, in text: String, line: Int) -> [String] {
        let ns = text as NSString
        let start = LivePreview.scan(ns)[line].start
        return p.spans.filter { $0.style == style }.map { ns.substring(with: NSRange(location: start + $0.range.location, length: $0.range.length)) }
    }

    @Test("lines are classified block by block")
    func scan() {
        let text = """
        ---
        title: x
        ---
        # Title
        Text
        ===
        - [ ] task
        1. one
        > [!tip] Tip
        > body
        ```swift
        let a = 1
        ```
        | a | b |
        |---|---|
        | 1 | 2 |
        $$
        x^2
        $$
        ***
        ![alt](pic.png)
        """
        let lines = LivePreview.scan(text as NSString)
        #expect(lines.count == 21)
        #expect(lines[0].kind == .frontmatter(delimiter: true))
        #expect(lines[1].kind == .frontmatter(delimiter: false))
        #expect(lines[3].kind == .heading(level: 1, marker: 2))
        #expect(lines[4].kind == .setextText(level: 1))
        #expect(lines[5].kind == .setextUnderline(level: 1))
        guard case let .list(task) = lines[6].kind else { Issue.record("task"); return }
        #expect(task.taskOffset == 2 && !task.checked)
        guard case let .list(ordered) = lines[7].kind else { Issue.record("ordered"); return }
        #expect(ordered.ordered && ordered.markerLength == 2)
        #expect(lines[8].quote?.callout?.kind == "tip" && lines[8].quote?.callout?.isTitle == true)
        #expect(lines[9].quote?.callout?.kind == "tip" && lines[9].quote?.callout?.isTitle == false)
        #expect(lines[8].group == LiveGroup(first: 8, last: 9))
        #expect(lines[10].kind == .fence(open: true, info: "swift"))
        #expect(lines[11].kind == .code(info: "swift"))
        #expect(lines[12].kind == .fence(open: false, info: "swift"))
        #expect(lines[13].kind == .tableHeader && lines[14].kind == .tableDelimiter && lines[15].kind == .tableRow)
        #expect(lines[13].group == LiveGroup(first: 13, last: 15))
        #expect(lines[16].kind == .mathFence && lines[17].kind == .math)
        #expect(lines[19].kind == .hr)
        #expect(lines[20].kind == .image)
    }

    @Test("utf-16 offsets survive emoji and accents")
    func offsets() {
        let text = "héllo 🎉\n**bold** ok"
        let lines = LivePreview.scan(text as NSString)
        #expect(lines[1].start == ("héllo 🎉\n" as NSString).length)
        let p = plan(text, line: 1)
        #expect(hidden(p, in: text, line: 1) == ["**", "**"])
        #expect(styled(p, .strong, in: text, line: 1) == ["bold"])
    }

    @Test("syntax hides off the cursor line and shows (dimmed) on it")
    func reveal() {
        let text = "## Heading\nsome **bold** and *it* and ~~gone~~ and ==hi== and `code`"
        let off = plan(text, line: 0)
        #expect(off.style == .heading(level: 2))
        #expect(hidden(off, in: text, line: 0) == ["## "])
        let on = plan(text, line: 0, active: [0])
        #expect(hidden(on, in: text, line: 0).isEmpty)
        #expect(styled(on, .marker, in: text, line: 0) == ["## "])

        let body = plan(text, line: 1)
        #expect(Set(hidden(body, in: text, line: 1)) == ["**", "*", "~~", "==", "`"])
        #expect(styled(body, .strong, in: text, line: 1) == ["bold"])
        #expect(styled(body, .emphasis, in: text, line: 1) == ["it"])
        #expect(styled(body, .strike, in: text, line: 1) == ["gone"])
        #expect(styled(body, .mark, in: text, line: 1) == ["hi"])
        #expect(styled(body, .code, in: text, line: 1) == ["code"])
        let bodyOn = plan(text, line: 1, active: [1])
        #expect(hidden(bodyOn, in: text, line: 1).isEmpty)
    }

    @Test("emphasis edge cases: intraword underscore, nested, code protects")
    func emphasisEdges() {
        let spans = LivePreview.inlineSpans("snake_case_name and ***both*** and `**not**`", active: false)
        let s = "snake_case_name and ***both*** and `**not**`" as NSString
        let strong = spans.filter { $0.style == .strong }.map { s.substring(with: $0.range) }
        let em = spans.filter { $0.style == .emphasis }.map { s.substring(with: $0.range) }
        #expect(!em.contains("case"))
        #expect(strong.contains { $0.contains("both") })
        #expect(em.contains { $0.contains("both") })
        #expect(!strong.contains("not"))
    }

    @Test("links: external, note, wikilink, autolink, bare url, unsafe schemes inert")
    func links() {
        let src = "[site](https://example.com) [n](other.md) [[Note|Alias]] <https://a.b/c> see https://x.y/z. [bad](javascript:alert(1))"
        let ns = src as NSString
        let spans = LivePreview.inlineSpans(src, active: false)
        let links = spans.compactMap { s -> (String, LiveLink)? in
            if case let .link(l) = s.style { return (ns.substring(with: s.range), l) }
            return nil
        }
        #expect(links.contains { $0.0 == "site" && $0.1 == .external("https://example.com") })
        #expect(links.contains { $0.0 == "n" && $0.1 == .note("other.md") })
        #expect(links.contains { $0.0 == "Alias" && $0.1 == .note("Note.md") })
        #expect(links.contains { $0.0 == "https://a.b/c" && $0.1 == .external("https://a.b/c") })
        #expect(links.contains { $0.0 == "https://x.y/z" })
        #expect(links.contains { $0.0 == "bad" && $0.1 == .inert })
        let hiddenText = spans.filter { $0.style == .hide }.map { ns.substring(with: $0.range) }
        #expect(hiddenText.contains("](https://example.com)"))
        #expect(hiddenText.contains("[[Note|"))
    }

    @Test("safe hrefs only for http(s)/mailto; note hrefs never carry a scheme")
    func hrefs() {
        #expect(LivePreview.safeHref("https://a.b") == "https://a.b")
        #expect(LivePreview.safeHref("mailto:x@y.z") != nil)
        #expect(LivePreview.safeHref("javascript:alert(1)") == nil)
        #expect(LivePreview.safeHref("file:///etc/passwd") == nil)
        #expect(LivePreview.safeHref("http://") == nil)
        #expect(LivePreview.noteHref("../a/b.md") == "../a/b.md")
        #expect(LivePreview.noteHref("lumi://open") == nil)
        #expect(LivePreview.noteHref("//evil.com/x") == nil)
        #expect(LivePreview.noteHref("#anchor") == nil)
    }

    @Test("tasks: box drawn off the line; toggle is one character")
    func tasks() {
        let text = "- [ ] todo\n- [x] done"
        let p = plan(text, line: 0)
        #expect(hidden(p, in: text, line: 0) == ["- "])
        #expect(styled(p, .taskBox(checked: false), in: text, line: 0) == ["[ ]"])
        #expect(plan(text, line: 1).taskDone)
        let ns = text as NSString
        #expect(LivePreview.taskToggle(ns, at: 2) == TextEdit(location: 3, length: 1, replacement: "x"))
        #expect(LivePreview.taskToggle(ns, at: 13) == TextEdit(location: 14, length: 1, replacement: " "))
        #expect(LivePreview.taskToggle(ns, at: 0) == nil)
        #expect(LivePreview.taskToggle(ns, at: 99) == nil)
    }

    @Test("bullets keep their width; ordered markers stay visible")
    func bullets() {
        let text = "- item\n  * nested\n3. third"
        #expect(styled(plan(text, line: 0), .bullet, in: text, line: 0) == ["-"])
        guard case let .list(nested) = LivePreview.scan(text as NSString)[1].kind else { Issue.record("nested"); return }
        #expect(nested.level == 1)
        #expect(hidden(plan(text, line: 2), in: text, line: 2).isEmpty)
    }

    @Test("code block: a widget off the block, source (dim fences) anywhere in it")
    func codeBlock() {
        let text = "intro\n```swift\nlet a = 1\n```\nafter"
        let off = plan(text, line: 1)
        #expect(off.style == .widget(.code(language: "swift", code: "let a = 1\n")))
        #expect(plan(text, line: 2).style == .collapsed)
        #expect(plan(text, line: 3).style == .collapsed)
        let on = plan(text, line: 1, active: [2])
        #expect(on.style == .code(fence: true, first: true, last: false))
        #expect(plan(text, line: 2, active: [2]).style == .code(fence: false, first: false, last: false))
        #expect(plan(text, line: 3, active: [2]).style == .code(fence: true, first: false, last: true))
    }

    @Test("mermaid and math fences become their widgets")
    func specialFences() {
        let text = "```mermaid\ngraph TD\n```\n$$\nx^2\n$$"
        #expect(plan(text, line: 0).style == .widget(.mermaid(code: "graph TD\n")))
        #expect(plan(text, line: 3).style == .widget(.math(latex: "x^2")))
        #expect(plan(text, line: 4).style == .collapsed)
        #expect(plan(text, line: 3, active: [5]).style == .source)
    }

    @Test("table: one widget while the cursor is outside, source when inside")
    func table() {
        let text = "| a | b |\n|:--|--:|\n| 1 | 2 |\n\nnext"
        #expect(plan(text, line: 0).style == .widget(.table(source: "| a | b |\n|:--|--:|\n| 1 | 2 |")))
        #expect(plan(text, line: 1).style == .collapsed)
        #expect(plan(text, line: 2).style == .collapsed)
        #expect(plan(text, line: 0, active: [2]).style == .source)
        #expect(plan(text, line: 4).style == .body)
    }

    @Test("quotes and callouts: prefix hidden, callout marker hidden, title kept")
    func quotes() {
        let text = "> [!warning]- Careful\n> body text\n\n> plain quote"
        let title = plan(text, line: 0)
        #expect(title.calloutFirst && !title.calloutLast)
        #expect(hidden(title, in: text, line: 0) == ["> ", "[!warning]- "])
        #expect(title.quote?.callout?.foldable == true)
        let body = plan(text, line: 1)
        #expect(body.calloutLast)
        #expect(hidden(body, in: text, line: 1) == ["> "])
        let plain = plan(text, line: 3)
        #expect(plain.quote?.callout == nil && plain.quoteFirst && plain.quoteLast)
        let on = plan(text, line: 0, active: [0])
        #expect(hidden(on, in: text, line: 0).isEmpty)
    }

    @Test("hr, setext, frontmatter, image line")
    func misc() {
        let text = "---\na: 1\n---\nTitle\n---\n\n***\n![cat](cat.png)"
        #expect(plan(text, line: 0).style == .frontmatter(first: true, last: false))
        #expect(plan(text, line: 3).style == .heading(level: 2))
        #expect(plan(text, line: 4).style == .collapsed)
        #expect(plan(text, line: 4, active: [4]).style == .heading(level: 2))
        #expect(plan(text, line: 6).style == .rule)
        #expect(plan(text, line: 6, active: [6]).style == .ruleSource)
        #expect(plan(text, line: 7).style == .widget(.image(source: "![cat](cat.png)")))
        #expect(plan(text, line: 7, active: [7]).style == .body)
    }

    @Test("active lines cover the selection; groups widen the reveal")
    func active() {
        let text = "a\nb\nc\n```\nx\n```"
        let lines = LivePreview.scan(text as NSString)
        #expect(LivePreview.activeLines([NSRange(location: 2, length: 2)], in: lines) == [1, 2])
        #expect(LivePreview.activeLines([NSRange(location: 0, length: 0)], in: lines) == [0])
        let g = LivePreview.revealedGroups([4], in: lines)
        #expect(g == [LiveGroup(first: 3, last: 5)])
    }

    @Test("plans are position independent: an edit above keeps lines below equal")
    func stablePlans() {
        let a = "x\n**b** [l](https://e.com)\n- [ ] t" as NSString
        let b = "longer first line\n**b** [l](https://e.com)\n- [ ] t" as NSString
        let la = LivePreview.scan(a), lb = LivePreview.scan(b)
        for i in 1...2 {
            #expect(LivePreview.plan(i, lines: la, text: a, active: false, groupRevealed: false)
                    == LivePreview.plan(i, lines: lb, text: b, active: false, groupRevealed: false))
        }
    }

    @Test("5k-line note scans quickly")
    func performance() {
        var s = ""
        for i in 0..<5_000 {
            switch i % 10 {
            case 0: s += "## Heading \(i)\n"
            case 1: s += "- [ ] task with **bold** and [link](https://e.com)\n"
            case 2: s += "```\n"
            case 3: s += "code \(i)\n"
            case 4: s += "```\n"
            case 5: s += "> quote with `code`\n"
            default: s += "Plain paragraph text with *emphasis* and words, line \(i).\n"
            }
        }
        let ns = s as NSString
        let t0 = Date()
        let lines = LivePreview.scan(ns)
        for i in lines.indices { _ = LivePreview.plan(i, lines: lines, text: ns, active: false, groupRevealed: false) }
        let dt = Date().timeIntervalSince(t0)
        #expect(lines.count == 5_001)
        #expect(dt < 2.0, "scan+plan took \(dt)s")
    }
}

@Suite("Note link resolution")
struct NoteLinkResolutionTests {
    @Test("relative, rooted, fragments, escapes; leaving the book is refused")
    func resolve() {
        #expect(LivePreview.resolveNoteLink("other.md", from: "a/b/note.md") == "a/b/other.md")
        #expect(LivePreview.resolveNoteLink("../c.md#top", from: "a/b/note.md") == "a/c.md")
        #expect(LivePreview.resolveNoteLink("/x/y.md", from: "a/b/note.md") == "x/y.md")
        #expect(LivePreview.resolveNoteLink("my%20note.md", from: "n.md") == "my note.md")
        #expect(LivePreview.resolveNoteLink("../../x.md", from: "a/n.md") == nil)
        #expect(LivePreview.resolveNoteLink("https://e.com/x.md", from: "n.md") == nil)
        #expect(LivePreview.resolveNoteLink("#anchor", from: "n.md") == nil)
    }
}
