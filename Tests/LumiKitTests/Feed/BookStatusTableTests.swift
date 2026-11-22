import Foundation
import Testing
@testable import LumiKit

/// Table-driven test over `Tests/Fixtures/books/bookstatus.cases.json`,
/// copied VERBATIM from the web client
/// (`web-client/src/test/fixtures/bookstatus.cases.json`) so Apple, web
/// and TUI agree on SPEC-LIVROS §4. Each case overrides `defaults`.
struct StatusCase: CustomTestStringConvertible, Sendable {
    let name: String
    let expect: String
    let book: BookStatusBook
    let feed: AccountFeedState?
    let catchUp: CatchUpSnapshot
    let editor: EditorSnapshot
    let rest: RestHealth?

    var testDescription: String { name }

    static func load() -> [StatusCase] {
        guard let data = try? Fixtures.data("books/bookstatus.cases.json"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = root["defaults"] as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { return [] }
        return cases.map { raw in
            func section(_ key: String) -> [String: Any]? {
                if raw.keys.contains(key) {
                    guard let override = raw[key] as? [String: Any] else { return nil } // explicit null
                    var merged = defaults[key] as? [String: Any] ?? [:]
                    merged.merge(override) { _, new in new }
                    return merged
                }
                return defaults[key] as? [String: Any]
            }
            let b = section("book") ?? [:]
            let feedObj = section("accountFeed")
            let cu = section("catchUp") ?? [:]
            let ed = section("editor") ?? [:]
            let rh = section("restHealth") ?? [:]

            // Web models "no account / no token" as accountFeed == null.
            let hasSession = feedObj != nil
            let book = BookStatusBook(
                kind: (b["kind"] as? String) == "local" ? .local : .bound,
                hasAccount: hasSession,
                hasToken: hasSession,
                hasVaultID: !(b["vault_id"] is NSNull) && b["vault_id"] != nil,
                revoked: b["revoked"] is String,
                canEdit: b["can_edit"] as? Bool ?? true)
            let feed: AccountFeedState? = switch feedObj?["state"] as? String {
            case "connecting": .connecting
            case "open": .open
            case "backoff": .backoff(attempt: 2, retryInSeconds: 2)
            case "auth_dead": .authDead
            case "disabled": .disabled
            default: nil
            }
            let failures = cu["failures"] as? Int ?? 0
            let phase: CatchUpSnapshot.Phase = switch cu["state"] as? String {
            case "running": .running
            case "failed": .failed(count: failures, reason: "changes failed")
            default: .idle
            }
            let catchUp = CatchUpSnapshot(phase: phase, cursor: Int64(cu["cursor"] as? Int ?? 0),
                                          head: (cu["head"] as? Int).map(Int64.init))
            let edPhase: EditorSnapshot.Phase = switch (ed["state"] as? String)?.lowercased() {
            case "connecting": .connecting
            case "syncing": .syncing
            case "live": .live
            case "offline": .offline
            default: .closed // "closed" and terminal "CLOSED"
            }
            let editor = EditorSnapshot(phase: edPhase, pending: ed["pending"] as? Bool ?? false)
            let n = rh["nonTransientFailures"] as? Int ?? 0
            let rest: RestHealth? = switch rh["last"] as? String {
            case "auth": .unauthorized
            case "network": .network("offline")
            case "server", "parse": .failing(count: n, reason: "HTTP 500")
            default: .ok
            }
            return StatusCase(name: raw["name"] as? String ?? "?", expect: raw["expect"] as? String ?? "?",
                              book: book, feed: feed, catchUp: catchUp, editor: editor, rest: rest)
        }
    }
}

/// Web state names → `BookSyncStatus.code`.
private let webToCode = ["not_bound": "local", "needs_login": "needs_sign_in", "error": "error", "offline": "offline",
                         "syncing": "syncing", "read_only": "read_only", "up_to_date": "up_to_date"]

@Suite("bookStatus — seven-state precedence table shared with web/TUI (SPEC-LIVROS §4)")
struct BookStatusTableTests {
    @Test("fixture loads and covers every state")
    func coverage() {
        let cases = StatusCase.load()
        #expect(cases.count == 31)
        #expect(Set(cases.map(\.expect)) == Set(webToCode.keys))
    }

    @Test("table case", arguments: StatusCase.load())
    func tableCase(_ c: StatusCase) {
        let got = bookStatus(book: c.book, accountFeed: c.feed, catchUp: c.catchUp, editor: c.editor, restHealth: c.rest)
        #expect(got.code == webToCode[c.expect], "\(c.name)")
    }
}
