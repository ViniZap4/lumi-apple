import Testing
@testable import LumiKit

@Suite("Note slug")
struct NoteSlugTests {
    @Test("lowercases and hyphenates")
    func basic() {
        #expect(Note.slug(from: "Hello World") == "hello-world")
    }

    @Test("collapses non-alphanumeric runs")
    func collapses() {
        #expect(Note.slug(from: "Foo!! Bar??  Baz") == "foo-bar-baz")
    }

    @Test("trims leading and trailing hyphens")
    func trims() {
        #expect(Note.slug(from: "  ~weird~ ") == "weird")
    }

    @Test("handles unicode letters")
    func unicode() {
        #expect(Note.slug(from: "Olá Mundo") == "olá-mundo")
    }
}
