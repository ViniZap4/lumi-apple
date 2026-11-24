import SwiftUI
import LumiKit

/// One account section on the Livros shelf.
public struct ShelfAccount: Identifiable, Equatable {
    public let id: String
    /// "ana" or "Este Mac".
    public let user: String
    /// "lumi.example.com" or "pastas neste Mac".
    public let host: String
    public let isLocal: Bool
    public let signedIn: Bool
    public let books: [ShelfBook]

    public init(id: String, user: String, host: String, isLocal: Bool, signedIn: Bool, books: [ShelfBook]) {
        self.id = id
        self.user = user
        self.host = host
        self.isLocal = isLocal
        self.signedIn = signedIn
        self.books = books
    }
}

/// One book row on the shelf.
public struct ShelfBook: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let isLocal: Bool
    public let noteCount: Int?
    public let lastNote: String?
    /// 1…9: the `g1`–`g9` / ⌃1–9 key that opens it.
    public let number: Int?
    public let isOpen: Bool
    public let statusLabel: String
    public let statusColor: Color
    public let syncing: Bool

    public init(id: String, name: String, isLocal: Bool, noteCount: Int?, lastNote: String?, number: Int?, isOpen: Bool,
                statusLabel: String, statusColor: Color, syncing: Bool) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.noteCount = noteCount
        self.lastNote = lastNote
        self.number = number
        self.isOpen = isOpen
        self.statusLabel = statusLabel
        self.statusColor = statusColor
        self.syncing = syncing
    }
}

/// The books level of the floating explorer: "Livros", one list of every
/// book grouped under account headers (not folder rows), with a details
/// column; or "Contas e servidores" as cards when there are many accounts.
public struct BooksShelfView: View {
    let accounts: [ShelfAccount]
    let cursor: BooksShelf.Cursor
    let onPick: (BooksShelf.Cursor) -> Void
    let onOpen: (BooksShelf.Cursor) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lumiDensity) private var density
    @Environment(\.lumiMotionPolicy) private var motion
    @Namespace private var slab

    public init(accounts: [ShelfAccount], cursor: BooksShelf.Cursor,
                onPick: @escaping (BooksShelf.Cursor) -> Void, onOpen: @escaping (BooksShelf.Cursor) -> Void) {
        self.accounts = accounts
        self.cursor = cursor
        self.onPick = onPick
        self.onOpen = onOpen
    }

    public var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 640
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if cursor.level == .accounts { accountCards } else { shelf }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .animation(motion.animation(.glide), value: cursor)
                }
                .scrollIndicators(.never)
                .frame(width: wide ? geo.size.width * 0.58 : geo.size.width)
                .background(theme.ramp.surfaceSunk.opacity(0.3))
                if wide {
                    Hairline(vertical: true)
                    details
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id("\(cursor.level)-\(cursor.account)-\(cursor.book)")
                        .lumiEnter(MotionFrom(x: 8, opacity: 0), spring: .gentle, delay: 0.04)
                }
            }
        }
    }

    // MARK: Livros

    private var shelf: some View {
        ForEach(Array(accounts.enumerated()), id: \.element.id) { a, acc in
            accountHeader(acc)
                .padding(.top, a == 0 ? 2 : 14)
                .staggerIn(a * 3, active: true)
            if acc.books.isEmpty {
                Text(acc.signedIn ? "nenhum livro nesta conta ainda" : "sessão encerrada · entre pela paleta (Entrar…)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.ramp.ink3)
                    .padding(.leading, 40)
                    .padding(.vertical, 4)
            }
            ForEach(Array(acc.books.enumerated()), id: \.element.id) { b, book in
                bookRow(book, selected: cursor.level == .books && cursor.account == a && cursor.book == b)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(BooksShelf.Cursor(level: .books, account: a, book: b)) }
                    .onTapGesture { onPick(BooksShelf.Cursor(level: .books, account: a, book: b)) }
                    .staggerIn(a * 3 + b + 1, active: true)
            }
        }
    }

    /// Account section header: avatar initial, user, host, a status dot
    /// and the count. Not a row (the cursor never lands here).
    private func accountHeader(_ acc: ShelfAccount) -> some View {
        HStack(spacing: 9) {
            avatar(acc, size: 22)
            Text(acc.user)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ramp.ink1)
            Text(acc.host)
                .font(ShellFont.small)
                .foregroundStyle(theme.ramp.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
            Circle()
                .fill(acc.isLocal ? theme.ramp.ink4 : acc.signedIn ? Color.green.opacity(0.8) : theme.warning)
                .frame(width: 6, height: 6)
            Spacer(minLength: 8)
            Text(BooksShelf.plural(acc.books.count, "livro", "livros"))
                .font(ShellFont.small)
                .foregroundStyle(theme.ramp.ink3)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.ramp.hairlineSoft).frame(height: 1).padding(.leading, 41)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func avatar(_ acc: ShelfAccount, size: CGFloat) -> some View {
        let hue = Self.hue(acc.id)
        return ZStack {
            Circle().fill(acc.isLocal ? theme.ramp.surface3 : Color(hue: hue, saturation: 0.45, brightness: theme.isDark ? 0.72 : 0.62))
            if acc.isLocal {
                Image(systemName: "laptopcomputer").font(.system(size: size * 0.45)).foregroundStyle(theme.ramp.ink2)
            } else {
                Text(acc.user.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }

    static func hue(_ s: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360) / 360
    }

    private func bookRow(_ book: ShelfBook, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: book.isOpen ? "book" : "book.closed")
                .font(.system(size: 12))
                .foregroundStyle(selected || book.isOpen ? theme.primary : theme.ramp.ink3)
                .frame(width: 16)
            Text(book.name)
                .font(.system(size: density.rowFont + 0.5, weight: book.isOpen ? .semibold : .regular))
                .foregroundStyle(theme.ramp.ink1)
                .lineLimit(1)
            if book.isOpen {
                Text("aberto")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(theme.ramp.accentWash))
            }
            Spacer(minLength: 8)
            if let n = book.noteCount {
                Text(BooksShelf.plural(n, "nota", "notas"))
                    .font(ShellFont.small)
                    .foregroundStyle(theme.ramp.ink3)
            }
            SyncPulseDot(color: book.statusColor, size: 6, syncing: book.syncing, pulse: 0)
                .help(book.statusLabel)
            if let n = book.number {
                Text("g\(n)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.ramp.ink4)
                    .frame(width: 20, alignment: .trailing)
            } else {
                Color.clear.frame(width: 20, height: 1)
            }
        }
        .padding(.leading, 31)
        .padding(.trailing, 10)
        .frame(height: density.rowHeight + 2)
        .background {
            if selected {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.selectionRow)
                    Capsule().fill(theme.primary).frame(width: 2.5).padding(.vertical, 5)
                }
                .matchedGeometryEffect(id: "shelf-slab", in: slab)
            }
        }
    }

    // MARK: Contas e servidores

    private var accountCards: some View {
        ForEach(Array(accounts.enumerated()), id: \.element.id) { a, acc in
            let selected = cursor.account == a
            HStack(spacing: 12) {
                avatar(acc, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.user).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ramp.ink1)
                    HStack(spacing: 5) {
                        Image(systemName: acc.isLocal ? "laptopcomputer" : "server.rack").font(.system(size: 10))
                        Text(acc.host).lineLimit(1)
                    }
                    .font(ShellFont.small)
                    .foregroundStyle(theme.ramp.ink3)
                }
                Spacer()
                Text(BooksShelf.plural(acc.books.count, "livro", "livros"))
                    .font(ShellFont.small)
                    .foregroundStyle(theme.ramp.ink3)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: LumiRadius.md, style: .continuous)
                    .fill(selected ? theme.selectionRow : theme.ramp.surface1)
                    .lumiElevation(selected ? .hovered : .raised, radius: LumiRadius.md, ramp: theme.ramp)
            )
            .overlay(RoundedRectangle(cornerRadius: LumiRadius.md, style: .continuous)
                .strokeBorder(selected ? theme.ramp.accentLine : .clear, lineWidth: 1))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen(BooksShelf.Cursor(level: .accounts, account: a)) }
            .onTapGesture { onPick(BooksShelf.Cursor(level: .accounts, account: a)) }
            .staggerIn(a, active: true)
        }
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        let ramp = theme.ramp
        if accounts.indices.contains(cursor.account) {
            let acc = accounts[cursor.account]
            if cursor.level == .books, acc.books.indices.contains(cursor.book) {
                let book = acc.books[cursor.book]
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIVRO").font(ShellFont.small).tracking(1).foregroundStyle(ramp.ink3)
                    Text(book.name)
                        .font(.system(size: LumiType.xl + 2, weight: .bold))
                        .tracking(LumiType.trackingTight * 22)
                        .foregroundStyle(ramp.ink1)
                    HStack(spacing: 6) {
                        SyncPulseDot(color: book.statusColor, size: 7, syncing: book.syncing, pulse: 0)
                        Text(book.statusLabel).font(ShellFont.chrome).foregroundStyle(ramp.ink3)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Conta").foregroundStyle(ramp.ink3)
                            Text(acc.isLocal ? "Este Mac" : "\(acc.user)@\(acc.host)").foregroundStyle(ramp.ink2)
                        }
                        GridRow {
                            Text("Notas").foregroundStyle(ramp.ink3)
                            Text(book.noteCount.map { BooksShelf.plural($0, "nota", "notas") } ?? "—").foregroundStyle(ramp.ink2)
                        }
                        if let last = book.lastNote {
                            GridRow {
                                Text("Última").foregroundStyle(ramp.ink3)
                                Text(last).foregroundStyle(ramp.ink2).lineLimit(1)
                            }
                        }
                    }
                    .font(ShellFont.small)
                    .padding(.top, 4)
                    Text(book.isOpen ? "Aberto agora — ⏎ ou l volta às notas" : "⏎ ou l abre este livro")
                        .font(ShellFont.small)
                        .foregroundStyle(ramp.ink3)
                        .padding(.top, 8)
                }
                .padding(20)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CONTA").font(ShellFont.small).tracking(1).foregroundStyle(ramp.ink3)
                    HStack(spacing: 10) {
                        avatar(acc, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.user).font(.system(size: 18, weight: .bold)).foregroundStyle(ramp.ink1)
                            Text(acc.host).font(ShellFont.small).foregroundStyle(ramp.ink3)
                        }
                    }
                    Text(BooksShelf.plural(acc.books.count, "livro", "livros"))
                        .font(ShellFont.chrome).foregroundStyle(ramp.ink2)
                    Text("⏎ ou l mostra os livros desta conta").font(ShellFont.small).foregroundStyle(ramp.ink3).padding(.top, 8)
                }
                .padding(20)
            }
        } else {
            Text("Nenhum livro ainda — paleta: Novo livro…")
                .font(ShellFont.chrome)
                .foregroundStyle(ramp.ink3)
                .padding(20)
        }
    }
}
