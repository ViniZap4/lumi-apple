import Testing
import Foundation
@testable import LumiKit

@Suite("MarkdownSyntaxHighlighter — line-local spans, dirty paragraphs")
struct MarkdownSyntaxHighlighterTests {
    @Test("spans are found per style within the given lines")
    func spans() {
        let text = "# Title\nsome **bold** and `code`\n> quote\n- item [l](u)" as NSString
        let styles = Set(MarkdownSyntaxHighlighter.spans(in: text, range: NSRange(location: 0, length: text.length)).map(\.style))
        #expect(styles == [.heading, .bold, .inlineCode, .quote, .bullet, .link])
    }

    @Test("an edit dirties only its own paragraph")
    func dirtyOneLine() {
        let text = "one\ntwo changed\nthree" as NSString
        let dirty = MarkdownSyntaxHighlighter.dirtyRange(for: [TextEdit(location: 7, length: 0, replacement: " changed")], in: text)
        #expect(dirty == NSRange(location: 4, length: 12))
    }

    @Test("a newline insert dirties both resulting lines; sequential edits union")
    func dirtyMulti() {
        let text = "ab\ncd\nef\ngh" as NSString
        let d = MarkdownSyntaxHighlighter.dirtyRange(for: [
            TextEdit(location: 0, length: 0, replacement: "a\n"), // "a\nab\ncd\nef\ngh"
        ], in: "a\nab\ncd\nef\ngh" as NSString)
        #expect(d == NSRange(location: 0, length: 5))
        let e = MarkdownSyntaxHighlighter.dirtyRange(for: [
            TextEdit(location: 0, length: 1, replacement: "A"),
            TextEdit(location: 9, length: 1, replacement: "G"),
        ], in: text)
        #expect(e == NSRange(location: 0, length: 11))
    }
}

extension MarkdownSyntaxHighlighterTests {
    @Test("splitting a heading line re-highlights the tail line too")
    func splitHeading() {
        // "# abc" → "# a\nbc"
        let d = MarkdownSyntaxHighlighter.dirtyRange(for: [TextEdit(location: 3, length: 0, replacement: "\n")], in: "# a\nbc" as NSString)
        #expect(d == NSRange(location: 0, length: 6))
    }
}
