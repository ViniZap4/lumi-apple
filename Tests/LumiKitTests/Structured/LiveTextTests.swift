import Testing
import Foundation
@testable import LumiKit

private let board = "## A\n\n- [ ] one\n- [ ] two\n\n## B\n\n- [ ] three\n"

@Suite("MemoryLiveText")
@MainActor
struct MemoryLiveTextTests {
    @Test("maps anchors through edits and supports undo/redo")
    func anchorsUndo() {
        let lt = MemoryLiveText("abcdef")
        let a = lt.anchor(3)
        lt.apply([TextEdit(from: 0, to: 0, insert: "XX")])
        #expect(a.position == 5)
        lt.remote([TextEdit(from: 1, to: 2, insert: "")])
        #expect(lt.read() == "Xabcdef")
        lt.undo()
        #expect(lt.read() == "abcdef")
        lt.redo()
        #expect(lt.read() == "Xabcdef")
    }

    @Test("reports local vs remote; read-only ignores apply; onWrite fires for local changes only")
    func flags() {
        let lt = MemoryLiveText("x")
        var seen: [Bool] = []
        var writes: [String] = []
        lt.onWrite = { writes.append($0) }
        let sub = lt.subscribe { seen.append($0) }
        lt.apply([TextEdit(from: 1, to: 1, insert: "y")])
        lt.remote([TextEdit(from: 0, to: 0, insert: "r")])
        lt.replaceExternally("rxyz")
        #expect(seen == [false, true, true])
        #expect(writes == ["xy"])
        sub.cancel()
        lt.isEditable = false
        lt.apply([TextEdit(from: 0, to: 0, insert: "no")])
        #expect(lt.read() == "rxyz")
        #expect(seen.count == 3)
    }
}

/// A `CollaborativeDocument` over a bare `LumiCRDT` that records every
/// local transaction (one `applyLocal` call = one Yjs transaction = one
/// update).
@MainActor
final class CRDTDocument: CollaborativeDocument {
    let crdt: LumiCRDT
    var updates: [Data] = []
    var changeHandler: ((DocumentChange) -> Void)?
    var isEditable = true

    init(_ crdt: LumiCRDT) { self.crdt = crdt }

    var text: String { crdt.text }
    func applyLocal(_ edits: [TextEdit]) {
        let r = crdt.applyLocal(edits)
        if !r.update.isEmpty { updates.append(r.update) }
    }
    func undo() -> Bool {
        guard let c = crdt.undo() else { return false }
        if !c.edits.isEmpty { changeHandler?(.undo(c.edits)) }
        return true
    }
    func redo() -> Bool {
        guard let c = crdt.redo() else { return false }
        if !c.edits.isEmpty { changeHandler?(.undo(c.edits)) }
        return true
    }
    func breakUndoGroup() { crdt.breakUndoGroup() }
    func receive(_ update: Data) throws {
        let edits = try crdt.applyRemote(update: update)
        if !edits.isEmpty { changeHandler?(.remote(edits)) }
    }
}

#if canImport(YSwift)
extension YrsSerial {
    @Suite("DocumentLiveText over the CRDT (live-text-y parity)")
    @MainActor
    struct DocumentLiveTextTests {
        @Test("a card move is one transaction holding a delete and an insert")
        func moveIsOneTransaction() throws {
            let server = Replica.server(board)
            let doc = CRDTDocument(try Replica.joined(server))
            let lt = DocumentLiveText(document: doc)
            lt.apply(KanbanEdits.plan(Kanban.parse(lt.read()), .moveCard(lane: 0, card: 0, toLane: 1, toIndex: 1)))
            #expect(doc.updates.count == 1)
            #expect(doc.text == "## A\n\n- [ ] two\n\n## B\n\n- [ ] three\n- [ ] one\n")
            // The single update carries the whole move to a peer.
            try server.applyRemote(update: doc.updates[0])
            #expect(server.text == doc.text)
            // And one undo reverts it as one group.
            lt.undo()
            #expect(doc.text == board)
        }

        @Test("reports remote vs local, keeps anchors sticky across a peer edit; undo works")
        func remoteAnchorsUndo() throws {
            let server = Replica.server(board)
            let doc = CRDTDocument(try Replica.joined(server))
            let lt = DocumentLiveText(document: doc)
            var seen: [Bool] = []
            let sub = lt.subscribe { seen.append($0) }
            let at = lt.anchor((board as NSString).range(of: "two").location)
            // A peer prepends a line.
            let peer = try Replica.joined(server)
            let u = peer.applyLocal(Replica.ins(0, "# Title\n\n")).update
            try doc.receive(u)
            #expect(seen == [true])
            let p = try #require(at.position)
            #expect((lt.read() as NSString).substring(with: NSRange(location: p, length: 3)) == "two")
            lt.apply([TextEdit(from: 0, to: 1, insert: "##")])
            #expect(seen == [true, false])
            lt.undo()
            #expect(lt.read().hasPrefix("# Title"))
            #expect(seen.last == false)
            sub.cancel()
        }

        @Test("honours editable; chains the previous change handler and restores it on detach")
        func editableAndChaining() throws {
            let server = Replica.server("abc")
            let doc = CRDTDocument(try Replica.joined(server))
            var editorSaw = 0
            doc.changeHandler = { _ in editorSaw += 1 }
            let lt = DocumentLiveText(document: doc, editable: { false })
            lt.apply([TextEdit(from: 0, to: 0, insert: "x")])
            #expect(doc.text == "abc")
            let peer = try Replica.joined(server)
            try doc.receive(peer.applyLocal(Replica.ins(3, "d")).update)
            #expect(editorSaw == 1)
            lt.detach()
            try doc.receive(peer.applyLocal(Replica.ins(4, "e")).update)
            #expect(editorSaw == 2)
        }

        @Test("over a live NoteSyncSession: a board move reaches the server as exactly one Sync Update")
        func sessionOneFrame() async throws {
            let room = FakeRoom(text: board)
            let connector = FakeConnector(room: room)
            let s = NoteSyncSession(vaultID: UUID(), noteID: "b", connector: connector, user: nil)
            s.backoff = { _ in 0.01 }
            let lt = DocumentLiveText(document: s)
            #expect(!lt.isEditable) // read-only until the first SyncStep2
            s.start()
            #expect(await eventually { s.phase == .live })
            #expect(lt.isEditable)
            let before = room.updatesReceived()
            lt.apply(KanbanEdits.plan(Kanban.parse(lt.read()), .moveCard(lane: 0, card: 1, toLane: 1, toIndex: 0)))
            #expect(room.updatesReceived() == before + 1)
            #expect(await eventually { room.doc.text == "## A\n\n- [ ] one\n\n## B\n\n- [ ] two\n- [ ] three\n" })
            // A server-side edit arrives as remote and keeps the anchor.
            var remote: [Bool] = []
            let sub = lt.subscribe { remote.append($0) }
            let anchor = lt.anchor((lt.read() as NSString).range(of: "three").location)
            room.serverEdit(Replica.ins(0, "> "))
            #expect(await eventually { remote == [true] })
            let p = try #require(anchor.position)
            #expect((lt.read() as NSString).substring(with: NSRange(location: p, length: 5)) == "three")
            sub.cancel()
            s.destroy()
        }
    }
}
#endif
