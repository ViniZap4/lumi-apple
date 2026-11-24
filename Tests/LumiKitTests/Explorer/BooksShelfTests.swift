import Foundation
import Testing
@testable import LumiKit

@Suite("Books level: Livros shelf (a scope, not a folder)")
struct BooksShelfTests {
    @Test("j/k cross account groups; headers are not rows; empty groups are skipped")
    func flatMoves() {
        let sizes = [2, 0, 3]
        var c = BooksShelf.Cursor()
        var seen: [String] = []
        for _ in 0..<6 {
            seen.append("\(c.account).\(c.book)")
            c = BooksShelf.step(sizes, c, .move(1)).0
        }
        #expect(seen == ["0.0", "0.1", "2.0", "2.1", "2.2", "2.2"])
        #expect(BooksShelf.step(sizes, c, .top).0 == BooksShelf.Cursor(account: 0, book: 0))
        #expect(BooksShelf.step(sizes, BooksShelf.Cursor(), .bottom).0 == BooksShelf.Cursor(account: 2, book: 2))
    }

    @Test("no accounts layer below three accounts: h says Livros is the top")
    func noLayer() {
        let sizes = [2, 1]
        #expect(!BooksShelf.hasAccountsLayer(sizes))
        let (c, out) = BooksShelf.step(sizes, BooksShelf.Cursor(account: 1), .parent)
        #expect(c.level == .books)
        #expect(out == .atTop)
        #expect(BooksShelf.crumbs(level: .books, account: "ana", hasLayer: false).map(\.1) == ["Livros"])
    }

    @Test("with three accounts h climbs to Contas e servidores; ⏎ jumps to the first book")
    func layer() {
        let sizes = [1, 2, 0]
        #expect(BooksShelf.hasAccountsLayer(sizes))
        var (c, _) = BooksShelf.step(sizes, BooksShelf.Cursor(account: 1, book: 1), .parent)
        #expect(c.level == .accounts)
        c = BooksShelf.step(sizes, c, .move(1)).0
        #expect(c.account == 2)
        #expect(BooksShelf.step(sizes, c, .open).1 == .emptyAccount(2))
        c = BooksShelf.step(sizes, c, .move(-1)).0
        let (inBooks, _) = BooksShelf.step(sizes, c, .open)
        #expect(inBooks == BooksShelf.Cursor(level: .books, account: 1, book: 0))
        #expect(BooksShelf.step(sizes, inBooks, .open).1 == .open(account: 1, book: 0))
        #expect(BooksShelf.crumbs(level: .books, account: "vinizap@host", hasLayer: true).map(\.1) == ["Contas", "vinizap@host", "Livros"])
        #expect(BooksShelf.crumbs(level: .accounts, account: nil, hasLayer: true).map(\.1) == ["Contas e servidores"])
    }

    @Test("pt-BR plurals and distinct icons per level")
    func copy() {
        #expect(BooksShelf.plural(1, "livro", "livros") == "1 livro")
        #expect(BooksShelf.plural(0, "livro", "livros") == "0 livros")
        #expect(BooksShelf.plural(44, "nota", "notas") == "44 notas")
        let icons = [BooksShelf.CrumbKind.server, .account, .shelf, .book, .folder].map(BooksShelf.symbol)
        #expect(Set(icons).count == 5)
    }
}
