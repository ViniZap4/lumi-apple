#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Offscreen renders for pane zoom, explorer row actions / drag-to-edge,
/// the fitted legend, kind glyphs and the mini canvas / board previews.
/// PNGs only when LUMI_RENDER_DIR is set; nothing opens a window.
@Suite("Zoom, explorer split actions, legend, mini previews (renders)", .serialized)
@MainActor
struct ZoomRenderTests {
    typealias R = PanesRenderTests
    static let themes = R.themes

    static func header(_ id: Int, focused: Bool, zoomed: Bool = false, kind: NoteKind = .markdown) -> some View {
        let titles = [1: ("Q3 plan", "plans"), 2: ("Routing notes", "plans"), 3: ("Hover cards", "")]
        let t = titles[id] ?? ("Note", "")
        return PaneHeaderBar(title: t.0, folder: t.1, views: kind.views, selection: kind.views[0], canEdit: true,
                             focused: focused, icon: kind == .markdown ? nil : kind.symbol, zoomed: zoomed,
                             onZoom: {}, onSelect: { _ in }, onClose: {})
    }

    static let root: PaneNode = .split(.vertical, [
        .leaf(PaneLeafID(1), .note(path: "plans/q3.md", view: .reading)),
        .split(.horizontal, [
            .leaf(PaneLeafID(2), .note(path: "plans/routing.md", view: .reading)),
            .leaf(PaneLeafID(3), .note(path: "hover-cards.md", view: .reading)),
        ], [0.55, 0.45]),
    ], [0.52, 0.48])

    static func panes(zoomed: PaneLeafID?, focused: PaneLeafID, drop: (PaneLeafID, PaneDropZone)? = nil) -> some View {
        PaneLayoutView(root: root, focused: focused, showsFocus: true, zoomed: zoomed, onResize: { _, _, _ in }) { id, _ in
            VStack(spacing: 0) {
                header(id.raw, focused: id == focused, zoomed: id == zoomed)
                R.reader([1: R.plan, 2: R.routing, 3: R.source][id.raw]!, title: ["", "Q3 plan", "Routing notes", "Hover cards"][id.raw])
            }
            .overlay {
                if let drop, drop.0 == id { PaneDropHighlight(zone: drop.1) }
            }
        }
    }

    struct Status: View {
        let mode: String
        let context: String
        var zoomed = false
        @Environment(\.theme) private var theme
        var body: some View {
            HStack(spacing: 10) {
                Text(mode).font(ShellFont.mode).tracking(0.6).foregroundStyle(theme.info)
                    .padding(.horizontal, 7).frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.info.opacity(0.16)))
                Text(context).font(ShellFont.small).foregroundStyle(theme.textDim)
                Spacer()
                if zoomed { ZoomBadge() }
                Text("synced").font(ShellFont.small).foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.overlayBackground.opacity(0.55))
            .overlay(alignment: .top) { Hairline() }
        }
    }

    static func legend(_ items: [LegendItem], pending: String = "", stat: String? = nil) -> some View {
        LegendLine(items: items, pending: pending, stat: stat, onAction: { _ in })
            .padding(.horizontal, 12)
            .frame(height: 26)
            .overlay(alignment: .top) { Hairline() }
    }

    @Test("a zoomed pane with its badge (header + status line), dark + light")
    func zoomed() throws {
        for (theme, n) in Self.themes {
            let view = VStack(spacing: 0) {
                R.TopLine(crumbs: "Work")
                Self.panes(zoomed: PaneLeafID(2), focused: PaneLeafID(2))
                Self.legend(CommandLegend.shellItems(.reader, pane: LegendItem("⌃h⌃j⌃k⌃l", "panes")))
                Status(mode: "READ", context: "plans/routing.md  · pane 2/3", zoomed: true)
            }
            try R.render(view, size: CGSize(width: 1440, height: 880), theme: theme, name: "zoom-pane-\(n)", settle: 1.5)
        }
    }

    @Test("the same layout unzoomed, for comparison")
    func unzoomed() throws {
        let view = VStack(spacing: 0) {
            R.TopLine(crumbs: "Work")
            Self.panes(zoomed: nil, focused: PaneLeafID(2))
            Status(mode: "READ", context: "plans/routing.md  · pane 2/3")
        }
        try R.render(view, size: CGSize(width: 1440, height: 880), theme: .tokyoNight, name: "zoom-pane-off-dark", settle: 1.5)
    }

    static func explorer(_ theme: LumiTheme, preview: AnyView? = nil, cursor: Int = 2) -> some View {
        let current: [(String, NoteKind?)] = [("drafts", nil), ("q3", .markdown), ("routing", .markdown), ("launch", .kanban),
                                              ("launch", .canvas), ("hover-cards", .markdown)]
        let names = NoteKind.disambiguated(current.compactMap { $0.1.map { k in (title: "x", kind: k) } }) // warm
        _ = names
        let display = NoteKind.disambiguated(current.map { (title: $0.0, kind: $0.1 ?? .markdown) })
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array([("archive", 12), ("journal", 41), ("plans", 6)].enumerated()), id: \.offset) { i, r in
                    ExplorerRowLabel(name: r.0, isFolder: true, count: r.1, isCursor: i == 2, active: false, isOpen: false, hidden: false)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .frame(width: 210)
            .background(theme.tokens.overlayBackground.opacity(0.35))
            Hairline(vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(current.enumerated()), id: \.offset) { i, r in
                    ExplorerRowLabel(name: r.1 == nil ? r.0 : display[i], isFolder: r.1 == nil, count: r.1 == nil ? 3 : 0,
                                     isCursor: i == cursor, active: true, isOpen: i == 1, hidden: false,
                                     icon: r.1.map(\.symbol))
                        .overlay(alignment: .trailing) {
                            if i == cursor { ExplorerRowActions(onOpen: {}, onRight: {}, onBelow: {}).padding(.trailing, 6) }
                        }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .frame(width: 320)
            Hairline(vertical: true)
            (preview ?? AnyView(R.reader(R.routing, title: "Routing notes").environment(\.markdownLite, true)))
        }
    }

    @Test("explorer: row actions (Open · right · below), kind glyphs, fitted footer legend with the count")
    func rowActions() throws {
        for (theme, n) in Self.themes {
            let view = ZStack {
                Self.panes(zoomed: nil, focused: PaneLeafID(1))
                FloatingPanel(title: "Work", path: "/plans", hints: [], onDismiss: {}) {
                    Self.explorer(theme)
                } footer: {
                    Self.legend(CommandLegend.floatItems, stat: "3/6")
                }
            }
            try R.render(view, size: CGSize(width: 1440, height: 880), theme: theme, name: "explorer-row-actions-\(n)", settle: 1.5)
        }
    }

    @Test("dragging a note onto a pane's right edge: the edge highlight, dark + light")
    func dropEdge() throws {
        for (theme, n) in Self.themes {
            let view = ZStack(alignment: .topLeading) {
                Self.panes(zoomed: nil, focused: PaneLeafID(1), drop: (PaneLeafID(2), .right))
                FloatingPanel(title: "Work", path: "/plans", hints: [], onDismiss: {}) {
                    Self.explorer(theme)
                } footer: { EmptyView() }
                .opacity(0.1)
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.split.3x1")
                    Text("launch").lineLimit(1)
                }
                .font(ShellFont.row)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.tokens.overlayBackground))
                .foregroundStyle(theme.tokens.text)
                .offset(x: 1270, y: 300)
            }
            try R.render(view, size: CGSize(width: 1440, height: 880), theme: theme, name: "drop-edge-\(n)", settle: 1.5)
            let bottom = Self.panes(zoomed: nil, focused: PaneLeafID(1), drop: (PaneLeafID(1), .bottom))
            if n == "dark" {
                try R.render(bottom, size: CGSize(width: 1200, height: 700), theme: theme, name: "drop-edge-bottom-dark", settle: 1.2)
            }
        }
    }

    @Test("the legend fits the width: wide shows the extras, narrow ends with ⋯")
    func legendFit() throws {
        let theme = LumiTheme.tokyoNight
        let items = CommandLegend.items(.normal, extras: .init(source: true, split: true, pane: LegendItem("⌃h⌃j⌃k⌃l", "panes")))
        for (w, name) in [(1600.0, "legend-wide-dark"), (760.0, "legend-narrow-dark")] {
            try R.render(VStack(spacing: 0) { Self.legend(items); Self.legend(CommandLegend.windowCommands, pending: "^W") },
                         size: CGSize(width: w, height: 52), theme: theme, name: name, settle: 0.3)
        }
    }

    static var canvasMini: StructuredMini {
        .canvas(CanvasMini.make(StructuredRenderTests.fixture("canvas/obsidian.canvas"))!)
    }
    static var boardMini: StructuredMini {
        .board(KanbanMini.make(StructuredRenderTests.fixture("kanban/basic.md")))
    }

    @Test("explorer preview of a canvas and of a board (mini renders), dark + light")
    func miniPreviews() throws {
        for (theme, n) in Self.themes {
            for (mini, cursor, tag) in [(Self.canvasMini, 4, "canvas"), (Self.boardMini, 3, "board")] {
                let preview = AnyView(VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: mini.kind.symbol).font(.system(size: 11)).foregroundStyle(theme.tokens.textDim)
                        Text("launch").font(ShellFont.chromeBold).foregroundStyle(theme.tokens.text)
                    }
                    .padding(.horizontal, 14).padding(.top, 12)
                    StructuredMiniView(mini).frame(maxWidth: .infinity, maxHeight: .infinity)
                })
                let view = FloatingPanel(title: "Work", path: "/plans", hints: [], onDismiss: {}) {
                    Self.explorer(theme, preview: preview, cursor: cursor)
                } footer: { Self.legend(CommandLegend.floatItems, stat: "\(cursor + 1)/6") }
                try R.render(view, size: CGSize(width: 1440, height: 820), theme: theme, name: "explorer-\(tag)-preview-\(n)", settle: 1.0)
            }
        }
    }

    @Test("hover cards on a board and a canvas link")
    func hoverMini() throws {
        for (theme, n) in Self.themes {
            var board = HoverCardView(kind: .note(title: "Launch", folder: "boards", updated: "5 min ago", body: "", truncated: false, error: nil),
                                      keyboard: true, onOpen: {}, onSplit: {}, onClose: {})
            board.structured = Self.boardMini
            var canvas = HoverCardView(kind: .note(title: "Launch plan", folder: "maps", updated: "1 h ago", body: "", truncated: false, error: nil),
                                       keyboard: false, onOpen: {}, onSplit: {}, onClose: {})
            canvas.structured = Self.canvasMini
            let view = HStack(alignment: .top, spacing: 30) {
                board.frame(height: HoverCardView.size.height)
                canvas.frame(height: HoverCardView.size.height)
            }
            .padding(30)
            try R.render(view, size: CGSize(width: 1040, height: 430), theme: theme, name: "hover-structured-\(n)", settle: 0.8)
        }
    }

    @Test("a board in Reading (read-only) with Reading | Edit | Source")
    func boardReading() throws {
        for (theme, n) in Self.themes {
            let model = KanbanBoardModel(doc: MemoryLiveText(StructuredRenderTests.fixture("kanban/basic.md")))
            model.readOnly = true
            let view = VStack(spacing: 0) {
                R.TopLine(crumbs: "Work")
                Self.header(1, focused: true, kind: .kanban)
                KanbanBoardView(model: model, title: "Launch board", status: nil, motion: false, onSource: nil)
                Self.legend(CommandLegend.shellItems(.reader))
            }
            try R.render(view, size: CGSize(width: 1300, height: 760), theme: theme, name: "board-reading-\(n)", settle: 1.0)
        }
    }
}
#endif
