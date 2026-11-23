import Testing
import Foundation
@testable import LumiKit

#if canImport(YSwift)

@MainActor
private func offlineSession(_ connector: FakeConnector, _ store: ReplicaStore, _ key: ReplicaKey,
                            title: String = "Plan") -> NoteSyncSession {
    let binding = ReplicaBinding(store: store, key: key, title: title)
    binding.flushDelay = 0
    let s = NoteSyncSession(vaultID: key.vaultID, noteID: key.noteID, connector: connector, user: nil, replica: binding)
    s.backoff = { _ in 0.01 }
    s.probeDelay = 0.01
    return s
}

private let offlineVault = UUID(uuidString: "9F2504E0-4F89-11D3-9A0C-0305E82C3301")!

extension YrsSerial {
    @Suite("Offline replicas — persistence, cold open, merge, lineage, pending")
    @MainActor
    struct OfflineReplicaTests {
        let key = ReplicaKey(account: accountA, vaultID: offlineVault, noteID: "plan")

        /// Join `room` once, optionally edit live, wait for the ack, close.
        private func primeReplica(_ store: ReplicaStore, _ room: FakeRoom, edit: [TextEdit]? = nil,
                                  lineage: NoteLineageProbe = .unsupported) async throws {
            let connector = FakeConnector(room: room)
            connector.lineage = lineage
            let s = offlineSession(connector, store, key)
            s.start()
            #expect(await eventually { s.phase == .live })
            if let edit {
                s.applyLocal(edit)
                #expect(s.hasPendingLocalChanges)
                #expect(await eventually { !s.hasPendingLocalChanges })
            }
            s.destroy()
        }

        @Test("nothing is persisted before the first SyncStep2; after it, the state round-trips")
        func persistenceRoundTrip() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: room)
            connector.offline = true
            let never = offlineSession(connector, store, key)
            never.start()
            try? await Task.sleep(nanoseconds: 50_000_000)
            never.destroy()
            #expect(!store.exists(key)) // never synced → never persisted

            try await primeReplica(store, room, edit: Replica.ins(5, " brave"))
            let stored = try #require(store.load(key))
            #expect(LumiCRDT.materializeText(stored.updates) == "hello brave world")
            #expect(!stored.meta.dirty)
            #expect(stored.meta.title == "Plan")
            #expect(try StateVector(decoding: stored.meta.knownServerSV)
                .dominates(StateVector(decoding: room.doc.stateVector())))

            // Incremental log without a clean close (crash): replays.
            let c2 = FakeConnector(room: room)
            let s = offlineSession(c2, store, key)
            s.start()
            #expect(await eventually { s.phase == .live })
            room.serverEdit(Replica.ins(0, "# "))
            #expect(await eventually { s.text == "# hello brave world" })
            s.replica?.flush()
            let crashed = try #require(store.load(key))
            #expect(LumiCRDT.materializeText(crashed.updates) == "# hello brave world")
            s.destroy()
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("cold offline open: a persisted replica is editable at once; edits stay pending and local")
        func coldOfflineOpen() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "hello world")
            try await primeReplica(store, room)
            let framesBefore = room.received.count

            let connector = FakeConnector(room: room)
            connector.offline = true
            let s = offlineSession(connector, store, key)
            #expect(s.restoredFromReplica)
            #expect(s.isEditable)
            #expect(s.phase == .offline)
            #expect(s.text == "hello world")
            s.start()
            s.applyLocal(Replica.ins(11, "?"))
            #expect(s.text == "hello world?")
            #expect(s.hasPendingLocalChanges)
            try? await Task.sleep(nanoseconds: 60_000_000)
            #expect(s.phase == .offline)
            #expect(room.received.count == framesBefore) // nothing reached the server
            #expect(room.doc.text == "hello world")
            s.destroy()
            // Quit: the edit and the pending flag survive.
            let stored = try #require(store.load(key))
            #expect(stored.meta.dirty)
            #expect(LumiCRDT.materializeText(stored.updates) == "hello world?")
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("offline edits from a previous launch merge both ways with concurrent server edits (V11)")
        func offlineMergeAfterRelaunch() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "hello world")
            try await primeReplica(store, room)

            // Launch 2, offline: edit, quit.
            let offline = FakeConnector(room: room)
            offline.offline = true
            let s2 = offlineSession(offline, store, key)
            s2.start()
            s2.applyLocal(Replica.ins(11, "?"))
            s2.destroy()
            // Meanwhile on the server.
            room.serverEdit(Replica.ins(0, "> "))

            // Launch 3, online.
            let online = FakeConnector(room: room)
            let s3 = offlineSession(online, store, key)
            #expect(s3.hasPendingLocalChanges)
            #expect(s3.text == "hello world?")
            s3.start()
            #expect(await eventually { s3.phase == .live })
            #expect(await eventually { s3.text == "> hello world?" && room.doc.text == "> hello world?" })
            #expect(await eventually { !s3.hasPendingLocalChanges })
            #expect(s3.replicaConflict == nil)
            s3.destroy()
            #expect(store.load(key)?.meta.dirty == false)
            #expect(room.doc.text.components(separatedBy: "hello").count == 2) // no duplication
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("live edits are pending until the probe round-trip acknowledges them")
        func ackClearsPending() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "abc")
            let connector = FakeConnector(room: room)
            let s = offlineSession(connector, store, key)
            s.probeDelay = 0.2
            s.start()
            #expect(await eventually { s.phase == .live })
            #expect(!s.hasPendingLocalChanges)
            s.applyLocal(Replica.ins(3, "d"))
            #expect(s.hasPendingLocalChanges)
            #expect(room.doc.text == "abcd")
            #expect(await eventually { !s.hasPendingLocalChanges })
            s.replica?.flush()
            #expect(store.load(key)?.meta.dirty == false)
            s.destroy()
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("server CRDT reset (new lineage, same id): pending replica is never merged — conflict copy instead")
        func lineageMismatchByStateVector() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let roomA = FakeRoom(text: "hello world")
            try await primeReplica(store, roomA)
            let offline = FakeConnector(room: roomA)
            offline.offline = true
            let s2 = offlineSession(offline, store, key)
            s2.applyLocal(Replica.ins(11, " (offline)"))
            s2.destroy()

            // Same note id, fresh lineage (same text, new seed clientID).
            let roomB = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: roomB)
            let s3 = offlineSession(connector, store, key)
            var reported: ReplicaConflict?
            s3.onReplicaConflict = { reported = $0 }
            // A REST refetch before the socket verified the lineage must
            // not merge either (pull-to-refresh path).
            s3.mergeSnapshotState(roomB.doc.encodeStateAsUpdate())
            #expect(s3.text == "hello world (offline)")
            s3.start()
            #expect(await eventually { s3.termination == .lineageChanged })
            #expect(!s3.isEditable)
            let conflict = try #require(reported)
            #expect(conflict.reason == .lineageChanged)
            #expect(conflict.hadPendingChanges)
            #expect(conflict.text == "hello world (offline)")
            #expect(conflict.title == "Plan")
            // The server saw no document frame from the stale replica.
            #expect(!roomB.received.contains { $0.type == YProtocol.messageSync })
            #expect(roomB.doc.text == "hello world")
            #expect(!store.exists(key))
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("note deleted + recreated (new created_at): mismatch caught before dialing")
        func lineageMismatchByStamp() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "")
            // An empty, never-edited doc: the state vector proves nothing,
            // the stamp has to.
            try await primeReplica(store, room, lineage: .createdAt(Date(timeIntervalSince1970: 1_700_000_000)))
            #expect(store.load(key)?.meta.noteCreatedAt == Date(timeIntervalSince1970: 1_700_000_000))
            let offline = FakeConnector(room: room)
            offline.offline = true
            let s2 = offlineSession(offline, store, key)
            s2.applyLocal(Replica.ins(0, "draft"))
            s2.destroy()

            let recreated = FakeRoom(text: "new body")
            let connector = FakeConnector(room: recreated)
            connector.lineage = .createdAt(Date(timeIntervalSince1970: 1_700_000_500))
            let s3 = offlineSession(connector, store, key)
            s3.start()
            #expect(await eventually { s3.termination == .lineageChanged })
            #expect(s3.replicaConflict?.text == "draft")
            #expect(connector.transports.isEmpty)
            #expect(recreated.doc.text == "new body")
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("same stamp and dominating vector: restored replica is accepted")
        func sameLineageAccepted() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "x")
            let stamp = NoteLineageProbe.createdAt(Date(timeIntervalSince1970: 1_700_000_000))
            try await primeReplica(store, room, lineage: stamp)
            let connector = FakeConnector(room: room)
            connector.lineage = stamp
            let s = offlineSession(connector, store, key)
            s.start()
            #expect(await eventually { s.phase == .live })
            #expect(s.termination == nil)
            s.destroy()
            try? FileManager.default.removeItem(at: store.root)
        }

        @Test("4404 with pending offline edits: recoverable copy, replica dropped")
        func deletedWhilePending() async throws {
            let store = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "keep me")
            try await primeReplica(store, room)
            let connector = FakeConnector(room: room)
            connector.offline = true
            let s = offlineSession(connector, store, key)
            s.applyLocal(Replica.ins(7, "!"))
            var reported: ReplicaConflict?
            s.onReplicaConflict = { reported = $0 }
            connector.offline = false
            connector.modes = [.closeBeforeOpen(4404)]
            s.start()
            #expect(await eventually { s.termination == .notFound })
            #expect(reported?.reason == .noteDeleted)
            #expect(reported?.text == "keep me!")
            #expect(!store.exists(key))
            s.destroy()
            try? FileManager.default.removeItem(at: store.root)
        }
    }

    @Suite("RemoteVaultsStore — offline replicas")
    @MainActor
    struct StoreOfflineTests {
        let vault = offlineVault

        private func makeStore(_ connector: FakeConnector, _ replicas: ReplicaStore) -> RemoteVaultsStore {
            // No base URL: every REST call fails like a dead network.
            let store = RemoteVaultsStore(client: LumiAPIClient())
            store.makeConnector = { _ in connector }
            store.replicaStore = replicas
            store.setClient(store.apiClient, account: accountA)
            return store
        }

        @Test("lineage mismatch: conflict copy recorded (uploadable), fresh session joins the new lineage")
        func conflictThenRejoin() async throws {
            let replicas = ReplicaStore(root: tempReplicaRoot())
            let roomA = FakeRoom(text: "hello world")
            let connector = FakeConnector(room: roomA)
            let store = makeStore(connector, replicas)
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            var s = try #require(store.openSession)
            #expect(await eventually { s.phase == .live })
            store.closeOpenNote()

            connector.offline = true
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            s = try #require(store.openSession)
            #expect(s.restoredFromReplica)
            s.applyLocal(Replica.ins(0, "offline: "))
            store.closeOpenNote()

            let roomB = FakeRoom(text: "reset body")
            connector.room = roomB
            connector.offline = false
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            #expect(await eventually {
                store.openSession.map { !$0.restoredFromReplica && $0.phase == .live } ?? false
            })
            let fresh = try #require(store.openSession)
            #expect(fresh.text == "reset body")
            #expect(roomB.doc.text == "reset body")
            #expect(store.recoveredNotes.count == 1)
            #expect(store.recoveredNotes.first?.text == "offline: hello world")
            #expect(store.recoveredNotes.first?.uploadable == true)
            #expect(store.recoveredNotes.first?.conflictTitle == "plan (conflito offline)")
            #expect(store.offlineNotice != nil)
            store.closeOpenNote()
            try? FileManager.default.removeItem(at: replicas.root)
        }

        @Test("clean replica on a new lineage is dropped silently (nothing to recover)")
        func cleanMismatch() async throws {
            let replicas = ReplicaStore(root: tempReplicaRoot())
            let roomA = FakeRoom(text: "one")
            let connector = FakeConnector(room: roomA)
            let store = makeStore(connector, replicas)
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            #expect(await eventually { store.openSession?.phase == .live })
            store.closeOpenNote()
            connector.room = FakeRoom(text: "two")
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            #expect(await eventually { store.openSession?.text == "two" && store.openSession?.phase == .live })
            #expect(store.recoveredNotes.isEmpty)
            store.closeOpenNote()
            try? FileManager.default.removeItem(at: replicas.root)
        }

        @Test("closed notes with offline edits are flushed headless when back online")
        func flushPending() async throws {
            let replicas = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "hello")
            let connector = FakeConnector(room: room)
            let store = makeStore(connector, replicas)
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            #expect(await eventually { store.openSession?.phase == .live })
            store.closeOpenNote()
            connector.offline = true
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            store.openSession?.applyLocal(Replica.ins(5, " world"))
            store.closeOpenNote()
            // Selects the vault; the listing fails without a cache, so the
            // store is not in offline mode and may flush.
            await store.selectVault(vault)
            connector.offline = false
            #expect(store.pendingReplicaNoteIDs() == ["plan"])
            await store.flushPendingReplicas(timeout: 2)
            #expect(room.doc.text == "hello world")
            #expect(store.pendingReplicaNoteIDs().isEmpty)
            try? FileManager.default.removeItem(at: replicas.root)
        }

        @Test("offline listing: the explorer reads the cache, marked stale, with cached capabilities")
        func listingFallback() async throws {
            let replicas = ReplicaStore(root: tempReplicaRoot())
            let store = makeStore(FakeConnector(room: FakeRoom(text: "")), replicas)
            let note = RemoteNote(id: "a", vaultID: vault, path: "a.md", title: "A", createdAt: nil, updatedAt: nil)
            let fetched = Date(timeIntervalSince1970: 1_700_000_000)
            replicas.saveListing(BookListingCache(notes: [note], capabilities: ["note.edit"], fetchedAt: fetched),
                                 account: accountA, vaultID: vault)
            await store.selectVault(vault)
            #expect(store.isOffline)
            #expect(store.notes == [note])
            #expect(store.staleListingDate == fetched)
            #expect(store.capabilities(forUsername: "ana") == ["note.edit"])
            #expect(store.lastError == nil)
            try? FileManager.default.removeItem(at: replicas.root)
        }

        @Test("account removal wipes the account's replicas; pending text comes back for export")
        func accountRemovalWipes() async throws {
            let replicas = ReplicaStore(root: tempReplicaRoot())
            let room = FakeRoom(text: "secret")
            let connector = FakeConnector(room: room)
            let store = makeStore(connector, replicas)
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            #expect(await eventually { store.openSession?.phase == .live })
            store.closeOpenNote()
            connector.offline = true
            store.openLiveSession(vaultID: vault, noteID: "plan", user: nil)
            store.openSession?.applyLocal(Replica.ins(6, " notes"))
            // Another account's replica must survive.
            let other = ReplicaKey(account: accountB, vaultID: vault, noteID: "plan")
            try replicas.save(ReplicaMeta(key: other), state: room.doc.encodeStateAsUpdate())

            let recovered = store.purgeReplicas(account: accountA, reason: .accountRemoved)
            #expect(store.openSession == nil)
            #expect(recovered.map(\.text) == ["secret notes"])
            #expect(recovered.first?.uploadable == false)
            #expect(replicas.summaries().map(\.key) == [other])
            #expect(!store.hasReplica(vaultID: vault, noteID: "plan"))
            try? FileManager.default.removeItem(at: replicas.root)
        }
    }
}

#endif
