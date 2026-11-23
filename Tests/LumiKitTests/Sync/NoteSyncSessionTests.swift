import Testing
import Foundation
@testable import LumiKit

#if canImport(YSwift)

// MARK: - Fake server

/// In-memory stand-in for the Go server's `wsync` room: a server replica
/// plus the y-websocket handshake (Step1 first on join, Step2 replies,
/// fan-out of updates and awareness to the *other* subscribers).
@MainActor
final class FakeRoom {
    let doc: LumiCRDT
    private(set) var clients: [FakeTransport] = []
    /// Every frame any client sent, decoded, for assertions.
    private(set) var received: [YProtocol.ParsedMessage] = []

    init(text: String) {
        doc = Replica.server(text)
    }

    func join(_ t: FakeTransport) {
        clients.append(t)
        t.push(.opened)
        t.push(.message(YProtocol.encodeSyncStep1(stateVector: doc.stateVector())))
    }

    func leave(_ t: FakeTransport) {
        clients.removeAll { $0 === t }
    }

    func handle(_ frame: Data, from t: FakeTransport) {
        guard let msg = try? YProtocol.decode(frame) else { return }
        received.append(msg)
        switch (msg.type, msg.syncSub) {
        case (YProtocol.messageSync, YProtocol.syncStep1):
            if let diff = try? doc.encodeDiff(againstStateVector: msg.body) {
                t.push(.message(YProtocol.encodeSyncStep2(update: diff)))
            }
        case (YProtocol.messageSync, YProtocol.syncStep2), (YProtocol.messageSync, YProtocol.syncUpdate):
            try? doc.applyRemote(update: msg.body)
            broadcast(YProtocol.encodeSyncUpdate(update: msg.body), except: t)
        case (YProtocol.messageAwareness, _):
            broadcast(frame, except: t)
        default:
            break
        }
    }

    /// A server-side edit (e.g. another client / fs-watcher) fanned out.
    func serverEdit(_ edits: [TextEdit]) {
        let u = doc.applyLocal(edits).update
        broadcast(YProtocol.encodeSyncUpdate(update: u), except: nil)
    }

    private func broadcast(_ frame: Data, except: FakeTransport?) {
        for c in clients where c !== except { c.push(.message(frame)) }
    }

    func updatesReceived() -> Int {
        received.filter { $0.type == YProtocol.messageSync && $0.syncSub == YProtocol.syncUpdate }.count
    }
}

/// Client end of a fake socket. `send` is always called on the main
/// actor by the session.
final class FakeTransport: SyncTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    weak var room: FakeRoom?
    private(set) var closed = false

    init(room: FakeRoom?) {
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
        self.room = room
    }

    func push(_ e: TransportEvent) { continuation.yield(e) }

    func send(_ frame: Data) {
        MainActor.assumeIsolated {
            guard !closed else { return }
            room?.handle(frame, from: self)
        }
    }

    func close() {
        MainActor.assumeIsolated { drop(code: 1000) }
    }

    /// Server-side close (network drop = nil code, or a close code).
    func drop(code: Int?) {
        guard !closed else { return }
        closed = true
        MainActor.assumeIsolated { room?.leave(self) }
        continuation.yield(.closed(code: code, reason: nil))
        continuation.finish()
    }
}

/// Connector whose behaviour each test scripts.
final class FakeConnector: SyncConnector, @unchecked Sendable {
    enum Mode { case join, closeBeforeOpen(Int?), fail(SyncConnectError) }
    var room: FakeRoom
    var modes: [Mode] = []
    var probe: AuthProbeResult = .unknown
    /// Network down: every connect fails transiently (lineage probe too).
    var offline = false
    var lineage: NoteLineageProbe = .unsupported
    private(set) var lineageProbes = 0
    private(set) var transports: [FakeTransport] = []
    private(set) var probes = 0

    @MainActor init(room: FakeRoom) { self.room = room }

    func connect(vaultID: UUID, noteID: String) async throws(SyncConnectError) -> any SyncTransport {
        if offline { throw .transient("offline") }
        let mode = modes.isEmpty ? .join : modes.removeFirst()
        let t = await MainActor.run { FakeTransport(room: room) }
        transports.append(t)
        switch mode {
        case .join:
            await MainActor.run { room.join(t) }
        case .closeBeforeOpen(let code):
            await MainActor.run { t.drop(code: code) }
        case .fail(let e):
            throw e
        }
        return t
    }

    func probeAuth() async -> AuthProbeResult {
        probes += 1
        return probe
    }

    func noteLineage(vaultID: UUID, noteID: String) async -> NoteLineageProbe {
        lineageProbes += 1
        return offline ? .unavailable("offline") : lineage
    }
}

@MainActor
func eventually(_ timeout: Double = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

@MainActor
private func makeSession(_ connector: FakeConnector, note: String = "n1", user: String = "ana") -> NoteSyncSession {
    let s = NoteSyncSession(
        vaultID: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!,
        noteID: note,
        connector: connector,
        user: AwarenessUser(username: user, displayName: user.capitalized)
    )
    s.backoff = { _ in 0.01 }
    return s
}

// MARK: - Tests

extension YrsSerial {
    @Suite("NoteSyncSession — join, live edits, reconnect, fatal closes")
    @MainActor
    struct NoteSyncSessionTests {
        @Test("join empty, read-only until SyncStep2, then live with the server text (V1, V15)")
        func joinThenLive() async throws {
            let room = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: room)
            let s = makeSession(connector)
            #expect(!s.isEditable)
            s.applyLocal(Replica.ins(0, "typed early ")) // V15: no-op
            s.start()
            #expect(s.phase == .connecting)
            #expect(await eventually { s.phase == .live })
            #expect(s.text == "hello world")
            #expect(s.isEditable)
            #expect(!s.emptyAtSync)
            // Nothing local was ever sent as an update; our Step2 to the
            // server's Step1 was the empty update.
            #expect(room.updatesReceived() == 0)
            #expect(room.doc.text == "hello world")
            s.destroy()
        }

        @Test("local edits travel as ranged updates; a concurrent peer edit converges without duplication")
        func concurrentEdits() async throws {
            let room = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: room)
            let a = makeSession(connector, user: "ana")
            let b = makeSession(connector, user: "bia")
            var aChanges: [DocumentChange] = []
            a.changeHandler = { aChanges.append($0) }
            a.start(); b.start()
            #expect(await eventually { a.phase == .live && b.phase == .live })

            // Concurrent: both edit before seeing each other.
            a.applyLocal(Replica.ins(5, " brave"))
            b.applyLocal(Replica.ins(11, "!"))
            #expect(await eventually { a.text == b.text && room.doc.text == a.text && a.text.count == 18 })
            #expect(a.text == "hello brave world!")
            #expect(aChanges.contains(.remote([TextEdit(location: 17, length: 0, replacement: "!")])))
            // No duplication anywhere (V2/V8 guard).
            #expect(room.doc.text.components(separatedBy: "hello").count == 2)
            a.destroy(); b.destroy()
        }

        @Test("a drop keeps the replica; offline edits and server edits merge on reconnect (V11)")
        func reconnectKeepsDoc() async throws {
            let room = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: room)
            let s = makeSession(connector)
            s.start()
            #expect(await eventually { s.phase == .live })
            connector.modes = [.closeBeforeOpen(nil)] // first retry fails too
            connector.transports.last?.drop(code: nil)
            #expect(await eventually { s.phase == .offline })
            #expect(s.isEditable) // still editable offline (§2.2.6)
            s.applyLocal(Replica.ins(11, "?"))
            #expect(s.hasPendingLocalChanges)
            room.serverEdit(Replica.ins(0, "> "))
            #expect(await eventually { s.phase == .live })
            #expect(await eventually { s.text == "> hello world?" && room.doc.text == "> hello world?" })
            #expect(!s.hasPendingLocalChanges)
            #expect(connector.transports.count == 3)
            s.destroy()
        }

        @Test("fatal close codes stop reconnecting: 4401 unauthorized, 4403 forbidden, 4404 not found, 1008 policy")
        func fatalCloses() async throws {
            for (code, expected) in [(4401, SessionTermination.unauthorized), (4403, .forbidden), (4404, .notFound), (1008, .policy)] {
                let room = FakeRoom(text: "x")
                let connector = FakeConnector(room: room)
                connector.modes = [.closeBeforeOpen(code)]
                let s = makeSession(connector)
                var unauthorized = false
                s.onUnauthorized = { unauthorized = true }
                s.start()
                #expect(await eventually { s.termination == expected })
                try? await Task.sleep(nanoseconds: 30_000_000)
                #expect(connector.transports.count == 1)
                #expect(unauthorized == (expected == .unauthorized))
                #expect(!s.isEditable)
            }
        }

        @Test("two never-opened attempts probe auth; a 401 probe terminates as unauthorized")
        func probeAfterFailures() async throws {
            let room = FakeRoom(text: "x")
            let connector = FakeConnector(room: room)
            connector.modes = [.closeBeforeOpen(nil), .closeBeforeOpen(nil), .closeBeforeOpen(nil)]
            connector.probe = .unauthorized
            let s = makeSession(connector)
            s.start()
            #expect(await eventually { s.termination == .unauthorized })
            #expect(connector.probes == 1)
            #expect(connector.transports.count == 2)
        }

        @Test("ticket endpoint 401 is terminal; transient connect errors retry")
        func connectErrors() async throws {
            let room = FakeRoom(text: "abc")
            let connector = FakeConnector(room: room)
            connector.modes = [.fail(.transient("offline")), .join]
            let s = makeSession(connector)
            s.start()
            #expect(await eventually { s.phase == .live })
            s.destroy()

            let c2 = FakeConnector(room: room)
            c2.modes = [.fail(.unauthorized)]
            let s2 = makeSession(c2)
            s2.start()
            #expect(await eventually { s2.termination == .unauthorized })
        }

        @Test("awareness: standard frames on join, peers visible both ways, leave on destroy")
        func awarenessFlow() async throws {
            let room = FakeRoom(text: "hi")
            let connector = FakeConnector(room: room)
            let a = makeSession(connector, user: "ana")
            let b = makeSession(connector, user: "bia")
            a.start()
            #expect(await eventually { a.phase == .live })
            b.start()
            #expect(await eventually { a.peers.map(\.name) == ["Bia"] })
            // a learns about b from b's join frame; b learns about a when
            // a renews (tick) — y-protocols peers converge within 15 s.
            a.tick(now: Date().addingTimeInterval(20))
            #expect(await eventually { b.peers.map(\.name) == ["Ana"] })
            // Every awareness body the server saw decodes as y-protocols.
            let bodies = room.received.filter { $0.type == YProtocol.messageAwareness }.map(\.body)
            #expect(!bodies.isEmpty)
            #expect(bodies.allSatisfy { (try? AwarenessCodec.decode($0)) != nil })
            b.destroy()
            #expect(await eventually { a.peers.isEmpty })
            a.destroy()
        }

        @Test("an empty synced replica is flagged; Load file contents seeds it once, explicitly (§2.2.5)")
        func legacyEmpty() async throws {
            let room = FakeRoom(text: "")
            let connector = FakeConnector(room: room)
            let s = makeSession(connector)
            s.start()
            #expect(await eventually { s.phase == .live })
            #expect(s.emptyAtSync)
            #expect(s.initialiseFromFile("# from disk"))
            #expect(!s.initialiseFromFile("# again"))
            #expect(await eventually { room.doc.text == "# from disk" })
            s.destroy()
        }

        @Test("pull-to-refresh merges the snapshot state into the kept replica (V8)")
        func refreshMerges() async throws {
            let room = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: room)
            let s = makeSession(connector)
            s.start()
            #expect(await eventually { s.phase == .live })
            s.applyLocal(Replica.ins(11, "!"))
            s.mergeSnapshotState(room.doc.encodeStateAsUpdate())
            #expect(s.text == "hello world!")
            s.destroy()
        }

        @Test("undo/redo go through the replica and reach the server")
        func undoRedo() async throws {
            let room = FakeRoom(text: "hello")
            let connector = FakeConnector(room: room)
            let s = makeSession(connector)
            var changes: [DocumentChange] = []
            s.changeHandler = { changes.append($0) }
            s.start()
            #expect(await eventually { s.phase == .live })
            s.breakUndoGroup()
            s.applyLocal(Replica.ins(5, " world"))
            s.breakUndoGroup()
            #expect(s.undo())
            #expect(changes.last == .undo([TextEdit(location: 5, length: 6, replacement: "")]))
            #expect(await eventually { room.doc.text == "hello" })
            #expect(s.redo())
            #expect(await eventually { room.doc.text == "hello world" })
            s.destroy()
        }
    }

    @Suite("RemoteVaultsStore — one session per open note")
    @MainActor
    struct StoreSessionTests {
        @Test("V16: switching notes mid-sync destroys the first session; the second starts empty")
        func switchNotes() async throws {
            let room = FakeRoom(text: "note one")
            let connector = FakeConnector(room: room)
            let store = RemoteVaultsStore(client: LumiAPIClient())
            store.makeConnector = { _ in connector }
            let vault = UUID()
            store.openLiveSession(vaultID: vault, noteID: "n1", user: nil)
            let first = try #require(store.openSession)
            store.openLiveSession(vaultID: vault, noteID: "n2", user: nil)
            let second = try #require(store.openSession)
            #expect(first !== second)
            #expect(first.isDestroyed)
            #expect(first.phase == .closed)
            // Re-opening the same note keeps the same replica.
            store.openLiveSession(vaultID: vault, noteID: "n2", user: nil)
            #expect(store.openSession === second)
            #expect(room.doc.text == "note one")
            store.closeOpenNote()
            #expect(store.openSession == nil)
            #expect(second.isDestroyed)
        }
    }
}

#endif
