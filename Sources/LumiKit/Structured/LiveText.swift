import Foundation

// LiveText: the one surface structured views (kanban, canvas) write
// through — port of web-client `lib/live-text.ts` / `live-text-y.ts`.
//
// Contract:
//  - `read()` returns the CURRENT text. Callers plan edits against it
//    and call `apply()` synchronously (main actor), so no remote update
//    can land in between (CRDT protocol §3.2).
//  - `apply(edits)` takes disjoint edits in the coordinates of that read
//    and applies them right to left in ONE transaction.
//  - `subscribe(fn)` fires after every change, local or remote, with
//    `remote` telling them apart.
//  - `anchor(i)` returns a sticky position that follows the character at
//    `i` through later edits.

/// A sticky position into a `LiveText`. `position` is nil once the
/// anchor was invalidated (text replaced wholesale).
@MainActor
public final class LiveTextAnchor {
    public internal(set) var position: Int?
    init(_ position: Int?) { self.position = position }
}

/// Cancels a `LiveText.subscribe` registration.
@MainActor
public final class LiveTextSubscription {
    private var cancelAction: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

@MainActor
public protocol LiveText: AnyObject {
    func read() -> String
    /// Disjoint edits in the coordinates of the last `read()`, applied in
    /// one transaction. Ignored when not editable or overlapping.
    func apply(_ edits: [TextEdit])
    func subscribe(_ fn: @escaping (_ remote: Bool) -> Void) -> LiveTextSubscription
    var isEditable: Bool { get }
    func anchor(_ index: Int) -> LiveTextAnchor
    var canUndo: Bool { get }
    func undo()
    func redo()
}

/// Shared bookkeeping: subscribers + anchors.
@MainActor
public class LiveTextBase {
    private var subscribers: [Int: (Bool) -> Void] = [:]
    private var nextID = 0
    private var anchors: [WeakAnchor] = []

    private struct WeakAnchor { weak var anchor: LiveTextAnchor? }

    func addSubscriber(_ fn: @escaping (Bool) -> Void) -> LiveTextSubscription {
        let id = nextID
        nextID += 1
        subscribers[id] = fn
        return LiveTextSubscription { [weak self] in self?.subscribers[id] = nil }
    }

    func notify(remote: Bool) {
        for fn in subscribers.values { fn(remote) }
    }

    func makeAnchor(_ index: Int) -> LiveTextAnchor {
        let a = LiveTextAnchor(index)
        anchors.removeAll { $0.anchor == nil }
        anchors.append(WeakAnchor(anchor: a))
        return a
    }

    /// Map anchors through a *sequential* edit list (Yjs relative-position
    /// semantics, CRDT-CLIENT-PROTOCOL §4.3).
    func mapAnchors(sequential edits: [TextEdit]) {
        guard !edits.isEmpty else { return }
        for w in anchors {
            guard let a = w.anchor, let p = a.position else { continue }
            a.position = PositionMapper.map(p, through: edits, assoc: .after)
        }
    }

    func invalidateAnchors() {
        for w in anchors { w.anchor?.position = nil }
    }
}

// MARK: - In-memory

/// In-memory LiveText (tests, read-only previews, offscreen renders,
/// local-book notes via `onWrite`). Undo is a snapshot history.
@MainActor
public final class MemoryLiveText: LiveTextBase, LiveText {
    public private(set) var text: String
    public var isEditable: Bool
    /// Called after every local change (apply / undo / redo) with the new
    /// text — local books write it through to the editor buffer.
    public var onWrite: ((String) -> Void)?
    private var history: [String] = []
    private var future: [String] = []

    public init(_ initial: String, editable: Bool = true) {
        text = initial
        isEditable = editable
    }

    public func read() -> String { text }

    public func apply(_ edits: [TextEdit]) {
        guard isEditable else { return }
        run(edits, remote: false)
    }

    /// Simulate a remote change (disjoint edits in current coordinates).
    public func remote(_ edits: [TextEdit]) {
        run(edits, remote: true)
    }

    /// The text changed outside this LiveText (file reloaded, Source
    /// editor): adopt it as a remote change with a minimal diff.
    public func replaceExternally(_ newText: String) {
        guard let e = RangedEdits.diff(text, newText) else { return }
        run([e], remote: true)
    }

    private func run(_ edits: [TextEdit], remote: Bool) {
        let live = edits.filter { !$0.isNoOp }
        guard !live.isEmpty, RangedEdits.isDisjoint(live) else { return }
        if !remote {
            history.append(text)
            future.removeAll()
        }
        text = RangedEdits.apply(live, to: text)
        // Right to left = a valid sequential list.
        mapAnchors(sequential: RangedEdits.sortedDescending(live))
        if !remote { onWrite?(text) }
        notify(remote: remote)
    }

    public func anchor(_ index: Int) -> LiveTextAnchor { makeAnchor(index) }

    public func subscribe(_ fn: @escaping (Bool) -> Void) -> LiveTextSubscription { addSubscriber(fn) }

    public var canUndo: Bool { !history.isEmpty }

    public func undo() {
        guard isEditable, let prev = history.popLast() else { return }
        future.append(text)
        swap(to: prev)
    }

    public func redo() {
        guard isEditable, let next = future.popLast() else { return }
        history.append(text)
        swap(to: next)
    }

    private func swap(to newText: String) {
        if let e = RangedEdits.diff(text, newText) { mapAnchors(sequential: [e]) }
        text = newText
        onWrite?(text)
        notify(remote: false)
    }
}

// MARK: - Over a CRDT session

/// LiveText over a note's live CRDT session (`NoteSyncSession`, or any
/// `CollaborativeDocument`).
///
/// - Every `apply` is ONE `applyLocal` call: the disjoint edits, right to
///   left, as one sequential list → one Yjs transaction tagged
///   `lumi:editor` → one Sync Update frame (a kanban move = delete +
///   insert in the same transaction).
/// - Each apply is its own undo group, so `u` / `⌃r` undo board/canvas
///   operations through the session's own-edits undo manager (never a
///   peer's edit).
/// - Remote changes arrive through the document's `changeHandler`; the
///   handler that was installed before (e.g. a Source editor in another
///   pane) keeps receiving them.
/// - Anchors are mapped through every delta (yswift 0.2.1 has no
///   `StickyIndex`; mapping each delta is equivalent, see
///   `PositionMapper`).
@MainActor
public final class DocumentLiveText: LiveTextBase, LiveText {
    public let document: any CollaborativeDocument
    private let editable: () -> Bool
    private var previousHandler: ((DocumentChange) -> Void)?
    private var attached = false
    private var lastText: String

    public init(document: any CollaborativeDocument, editable: (() -> Bool)? = nil) {
        self.document = document
        self.editable = editable ?? { [weak document] in document?.isEditable ?? false }
        self.lastText = document.text
        super.init()
        attach()
    }

    /// Start listening (installed by `init`).
    public func attach() {
        guard !attached else { return }
        attached = true
        previousHandler = document.changeHandler
        let chained = previousHandler
        document.changeHandler = { [weak self] change in
            chained?(change)
            self?.handle(change)
        }
    }

    /// Stop listening and give the document back its previous handler.
    public func detach() {
        guard attached else { return }
        attached = false
        document.changeHandler = previousHandler
        previousHandler = nil
    }

    public var isEditable: Bool { editable() }

    public func read() -> String { document.text }

    public func apply(_ edits: [TextEdit]) {
        let live = edits.filter { !$0.isNoOp }
        guard !live.isEmpty, isEditable, RangedEdits.isDisjoint(live) else { return }
        let sequential = RangedEdits.sortedDescending(live)
        document.breakUndoGroup()
        document.applyLocal(sequential)
        document.breakUndoGroup()
        mapAnchors(sequential: sequential)
        lastText = document.text
        notify(remote: false)
    }

    private func handle(_ change: DocumentChange) {
        switch change {
        case let .remote(edits):
            mapAnchors(sequential: edits)
            lastText = document.text
            notify(remote: true)
        case let .undo(edits):
            mapAnchors(sequential: edits)
            lastText = document.text
            notify(remote: false)
        case let .resync(text):
            if let e = RangedEdits.diff(lastText, text) { mapAnchors(sequential: [e]) }
            lastText = text
            notify(remote: true)
        }
    }

    public func subscribe(_ fn: @escaping (Bool) -> Void) -> LiveTextSubscription { addSubscriber(fn) }

    public func anchor(_ index: Int) -> LiveTextAnchor { makeAnchor(index) }

    public var canUndo: Bool { true }

    public func undo() {
        guard isEditable else { return }
        document.undo()
    }

    public func redo() {
        guard isEditable else { return }
        document.redo()
    }
}
