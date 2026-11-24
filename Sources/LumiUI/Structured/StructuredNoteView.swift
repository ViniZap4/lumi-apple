import SwiftUI
import Observation
import LumiKit

/// The structured note kinds this host renders.
public enum StructuredKind: Sendable, Equatable {
    case kanban, canvas
}

/// How a structured view gets its text.
public enum StructuredSource {
    /// A server note: join its live session (CRDT-CLIENT-PROTOCOL §2).
    /// `acquire` returns the session (or an error message); `release`
    /// hands it back. The REST `body` is shown read-only until the first
    /// SyncStep2, then the replica is edited live.
    case session(acquire: @MainActor () async -> Result<any StructuredSession, StructuredSessionError>,
                 release: (@MainActor (any StructuredSession) -> Void)?)
    /// A local-book note (or any text the host owns): edits write through
    /// the LiveText (e.g. `MemoryLiveText.onWrite` → editor buffer + save).
    case local(any LiveText)
    /// No live editing (viewer role, visionOS): the body, read-only.
    case readOnly
}

public struct StructuredSessionError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Owns the LiveText + view model across renders of the host.
@MainActor
@Observable
final class StructuredHostState {
    let kind: StructuredKind
    let preview: MemoryLiveText
    private(set) var body: String
    private(set) var session: (any StructuredSession)?
    private(set) var live: DocumentLiveText?
    private(set) var local: (any LiveText)?
    private(set) var error: String?
    @ObservationIgnored var release: (@MainActor (any StructuredSession) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    let kanban: KanbanBoardModel?
    let canvas: CanvasBoardModel?
    /// Reading mode: navigation only (SPEC-PARTE2 §5a).
    var readOnly = false {
        didSet {
            kanban?.readOnly = readOnly
            canvas?.readOnly = readOnly
        }
    }

    init(kind: StructuredKind, body: String) {
        self.kind = kind
        self.body = body
        preview = MemoryLiveText(body, editable: false)
        kanban = kind == .kanban ? KanbanBoardModel(doc: preview) : nil
        canvas = kind == .canvas ? CanvasBoardModel(doc: preview) : nil
    }

    func start(_ source: StructuredSource) {
        switch source {
        case .readOnly:
            break
        case let .local(lt):
            local = lt
            adopt()
        case let .session(acquire, release):
            self.release = release
            task = Task { [weak self] in
                let got = await acquire()
                guard let self, !Task.isCancelled else {
                    if case let .success(s) = got { release?(s) }
                    return
                }
                switch got {
                case let .failure(e): self.error = e.message
                case let .success(s):
                    self.session = s
                    self.live = DocumentLiveText(document: s, editable: { [weak s] in
                        guard let s else { return false }
                        return s.isEditable && !s.isDestroyed
                    })
                    self.adopt()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        live?.detach()
        if let s = session { release?(s) }
        live = nil
        session = nil
    }

    /// REST refresh while not live: keep the preview in step.
    func updateBody(_ body: String) {
        self.body = body
        guard live == nil, local == nil, body != preview.read() else { return }
        preview.replaceExternally(body)
    }

    /// Live once the session is editable and not a legacy empty doc.
    var isLive: Bool {
        guard let s = session else { return false }
        return s.isEditable && !(s.emptyAtSync && !body.isEmpty)
    }

    /// The LiveText the view should use now.
    var doc: any LiveText {
        if let local { return local }
        if let live, isLive { return live }
        return preview
    }

    func adopt() {
        let d = doc
        kanban?.rebind(d)
        canvas?.rebind(d)
    }
}

/// Host for the structured note views (kanban board, canvas) — the
/// web's `StructuredNoteView.svelte`. A note pane renders this instead of
/// the markdown reader when the note's kind is `.kanban` / `.canvas`.
///
/// It joins the note's live session following the protocol (REST body
/// read-only until the first SyncStep2, then live), shows the
/// uninitialised-note recovery, and hands the board / canvas a LiveText.
/// In a pane the session comes from the host's pool via `acquire` /
/// `release` so a board and its Source editor share one replica.
public struct StructuredNoteView: View {
    let kind: StructuredKind
    let title: String
    let restBody: String
    let source: StructuredSource
    let notes: [CanvasNoteRef]
    let loadNote: ((String) async -> String?)?
    let openLink: (String, StructuredOpenTarget) -> Void
    let onSource: (() -> Void)?
    let motion: Bool
    /// Hosts that route keys per pane get the handler here (nil when the
    /// view goes); without it the view installs into `StructuredKeyRouting`.
    let keySink: ((((StructuredKey) -> Bool)?) -> Void)?
    /// Reading (read-only) rather than Edit.
    let readOnly: Bool
    /// The view asks for Edit (`i` / `e` in Reading) or Reading (`Esc` /
    /// `q` in Edit with nothing selected).
    let onMode: ((StructuredModeKeys.Request) -> Void)?

    @State private var state: StructuredHostState
    @Environment(\.theme) private var theme

    public init(
        kind: StructuredKind,
        title: String = "",
        body: String,
        source: StructuredSource,
        notes: [CanvasNoteRef] = [],
        loadNote: ((String) async -> String?)? = nil,
        motion: Bool = true,
        openLink: @escaping (String, StructuredOpenTarget) -> Void = { _, _ in },
        onSource: (() -> Void)? = nil,
        keySink: ((((StructuredKey) -> Bool)?) -> Void)? = nil,
        readOnly: Bool = false,
        onMode: ((StructuredModeKeys.Request) -> Void)? = nil
    ) {
        self.keySink = keySink
        self.readOnly = readOnly
        self.onMode = onMode
        self.kind = kind
        self.title = title
        self.restBody = body
        self.source = source
        self.notes = notes
        self.loadNote = loadNote
        self.motion = motion
        self.openLink = openLink
        self.onSource = onSource
        _state = State(initialValue: StructuredHostState(kind: kind, body: body))
    }

    private var status: String? {
        switch source {
        case .readOnly: return "read-only"
        case let .local(lt): return lt.isEditable ? nil : "read-only"
        case .session:
            if state.error != nil { return nil }
            guard let s = state.session else { return "loading…" }
            return s.structuredStatus
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let e = state.error { banner(e, tone: theme.error) }
            if let s = state.session, s.isEditable, s.emptyAtSync, !restBody.isEmpty {
                HStack {
                    Text("The server has no live-editing state for this \(kind == .kanban ? "board" : "canvas") yet.")
                        .font(.callout)
                    Spacer()
                    Button("Load file contents") { _ = s.initialiseFromFile(restBody) }
                }
                .padding(10)
                .background(theme.warning.opacity(0.12))
            }
            content
        }
        .onAppear {
            state.readOnly = readOnly
            state.start(source)
            wire()
            let inner: ((StructuredKey) -> Bool)? = state.kanban.map { k in { k.handleKey($0) } }
                ?? state.canvas.map { c in { c.handleKey($0) } }
            let state = self.state, onMode = self.onMode
            let handler: ((StructuredKey) -> Bool)? = inner.map { inner in
                { key in
                    if let onMode, let r = StructuredModeKeys.before(key, reading: state.readOnly) {
                        onMode(r)
                        return true
                    }
                    let handled = inner(key)
                    if let onMode, let r = StructuredModeKeys.after(key, reading: state.readOnly, handled: handled) {
                        onMode(r)
                        return true
                    }
                    return handled
                }
            }
            if let keySink { keySink(handler) } else if let handler { StructuredKeyRouting.install(state, handler) }
        }
        .onDisappear {
            if let keySink { keySink(nil) } else { StructuredKeyRouting.uninstall(state) }
            state.stop()
        }
        .onChange(of: restBody) { _, b in state.updateBody(b) }
        .onChange(of: readOnly) { _, r in state.readOnly = r }
        // Switch preview → live when the first SyncStep2 lands.
        .onChange(of: state.isLive) { _, _ in state.adopt() }
        .onChange(of: notes) { _, n in state.canvas?.notes = n }
    }

    @ViewBuilder
    private var content: some View {
        if let k = state.kanban {
            KanbanBoardView(model: k, title: title, status: status, motion: motion, onSource: onSource)
        } else if let c = state.canvas {
            CanvasBoardView(model: c, title: title, status: status, motion: motion, onSource: onSource)
        }
    }

    private func wire() {
        guard let c = state.canvas else { return }
        c.notes = notes
        c.onOpenFile = { path, split in openLink(path, split ? .split : .current) }
        c.onOpenURL = { url in openLink(url.absoluteString, .external) }
        if let loadNote {
            c.loadNote = loadNote
            c.refreshPreviews()
        }
    }

    private func banner(_ text: String, tone: Color) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(.callout)
            Spacer()
        }
        .foregroundStyle(tone)
        .padding(10)
        .background(tone.opacity(0.1))
    }
}
