#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Offscreen frame sequences of every motion moment: the same view
/// rendered at several times through the test-only `lumiMotionClock`
/// (springs are evaluated in closed form, so frame t is exactly what the
/// app shows t seconds in). One contact sheet per moment and theme, plus
/// the "reduzido" final frame. PNGs only when LUMI_RENDER_DIR is set;
/// nothing ever opens a window.
@Suite("Motion frame sequences (LUMI_RENDER_DIR)", .serialized)
@MainActor
struct MotionFrameRenderTests {
    static let themes: [(LumiTheme, String)] = [(.tokyoNight, "dark"), (.catppuccinLatte, "light")]
    static let times: [Double] = [0, 0.03, 0.06, 0.10, 0.15, 0.22, 0.32, 0.6]

    static var dir: URL? {
        ProcessInfo.processInfo.environment["LUMI_RENDER_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("frames") }
    }

    /// A contact sheet: `rig` at every time in `times`, scaled down,
    /// labelled, plus the reduced-motion frame at the end.
    static func sheet<V: View>(_ name: String, size: CGSize, theme: LumiTheme, times: [Double] = times, scale: CGFloat = 0.42,
                               @ViewBuilder rig: @escaping () -> V) throws {
        guard let dir else { return }
        let cols = 3
        let cells: [(String, LumiMotion, Double?)] = times.map { (String(format: "t = %.0f ms", $0 * 1000), LumiMotion.full, $0) }
            + [("reduzido (any t)", LumiMotion.reduced, 0)]
        let w = size.width * scale, h = size.height * scale
        let rows = (cells.count + cols - 1) / cols
        let sheetSize = CGSize(width: CGFloat(cols) * (w + 16) + 16, height: CGFloat(rows) * (h + 34) + 16)
        let root = VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<cols, id: \.self) { c in
                        let i = r * cols + c
                        if i < cells.count {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cells[i].0)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.tokens.textDim)
                                rig()
                                    .frame(width: size.width, height: size.height)
                                    .background(theme.tokens.background)
                                    .clipped()
                                    .environment(\.lumiMotionClock, cells[i].2)
                                    .lumiMotion(cells[i].1)
                                    .scaleEffect(scale, anchor: .topLeading)
                                    .frame(width: w, height: h, alignment: .topLeading)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.tokens.border.opacity(0.6), lineWidth: 0.5))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: sheetSize.width, height: sheetSize.height, alignment: .topLeading)
        .background(theme.tokens.overlayBackground)
        .environment(\.theme, theme.tokens)

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: sheetSize)
        host.appearance = NSAppearance(named: theme.tokens.isDark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1.2)
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

    static let window = CGSize(width: 1100, height: 690)

    static func hoverCard() -> HoverCardView {
        var card = HoverCardView(kind: .note(title: "Hover cards", folder: "notes", updated: "5 min ago",
                                             body: HoverPreview.excerpt(PanesRenderTests.source).text, truncated: false, error: nil),
                                 keyboard: false, scale: 0.9, onOpen: {}, onSplit: {}, onClose: {})
        card.excerptOverride = { AnyView(PanesRenderTests.reader($0, title: "Hover cards", scale: 0.8)) }
        return card
    }

    // MARK: Rigs (LumiUI surfaces with their real motion modifiers)

    /// The book home at rest (its own entrance long finished), for rigs
    /// where something else is the moment.
    static func home() -> some View {
        homeEntering().environment(\.lumiMotionClock, 30)
    }

    static func homeEntering() -> some View {
        VStack(spacing: 0) {
            PanesRenderTests.TopLine(crumbs: "Work")
            BookHomeView(name: "Work", status: "up to date", location: "ana@lumi.example.com", noteCount: 128,
                         recents: (0..<9).map { i in
                             .init(id: "\(i)", name: ["Q3 plan", "Routing notes", "Hover cards", "1:1 — Marta", "Kanban", "Canvas ideas", "Reading list", "Inbox", "Retro"][i],
                                   folder: ["plans", "plans", "", "journal", "boards", "", "", "", "journal"][i], updated: "\(i + 1) h ago")
                         },
                         cursor: nil, loading: false,
                         dot: { Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7) },
                         onOpen: { _ in })
        }
    }

    struct ExplorerOpenRig: View {
        let theme: LumiTheme
        var body: some View {
            ZStack {
                MotionFrameRenderTests.home().lumiRecede(true)
                FloatingPanel(title: "Work", path: "/plans", hints: [("⏎", "open"), ("⌃v", "split"), ("gb", "livros"), ("esc", "close")],
                              origin: UnitPoint(x: 0.12, y: 0), icon: "book.closed", onDismiss: {}) {
                    HStack(spacing: 0) {
                        column(["archive", "journal", "plans", "inbox.md"], cursor: 2, active: false, folders: 3)
                            .frame(width: 200)
                            .lumiEnter(.travel(forward: true), spring: .gentle, delay: 0.04)
                        Hairline(vertical: true)
                        column(["drafts", "q3", "routing", "hover-cards", "kanban", "canvas ideas"], cursor: 2, active: true, folders: 1)
                            .frame(width: 290)
                            .lumiEnter(.travel(forward: true), spring: .gentle)
                        Hairline(vertical: true)
                        PanesRenderTests.reader(PanesRenderTests.routing, title: "Routing notes", scale: 0.8)
                            .lumiEnter(MotionFrom(x: 10, opacity: 0), spring: .gentle, delay: 0.08)
                    }
                } footer: { EmptyView() }
            }
        }

        func column(_ names: [String], cursor: Int, active: Bool, folders: Int) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                    ExplorerRowLabel(name: n, isFolder: i < folders, count: i < folders ? 4 + i : 0, isCursor: i == cursor, active: active,
                                     isOpen: false, hidden: false)
                        .staggerIn(i, active: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    struct ShelfRig: View {
        var body: some View {
            ZStack {
                MotionFrameRenderTests.home().lumiRecede(true)
                FloatingPanel(title: "Livros", path: "5 livros · 3 contas", hints: [("⏎", "abrir"), ("h", "contas"), ("esc", "fechar")],
                              icon: "books.vertical", onDismiss: {}) {
                    BooksShelfView(accounts: MotionFrameRenderTests.shelfAccounts, cursor: BooksShelf.Cursor(level: .books, account: 1, book: 1),
                                   onPick: { _ in }, onOpen: { _ in })
                        .lumiEnter(MotionFrom(scale: 1.05, opacity: 0), spring: .gentle)
                } footer: { EmptyView() }
            }
        }
    }

    static var shelfAccounts: [ShelfAccount] {
        func b(_ id: String, _ n: String, _ c: Int?, _ num: Int, open: Bool = false, color: Color = .green, sync: Bool = false, local: Bool = false) -> ShelfBook {
            ShelfBook(id: id, name: n, isLocal: local, noteCount: c, lastNote: open ? "Q3 plan" : nil, number: num, isOpen: open,
                      statusLabel: sync ? "syncing" : "up to date", statusColor: color.opacity(0.85), syncing: sync)
        }
        return [
            ShelfAccount(id: "local", user: "Este Mac", host: "pastas neste Mac", isLocal: true, signedIn: true,
                         books: [b("l1", "Diário", 212, 1, color: .gray, local: true)]),
            ShelfAccount(id: "ana@lumi.example.com", user: "ana", host: "lumi.example.com", isLocal: false, signedIn: true,
                         books: [b("w", "Work", 128, 2), b("p", "Pesquisa", 44, 3, open: true), b("r", "Receitas", 1, 4, color: .blue, sync: true)]),
            ShelfAccount(id: "vini@notes.casa", user: "vini", host: "notes.casa", isLocal: false, signedIn: false, books: []),
        ]
    }

    // MARK: Moments

    @Test("explorer opens from its trigger: overshoot, staggered columns, depth behind")
    func explorerOpen() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("01-explorer-open-\(n)", size: Self.window, theme: t) { ExplorerOpenRig(theme: t) }
        }
    }

    @Test("books level: a scope (zoom out to the shelf), accounts as headers")
    func shelf() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("02-books-shelf-\(n)", size: Self.window, theme: t) { ShelfRig() }
        }
    }

    @Test("folder travel: the column leads, context follows 40 ms later")
    func folderTravel() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("03-folder-travel-\(n)", size: CGSize(width: 900, height: 420), theme: t, times: [0, 0.03, 0.06, 0.1, 0.16, 0.3]) {
                HStack(spacing: 0) {
                    ExplorerOpenRig(theme: t).column(["notes", "plans", "q3", "routing"], cursor: 1, active: false, folders: 2)
                        .frame(width: 220).lumiEnter(.travel(forward: true), spring: .gentle, delay: 0.04)
                    Hairline(vertical: true)
                    ExplorerOpenRig(theme: t).column(["q3", "routing", "hover-cards", "kanban"], cursor: 0, active: true, folders: 0)
                        .frame(width: 300).lumiEnter(.travel(forward: true), spring: .gentle)
                    Hairline(vertical: true)
                    PanesRenderTests.reader(PanesRenderTests.plan, title: "Q3 plan", scale: 0.75)
                        .lumiEnter(MotionFrom(x: 10, opacity: 0), spring: .gentle, delay: 0.08)
                }
            }
        }
    }

    @Test("note content rises in by bands, top first")
    func noteReveal() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("04-note-reveal-\(n)", size: CGSize(width: 900, height: 620), theme: t,
                           times: [0, 0.06, 0.12, 0.2, 0.3, 0.45, 0.7, 1.2]) {
                PanesRenderTests.reader(ProseSample.note, title: "", scale: 0.9).lumiReveal(trigger: 0)
            }
        }
    }

    @Test("split unfolds from the divider; the focus light sits on the new pane")
    func splitUnfold() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("05-split-unfold-\(n)", size: Self.window, theme: t) {
                SplitRig()
            }
        }
    }

    struct SplitRig: View {
        @Environment(\.lumiMotionClock) private var clock
        @Environment(\.lumiMotionPolicy) private var motion
        var body: some View {
            let p = clock.map { motion.value(.glide, at: $0) } ?? 1
            let q = clock.map { motion.value(.gentle, at: $0) } ?? 1
            GeometryReader { geo in
                let w = geo.size.width
                // The old pane springs from full width to half (glide); the
                // new one unfolds from the divider (gentle).
                let left = w - (w / 2) * p
                ZStack(alignment: .topLeading) {
                    PanesRenderTests.reader(PanesRenderTests.plan, title: "Q3 plan", scale: 0.85)
                        .frame(width: left)
                        .overlay(Color(white: 0, opacity: 0).allowsHitTesting(false))
                    Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 1).offset(x: left)
                    PanesRenderTests.reader(PanesRenderTests.routing, title: "Routing notes", scale: 0.85)
                        .frame(width: w / 2)
                        .overlay { FocusLight(radius: 4).padding(1) }
                        .modifier(MotionFromEffect(from: .unfold(edge: .trailing), p: q))
                        .offset(x: left + 1)
                }
            }
        }
    }

    @Test("vim mode colour sweeps down the editor edge")
    func modeSweep() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("06-mode-sweep-\(n)", size: CGSize(width: 520, height: 300), theme: t, times: [0, 0.04, 0.08, 0.14, 0.22, 0.4], scale: 0.6) {
                ModeSweepRig()
            }
        }
    }

    struct ModeSweepRig: View {
        @Environment(\.theme) private var theme
        var body: some View {
            HStack(spacing: 0) {
                // The rig shows the insert colour arriving over normal.
                ModeEdge(color: theme.accent, from: theme.primary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("-- INSERT --").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent)
                    Text("Lumi keeps notes as plain markdown.").font(.system(size: 15, design: .monospaced)).foregroundStyle(theme.text)
                    Text("- [ ] write the parity report").font(.system(size: 15, design: .monospaced)).foregroundStyle(theme.text)
                    Spacer()
                }
                .padding(16)
            }
        }
    }

    @Test("sync dot: breathing while syncing, one ripple on a remote change")
    func syncRipple() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("07-sync-ripple-\(n)", size: CGSize(width: 220, height: 120), theme: t, times: [0, 0.1, 0.2, 0.35, 0.5, 0.7, 1.2, 1.6], scale: 1) {
                HStack(spacing: 28) {
                    SyncPulseDot(color: t.tokens.info, size: 10, syncing: true, pulse: 1)
                    SyncPulseDot(color: .green, size: 10, syncing: false, pulse: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @Test("palette: settles on bouncy, results ripple in")
    func palette() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("08-palette-\(n)", size: Self.window, theme: t) {
                ZStack(alignment: .top) {
                    MotionFrameRenderTests.home().lumiRecede(true)
                    Color.black.opacity(0.2).lumiEnter(MotionFrom(opacity: 0), spring: .soft)
                    VStack(spacing: 0) {
                        HStack { Text("open…").font(ShellFont.palette).foregroundStyle(t.tokens.textDim); Spacer() }
                            .padding(.horizontal, 18).frame(height: 52)
                        Hairline()
                        VStack(spacing: 0) {
                            ForEach(Array(["Q3 plan", "Routing notes", "Hover cards", "Kanban board", "Canvas ideas", "Theme: Tokyo Night"].enumerated()), id: \.offset) { i, s in
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(i == 0 ? t.tokens.accent : t.tokens.textDim)
                                    Text(s).font(ShellFont.row).foregroundStyle(t.tokens.text)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 7).fill(i == 0 ? t.tokens.primary.opacity(0.16) : .clear))
                                .staggerIn(i, active: true)
                            }
                        }
                        .padding(6)
                    }
                    .frame(width: 640)
                    .lumiGlass(theme: t.tokens)
                    .padding(.top, 90)
                    .lumiEnter(.overlay(from: .top), spring: .bouncy)
                }
            }
        }
    }

    @Test("toasts: slide up on bouncy, the stack settles back")
    func toasts() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("09-toasts-\(n)", size: CGSize(width: 520, height: 260), theme: t, times: [0, 0.05, 0.1, 0.16, 0.25, 0.5], scale: 0.7) {
                VStack(alignment: .trailing, spacing: 8) {
                    Spacer()
                    ForEach(Array(["Saved Q3 plan", "Book synced", "Could not reach lumi.example.com"].enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 8) {
                            Circle().fill(i == 2 ? t.tokens.error : t.tokens.info).frame(width: 6, height: 6)
                                .lumiEnter(.pop, spring: .bouncy, delay: i == 2 ? 0.06 : -1)
                            Text(s).font(ShellFont.chrome).foregroundStyle(t.tokens.text)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .lumiGlass(theme: t.tokens, radius: 18, level: .menu, accentEdge: false)
                        .scaleEffect(1 - 0.035 * Double(2 - i), anchor: .bottomTrailing)
                        .opacity(1 - 0.18 * Double(2 - i))
                        .lumiEnter(i == 2 ? MotionFrom(scale: 0.96, y: 16, opacity: 0, anchor: .bottomTrailing) : MotionFrom(), spring: .bouncy)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    @Test("hover card grows from the link, tether drawn")
    func hoverCard() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("10-hover-card-\(n)", size: Self.window, theme: t) {
                ZStack(alignment: .topLeading) {
                    PanesRenderTests.reader(PanesRenderTests.plan, title: "Q3 plan", scale: 0.92)
                    Path { p in p.move(to: CGPoint(x: 420, y: 150)); p.addLine(to: CGPoint(x: 440, y: 190)) }
                        .stroke(t.tokens.ramp.accentLine, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    MotionFrameRenderTests.hoverCard()
                        .frame(height: HoverCardView.size.height)
                        .lumiEnter(MotionFrom(scale: 0.4, opacity: 0, anchor: UnitPoint(x: 0.05, y: 0)), spring: .bouncy)
                        .offset(x: 400, y: 190)
                }
            }
        }
    }

    @Test("kanban: cards pop in as a ripple; a lifted card leans with velocity")
    func kanban() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            let model = KanbanBoardModel(doc: MemoryLiveText(StructuredRenderTests.fixture("kanban/basic.md")))
            try Self.sheet("11-kanban-\(n)", size: CGSize(width: 1100, height: 520), theme: t, times: [0, 0.04, 0.08, 0.14, 0.24, 0.5]) {
                ZStack(alignment: .topLeading) {
                    KanbanBoardView(model: model, title: "Sprint")
                    // A lifted card at three pointer velocities (0, 900, -1800 pt/s).
                    HStack(spacing: 40) {
                        ForEach([0.0, 900, -1800], id: \.self) { vx in
                            KanbanCardView(card: model.lanes[0].cards[0].card, focused: true, confirming: false, onToggle: {})
                                .frame(width: 240)
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(t.tokens.ramp.accentLine))
                                .shadow(color: t.tokens.ramp.accentGlow, radius: 16, y: 2)
                                .lumiElevation(.floating, radius: 9, ramp: t.tokens.ramp)
                                .rotationEffect(.degrees(max(-7, min(7, vx / 260)) + 1))
                                .scaleEffect(1.035)
                        }
                    }
                    .offset(x: 60, y: 360)
                }
            }
        }
    }

    @Test("canvas: nodes pop in staggered, edges draw from their source")
    func canvas() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            let model = CanvasBoardModel(doc: MemoryLiveText(StructuredRenderTests.fixture("canvas/obsidian.canvas")))
            model.setSize(CGSize(width: 1100, height: 620))
            model.fitAll(ease: false)
            try Self.sheet("12-canvas-\(n)", size: CGSize(width: 1100, height: 620), theme: t, times: [0, 0.05, 0.1, 0.16, 0.24, 0.36, 0.6]) {
                CanvasBoardView(model: model, title: "Ideas")
            }
        }
    }

    @Test("book home: the light drifts (48/61 s), switching books opens a cover")
    func homeAmbient() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("13-home-cover-\(n)", size: Self.window, theme: t, times: [0, 0.05, 0.1, 0.16, 0.24, 0.4, 6, 12]) {
                MotionFrameRenderTests.homeEntering().lumiEnter(.cover, spring: .gentle)
            }
        }
    }

    @Test("pane focus: lit pane (ring, breathing edge, wash) vs veiled rest")
    func focus() throws {
        guard Self.dir != nil else { return }
        for (t, n) in Self.themes {
            try Self.sheet("14-pane-focus-\(n)", size: Self.window, theme: t, times: [0, 1.3, 2.6]) {
                HStack(spacing: 1) {
                    PanesRenderTests.reader(PanesRenderTests.plan, title: "Q3 plan", scale: 0.85)
                        .overlay(t.tokens.background.opacity(0.18).allowsHitTesting(false))
                    PanesRenderTests.reader(PanesRenderTests.routing, title: "Routing notes", scale: 0.85)
                        .overlay { FocusLight(radius: 4).padding(1) }
                }
                .background(t.tokens.border.opacity(0.6))
            }
        }
    }
}
#endif
