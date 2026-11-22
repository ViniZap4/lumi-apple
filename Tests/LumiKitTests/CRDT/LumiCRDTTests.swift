import Testing
import Foundation
@testable import LumiKit

#if canImport(YSwift)

/// Every test touching yrs lives under this one serialized parent:
/// separate suites run in parallel and yrs panics on concurrent
/// transactions across docs.
@Suite("yrs", .serialized)
enum YrsSerial {}

/// Test helpers mirroring the spec's §9 setup.
enum Replica {
    /// The server's `InitFromText`: a doc that inserted `text` under its
    /// own clientID.
    static func server(_ text: String = "hello world") -> LumiCRDT {
        let s = LumiCRDT()
        s.applyLocal([TextEdit(location: 0, length: 0, replacement: text)])
        return s
    }

    /// An empty client that joined and synced with `server`.
    static func joined(_ server: LumiCRDT) throws -> LumiCRDT {
        let c = LumiCRDT()
        try c.applyRemote(update: server.encodeDiff(againstStateVector: c.stateVector()))
        return c
    }

    /// Full two-way state exchange.
    static func sync(_ a: LumiCRDT, _ b: LumiCRDT) throws {
        let toB = try a.encodeDiff(againstStateVector: b.stateVector())
        let toA = try b.encodeDiff(againstStateVector: a.stateVector())
        try b.applyRemote(update: toB)
        try a.applyRemote(update: toA)
    }

    static func ins(_ at: Int, _ s: String) -> [TextEdit] { [TextEdit(location: at, length: 0, replacement: s)] }
    static func del(_ at: Int, _ n: Int) -> [TextEdit] { [TextEdit(location: at, length: n, replacement: "")] }
}

extension YrsSerial {
    @Suite("LumiCRDT — replica + protocol vectors (§9)")
    struct LumiCRDTTests {
        @Test("a new replica is empty and uses the shared `content` root")
        func emptyReplica() {
            let c = LumiCRDT()
            #expect(c.text == "")
            #expect(c.length == 0)
            #expect(LumiCRDT.textName == "content")
        }

        @Test("V1: an empty client syncs to the server text; server unchanged")
        func v1() throws {
            let s = Replica.server()
            let c = try Replica.joined(s)
            #expect(c.text == "hello world")
            try Replica.sync(s, c)
            #expect(s.text == "hello world")
        }

        @Test("V2: seeding before sync duplicates (why the API has no seed)")
        func v2() throws {
            let s = Replica.server()
            let c = LumiCRDT()
            c.applyLocal(Replica.ins(0, "hello world")) // the forbidden seed
            try Replica.sync(s, c)
            #expect(c.text == "hello worldhello world")
            #expect(s.text == c.text)
        }

        @Test("V3: concurrent inserts at different places")
        func v3() throws {
            let s = Replica.server()
            let a = try Replica.joined(s), b = try Replica.joined(s)
            a.applyLocal(Replica.ins(5, " brave"))
            b.applyLocal(Replica.ins(11, "!"))
            try Replica.sync(a, b)
            #expect(a.text == "hello brave world!")
            #expect(b.text == a.text)
        }

        @Test("V4: concurrent inserts at the same index converge deterministically")
        func v4() throws {
            let s = Replica.server()
            let a = try Replica.joined(s), b = try Replica.joined(s)
            a.applyLocal(Replica.ins(5, "A"))
            b.applyLocal(Replica.ins(5, "B"))
            try Replica.sync(a, b)
            // yswift assigns random clientIDs; the lower one goes left.
            #expect(["helloAB world", "helloBA world"].contains(a.text))
            #expect(b.text == a.text)
        }

        @Test("V5: a concurrent insert inside a deleted range survives")
        func v5() throws {
            let s = Replica.server()
            let a = try Replica.joined(s), b = try Replica.joined(s)
            a.applyLocal(Replica.del(5, 6))
            b.applyLocal(Replica.ins(8, "X"))
            try Replica.sync(a, b)
            #expect(a.text == "helloX")
            #expect(b.text == "helloX")
        }

        @Test("V6: delete-all/insert-all displaces a concurrent insert; V6b ranged ops keep it")
        func v6() throws {
            let s = Replica.server()
            var a = try Replica.joined(s), b = try Replica.joined(s)
            a.applyLocal([TextEdit(location: 0, length: 11, replacement: "hello brave world")])
            b.applyLocal(Replica.ins(5, "X"))
            try Replica.sync(a, b)
            #expect(a.text == "Xhello brave world")

            a = try Replica.joined(s); b = try Replica.joined(s)
            let (edit, _) = a.replaceText(with: "hello brave world")
            // Prefix-maximal hunk: insert "brave " after "hello ".
            #expect(edit == TextEdit(location: 6, length: 0, replacement: "brave "))
            b.applyLocal(Replica.ins(5, "X"))
            try Replica.sync(a, b)
            #expect(a.text == "helloX brave world")
            #expect(b.text == a.text)
        }

        @Test("V7: delete-all/insert-all resurrects a delete; V7b ranged ops respect it")
        func v7() throws {
            let s = Replica.server()
            var a = try Replica.joined(s), b = try Replica.joined(s)
            a.applyLocal([TextEdit(location: 0, length: 11, replacement: "hello world!")])
            b.applyLocal(Replica.del(0, 6))
            try Replica.sync(a, b)
            #expect(a.text == "hello world!")

            a = try Replica.joined(s); b = try Replica.joined(s)
            a.replaceText(with: "hello world!")
            b.applyLocal(Replica.del(0, 6))
            try Replica.sync(a, b)
            #expect(a.text == "world!")
            #expect(b.text == "world!")
        }

        @Test("V8: fresh-doc refetch duplicates; merging the snapshot state into the kept doc does not")
        func v8() throws {
            let s = Replica.server()
            let fresh = LumiCRDT()
            fresh.applyLocal(Replica.ins(0, "hello world!"))
            try Replica.sync(s, fresh)
            #expect(fresh.text == "hello world!hello world")

            let s2 = Replica.server()
            let kept = try Replica.joined(s2)
            kept.applyLocal(Replica.ins(11, "!"))
            // Pull-to-refresh: merge the REST `state` into the same doc.
            let edits = try kept.applyRemote(update: s2.encodeStateAsUpdate())
            #expect(edits.isEmpty)
            #expect(kept.text == "hello world!")
        }

        @Test("V11: offline edits merge both ways on reconnect with the same doc")
        func v11() throws {
            let s = Replica.server()
            let c = try Replica.joined(s)
            c.applyLocal(Replica.ins(11, "?"))   // offline
            s.applyLocal(Replica.ins(0, "> "))   // meanwhile on the server
            try Replica.sync(s, c)               // Step1/Step2 both ways
            #expect(c.text == "> hello world?")
            #expect(s.text == "> hello world?")
        }

        @Test("V13: replaying the same update applies once")
        func v13() throws {
            let s = Replica.server()
            let c = try Replica.joined(s)
            let u = s.applyLocal(Replica.ins(0, "x")).update
            #expect(try c.applyRemote(update: u) == Replica.ins(0, "x"))
            #expect(try c.applyRemote(update: u).isEmpty)
            #expect(c.text == "xhello world")
        }

        @Test("local updates carry exactly the transaction's ops (inserts and deletes)")
        func localUpdate() throws {
            let s = Replica.server()
            let c = try Replica.joined(s)
            let u1 = c.applyLocal(Replica.ins(5, ",")).update
            let u2 = c.applyLocal(Replica.del(0, 1)).update
            #expect(!u1.isEmpty && !u2.isEmpty)
            #expect(try s.applyRemote(update: u1) == Replica.ins(5, ","))
            #expect(try s.applyRemote(update: u2) == Replica.del(0, 1))
            #expect(s.text == "ello, world")
        }

        @Test("remote deltas are UTF-16 ranged edits")
        func utf16Deltas() throws {
            let s = Replica.server("a😀b")
            let c = try Replica.joined(s)
            let u = s.applyLocal(Replica.ins(3, "Z")).update // after the pair
            #expect(try c.applyRemote(update: u) == Replica.ins(3, "Z"))
            #expect(c.text == "a😀Zb")
        }

        @Test("out-of-range local edits are refused, never crash yrs")
        func outOfRange() {
            let c = Replica.server("abc")
            let r = c.applyLocal(Replica.del(2, 5))
            #expect(!r.applied)
            #expect(c.text == "abc")
        }

        @Test("V12 via replaceText: the surrogate pair is replaced whole")
        func v12() throws {
            let s = Replica.server("a😀b")
            let c = try Replica.joined(s)
            let (edit, update) = c.replaceText(with: "a😁b")
            #expect(edit == TextEdit(location: 1, length: 2, replacement: "😁"))
            try s.applyRemote(update: update)
            #expect(s.text == "a😁b")
            #expect(s.length == 4)
        }

        @Test("undo reverts only this user's group, never a peer's concurrent edit")
        func undoKeepsPeerEdits() throws {
            let s = Replica.server()
            let c = try Replica.joined(s)
            c.breakUndoGroup()
            try s.applyRemote(update: c.applyLocal(Replica.ins(11, "!")).update)
            try s.applyRemote(update: c.applyLocal(Replica.ins(12, "!")).update)
            // A peer edit lands afterwards.
            let peer = s.applyLocal(Replica.ins(0, "> ")).update
            #expect(try c.applyRemote(update: peer) == Replica.ins(0, "> "))
            c.breakUndoGroup()
            let undo = try #require(c.undo())
            #expect(c.text == "> hello world")
            #expect(TextEdit.apply(undo.edits, to: "> hello world!!") == "> hello world")
            // The undo travels to the server as an update.
            try s.applyRemote(update: undo.update)
            #expect(s.text == "> hello world")
            let redo = try #require(c.redo())
            #expect(c.text == "> hello world!!")
            try s.applyRemote(update: redo.update)
            #expect(s.text == "> hello world!!")
        }

        @Test("undo groups follow breakUndoGroup boundaries")
        func undoGroups() {
            let c = Replica.server("")
            c.breakUndoGroup()
            c.applyLocal(Replica.ins(0, "one"))
            c.breakUndoGroup()
            c.applyLocal(Replica.ins(3, " two"))
            c.applyLocal(Replica.ins(7, " three"))
            c.breakUndoGroup()
            _ = c.undo()
            #expect(c.text == "one")
            _ = c.undo()
            #expect(c.text == "")
            #expect(c.undo() == nil)
        }

        @Test("initialiseFromFile only writes into an empty replica")
        func initFromFile() throws {
            let c = LumiCRDT()
            #expect(c.initialiseFromFile("body") != nil)
            #expect(c.text == "body")
            #expect(c.initialiseFromFile("again") == nil)
        }

        @Test("malformed updates throw and leave the doc intact")
        func malformed() throws {
            let c = Replica.server("abc")
            #expect(throws: (any Error).self) { try c.applyRemote(update: Data([0xFF, 0xFF, 0xFF])) }
            #expect(c.text == "abc")
        }
    }
}

#endif
