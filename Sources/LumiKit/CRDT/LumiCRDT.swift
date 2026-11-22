import Foundation
import Synchronization

/// Outcome of a local edit applied to the replica.
public struct LocalEditResult: Sendable, Equatable {
    /// lib0-v1 update carrying exactly this transaction's ops. Empty when
    /// the edits were no-ops.
    public let update: Data
    /// False when an edit was out of bounds — the editor and the replica
    /// disagree and the editor must resync from `text` (should never
    /// happen; guarded so a bug cannot crash yrs with a panic).
    public let applied: Bool
}

/// Outcome of a remote update / undo / redo applied to the replica.
public struct ReplicaChange: Sendable, Equatable {
    /// Sequential ranged edits to replay on the editor (UTF-16).
    public let edits: [TextEdit]
    /// lib0-v1 update to send to peers. Empty for remote updates (they
    /// are never echoed); the undo/redo ops for undo/redo.
    public let update: Data
}

#if canImport(YSwift)
@preconcurrency import YSwift

/// One Yjs replica of a server note: a single root `Y.Text` named
/// `content` (CRDT-CLIENT-PROTOCOL §1 "Doc layout").
///
/// Rules enforced by the API shape:
/// - **Never seed** (§0 rule 1): there is no initializer taking text. A
///   new replica is empty and learns the body from the server's
///   SyncStep2. The only way to write text without a sync is
///   `initialiseFromFile`, an explicit user action (§2.2.5).
/// - **Ranged ops only** (§3): `applyLocal` takes ranged edits; the
///   whole-text path `replaceText` diffs against the *current* Y.Text in
///   the same transaction.
/// - Remote updates come back as ranged `TextEdit`s mapped from the
///   yrs delta (§4.2) so the editor can replay them in place.
///
/// Isolation: a plain non-`Sendable` class. It is owned by exactly one
/// `NoteSyncSession` on the main actor, which serialises local edits and
/// remote applies so the editor buffer and the replica always move in
/// lockstep (§3.2 "remote updates must not interleave between the read
/// and the write"). yswift runs each transaction synchronously on its
/// own queue; yrs work for a keystroke is microseconds.
public final class LumiCRDT {
    public static let isSupported = true
    /// Root text name shared with the server (`crdt.rootBranchName`) and
    /// the web client (`doc.getText('content')`).
    public static let textName = "content"

    /// Origin of local editor transactions — the only origin the undo
    /// manager tracks (§6, §8).
    static let editorOrigin = makeOrigin("lumi:editor")
    static let remoteOrigin = makeOrigin("lumi:remote")
    static let initOrigin = makeOrigin("lumi:init-from-file")

    private let doc: YDocument
    private let ytext: YText
    private let collector = DeltaCollector()
    private var textSubscription: YSubscription?
    private let undoManager: YUndoManager<UndoMeta>
    private var undoSubscription: YSubscription?
    /// Number of undo-stack items each vim change group produced
    /// (yrs merges edits closer than 500 ms into one item, and a long
    /// insert session can span several items).
    private var undoGroups: [Int] = []
    private var redoGroups: [Int] = []
    private var groupOpen = false
    private let itemsAdded = ItemCounter()

    public init() {
        let doc = YDocument()
        let ytext = doc.getOrCreateText(named: Self.textName)
        self.doc = doc
        self.ytext = ytext
        self.undoManager = doc.undoManager(trackedRefs: [ytext])
        undoManager.addOrigin(Self.editorOrigin)
        let collector = self.collector
        textSubscription = ytext.observe { changes in
            collector.record(changes)
        }
        let counter = itemsAdded
        undoSubscription = undoManager.observeAdded { event, meta in
            // Counted only across local transactions (reset before,
            // read after), so the event kind — which yswift 0.2.1
            // reports inverted — does not matter.
            _ = event
            counter.value.withLock { $0 += 1 }
            return meta
        }
    }

    deinit {
        textSubscription?.cancel()
        undoSubscription?.cancel()
    }

    // MARK: - Reading

    /// Current text of the replica.
    public var text: String {
        let ytext = self.ytext
        return doc.transactSync { txn in ytext.getString(in: txn) }
    }

    /// UTF-16 length of the replica text.
    public var length: Int {
        let ytext = self.ytext
        return Int(doc.transactSync { txn in ytext.length(in: txn) })
    }

    /// lib0-v1 state vector (SyncStep1 body).
    public func stateVector() -> Data {
        doc.transactSync { txn in Data(txn.transactionStateVector()) }
    }

    /// Full state as one update.
    public func encodeStateAsUpdate() -> Data {
        doc.transactSync { txn in Data(txn.transactionEncodeStateAsUpdate()) }
    }

    /// Diff against a peer's state vector (SyncStep2 body). An empty
    /// vector yields the full state.
    public func encodeDiff(againstStateVector remote: Data) throws -> Data {
        if remote.isEmpty { return encodeStateAsUpdate() }
        let result: Result<Data, Error> = doc.transactSync { txn in
            do {
                return .success(Data(try txn.transactionEncodeStateAsUpdateFromSv(stateVector: Array(remote))))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    // MARK: - Remote

    /// Merge a peer update (SyncStep2 / Update frame, REST snapshot
    /// `state`). Idempotent. Returns the resulting change as ranged
    /// edits for the editor; empty when nothing changed (V13).
    @discardableResult
    public func applyRemote(update: Data) throws -> [TextEdit] {
        guard !update.isEmpty else { return [] }
        collector.begin()
        let result: Result<Void, Error> = doc.transactSync(origin: Self.remoteOrigin) { txn in
            do {
                try txn.transactionApplyUpdate(update: Array(update))
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let edits = collector.end()
        try result.get()
        return edits
    }

    // MARK: - Local

    /// Apply sequential ranged edits from the editor in **one**
    /// transaction tagged `lumi:editor` and return the update to send.
    @discardableResult
    public func applyLocal(_ edits: [TextEdit]) -> LocalEditResult {
        let live = edits.filter { !$0.isNoOp }
        guard !live.isEmpty else { return LocalEditResult(update: Data(), applied: true) }
        noteLocalChange()
        let ytext = self.ytext
        defer { attributeAddedItems() }
        return doc.transactSync(origin: Self.editorOrigin) { txn in
            var length = Int(ytext.length(in: txn))
            for e in live {
                guard e.location >= 0, e.length >= 0, e.location + e.length <= length else {
                    return LocalEditResult(update: Data(txn.transactionEncodeUpdate()), applied: false)
                }
                if e.length > 0 {
                    ytext.removeRange(start: UInt32(e.location), length: UInt32(e.length), in: txn)
                }
                if !e.replacement.isEmpty {
                    ytext.insert(e.replacement, at: UInt32(e.location), in: txn)
                }
                length += e.delta
            }
            return LocalEditResult(update: Data(txn.transactionEncodeUpdate()), applied: true)
        }
    }

    /// Whole-text path (§3.2): diff `newText` against the **current**
    /// replica text and apply the single ranged edit in the same
    /// transaction. Never delete-all + insert-all (V6/V7).
    @discardableResult
    public func replaceText(with newText: String) -> (edit: TextEdit?, update: Data) {
        noteLocalChange()
        let ytext = self.ytext
        defer { attributeAddedItems() }
        return doc.transactSync(origin: Self.editorOrigin) { txn in
            let current = ytext.getString(in: txn)
            guard let edit = TextDiff.edit(from: current, to: newText) else { return (nil, Data()) }
            if edit.length > 0 {
                ytext.removeRange(start: UInt32(edit.location), length: UInt32(edit.length), in: txn)
            }
            if !edit.replacement.isEmpty {
                ytext.insert(edit.replacement, at: UInt32(edit.location), in: txn)
            }
            return (edit, Data(txn.transactionEncodeUpdate()))
        }
    }

    /// Legacy-note recovery (§2.2.5): insert the REST body into an empty,
    /// synced replica. Explicit user action only. Returns nil when the
    /// replica is not empty.
    public func initialiseFromFile(_ body: String) -> Data? {
        let ytext = self.ytext
        return doc.transactSync(origin: Self.initOrigin) { txn -> Data? in
            guard ytext.length(in: txn) == 0, !body.isEmpty else { return nil }
            ytext.insert(body, at: 0, in: txn)
            return Data(txn.transactionEncodeUpdate())
        }
    }

    // MARK: - Undo (§8)

    /// Close the current undo group: the next local edit starts a new
    /// one. The editor calls this at every vim change boundary.
    public func breakUndoGroup() {
        groupOpen = false
    }

    public var canUndo: Bool { undoGroups.contains { $0 > 0 } }
    public var canRedo: Bool { !redoGroups.isEmpty }

    /// Undo this user's last change group as CRDT ops (never reverts a
    /// peer's edit). Returns the editor edits + the update to send.
    public func undo() -> ReplicaChange? {
        while let last = undoGroups.last, last == 0 { undoGroups.removeLast() }
        guard let items = undoGroups.popLast() else { return nil }
        groupOpen = false
        let change = runUndo(items: items) { try $0.undo() }
        redoGroups.append(items)
        return change
    }

    public func redo() -> ReplicaChange? {
        guard let items = redoGroups.popLast() else { return nil }
        groupOpen = false
        let change = runUndo(items: items) { try $0.redo() }
        undoGroups.append(items)
        return change
    }

    private func runUndo(items: Int, _ step: (YUndoManager<UndoMeta>) throws -> Bool) -> ReplicaChange {
        let before = stateVector()
        collector.begin()
        for _ in 0..<items {
            _ = try? step(undoManager)
        }
        let edits = collector.end()
        // A pure deletion does not advance the state vector; the diff
        // still carries the full delete set, so peers receive it.
        let update = (try? encodeDiff(againstStateVector: before)) ?? Data()
        itemsAdded.value.withLock { $0 = 0 }
        return ReplicaChange(edits: edits, update: update)
    }

    /// Bookkeeping before a local transaction: open a new undo group
    /// (forcing yrs to start a new stack item) when the previous one was
    /// closed.
    private func noteLocalChange() {
        itemsAdded.value.withLock { $0 = 0 }
        if !groupOpen {
            undoManager.wrap()
            undoGroups.append(0)
            redoGroups.removeAll()
            groupOpen = true
        }
    }

    /// After a local transaction committed: attribute the stack items it
    /// created to the open group.
    private func attributeAddedItems() {
        let n = itemsAdded.value.withLock { v -> Int in
            defer { v = 0 }
            return v
        }
        guard n > 0, !undoGroups.isEmpty else { return }
        undoGroups[undoGroups.count - 1] += n
    }

    private static func makeOrigin(_ name: String) -> Origin {
        // yswift 0.2.1 keeps `Origin.init(String)` internal; `Origin` is
        // Codable over its byte payload, so decode it from JSON.
        let json = try! JSONSerialization.data(withJSONObject: ["origin": Array(name.utf8).map(Int.init)])
        return try! JSONDecoder().decode(Origin.self, from: json)
    }
}

/// Shared counter of yrs undo-stack items added (observer → replica).
final class ItemCounter: Sendable {
    let value = Mutex(0)
}

/// Opaque per-stack-item metadata required by yswift's generic undo
/// manager. Unused.
final class UndoMeta {}

/// Collects the editor edits yrs reports while a remote apply / undo is
/// running. The observer fires on yswift's transaction queue *while* the
/// main actor is blocked in `transactSync` (or inside the undo call), so
/// the lock is uncontended; it exists for the checker. Several
/// transactions (multi-item undo) concatenate: sequential edit lists
/// compose by concatenation.
final class DeltaCollector: Sendable {
    private struct State {
        var capturing = false
        var edits: [TextEdit] = []
    }
    private let state = Mutex(State())

    func begin() {
        state.withLock { $0 = State(capturing: true, edits: []) }
    }

    func end() -> [TextEdit] {
        state.withLock { s in
            let out = s.edits
            s = State()
            return out
        }
    }

    /// yswift hands inserted chunks over JSON-encoded (`"\"x\""`):
    /// decode the JSON string. Non-string embeds never occur in a
    /// markdown Y.Text; they would decode to an empty insert.
    static func decodeInsert(_ raw: String) -> String {
        guard raw.hasPrefix("\"") else { return raw }
        let data = Data(raw.utf8)
        if let s = try? JSONDecoder().decode(String.self, from: data) { return s }
        return raw
    }

    func record(_ changes: [YTextChange]) {
        let deltas: [TextDelta] = changes.map { change in
            switch change {
            case let .inserted(value, _): return .insert(Self.decodeInsert(value))
            case let .deleted(n): return .delete(Int(n))
            case let .retained(n, _): return .retain(Int(n))
            }
        }
        state.withLock { s in
            guard s.capturing else { return }
            s.edits += TextDelta.edits(from: deltas)
        }
    }
}

#else

/// visionOS: yswift ships no visionOS slice. The type exists so call
/// sites compile; `isSupported` is false and nothing constructs it —
/// `NoteSyncSession` is unavailable and server notes use the REST
/// 3-way `/diff {text, base_state}` path (`RemoteEditorState`).
public final class LumiCRDT {
    public static let isSupported = false
    public static let textName = "content"
    private init() {}
}

#endif
