import Foundation

/// The books level of the floating explorer as a *scope*, not a folder
/// (owner, 2026-11-25: "os dois aparecem como book… confunde como se
/// fosse uma pasta pai"). Port of web `lib/books-nav.ts`:
///
/// - "Livros": ONE list of every book, grouped under account section
///   headers. Headers are not rows: the cursor skips them, j/k cross
///   groups.
/// - "Contas e servidores": a separate layer only with many accounts
///   (≥ `accountsLayerMin`); `h` on Livros climbs to it, `l` / ⏎ on an
///   account jumps to its first book. With fewer the layer does not
///   exist and `h` stays on Livros.
///
/// Pure: AppState keeps the cursor; `sizes` is each group's book count.
public enum BooksShelf {
    public static let accountsLayerMin = 3

    public enum Level: Sendable, Equatable { case accounts, books }

    public struct Cursor: Sendable, Equatable {
        public var level: Level
        public var account: Int
        public var book: Int
        public init(level: Level = .books, account: Int = 0, book: Int = 0) {
            self.level = level
            self.account = account
            self.book = book
        }
    }

    public enum Key: Sendable, Equatable { case move(Int), top, bottom, parent, open }

    public enum Outcome: Sendable, Equatable {
        case none
        /// Open the book at (account, book).
        case open(account: Int, book: Int)
        /// `h` on Livros with no accounts layer: say so.
        case atTop
        /// ⏎ on an account with no books (e.g. signed out).
        case emptyAccount(Int)
    }

    public static func hasAccountsLayer(_ sizes: [Int]) -> Bool { sizes.count >= accountsLayerMin }

    public static func flatIndex(_ sizes: [Int], _ c: Cursor) -> Int {
        var n = 0
        for a in 0..<min(c.account, sizes.count) { n += sizes[a] }
        return n + c.book
    }

    public static func fromFlat(_ sizes: [Int], _ i: Int) -> Cursor {
        let total = sizes.reduce(0, +)
        guard total > 0 else { return Cursor(account: sizes.firstIndex { $0 > 0 } ?? 0) }
        var r = max(0, min(total - 1, i))
        for (a, n) in sizes.enumerated() {
            if r < n { return Cursor(level: .books, account: a, book: r) }
            r -= n
        }
        return Cursor()
    }

    public static func step(_ sizes: [Int], _ c: Cursor, _ k: Key) -> (Cursor, Outcome) {
        let total = sizes.reduce(0, +)
        if c.level == .accounts {
            let n = sizes.count
            func at(_ i: Int) -> Cursor { Cursor(level: .accounts, account: max(0, min(n - 1, i)), book: 0) }
            switch k {
            case let .move(d): return (at(c.account + d), .none)
            case .top: return (at(0), .none)
            case .bottom: return (at(n - 1), .none)
            case .parent: return (c, .none)
            case .open:
                guard sizes.indices.contains(c.account) else { return (c, .none) }
                if sizes[c.account] == 0 { return (c, .emptyAccount(c.account)) }
                return (Cursor(level: .books, account: c.account, book: 0), .none)
            }
        }
        let i = flatIndex(sizes, c)
        switch k {
        case let .move(d): return (fromFlat(sizes, i + d), .none)
        case .top: return (fromFlat(sizes, 0), .none)
        case .bottom: return (fromFlat(sizes, total - 1), .none)
        case .parent:
            return hasAccountsLayer(sizes) ? (Cursor(level: .accounts, account: c.account, book: c.book), .none) : (c, .atTop)
        case .open:
            guard total > 0, sizes.indices.contains(c.account), c.book < sizes[c.account] else { return (c, .none) }
            return (c, .open(account: c.account, book: c.book))
        }
    }

    /// pt-BR count: "1 livro", "2 livros", "0 livros".
    public static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// The breadcrumb for the level: each crumb has its own icon kind.
    public enum CrumbKind: String, Sendable { case server, account, shelf, book, folder }

    public static func crumbs(level: Level, account: String?, hasLayer: Bool) -> [(CrumbKind, String)] {
        switch level {
        case .accounts: return [(.server, "Contas e servidores")]
        case .books:
            var out: [(CrumbKind, String)] = []
            if hasLayer {
                out.append((.server, "Contas"))
                if let account { out.append((.account, account)) }
            }
            out.append((.shelf, "Livros"))
            return out
        }
    }

    /// SF Symbol per level (distinct: server, account, shelf, book, folder).
    public static func symbol(_ kind: CrumbKind) -> String {
        switch kind {
        case .server: return "server.rack"
        case .account: return "person.crop.circle"
        case .shelf: return "books.vertical"
        case .book: return "book.closed"
        case .folder: return "folder"
        }
    }
}
