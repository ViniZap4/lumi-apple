import Testing
import Foundation
@testable import LumiKit

@Suite("Frontmatter parser")
struct FrontmatterParserTests {
    @Test("returns empty when no frontmatter block")
    func noFrontmatter() {
        let (fm, body) = FrontmatterParser.split("# Hello\n\nworld")
        #expect(fm.id == nil)
        #expect(fm.title == nil)
        #expect(body == "# Hello\n\nworld")
    }

    @Test("parses id, title, and tags list")
    func basic() {
        let source = """
        ---
        id: my-note
        title: My Note
        tags:
          - foo
          - bar
        ---
        body content
        """
        let (fm, body) = FrontmatterParser.split(source)
        #expect(fm.id == "my-note")
        #expect(fm.title == "My Note")
        #expect(fm.tags == ["foo", "bar"])
        #expect(body == "body content")
    }

    @Test("parses inline tag list")
    func inlineList() {
        let source = """
        ---
        title: T
        tags: [a, b, "c d"]
        ---
        x
        """
        let (fm, _) = FrontmatterParser.split(source)
        #expect(fm.tags == ["a", "b", "c d"])
    }

    @Test("parses ISO 8601 timestamps")
    func timestamps() {
        let source = """
        ---
        created_at: 2026-02-16T11:00:00Z
        updated_at: 2026-02-16T11:05:00Z
        ---
        """
        let (fm, _) = FrontmatterParser.split(source)
        #expect(fm.createdAt != nil)
        #expect(fm.updatedAt != nil)
        #expect(fm.updatedAt! > fm.createdAt!)
    }

    @Test("preserves unknown keys verbatim")
    func unknownKeys() {
        let source = """
        ---
        title: T
        custom: hello
        another: 42
        ---
        body
        """
        let (fm, _) = FrontmatterParser.split(source)
        #expect(fm.title == "T")
        #expect(fm.unknownLines.contains("custom: hello"))
        #expect(fm.unknownLines.contains("another: 42"))
    }

    @Test("preserves unknown list keys")
    func unknownListKeys() {
        let source = """
        ---
        title: T
        aliases:
          - one
          - two
        ---
        """
        let (fm, _) = FrontmatterParser.split(source)
        #expect(fm.unknownLines.contains("aliases:"))
        #expect(fm.unknownLines.contains("  - one"))
        #expect(fm.unknownLines.contains("  - two"))
    }

    @Test("serialize emits known + unknown in stable order")
    func serializeOrder() {
        let fm = Frontmatter(
            id: "n",
            title: "Note",
            tags: ["a", "b"],
            unknownLines: ["custom: x"]
        )
        let out = FrontmatterParser.serialize(fm)
        #expect(out.hasPrefix("---\n"))
        #expect(out.contains("id: n"))
        #expect(out.contains("title: Note"))
        #expect(out.contains("  - a"))
        #expect(out.contains("custom: x"))
        #expect(out.hasSuffix("---\n"))
    }

    @Test("roundtrip preserves shape for typical note")
    func roundtrip() {
        let source = """
        ---
        id: abc
        title: ABC
        tags:
          - x
          - y
        custom: hi
        ---
        # Body
        text
        """
        let (fm, body) = FrontmatterParser.split(source)
        let reserialized = FrontmatterParser.serialize(fm) + body
        let (fm2, body2) = FrontmatterParser.split(reserialized)
        #expect(fm2.id == fm.id)
        #expect(fm2.title == fm.title)
        #expect(fm2.tags == fm.tags)
        #expect(fm2.unknownLines == fm.unknownLines)
        #expect(body2 == body)
    }
}
