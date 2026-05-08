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
}
