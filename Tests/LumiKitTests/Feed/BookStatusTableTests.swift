import Foundation
import Testing
@testable import LumiKit

/// Table-driven test over `Tests/Fixtures/books/book-status.cases.json`,
/// the case set shared with the TUI and web (SPEC-LIVROS §4.2).
struct StatusCase: Decodable, CustomTestStringConvertible, Sendable {
    struct BookIn: Decodable, Sendable {
        let kind: String; let has_account: Bool; let has_token: Bool
        let has_vault_id: Bool; let revoked: Bool; let can_edit: Bool
    }
    struct CatchUpIn: Decodable, Sendable {
        let phase: String; let failures: Int; let reason: String?; let cursor: Int64; let head: Int64?
    }
    struct EditorIn: Decodable, Sendable { let phase: String; let pending: Bool }

    let name: String
    let spec: String
    let book: BookIn
    let feed: String?
    let catch_up: CatchUpIn
    let editor: EditorIn
    let rest: String
    let expected: String

    var testDescription: String { name }

    static func load() -> [StatusCase] {
        struct Doc: Decodable { let cases: [StatusCase] }
        let data = (try? Fixtures.data("books/book-status.cases.json")) ?? Data()
        return (try? JSONDecoder().decode(Doc.self, from: data).cases) ?? []
    }

    var inputs: (BookStatusBook, AccountFeedState?, CatchUpSnapshot, EditorSnapshot, RestHealth?) {
        let b = BookStatusBook(kind: Book.Kind(rawValue: book.kind)!, hasAccount: book.has_account,
                               hasToken: book.has_token, hasVaultID: book.has_vault_id,
                               revoked: book.revoked, canEdit: book.can_edit)
        let f: AccountFeedState? = switch feed {
        case "connecting": .connecting
        case "open": .open
        case "backoff": .backoff(attempt: 2, retryInSeconds: 2)
        case "auth_dead": .authDead
        case "disabled": .disabled
        default: nil
        }
        let phase: CatchUpSnapshot.Phase = switch catch_up.phase {
        case "running": .running
        case "failed": .failed(count: catch_up.failures, reason: catch_up.reason ?? "")
        default: .idle
        }
        let r: RestHealth? = if rest == "ok" { .ok }
            else if rest == "network" { .network("offline") }
            else if rest == "unauthorized" { .unauthorized }
            else if rest.hasPrefix("failing:") { .failing(count: Int(rest.dropFirst(8)) ?? 0, reason: "HTTP 500") }
            else { nil }
        return (b, f, CatchUpSnapshot(phase: phase, cursor: catch_up.cursor, head: catch_up.head),
                EditorSnapshot(phase: EditorSnapshot.Phase(rawValue: editor.phase)!, pending: editor.pending), r)
    }
}

@Suite("bookStatus — seven-state precedence table (SPEC-LIVROS §4)")
struct BookStatusTableTests {
    @Test("fixture loads and covers every state")
    func coverage() {
        let cases = StatusCase.load()
        #expect(cases.count >= 20)
        #expect(Set(cases.map(\.expected)) == ["local", "needs_sign_in", "error", "offline", "syncing", "read_only", "up_to_date"])
    }

    @Test("table case", arguments: StatusCase.load())
    func tableCase(_ c: StatusCase) {
        let (book, feed, catchUp, editor, rest) = c.inputs
        let got = bookStatus(book: book, accountFeed: feed, catchUp: catchUp, editor: editor, restHealth: rest)
        #expect(got.code == c.expected, "\(c.name) — spec: \(c.spec)")
    }
}
