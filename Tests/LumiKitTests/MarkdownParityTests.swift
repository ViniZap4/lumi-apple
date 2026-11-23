import Testing
import Foundation
@testable import LumiKit

@Suite("Markdown parity: blocks and inlines the web renders")
struct MarkdownParityParserTests {
    @Test("GFM table: header, rows, alignments")
    func table() throws {
        let doc = MarkdownParser.parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | **2** | 3 |\n| 4 | 5 |")
        guard case let .table(t)? = doc.blocks.first else { Issue.record("no table"); return }
        #expect(t.alignments == [.left, .center, .right])
        #expect(t.header.count == 3)
        #expect(t.rows.count == 2)
        #expect(t.rows[0][1] == [.strong([.text("2")])])
        #expect(t.rows[1].count == 3) // padded
    }

    @Test("callouts: kind, alias, title, body, fold state")
    func callouts() throws {
        let doc = MarkdownParser.parse("> [!tip] Keyboard first\n> Every action has a key.\n\n> [!bug]-\n> hidden\n\n> [!unknown]+ T\n> x")
        #expect(doc.blocks.count == 3)
        guard case let .callout(a) = doc.blocks[0], case let .callout(b) = doc.blocks[1], case let .callout(c) = doc.blocks[2] else {
            Issue.record("expected three callouts"); return
        }
        #expect(a.kind == "tip" && a.fold == .none)
        #expect(a.title == [.text("Keyboard first")])
        #expect(a.blocks == [.paragraph(inline: [.text("Every action has a key.")])])
        #expect(b.kind == "danger" && b.rawKind == "bug" && b.fold == .closed && b.title.isEmpty)
        #expect(c.kind == "note" && c.fold == .open)
    }

    @Test("plain quotes stay quotes; a marker in code stays text")
    func notCallouts() {
        let doc = MarkdownParser.parse("> just a quote\n\n```\n> [!note]\n```")
        guard case .blockQuote = doc.blocks[0], case let .codeBlock(_, code) = doc.blocks[1] else { Issue.record("shape"); return }
        #expect(code.contains("[!note]"))
    }

    @Test("footnotes: numbered refs, definitions collected at the end")
    func footnotes() {
        let doc = MarkdownParser.parse("A claim[^src] and another[^2].\n\n[^2]: Second.\n[^src]: The source.\n\nUnused [^nope].")
        guard case let .paragraph(inline) = doc.blocks[0] else { Issue.record("no paragraph"); return }
        #expect(inline.contains(.footnoteRef(id: "src", number: 1)))
        #expect(inline.contains(.footnoteRef(id: "2", number: 2)))
        guard case let .footnotes(items)? = doc.blocks.last else { Issue.record("no footnotes"); return }
        #expect(items.map(\.id) == ["src", "2"])
        #expect(items[0].inline == [.text("The source.")])
        // Undefined refs stay literal.
        guard case let .paragraph(tail) = doc.blocks[1] else { Issue.record("tail"); return }
        #expect(MarkdownParser.plainText(tail).contains("[^nope]"))
    }

    @Test("==mark== and <kbd> inline")
    func markAndKbd() {
        let doc = MarkdownParser.parse("Press <kbd>⌘</kbd> for ==**bold** mark== but not a == b.")
        guard case let .paragraph(inline) = doc.blocks[0] else { Issue.record("no paragraph"); return }
        #expect(inline.contains(.kbd("⌘")))
        #expect(inline.contains(.mark([.strong([.text("bold")]), .text(" mark")])))
        #expect(MarkdownParser.plainText(inline).contains("a == b"))
    }

    @Test("image title becomes the caption")
    func figure() {
        let doc = MarkdownParser.parse("![Alt](https://x.y/a.png \"A caption\")")
        guard case let .media(ref) = doc.blocks[0] else { Issue.record("no media"); return }
        #expect(ref.title == "A caption")
    }

    @Test("source lines per top-level block, through multi-line math")
    func sourceLines() {
        let src = "# Title\n\n$$\na\nb\n$$\n\nPara\n\n- x\n- y\n\n[^1]: n\n\nref[^1]"
        let doc = MarkdownParser.parse(src)
        #expect(doc.lineCount == 15)
        #expect(doc.sourceLines.count == doc.blocks.count)
        #expect(Array(doc.sourceLines.prefix(5)) == [0, 2, 7, 9, 14])
        guard case .footnotes? = doc.blocks.last else { Issue.record("footnotes"); return }
    }

    @Test("in-document anchors stay fragments")
    func anchors() {
        #expect(MarkdownParser.resolve(source: "#intro", baseURL: URL(fileURLWithPath: "/tmp/v/")).map(\.absoluteString) == "#intro")
    }
}

@Suite("Task markers (web taskMarkers / taskToggle)")
struct MarkdownTasksTests {
    @Test("markers in document order, fenced code skipped, quotes and ordered lists included")
    func markers() {
        let src = "- [ ] a\n```\n- [ ] code\n```\n> - [x] quoted\n1. [ ] num\n* [X] star\n- [] not"
        let m = MarkdownTasks.markers(in: src)
        #expect(m.count == 4)
        let ns = src as NSString
        #expect(m.map { ns.substring(with: NSRange(location: $0, length: 1)) } == [" ", "x", " ", "X"])
    }

    @Test("toggle is a single-character ranged edit (UTF-16)")
    func toggle() throws {
        let src = "😀 intro\n- [ ] one\n- [x] two"
        let e = try #require(MarkdownTasks.toggle(in: src, index: 0))
        #expect(e.length == 1 && e.replacement == "x")
        let ns = NSMutableString(string: src)
        #expect(e.apply(to: ns))
        #expect(ns as String == "😀 intro\n- [x] one\n- [x] two")
        let off = try #require(MarkdownTasks.toggle(in: src, index: 1))
        #expect(off.replacement == " ")
        #expect(MarkdownTasks.toggle(in: src, index: 2) == nil)
    }
}

@Suite("Reader text helpers")
struct MarkdownTextTests {
    @Test("startsWithTitle ignores case, emphasis, closing hashes")
    func title() {
        #expect(MarkdownText.startsWithTitle("\n# Field *Notes* ##\nbody", title: "field notes"))
        #expect(!MarkdownText.startsWithTitle("## Field notes", title: "Field notes"))
        #expect(!MarkdownText.startsWithTitle("# Other", title: "Field notes"))
        #expect(!MarkdownText.startsWithTitle("# x", title: ""))
    }

    @Test("word count skips markup; reading time ≈ 230 wpm, at least 1")
    func words() {
        #expect(MarkdownText.wordCount("# Hello **world** — it's 2026, olá_mundo") == 5)
        #expect(MarkdownText.readingMinutes(words: 0) == 0)
        #expect(MarkdownText.readingMinutes(words: 10) == 1)
        #expect(MarkdownText.readingMinutes(words: 690) == 3)
    }

    @Test("heading slug")
    func slug() {
        #expect(MarkdownText.slug("Getting Started — Fast!") == "h-getting-started-fast")
        #expect(MarkdownText.slug("Olá Mundo") == "h-ola-mundo")
        #expect(MarkdownText.slug("!!!") == "h-section")
    }
}

@Suite("Code highlighter")
struct CodeHighlighterTests {
    private func kinds(_ code: String, _ lang: String) -> [String: CodeHighlighter.Kind] {
        let ns = code as NSString
        var out: [String: CodeHighlighter.Kind] = [:]
        for t in CodeHighlighter.tokens(code, language: lang) { out[ns.substring(with: t.range)] = t.kind }
        return out
    }

    @Test("swift: keywords, strings, numbers, comments, types, calls")
    func swift() {
        let k = kinds("// hi\nlet x: Int = foo(\"s\", 42)", "swift")
        #expect(k["// hi"] == .comment)
        #expect(k["let"] == .keyword)
        #expect(k["Int"] == .type)
        #expect(k["foo"] == .function)
        #expect(k["\"s\""] == .string)
        #expect(k["42"] == .number)
    }

    @Test("python comments, json keys, no language → nothing")
    func others() {
        #expect(kinds("# c\ndef f(): pass", "python")["# c"] == .comment)
        #expect(kinds("{\"a\": 1}", "json")["\"a\""] == .property)
        #expect(CodeHighlighter.tokens("let x", language: nil).isEmpty)
    }
}

@Suite("Split preview scroll sync + hint labels")
struct ScrollSyncTests {
    @Test("anchors normalise, interpolate both ways")
    func mapping() {
        let a = ScrollSync.normalize([.init(line: 10, top: 300), .init(line: 4, top: 100), .init(line: 6, top: 90)], totalLines: 20, contentHeight: 800)
        #expect(a.map(\.line) == [0, 4, 10, 20])
        #expect(ScrollSync.offset(forLine: 2, anchors: a) == 50)
        #expect(ScrollSync.offset(forLine: 7, anchors: a) == 200)
        #expect(ScrollSync.line(forOffset: 200, anchors: a) == 7)
        #expect(ScrollSync.line(forOffset: 5000, anchors: a) == 20)
        #expect(ScrollSync.clampRatio(0.9) == 0.75)
    }

    @Test("hint labels are prefix-free; filtering finds the hit")
    func hints() {
        #expect(HintLabels.make(3) == ["a", "s", "d"])
        let many = HintLabels.make(30)
        #expect(Set(many.map(\.count)) == [2])
        #expect(Set(many).count == 30)
        let f = HintLabels.filter(many, typed: many[7])
        #expect(f.hit == 7 && f.live == [7])
    }
}
