import Foundation
import Testing
@testable import LumiKit

private let vault = UUID(uuidString: "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f")!

private func noteJSON(_ id: String) -> String {
    #"{"id":"\#(id)","vault_id":"\#(vault.uuidString.lowercased())","path":"\#(id).md","title":"\#(id)","change_seq":1}"#
}

@Suite("Catch-up via GET /changes, 410 → full resync")
struct CatchUpTests {
    @Test("pages until more=false and advances the cursor to head")
    func pages() async throws {
        let host = "cu-\(UUID().uuidString.prefix(8).lowercased()).test"
        HostRoutedURLProtocol.route(host: host) { req in
            let q = req.url?.query ?? ""
            if q.contains("after=10") {
                return (200, Data(#"{"notes":[\#(noteJSON("a"))],"deleted":[],"head":12,"more":true}"#.utf8))
            }
            if q.contains("after=12") {
                return (200, Data(#"{"notes":[\#(noteJSON("b"))],"deleted":[{"id":"old","seq":13}],"head":14,"more":false}"#.utf8))
            }
            return (500, Data())
        }
        let client = LumiAPIClient(baseURL: URL(string: "https://\(host)")!, token: "t", session: HostRoutedURLProtocol.session)
        let out = try await CatchUp.run(client: client, vaultID: vault, cursor: 10)
        #expect(out.upserts.map(\.id) == ["a", "b"])
        #expect(out.deleted == ["old"])
        #expect(out.newCursor == 14)
        #expect(out.fullList == nil)
        let existing = [RemoteNote(id: "old", vaultID: vault, path: "old.md", title: "old", createdAt: nil, updatedAt: nil),
                        RemoteNote(id: "a", vaultID: vault, path: "x.md", title: "stale", createdAt: nil, updatedAt: nil)]
        #expect(CatchUp.apply(out, to: existing).map(\.title) == ["a", "b"])
    }

    @Test("410 resync_required reads head first, lists everything, cursor = that head")
    func resync() async throws {
        let host = "rs-\(UUID().uuidString.prefix(8).lowercased()).test"
        let order = OrderLog()
        HostRoutedURLProtocol.route(host: host) { req in
            let path = req.url?.path ?? ""
            order.append(path)
            if path.hasSuffix("/changes") { return (410, Data(#"{"error":"resync_required","head":99}"#.utf8)) }
            if path.hasSuffix("/notes") {
                return (200, Data(#"{"notes":[\#(noteJSON("x"))],"limit":200,"offset":0}"#.utf8))
            }
            return (200, Data(#"{"id":"\#(vault.uuidString.lowercased())","slug":"w","name":"W","created_by":"\#(UUID().uuidString)","head":99}"#.utf8))
        }
        let client = LumiAPIClient(baseURL: URL(string: "https://\(host)")!, token: "t", session: HostRoutedURLProtocol.session)
        let out = try await CatchUp.run(client: client, vaultID: vault, cursor: 3)
        #expect(out.fullList?.map(\.id) == ["x"])
        #expect(out.newCursor == 99)
        let paths = order.items
        #expect(paths.firstIndex { !$0.hasSuffix("/changes") && !$0.hasSuffix("/notes") }! < paths.firstIndex { $0.hasSuffix("/notes") }!,
                "head is read before listing")
    }
}

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
