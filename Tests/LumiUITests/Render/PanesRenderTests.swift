#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Offscreen renders of the part-2 shell surfaces (3-pane split, floating
/// explorer, hover card, book home, the open transition). PNGs only when
/// LUMI_RENDER_DIR is set; nothing ever opens a window.
@Suite("Part 2 shell renders (offscreen PNGs when LUMI_RENDER_DIR is set)", .serialized)
@MainActor
struct PanesRenderTests {
    static let themes: [(LumiTheme, String)] = [(.tokyoNight, "dark"), (.catppuccinLatte, "light")]

    static let plan = """
    # Q3 plan

    Ship **splits**, the [floating explorer](explorer.md) and [[Hover cards]] across clients.

    - [x] pane tree model
    - [ ] link routing — see [routing notes](routing.md)
    - [ ] kanban board view

    > [!tip] Keys
    > ⌃w v splits, ⌃w q closes, ⌃h/⌃l move between panes.

    ## Risks

    Two panes on one note must share one live session.
    """

    static let routing = """
    # Routing notes

    One table for every surface: **here**, *vsplit*, *hsplit*.

    | Gesture | Opens |
    |:--|:--|
    | gf / Enter | current pane |
    | ⌘-click | vertical split |
    | ⇧⌘-click | horizontal split |

    External links like <https://jsoncanvas.org> only open on an explicit action.
    """

    static let source = """
    ---
    title: Hover cards
    ---
    # Hover cards

    Rest on a link for 350 ms to see the note.
    `K` opens the card from the keyboard.

    - [ ] sanitise the excerpt
    - [x] 40 lines max
    """

    // MARK: Harness

    static func render<V: View>(_ view: V, size: CGSize, theme: LumiTheme, name: String, settle: TimeInterval = 1.0) throws {
        guard let dir = ParityRenderTests.dir else { return }
        let root = view
            .environment(\.theme, theme.tokens)
            .environment(\.lumiMotion, false)
            .frame(width: size.width, height: size.height)
            .background(theme.tokens.background)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: theme.tokens.isDark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// Fake chrome so the renders read like the window.
    struct TopLine: View {
        let crumbs: String
        @Environment(\.theme) private var theme
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.squares.left").font(.system(size: 13)).foregroundStyle(theme.textDim)
                Text(crumbs).font(ShellFont.chromeBold).foregroundStyle(theme.text)
                Spacer()
                Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7)
            }
            .padding(.leading, 84).padding(.trailing, 14)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    struct StatusLine: View {
        let mode: String
        let context: String
        @Environment(\.theme) private var theme
        var body: some View {
            HStack(spacing: 10) {
                Text(mode).font(ShellFont.mode).tracking(0.6).foregroundStyle(theme.primary)
                    .padding(.horizontal, 7).frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.primary.opacity(0.16)))
                Text(context).font(ShellFont.small).foregroundStyle(theme.textDim)
                Spacer()
                Text("synced").font(ShellFont.small).foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.overlayBackground.opacity(0.55))
            .overlay(alignment: .top) { Hairline() }
        }
    }

    /// The reader's TextKit view, laid out synchronously (an offscreen
    /// NSHostingView never runs TextKit's viewport layout on its own).
    static func reader(_ text: String, title: String, scale: Double = 0.92) -> some View {
        RenderReader(text: text, title: title, scale: scale)
    }

    struct RenderReader: NSViewRepresentable {
        let text: String
        let title: String
        let scale: Double
        @Environment(\.theme) private var theme

        final class Box: NSView {
            var controller: MarkdownDocumentController?
            var configure: ((MarkdownDocumentController, NSSize) -> Void)?
            override var isFlipped: Bool { true }
            override func layout() {
                super.layout()
                guard bounds.width > 10, let c = controller else { return }
                c.scrollView.frame = bounds
                c.textView.frame = NSRect(origin: .zero, size: bounds.size)
                configure?(c, bounds.size)
            }
        }

        func makeNSView(context: Context) -> Box {
            let box = Box()
            let c = MarkdownDocumentController()
            box.controller = c
            box.addSubview(c.scrollView)
            let theme = self.theme
            let text = self.text, title = self.title, scale = self.scale
            box.configure = { c, size in
                let header = MarkdownText.startsWithTitle(text, title: title) ? nil : MarkdownHeader(title: title, tags: [])
                c.update(header: header, document: MarkdownParser.parse(HoverPreview.stripFrontmatter(text)),
                         style: MarkdownRenderStyle(theme: theme, scale: scale, tasksInteractive: true),
                         readingWidth: min(620, size.width - 40), linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0,
                         onToggleTask: { _ in })
                if let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager {
                    tlm.ensureLayout(for: tcm.documentRange)
                }
                c.textView.sizeToFit()
                c.overlays.layout()
            }
            return box
        }

        func updateNSView(_ nsView: Box, context: Context) { nsView.needsLayout = true }
    }

    static var splitBody: some View {
        let one = PaneLeafID(1), two = PaneLeafID(2), three = PaneLeafID(3)
        let root = PaneNode.split(.vertical, [
            .leaf(one, .note(path: "plans/q3.md", view: .reading)),
            .split(.horizontal, [
                .leaf(two, .note(path: "plans/routing.md", view: .reading)),
                .leaf(three, .note(path: "hover-cards.md", view: .source)),
            ], [0.55, 0.45]),
        ], [0.52, 0.48])
        return VStack(spacing: 0) {
            TopLine(crumbs: "Work")
            PaneLayoutView(root: root, focused: two, showsFocus: true, onResize: { _, _, _ in }) { id, _ in
                VStack(spacing: 0) {
                    switch id.raw {
                    case 1:
                        PaneHeaderBar(title: "Q3 plan", folder: "plans", views: [.reading, .live, .source], selection: .reading,
                                      canEdit: true, focused: false, onSelect: { _ in }, onClose: {})
                        reader(plan, title: "Q3 plan")
                    case 2:
                        PaneHeaderBar(title: "Routing notes", folder: "plans", views: [.reading, .live, .source], selection: .reading,
                                      canEdit: true, focused: true, onSelect: { _ in }, onClose: {})
                        reader(routing, title: "Routing notes")
                    default:
                        PaneHeaderBar(title: "Hover cards", folder: "", views: [.reading, .live, .source], selection: .source,
                                      canEdit: true, focused: false, badge: "modified", onSelect: { _ in }, onClose: {})
                        VimEditor(text: .constant(source), showLineNumbers: true, fileName: "hover-cards.md")
                            .clipped()
                    }
                }
            }
            StatusLine(mode: "READ", context: "plans/routing.md  · pane 2/3")
        }
    }

    static func explorerColumns(_ theme: LumiTheme, preview: Bool = true) -> some View {
        let parent: [(String, Bool, Int)] = [("archive", true, 12), ("journal", true, 41), ("plans", true, 6), ("inbox.md", false, 0)]
        let current: [(String, Bool, Int)] = [("drafts", true, 3), ("q3", false, 0), ("routing", false, 0), ("hover-cards", false, 0),
                                              ("kanban", false, 0), ("canvas ideas", false, 0)]
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(parent.enumerated()), id: \.offset) { i, r in
                    ExplorerRowLabel(name: r.0, isFolder: r.1, count: r.2, isCursor: i == 2, active: false, isOpen: false, hidden: false)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .frame(width: 210)
            .background(theme.tokens.overlayBackground.opacity(0.35))
            Hairline(vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(current.enumerated()), id: \.offset) { i, r in
                    ExplorerRowLabel(name: r.0, isFolder: r.1, count: r.2, isCursor: i == 2, active: true, isOpen: i == 1, hidden: false)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .frame(width: preview ? 300 : nil)
            .frame(maxWidth: preview ? nil : .infinity)
            if preview {
                Hairline(vertical: true)
                reader(routing, title: "Routing notes")
                    .environment(\.markdownLite, true)
            }
        }
    }

    // MARK: Renders

    @Test("3-pane split, dark + light")
    func split() throws {
        for (theme, n) in Self.themes {
            try Self.render(Self.splitBody, size: CGSize(width: 1440, height: 880), theme: theme, name: "split3-\(n)", settle: 1.5)
        }
    }

    @Test("floating explorer over a split, dark + light")
    func floating() throws {
        for (theme, n) in Self.themes {
            let view = ZStack {
                Self.splitBody
                FloatingPanel(title: "Work", path: "/plans", hints: [("⏎", "open"), ("⌃v", "split"), ("⌃s", "stacked"), ("gb", "books"), ("esc", "close")],
                              onDismiss: {}) {
                    Self.explorerColumns(theme)
                } footer: { EmptyView() }
            }
            try Self.render(view, size: CGSize(width: 1440, height: 880), theme: theme, name: "floating-explorer-\(n)", settle: 1.5)
        }
    }

    @Test("floating explorer as a sheet in a narrow window")
    func floatingCompact() throws {
        let theme = LumiTheme.tokyoNight
        let view = ZStack {
            Self.reader(Self.plan, title: "Q3 plan")
            FloatingPanel(title: "Work", path: "/plans", hints: [("esc", "close")], compact: true, onDismiss: {}) {
                Self.explorerColumns(theme, preview: false)
            } footer: { EmptyView() }
        }
        try Self.render(view, size: CGSize(width: 640, height: 720), theme: theme, name: "floating-explorer-narrow-dark")
    }

    @Test("hover card over a reader, dark + light")
    func hover() throws {
        for (theme, n) in Self.themes {
            let card = HoverCardView(kind: .note(title: "Hover cards", folder: "notes", updated: "5 min ago",
                                                 body: HoverPreview.excerpt(Self.source).text, truncated: false, error: nil),
                                     keyboard: true, scale: 1, onOpen: {}, onSplit: {}, onClose: {})
            var withBody = card
            withBody.excerptOverride = { AnyView(Self.reader($0, title: "Hover cards", scale: 0.8)) }
            let url = HoverCardView(kind: .external(LinkRouting.urlCard("https://jsoncanvas.org/spec/1.0/")!, href: "https://jsoncanvas.org/spec/1.0/"),
                                    keyboard: false, onOpen: {}, onSplit: nil, onClose: {})
            let view = ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    TopLine(crumbs: "Work / plans")
                    Self.reader(Self.plan, title: "Q3 plan")
                    StatusLine(mode: "READ", context: "plans/q3.md")
                }
                withBody.frame(height: HoverCardView.size.height).offset(x: 470, y: 205)
                url.offset(x: 860, y: 560)
            }
            try Self.render(view, size: CGSize(width: 1360, height: 820), theme: theme, name: "hover-card-\(n)", settle: 1.5)
        }
    }

    static func home(cursor: Int?) -> some View {
        VStack(spacing: 0) {
            TopLine(crumbs: "Work")
            BookHomeView(name: "Work", status: "up to date", location: "ana@lumi.example.com", noteCount: 128,
                         recents: [
                            .init(id: "1", name: "Q3 plan", folder: "plans", updated: "just now"),
                            .init(id: "2", name: "Routing notes", folder: "plans", updated: "5 min ago"),
                            .init(id: "3", name: "Hover cards", folder: "", updated: "2 h ago"),
                            .init(id: "4", name: "1:1 — Marta", folder: "journal", updated: "3 days ago"),
                         ],
                         cursor: cursor, loading: false,
                         dot: { Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7) },
                         onOpen: { _ in })
            StatusLine(mode: "BROWSE", context: "/plans")
        }
    }

    @Test("empty book home with the explorer open, dark + light")
    func homeExplorer() throws {
        for (theme, n) in Self.themes {
            let view = ZStack {
                Self.home(cursor: nil)
                FloatingPanel(title: "Work", path: "/plans", hints: [("⏎", "open"), ("⌃v", "split"), ("⌃s", "stacked"), ("gb", "books"), ("esc", "close")],
                              onDismiss: {}) {
                    Self.explorerColumns(theme)
                } footer: { EmptyView() }
            }
            try Self.render(view, size: CGSize(width: 1440, height: 880), theme: theme, name: "home-explorer-\(n)", settle: 1.2)
        }
    }

    @Test("a note opened from the explorer, mid-transition")
    func openTransition() throws {
        for (theme, n) in Self.themes {
            let from = CGRect(x: 432, y: 205, width: 300, height: 26)
            let to = CGRect(x: 0, y: 34, width: 1440, height: 822)
            let view = ZStack(alignment: .topLeading) {
                Self.home(cursor: nil)
                FloatingPanel(title: "Work", path: "/plans", hints: [("⏎", "open"), ("esc", "close")], onDismiss: {}) {
                    Self.explorerColumns(theme)
                } footer: { EmptyView() }
                .opacity(0.35)
                .scaleEffect(0.98)
                OpenMorphView(from: from, to: to, progress: 0.55, title: "Routing notes")
            }
            try Self.render(view, size: CGSize(width: 1440, height: 880), theme: theme, name: "open-transition-\(n)", settle: 1.0)
        }
    }

    // MARK: Pure bits

    @Test("split sizes: weights, dividers, last child takes the rest")
    func sizes() {
        let s = PaneSplitStack.sizes(weights: [0.25, 0.75], count: 2, room: 999)
        #expect(abs(s[0] - 249.75) < 0.01 && abs(s[0] + s[1] - 999) < 0.001)
        #expect(PaneSplitStack.sizes(weights: [], count: 3, room: 300) == [100, 100, 100])
    }

    @Test("remote edits flash where their text lands")
    func insertedRanges() {
        let edits = [TextEdit(location: 10, length: 0, replacement: "abc"), TextEdit(location: 2, length: 1, replacement: "XY")]
        #expect(VimController.insertedRanges(edits) == [NSRange(location: 11, length: 3), NSRange(location: 2, length: 2)])
    }
}
#endif
