import Foundation
import CoreGraphics
import Observation

/// View model of the canvas view (SPEC-PARTE2 §6) — the logic of
/// web-client `components/canvas/CanvasView.svelte`, UI-free so pointer
/// gestures, keys and commits are unit-testable.
///
/// - The canvas is derived from the text on every change. Invalid JSON
///   (a peer mid-edit in Source) keeps the last good parse on screen,
///   read-only, with a banner.
/// - Gestures move/resize a local *draft*; the text is written once, on
///   drop (no per-frame CRDT traffic). Every write is `Canvas.commit` →
///   one minimal ranged edit; commits over 4 MiB are refused.
@MainActor
@Observable
public final class CanvasBoardModel {
    public enum Editing: Equatable, Sendable {
        case text(id: String, isNew: Bool)
        case label(id: String)
        case edge(id: String)
    }

    public struct Picker: Equatable, Sendable {
        public var query: String
        public var at: CGPoint
        public var cursor: Int
    }

    public enum Gesture: Equatable, Sendable {
        case pan(start: CGPoint, origin: CanvasViewport)
        case move(start: CGPoint, origin: [String: CGRect], moved: Bool)
        case resize(id: String, start: CGPoint, origin: CGRect)
        case connect(from: String, side: CanvasSide, to: CGPoint)
    }

    public enum PreviewState: Equatable, Sendable {
        case loading
        case ok(String)
        case missing
    }

    public static let topInset = 44.0
    public static let handleRadius = 7.0

    public private(set) var doc: any LiveText
    public private(set) var text: String
    public private(set) var parse: CanvasParse
    public private(set) var lastGood: (nodes: [CanvasNode], edges: [CanvasEdge]) = ([], [])
    /// Local geometry during a gesture (never written until drop).
    public private(set) var drafts: [String: CGRect] = [:]
    public private(set) var viewport = CanvasViewport()
    /// The last viewport change should ease (keys, fit), not track a pointer.
    public private(set) var viewportEased = false
    public private(set) var size: CGSize = .zero
    public private(set) var selection: [String] = []
    public private(set) var selectedEdge: String?
    public private(set) var editing: Editing?
    public var draft: String = ""
    public var picker: Picker?
    public private(set) var notice: String?
    public private(set) var pending: String?
    public private(set) var gesture: Gesture?
    public private(set) var hovered: String?
    public var spaceDown = false
    public private(set) var previews: [String: PreviewState] = [:]
    public private(set) var focusRequest = 0
    public private(set) var lastChangeRemote = false

    /// Notes offered by the file-node picker.
    public var notes: [CanvasNoteRef] = []
    @ObservationIgnored public var loadNote: ((String) async -> String?)?
    @ObservationIgnored public var onOpenFile: ((String, Bool) -> Void)?
    @ObservationIgnored public var onOpenURL: ((URL) -> Void)?

    @ObservationIgnored private var keys = CanvasKeys()
    @ObservationIgnored private var subscription: LiveTextSubscription?
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var typingTask: Task<Void, Never>?
    @ObservationIgnored var newID: () -> String = { Canvas.newID() }

    public init(doc: any LiveText) {
        self.doc = doc
        let t = doc.read()
        text = t
        parse = Canvas.parse(t)
        adoptParse()
        subscription = doc.subscribe { [weak self] remote in self?.reload(remote: remote) }
    }

    public func rebind(_ newDoc: any LiveText) {
        guard newDoc !== doc else { return }
        subscription?.cancel()
        doc = newDoc
        reload(remote: true)
        subscription = doc.subscribe { [weak self] remote in self?.reload(remote: remote) }
    }

    private func reload(remote: Bool) {
        let t = doc.read()
        lastChangeRemote = remote
        guard t != text else { return }
        text = t
        parse = Canvas.parse(t)
        adoptParse()
    }

    private func adoptParse() {
        if let p = parse.parsed { lastGood = (p.nodes, p.edges) }
        // Drop selection of nodes that are gone.
        let ids = Set(baseNodes.map(\.id))
        if selection.contains(where: { !ids.contains($0) }) { selection = selection.filter(ids.contains) }
        if let e = selectedEdge, !edges.contains(where: { $0.id == e }) { selectedEdge = nil }
        loadPreviews()
        fitIfNeeded()
    }

    // MARK: - Derived

    public var invalid: String? { parse.error }
    public var isEditable: Bool { doc.isEditable && invalid == nil }
    public var issues: [String] { parse.parsed?.issues ?? [] }

    var baseNodes: [CanvasNode] { parse.parsed?.nodes ?? lastGood.nodes }
    public var edges: [CanvasEdge] { parse.parsed?.edges ?? lastGood.edges }

    /// Nodes with in-flight gesture drafts applied (file order = z order).
    public var nodes: [CanvasNode] {
        guard !drafts.isEmpty else { return baseNodes }
        return baseNodes.map { n in
            guard let r = drafts[n.id] else { return n }
            var m = n
            m.rect = r
            return m
        }
    }

    public func node(_ id: String) -> CanvasNode? { nodes.first { $0.id == id } }

    public var selectedNode: CanvasNode? { selection.count == 1 ? node(selection[0]) : nil }
    public var hasSelection: Bool { !selection.isEmpty || selectedEdge != nil }

    // MARK: - Notices / commits

    public func flash(_ msg: String) {
        notice = msg
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    @discardableResult
    public func commit(_ op: @escaping CanvasOp) -> Bool {
        guard isEditable else {
            flash(invalid != nil ? "Invalid JSON: fix it in Source" : "Read-only")
            return false
        }
        let cur = doc.read()
        let edits = Canvas.commit(cur, op)
        guard Canvas.fitsLimit(cur, edits) else {
            flash("Canvas too large (4 MiB limit)")
            return false
        }
        if !edits.isEmpty { doc.apply(edits) }
        return !edits.isEmpty
    }

    // MARK: - Viewport

    public func setSize(_ s: CGSize) {
        guard s != size else { return }
        size = s
        fitIfNeeded()
    }

    private func fitIfNeeded() {
        if !fitted, size.width > 0, size.height > 0, parse.parsed != nil {
            fitted = true
            fitAll(ease: false)
        }
    }

    public func setViewport(_ v: CanvasViewport, ease: Bool = false) {
        viewportEased = ease
        viewport = v
    }

    public func fitAll(ease: Bool = true) {
        var v = CanvasGeometry.fit(CanvasGeometry.bounds(nodes.map(\.rect)), size.width, size.height - Self.topInset, pad: 56)
        v.y += Self.topInset
        setViewport(v, ease: ease)
    }

    public func zoom(by factor: Double, at p: CGPoint? = nil, ease: Bool = true) {
        let c = p ?? CGPoint(x: size.width / 2, y: size.height / 2)
        setViewport(CanvasGeometry.zoomAt(viewport, c.x, c.y, factor), ease: ease)
    }

    public func pan(dx: Double, dy: Double, ease: Bool = false) {
        setViewport(CanvasGeometry.panBy(viewport, dx, dy), ease: ease)
    }

    public func wheel(_ e: CanvasGeometry.Wheel, at p: CGPoint) {
        setViewport(CanvasGeometry.wheel(viewport, e, at: p))
    }

    public func world(_ screen: CGPoint) -> CGPoint { CanvasGeometry.toWorld(viewport, screen) }

    public var centerWorld: CGPoint { world(CGPoint(x: size.width / 2, y: size.height / 2)) }

    /// Pan so `n` is visible.
    public func reveal(_ n: CanvasNode) {
        let r = CanvasGeometry.toScreen(viewport, n.rect)
        let pad = 40.0
        guard size.width > 0 else { return }
        if r.minX >= pad, r.minY >= Self.topInset + pad, r.maxX <= size.width - pad, r.maxY <= size.height - pad { return }
        let c = CanvasGeometry.toScreen(viewport, CGPoint(x: n.rect.midX, y: n.rect.midY))
        pan(dx: size.width / 2 - c.x, dy: (size.height + Self.topInset) / 2 - c.y, ease: true)
    }

    // MARK: - Selection / editing

    public func select(_ ids: [String], edge: String? = nil) {
        selection = ids
        selectedEdge = edge
    }

    public func startEdit(_ n: CanvasNode, isNew: Bool = false) {
        guard isEditable else { return flash("Read-only") }
        select([n.id])
        switch n.type {
        case .text:
            editing = .text(id: n.id, isNew: isNew)
            draft = n.text
        case .group:
            editing = .label(id: n.id)
            draft = n.label ?? ""
        default: break
        }
    }

    public func startEdgeEdit(_ e: CanvasEdge) {
        guard isEditable else { return flash("Read-only") }
        select([], edge: e.id)
        editing = .edge(id: e.id)
        draft = e.label ?? ""
    }

    /// Live collaboration while typing: debounced ranged commits.
    public func draftChanged() {
        typingTask?.cancel()
        typingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.flushTyping()
        }
    }

    public func flushTyping() {
        typingTask?.cancel()
        typingTask = nil
        if case let .text(id, _) = editing {
            let t = draft
            commit(Canvas.patchNodes([id: [("text", .string(t))]]))
        }
    }

    public func finishEdit() {
        guard let e = editing else { return }
        typingTask?.cancel()
        typingTask = nil
        editing = nil
        let t = draft
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case let .text(id, isNew):
            if isNew && trimmed.isEmpty { commit(Canvas.removeItems([id])) }
            else { commit(Canvas.patchNodes([id: [("text", .string(t))]])) }
        case let .label(id):
            commit(Canvas.patchNodes([id: [("label", trimmed.isEmpty ? nil : .string(trimmed))]]))
        case let .edge(id):
            commit(Canvas.patchEdge(id, [("label", trimmed.isEmpty ? nil : .string(trimmed))]))
        }
        focusRequest += 1
    }

    // MARK: - Creating

    public func addText(at p: CGPoint) {
        guard isEditable else { return flash(invalid != nil ? "Invalid JSON: fix it in Source" : "Read-only") }
        let id = newID()
        let node = Canvas.textNode(id: id, text: "", x: JSNumber.round(p.x - 125), y: JSNumber.round(p.y - 30))
        if commit(Canvas.addNode(node)) {
            select([id])
            editing = .text(id: id, isNew: true)
            draft = ""
        }
    }

    func nextSlot(_ w: Double) -> CGPoint {
        if let s = selectedNode { return CGPoint(x: s.x + s.width + 60 + w / 2, y: s.y + 30) }
        return centerWorld
    }

    public var pickList: [CanvasNoteRef] {
        guard let picker else { return [] }
        let q = picker.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(notes.filter { q.isEmpty || $0.path.lowercased().contains(q) || ($0.title ?? "").lowercased().contains(q) }.prefix(50))
    }

    public func openPicker(at: CGPoint? = nil) {
        guard isEditable else { return flash("Read-only") }
        picker = Picker(query: "", at: at ?? nextSlot(400), cursor: 0)
    }

    public func pick(_ n: CanvasNoteRef) {
        let at = picker?.at ?? centerWorld
        picker = nil
        let id = newID()
        if commit(Canvas.addNode(Canvas.fileNode(id: id, file: n.path, x: JSNumber.round(at.x - 200), y: JSNumber.round(at.y - 150)))) {
            select([id])
        }
        focusRequest += 1
    }

    /// Picker keys (the query field owns the keyboard).
    public func pickerKey(_ e: StructuredKey) -> Bool {
        guard var p = picker else { return false }
        switch (e.key, e.ctrl) {
        case ("Escape", _):
            picker = nil
            focusRequest += 1
        case ("ArrowDown", _), ("n", true):
            p.cursor = min(max(0, pickList.count - 1), p.cursor + 1)
            picker = p
        case ("ArrowUp", _), ("p", true):
            p.cursor = max(0, p.cursor - 1)
            picker = p
        case ("Enter", _):
            let list = pickList
            if list.indices.contains(p.cursor) { pick(list[p.cursor]) }
        default:
            return false
        }
        return true
    }

    // MARK: - Opening

    public static func safeURL(_ u: String) -> URL? {
        guard let url = URL(string: u), let s = url.scheme?.lowercased(), s == "http" || s == "https", url.host != nil else { return nil }
        return url
    }

    public func open(_ n: CanvasNode, split: Bool = false) {
        switch n.type {
        case .file:
            if !n.file.isEmpty { onOpenFile?(n.file, split) }
        case .link:
            guard let u = Self.safeURL(n.url) else { return flash("Only http(s) links open") }
            onOpenURL?(u)
        default: break
        }
    }

    public func activate() {
        if let id = selectedEdge, let e = edges.first(where: { $0.id == id }) {
            startEdgeEdit(e)
            return
        }
        guard let n = selectedNode else { return }
        if n.type == .text || n.type == .group { startEdit(n) } else { open(n) }
    }

    public func setColor(_ c: String?) {
        let v: JSONValue? = c.map { .string($0) }
        if let e = selectedEdge { commit(Canvas.patchEdge(e, [("color", v)])) }
        else if !selection.isEmpty {
            var patches: [String: CanvasPatch] = [:]
            for id in selection { patches[id] = [("color", v)] }
            commit(Canvas.patchNodes(patches))
        }
    }

    public func deleteSelection() {
        guard hasSelection else { return }
        if commit(Canvas.removeItems(selection, edges: selectedEdge.map { [$0] } ?? [])) { select([]) }
    }

    // MARK: - File previews

    private static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp"]

    private func loadPreviews() {
        for n in baseNodes where n.type == .file {
            let f = n.file
            let ext = (f as NSString).pathExtension.lowercased()
            guard !f.isEmpty, previews[f] == nil, !Self.imageExt.contains(ext), ext != "canvas" else { continue }
            guard let loadNote else {
                previews[f] = .missing
                continue
            }
            previews[f] = .loading
            Task { [weak self] in
                let md = await loadNote(f)
                let preview: PreviewState = md.map { .ok($0.components(separatedBy: "\n").prefix(40).joined(separator: "\n")) } ?? .missing
                self?.previews[f] = preview
            }
        }
    }

    /// Preview state of a file node (set by tests / hosts that preload).
    public func setPreview(_ path: String, _ state: PreviewState) { previews[path] = state }

    /// Call after setting `loadNote` to fetch previews for existing nodes.
    public func refreshPreviews() {
        previews = previews.filter { $0.value != .missing }
        loadPreviews()
    }

    // MARK: - Pointer gestures (screen coordinates of the canvas view)

    public enum Hit: Equatable, Sendable {
        case handle(id: String, side: CanvasSide)
        case resize(id: String)
        case node(id: String)
        case edge(id: String)
        case empty
    }

    /// What is under screen point `p`.
    public func hitTest(_ p: CGPoint) -> Hit {
        let w = world(p)
        if isEditable {
            // Side handles of the selected / hovered node, then its resize corner.
            for id in [selectedNode?.id, hovered].compactMap({ $0 }) {
                guard let n = node(id) else { continue }
                for side in CanvasSide.allCases {
                    let s = CanvasGeometry.toScreen(viewport, CanvasGeometry.sidePoint(n.rect, side))
                    if hypot(s.x - p.x, s.y - p.y) <= Self.handleRadius + 3 { return .handle(id: id, side: side) }
                }
            }
            if let n = selectedNode {
                let r = CanvasGeometry.toScreen(viewport, n.rect)
                if p.x >= r.maxX - 14, p.x <= r.maxX + 4, p.y >= r.maxY - 14, p.y <= r.maxY + 4 { return .resize(id: n.id) }
            }
        }
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let n = CanvasGeometry.hitNode(nodes, w), n.type != .group { return .node(id: n.id) }
        for e in edges.reversed() {
            guard let a = byId[e.fromNode], let b = byId[e.toNode] else { continue }
            let g = CanvasGeometry.edgeGeometry(e, a.rect, b.rect)
            if CanvasGeometry.distance(w, to: g) * viewport.zoom <= 6 { return .edge(id: e.id) }
        }
        if let n = CanvasGeometry.hitNode(nodes, w) { return .node(id: n.id) }
        return .empty
    }

    public func hover(_ p: CGPoint?) {
        guard gesture == nil else { return }
        let id: String?
        if let p, case let .node(nid) = hitTest(p) { id = nid } else if let p, case let .handle(hid, _) = hitTest(p) { id = hid } else { id = nil }
        if id != hovered { hovered = id }
    }

    public func pointerDown(at p: CGPoint, shift: Bool = false, panning: Bool = false) {
        focusRequest += 1
        if picker != nil { picker = nil }
        if editing != nil { finishEdit() }
        if panning || spaceDown {
            gesture = .pan(start: p, origin: viewport)
            return
        }
        let w = world(p)
        switch hitTest(p) {
        case let .handle(id, side):
            gesture = .connect(from: id, side: side, to: w)
        case let .resize(id):
            guard let n = node(id) else { return }
            select([id])
            gesture = .resize(id: id, start: w, origin: n.rect)
        case let .node(id):
            if shift { select(selection.contains(id) ? selection.filter { $0 != id } : selection + [id]) }
            else if !selection.contains(id) { select([id]) }
            guard isEditable else { return }
            // Moving a group carries the nodes inside it.
            var ids = Set(selection.contains(id) ? selection : [id])
            let all = nodes
            for g in all where ids.contains(g.id) && g.type == .group {
                for n in all where n.id != g.id && CanvasGeometry.contains(g.rect, n.rect) { ids.insert(n.id) }
            }
            var origin: [String: CGRect] = [:]
            for n in all where ids.contains(n.id) { origin[n.id] = n.rect }
            gesture = .move(start: w, origin: origin, moved: false)
        case let .edge(id):
            select([], edge: id)
        case .empty:
            if !shift { select([]) }
            gesture = .pan(start: p, origin: viewport)
        }
    }

    public func pointerMove(to p: CGPoint) {
        guard let g = gesture else { return }
        switch g {
        case let .pan(start, origin):
            setViewport(CanvasViewport(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y, zoom: origin.zoom))
        case let .move(start, origin, moved):
            let w = world(p)
            let dx = w.x - start.x, dy = w.y - start.y
            if !moved && hypot(dx, dy) * viewport.zoom < 3 { return }
            gesture = .move(start: start, origin: origin, moved: true)
            var next: [String: CGRect] = [:]
            for (id, o) in origin { next[id] = CGRect(x: JSNumber.round(o.minX + dx), y: JSNumber.round(o.minY + dy), width: o.width, height: o.height) }
            drafts = next
        case let .resize(id, start, origin):
            let w = world(p)
            drafts = [id: CGRect(x: origin.minX, y: origin.minY,
                                 width: max(80, JSNumber.round(origin.width + w.x - start.x)),
                                 height: max(40, JSNumber.round(origin.height + w.y - start.y)))]
        case let .connect(from, side, _):
            gesture = .connect(from: from, side: side, to: world(p))
        }
    }

    public func pointerUp() {
        guard let g = gesture else { return }
        gesture = nil
        let d = drafts
        switch g {
        case let .move(_, _, moved):
            drafts = [:]
            if moved {
                var patches: [String: CanvasPatch] = [:]
                for (id, r) in d { patches[id] = [("x", .number(r.minX)), ("y", .number(r.minY))] }
                commit(Canvas.patchNodes(patches))
            }
        case .resize:
            drafts = [:]
            var patches: [String: CanvasPatch] = [:]
            for (id, r) in d { patches[id] = [("width", .number(r.width)), ("height", .number(r.height))] }
            commit(Canvas.patchNodes(patches))
        case let .connect(from, side, to):
            if let target = CanvasGeometry.hitNode(nodes.filter { $0.id != from }, to) {
                let id = newID()
                if commit(Canvas.addEdge(Canvas.edge(id: id, from: from, fromSide: side, to: target.id,
                                                     toSide: CanvasGeometry.nearestSide(target.rect, to)))) {
                    select([], edge: id)
                }
            }
        case .pan:
            break
        }
    }

    public func pinch(_ factor: Double, at p: CGPoint, origin: CanvasViewport) {
        setViewport(CanvasGeometry.zoomAt(origin, p.x, p.y, factor))
    }

    public func doubleClick(at p: CGPoint, command: Bool = false) {
        switch hitTest(p) {
        case let .node(id), let .handle(id, _), let .resize(id):
            guard let n = node(id) else { return }
            switch n.type {
            case .text: startEdit(n)
            case .group:
                // The label strip edits the label; inside the frame adds a node.
                let r = CanvasGeometry.toScreen(viewport, n.rect)
                if p.y < r.minY + 28 { startEdit(n) } else { addText(at: world(p)) }
            default: open(n, split: command)
            }
        case let .edge(id):
            if let e = edges.first(where: { $0.id == id }) { startEdgeEdit(e) }
        case .empty:
            addText(at: world(p))
        }
    }

    // MARK: - Keyboard

    @discardableResult
    public func handleKey(_ e: StructuredKey) -> Bool {
        if picker != nil { return pickerKey(e) }
        if editing != nil { return false }
        let had = keys.pending
        let action = keys.feed(e, hasSelection: hasSelection)
        pending = keys.pending
        guard let action else { return keys.pending != nil || had != nil }
        switch action {
        case let .cycle(dir):
            let order = CanvasGeometry.readingOrder(nodes)
            guard !order.isEmpty else { break }
            let i = selectedNode.flatMap { s in order.firstIndex { $0.id == s.id } }
            let next = i.map { ($0 + dir + order.count) % order.count } ?? (dir > 0 ? 0 : order.count - 1)
            select([order[next].id])
            reveal(order[next])
        case .activate: activate()
        case let .openFile(split):
            if let n = selectedNode, n.type == .file { open(n, split: split) }
        case let .pan(dx, dy): pan(dx: dx, dy: dy, ease: true)
        case let .nudge(dx, dy):
            var patches: [String: CanvasPatch] = [:]
            for id in selection {
                guard let n = node(id) else { continue }
                patches[id] = [("x", .number(n.x + dx)), ("y", .number(n.y + dy))]
            }
            if !patches.isEmpty { commit(Canvas.patchNodes(patches)) }
        case let .zoom(factor): zoom(by: factor)
        case .fit: fitAll()
        case .addText: addText(at: nextSlot(250))
        case .addFile: openPicker()
        case .delete: deleteSelection()
        case let .color(c): setColor(c)
        case .undo: doc.undo()
        case .redo: doc.redo()
        case .escape:
            if hasSelection { select([]) } else { return false }
        }
        return true
    }
}
