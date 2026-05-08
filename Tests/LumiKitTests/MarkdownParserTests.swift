import Testing
import Foundation
@testable import LumiKit

@Suite("Markdown parser")
struct MarkdownParserTests {
    @Test("parses headings and paragraphs")
    func basicBlocks() {
        let doc = MarkdownParser.parse("# Title\n\nHello world.")
        #expect(doc.blocks.count == 2)
        if case let .heading(level, _) = doc.blocks[0] {
            #expect(level == 1)
        } else {
            Issue.record("expected heading first")
        }
        if case .paragraph = doc.blocks[1] {
            // ok
        } else {
            Issue.record("expected paragraph second")
        }
    }

    @Test("lifts a paragraph that is only an image into a media block")
    func liftsImageParagraph() {
        let doc = MarkdownParser.parse("![alt](https://example.com/foo.png)")
        #expect(doc.blocks.count == 1)
        if case let .media(ref) = doc.blocks[0] {
            #expect(ref.kind == .image)
            #expect(ref.alt == "alt")
        } else {
            Issue.record("expected media block")
        }
    }

    @Test("does not lift inline image inside surrounding text")
    func keepsInlineImage() {
        let doc = MarkdownParser.parse("look at ![alt](https://x.com/foo.png) here")
        #expect(doc.blocks.count == 1)
        if case .paragraph = doc.blocks[0] { /* ok */ } else { Issue.record("expected paragraph") }
    }

    @Test("detects YouTube via image syntax")
    func youtubeDetect() {
        let doc = MarkdownParser.parse("![demo](https://www.youtube.com/watch?v=dQw4w9WgXcQ)")
        guard case let .media(ref) = doc.blocks[0] else {
            Issue.record("expected media block"); return
        }
        if case let .youtube(id) = ref.kind {
            #expect(id == "dQw4w9WgXcQ")
        } else {
            Issue.record("expected youtube kind")
        }
    }

    @Test("detects PDF and video by extension")
    func extensionsDetect() {
        let pdfDoc = MarkdownParser.parse("![doc](https://example.com/file.pdf)")
        let vidDoc = MarkdownParser.parse("![v](https://example.com/clip.mp4)")
        if case let .media(ref) = pdfDoc.blocks[0] { #expect(ref.kind == .pdf) }
        if case let .media(ref) = vidDoc.blocks[0] { #expect(ref.kind == .video) }
    }
}
