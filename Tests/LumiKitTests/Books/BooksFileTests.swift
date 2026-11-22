import Foundation
import Testing
@testable import LumiKit

@Suite("books.yaml codec — byte-exact against the shared fixture (SPEC-LIVROS §2.3)")
struct BooksFileTests {
    @Test("canonical fixture round-trips byte for byte")
    func roundTripCanonical() throws {
        let bytes = try Fixtures.data("books/books.v1.yaml")
        let doc = try BooksFile.decode(String(decoding: bytes, as: UTF8.self))
        #expect(Data(BooksFile.encode(doc).utf8) == bytes)
    }

    @Test("empty fixture round-trips byte for byte")
    func roundTripEmpty() throws {
        let bytes = try Fixtures.data("books/books.v1.empty.yaml")
        let doc = try BooksFile.decode(String(decoding: bytes, as: UTF8.self))
        #expect(doc.books.isEmpty)
        #expect(doc.active == nil)
        #expect(Data(BooksFile.encode(doc).utf8) == bytes)
    }

    @Test("non-canonical hand edit normalises to the canonical fixture")
    func normalisesNonCanonical() throws {
        let messy = try Fixtures.text("books/books.v1.noncanonical.yaml")
        let canonical = try Fixtures.data("books/books.v1.yaml")
        let doc = try BooksFile.decode(messy)
        #expect(Data(BooksFile.encode(doc).utf8) == canonical)
    }

    @Test("decoded fields match the fixture semantics")
    func decodedFields() throws {
        let doc = try BooksFile.decode(try Fixtures.text("books/books.v1.yaml"))
        #expect(doc.version == 1)
        #expect(doc.active == "0192f7a1-3b4c-7d5e-8f60-718293a4b5c6")
        #expect(doc.books.map(\.sort) == [10, 20, 20, 30, 40])
        let work = doc.books[0]
        #expect(work.kind == .bound)
        #expect(work.serverURL == "https://lumi.work.com")
        #expect(work.account == "alice")
        #expect(work.vaultID == "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f")
        #expect(work.path == "~/notes/work")
        #expect(work.addedAt == ts("2026-11-22T10:00:00Z"))
        let diary = doc.books[1]
        #expect(diary.name == "Diário \"pessoal\" \\ rascunhos")
        #expect(diary.kind == .local && diary.serverURL == nil && diary.lastOpenedAt == nil)
        #expect(doc.books[3].id == "legacy-local-1")
        #expect(doc.books[3].name == "Tab\there")
        #expect(doc.books[4].vaultID == nil)
    }

    @Test("newer version is refused so old clients never truncate it")
    func newerVersion() {
        #expect(throws: BooksFile.DecodeError.unsupportedVersion(2)) {
            try BooksFile.decode("version: 2\nactive: null\nbooks: []\n")
        }
    }

    @Test("control characters escape as \\u00XX and decode back")
    func controlEscapes() throws {
        let book = Book(id: "x", name: "a\u{1}b\u{7F}c\nd\re", kind: .local, sort: 10,
                        addedAt: ts("2026-01-01T00:00:00Z"))
        let text = BooksFile.encode(BooksDocument(books: [book]))
        #expect(text.contains(#"name: "a\u0001b\u007Fc\nd\re""#))
        #expect(try BooksFile.decode(text).books[0].name == book.name)
    }

    @Test("fractional seconds are truncated, not rounded")
    func truncatesFraction() {
        #expect(BooksFile.timestamp(Date(timeIntervalSince1970: 1_700_000_000.999)) == "2023-11-14T22:13:20Z")
    }

    @Test("server URL normalisation (§2.1)")
    func normaliseURL() throws {
        #expect(try ServerURL.normalize("HTTPS://Lumi.Work.com:443/") == "https://lumi.work.com")
        #expect(try ServerURL.normalize("lumi.work.com/lumi/?x=1") == "https://lumi.work.com/lumi")
        #expect(try ServerURL.normalize("http://localhost:8080") == "http://localhost:8080")
        #expect(try ServerURL.normalize("http://nas.local") == "http://nas.local")
        #expect(try ServerURL.normalize("http://10.0.0.5") == "http://10.0.0.5")
        #expect(throws: ServerURL.NormalizationError.insecurePublicHost) { try ServerURL.normalize("http://lumi.work.com") }
        #expect(throws: ServerURL.NormalizationError.unsupportedScheme) { try ServerURL.normalize("ftp://x.com") }
    }
}
