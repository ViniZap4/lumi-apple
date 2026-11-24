import Foundation

/// Where the keyboard is: decides which keys the command legend shows.
public enum LegendContext: String, Sendable, Hashable, CaseIterable {
    case explorer, reader
    /// The split preview, focused for keyboard reading.
    case preview
    /// The books sidebar, focused.
    case sidebar
    case normal, insert, replace
    case visual, visualLine, visualBlock
    case operatorPending
    case commandLine, search
    case substituteConfirm
    case palette, prompt, confirm, filter, books, help
    /// The book's empty home (no note open).
    case home
    /// A hover card opened with `K`.
    case hover
}

/// What a click on a legend item does — the same as typing its keys.
public enum LegendAction: Sendable, Hashable {
    /// Shell keys, fed to the shell key handler (`j`, `gg`, `⌃w v` is
    /// better as `.app`).
    case keys(String)
    /// Vim key notation sent to the focused editor (`i`, `<Esc>`, `za`).
    case vim(String)
    /// An app action (`vsplit`, `zoom`, `explorer`, `hints`, …).
    case app(String)
    /// An ex command the app runs (`preview split`, `only`).
    case ex(String)
}

public struct LegendItem: Sendable, Hashable {
    public var keys: String
    public var label: String
    /// Clicking the item runs this (nil: display only).
    public var action: LegendAction?
    /// Longer tooltip.
    public var tip: String?

    public init(_ keys: String, _ label: String, _ action: LegendAction? = nil, tip: String? = nil) {
        self.keys = keys
        self.label = label
        self.action = action
        self.tip = tip
    }
}

/// Command legend (which-key style): the handful of keys that matter in
/// the current context, and the completions while a key sequence is
/// pending (`g…`, `z…`, `"…`, a count, an operator, the leader). Pure —
/// the views resolve the context, this decides what to show. Mirrors the
/// web client's `legend.ts`; one compact line, `?` has the full keymap.
public enum CommandLegend {
    public struct Extras: Sendable, Hashable {
        /// Vim leader as key notation (`\`, `,`, `<Space>`).
        public var leader: String
        /// Leader mappings: keys AFTER the leader → their right-hand side.
        public var leaderMaps: [LegendItem]
        /// Insert-mode escape sequences (`jj`).
        public var escapeSequences: [String]
        /// Recording a macro into this register.
        public var recording: Character?
        /// Source mode (the split preview keys apply).
        public var source: Bool
        /// The split preview shows.
        public var split: Bool
        /// The pane hint (`⌃h ⌃l panes`) when several panes show.
        public var pane: LegendItem?

        public init(leader: String = "\\", leaderMaps: [LegendItem] = [], escapeSequences: [String] = [], recording: Character? = nil,
                    source: Bool = false, split: Bool = false, pane: LegendItem? = nil) {
            self.leader = leader
            self.leaderMaps = leaderMaps
            self.escapeSequences = escapeSequences
            self.recording = recording
            self.source = source
            self.split = split
            self.pane = pane
        }
    }

    // MARK: Shell (explorer / reader) — web `legend.ts` parity, priority order

    static let shellG: [LegendItem] = [
        .init("gg", "top", .keys("gg")), .init("ge", "bottom", .keys("ge")), .init("gf", "follow link", .keys("gf")),
        .init("gb", "books", .app("books")), .init("gh", "book root", .keys("gh")), .init("g1–9", "book n"),
    ]
    static let shellZ: [LegendItem] = [.init("zp", "preview", .keys("zp")), .init("zh", "book root", .keys("zh"))]

    /// After `⌃w` (shell or editor) — web `PANE_W` plus zoom.
    public static let windowCommands: [LegendItem] = [
        .init("v", "split right", .app("vsplit")), .init("s", "split below", .app("hsplit")),
        .init("h j k l", "move to pane"), .init("z", "zoom", .app("zoom"), tip: "Zoom the pane to the whole area and back (tmux prefix z) — also :zoom, double-click the header"),
        .init("q", "close pane", .app("closePane")), .init("o", "only this", .app("onlyPane")),
        .init("=", "equalize", .app("equalPanes")), .init("f ⏎", "link → split"), .init("F", "link → below"),
        .init("w", "next pane", .app("panes")), .init("p", "previous pane"), .init("< > + -", "resize"),
        .init("Esc", "cancel"),
    ]

    /// The floating explorer, files level (web `FLOAT_ITEMS`).
    public static let floatItems: [LegendItem] = [
        .init("j k", "move", .keys("j")), .init("h l", "folders", .keys("l"), tip: "h at the book root climbs to the books"),
        .init("⏎", "open here", .keys("⏎")), .init("⌃v", "split right", .keys("⌃v")), .init("⌃s", "split below", .keys("⌃s")),
        .init("/", "filter", .keys("/")), .init("a r d", "new/rename/delete", .keys("a")), .init("y p", "copy", .keys("y")),
        .init("Esc q", "close", .keys("Esc")), .init("f", "hints", .keys("f")), .init("gb", "books", .keys("gb")),
        .init("e", "edit", .keys("e")), .init("⇧F10", "menu"), .init("gg G", "top/end", .keys("gg")),
        .init("H L", "history", .keys("H")), .init(".", "hidden", .keys(".")), .init("zp", "preview", .keys("zp")),
        .init("?", "keys", .keys("?")),
    ]

    /// The floating explorer, books level (web `BOOKS_ITEMS`).
    public static let booksItems: [LegendItem] = [
        .init("j k", "mover", .keys("j")), .init("⏎ l", "abrir livro", .keys("⏎")), .init("h", "contas", .keys("h")),
        .init("[ ]", "livro ant./próx.", .keys("]")), .init("gg G", "topo/fim", .keys("g")), .init("Esc q", "fechar", .keys("Esc")),
        .init("?", "teclas", .keys("?")),
    ]

    /// A keyboard hover card (web `HOVER_ITEMS`).
    public static let hoverItems: [LegendItem] = [
        .init("j k", "scroll", .keys("j")), .init("d u", "half page", .keys("d")), .init("⏎", "open", .keys("⏎")),
        .init("⌃w f", "open in split", .keys("v")), .init("⌃w F", "split below", .keys("s")), .init("Esc q", "close", .keys("Esc")),
    ]

    /// The book's empty home (web `home`).
    public static let homeItems: [LegendItem] = [
        .init("-", "explorer", .app("explorer"), tip: "The floating explorer: the only navigation (also l, ⏎, <leader>e, :explore)"),
        .init("a", "new note", .keys("a")), .init("j k", "recent", .keys("j")),
        .init("gb", "books", .app("books"), tip: "Switch book in the floating explorer (accounts → books)"),
        .init("[ ]", "prev/next book", .keys("]")), .init("space", "commands", .keys(" ")), .init("?", "keys", .keys("?")),
        .init("F", "hints", .app("hints"), tip: "Label everything clickable; type a label to click it"),
        .init("H L", "history", .keys("H")), .init(":", "command", .keys(":")), .init("R", "refresh", .keys("R")),
        .init("⌘,", "settings", .app("settings")),
    ]

    static let readerItems: [LegendItem] = [
        .init("j k", "scroll", .keys("j")), .init("d u", "half page", .keys("d")),
        .init("-", "explorer", .keys("-"), tip: "The floating explorer at this note (yazi) — also <leader>e, :explore"),
        .init("e i", "edit", .keys("e")), .init("gg G", "top/end", .keys("gg")),
        .init("q", "close", .keys("q"), tip: "Close the note (back to the book home); in a split, close the pane"),
        .init("⌃w v", "split", .app("vsplit"), tip: "⌃w v / s split · q close · o only · z zoom · = equalize"),
        .init("K", "preview link", .keys("K"), tip: "Preview the focused (or first visible) link"),
        .init("gf", "follow link", .keys("gf"), tip: "gf / Enter: this pane · ⌃w f: split · ⌘-click: split"),
        .init("H L", "back/forward", .keys("H"), tip: "Previous / next note opened here"),
        .init("y", "copy", .keys("y")), .init("F", "hints", .app("hints"), tip: "Label links, tasks and buttons; type a label to click it"),
        // (pane item lands here)
        .init("space", "commands", .keys(" ")), .init("?", "keys", .keys("?")),
        .init("/ n", "find", .keys("/")), .init("{ }", "heading", .keys("}")), .init("gb", "books", .app("books")),
        .init("⌘E", "edit", .keys("e")), .init(":", "command", .keys(":")), .init("[ ]", "prev/next book", .keys("]")),
        .init("⌘,", "settings", .app("settings")),
    ]

    static let previewItems: [LegendItem] = [
        .init("j k", "scroll", .keys("j")), .init("d u", "half page", .keys("d")),
        .init("{ }", "heading", .keys("}"), tip: "} next heading · { previous (also ]] [[)"),
        .init("/", "find", .keys("/"), tip: "/ find in the preview · n N next/previous match"),
        .init("f", "hints", .keys("f"), tip: "Label links, tasks and copy buttons; type a label to click it"),
        .init("q ⌃h", "editor", .keys("q"), tip: "q, Esc, e, i or ⌃h: back to the editor"),
        .init("y", "copy", .keys("y")), .init("gg G", "top/end", .keys("gg")), .init("n N", "next match", .keys("n")),
        .init("⏎ gf", "open link"), .init("K", "preview link", .keys("K")), .init("-", "explorer", .keys("-")),
        .init("space", "page", .keys(" ")), .init("⌃w w", "next pane", .app("panes")), .init("?", "keys", .keys("?")),
    ]

    static let headingChord: [LegendItem] = [.init("[[", "prev heading", .keys("[[")), .init("]]", "next heading", .keys("]]"))]

    /// Explorer / reader / preview / sidebar / home / hover legend;
    /// `pending` is the shell keymap's pending keys (`g`, `z`, `^W`, a
    /// count). `pane` is the pane hint the host adds when it applies.
    public static func shellItems(_ ctx: LegendContext, pending: String = "", pane: LegendItem? = nil) -> [LegendItem] {
        let digits = pending.prefix(while: { $0.isASCII && $0.isNumber })
        let chord = pending.dropFirst(digits.count)
        if ctx == .hover { return hoverItems }
        if ctx == .books { return booksItems }
        if chord == "^W" { return windowCommands }
        if chord == "g" { return ctx == .preview ? [.init("gg", "top", .keys("gg"))] : shellG }
        if chord == "z" { return shellZ }
        if chord == "[" || chord == "]" { return headingChord }
        if !digits.isEmpty {
            switch ctx {
            case .explorer, .home:
                return [.init("\(digits)j", "down \(digits)"), .init("\(digits)k", "up \(digits)"), .init("Esc", "cancel")]
            case .preview:
                return [.init("\(digits)j", "scroll \(digits)"), .init("\(digits)}", "\(digits) headings"), .init("Esc", "cancel")]
            default:
                return [.init("\(digits)j", "scroll \(digits)"), .init("\(digits)k", "scroll \(digits) up")]
            }
        }
        var out: [LegendItem]
        switch ctx {
        case .explorer: return floatItems
        case .home: out = homeItems
        case .preview: out = previewItems
        case .sidebar:
            return [
                .init("j k", "move"), .init("⏎ l", "open book"), .init("gg G", "top/end"), .init("g1–9", "book n"),
                .init("Esc ⌃l", "back"), .init("?", "keys"),
            ]
        default: out = readerItems
        }
        if let pane, ctx == .reader || ctx == .preview {
            // After `F` hints (web order), before `space`.
            let at = out.firstIndex { $0.keys == "space" } ?? out.count
            out.insert(pane, at: at)
        }
        return out
    }

    /// Which items fit on one line (web `fitLegend`). `widths[i]` is item
    /// i's measured width in priority order, `gap` the space between
    /// items, `available` the room. Greedy in priority order: an item
    /// that does not fit is skipped and smaller, lower-priority ones may
    /// still take the remaining room; the result keeps priority order.
    /// When something is left out, `reserve` (the "⋯" marker) stays free.
    public static func fit(widths: [Double], available: Double, gap: Double, reserve: Double = 0) -> (shown: [Int], overflow: Bool) {
        let total = widths.reduce(0, +) + gap * Double(max(0, widths.count - 1))
        if total <= available { return (Array(widths.indices), false) }
        let room = available - reserve - gap
        var shown: [Int] = []
        var used = 0.0
        for (i, w) in widths.enumerated() {
            let need = w + (shown.isEmpty ? 0 : gap)
            if used + need <= room {
                shown.append(i)
                used += need
            }
        }
        return (shown, shown.count < widths.count)
    }

    // MARK: Editor (vim)

    static let vimG: [LegendItem] = [
        .init("gg", "top"), .init("gj gk", "display line"), .init("ge", "word end back"), .init("g_", "last char"),
        .init("gu gU g~", "case"), .init("gv", "reselect"), .init("gJ", "join"), .init("gp gP", "put, after"),
        .init("gi", "insert again"), .init("g* g#", "search part"), .init("g&", ":s all lines"), .init("gf", "follow link"),
    ]
    static let vimZ: [LegendItem] = [
        .init("zz", "center"), .init("zt", "to top"), .init("zb", "to bottom"), .init("z. z⏎ z-", "…+ first char"),
    ]
    static let vimBigZ: [LegendItem] = [.init("ZZ", "save & close"), .init("ZQ", "close, discard")]
    static let registers: [LegendItem] = [
        .init("a–z", "named"), .init("A–Z", "append"), .init("0", "last yank"), .init("1–9", "deletes"),
        .init("+ *", "clipboard"), .init("_", "black hole"), .init(". : / %", "read-only"),
    ]
    static let textObjects: [LegendItem] = [
        .init("w W", "word"), .init("s", "sentence"), .init("p", "paragraph"), .init("\" ' `", "quotes"),
        .init("( [ { <", "brackets"), .init("b B", "() {}"), .init("t", "tag"),
    ]
    static let operatorMotions: [LegendItem] = [
        .init("w e b", "word"), .init("iw aw", "inner/a word"), .init("ip ap", "paragraph"),
        .init("i\" i( i[", "inside"), .init("$ 0 ^", "to end/start"), .init("j k", "lines"),
        .init("f t", "to char"), .init("/ n", "to match"), .init("gg G", "to top/end"),
    ]

    /// Legend for the editor (and the generic overlays: palette, prompt …).
    public static func items(_ ctx: LegendContext, pending: VimPendingInfo = VimPendingInfo(), extras: Extras = Extras()) -> [LegendItem] {
        switch ctx {
        case .explorer, .reader, .preview, .sidebar, .home, .hover, .books:
            return shellItems(ctx, pending: pending.display)
        default:
            break
        }

        if [.normal, .visual, .visualLine, .visualBlock, .operatorPending].contains(ctx), !pending.isEmpty {
            if let c = pendingItems(pending, extras: extras) { return c }
        }

        switch ctx {
        case .normal:
            let leader = displayLeader(extras.leader)
            var out: [LegendItem] = [
                .init("i a o", "insert", .vim("i")), .init("v V", "visual", .vim("v")), .init("dd yy p", "cut/copy/paste"),
                .init("u ⌃r", "undo/redo", .vim("u"), tip: "u undo · ⌃r redo"), .init("/ n", "search", .vim("/")),
                .init("-", "explorer", .ex("explore"), tip: "Floating explorer at this note"),
            ]
            if extras.source {
                out.append(.init("\(leader)p", extras.split ? "hide preview" : "preview", .ex("preview split"),
                                 tip: "Rendered preview beside the source (⌥⌘P, :preview split)"))
            }
            if extras.split, extras.pane != nil {
                out.append(.init("⌃l", "read preview", .app("readPreview"), tip: "⌃l focuses the preview: j/k, { }, /, f; q or ⌃h comes back"))
            } else if let pane = extras.pane {
                out.append(pane)
            }
            out += [
                .init(":q", "close", .ex("q")),
                .init("gf K", "follow/preview link", .ex("hover"), tip: "gf or Enter on a link follows it · K previews it · ⌃w f opens it in a split"),
                .init("⌃w v", "split", .ex("vsplit"), tip: ":vsplit / :split [note] · ⌃w q close · o only · z zoom · = equalize"),
                .init("⌘E", "reading", .app("reading")), .init("ciw", "change word", .vim("ciw")), .init(".", "repeat", .vim(".")),
                .init(">> <<", "indent", .vim(">>")), .init("* #", "word search", .vim("*")), .init("gg G", "top/end", .vim("gg")),
                .init("ma 'a", "marks", tip: "m{a-z} sets a mark, '{a-z} jumps to it"),
                .init("\"a", "registers", tip: "\"{a-z} before y/d/p picks a register"), .init("zz", "center", .vim("zz")),
                .init("⌥⌘L ⌥⌘S", extras.source ? "live preview" : "source", .app("toggleMode")), .init(":", "ex", .vim(":")),
            ]
            if extras.split { out.append(.init("⌥⌘P", "split", .ex("preview split"))) }
            if let r = extras.recording { out.insert(.init("q", "stop recording @\(r)", .vim("q")), at: 0) }
            if !extras.leaderMaps.isEmpty { out.insert(.init(leader, "leader"), at: min(6, out.count)) }
            return out
        case .insert:
            let esc = extras.escapeSequences.isEmpty ? "Esc" : "Esc " + extras.escapeSequences.joined(separator: " ")
            return [
                .init(esc, "normal", .vim("<Esc>")), .init("[[", "link a note"), .init("⌃w", "delete word"),
                .init("⌃u", "delete line start"), .init("⌃o", "one normal cmd"), .init("⌘E", "reading", .app("reading")),
                .init("⌃r{r}", "paste register"), .init("⌃t ⌃d", "indent"),
            ]
        case .replace:
            return [.init("Esc", "normal"), .init("⌫", "restore"), .init("^R{r}", "paste register")]
        case .visual, .visualLine:
            var out: [LegendItem] = [
                .init("y d c", "copy/cut/change", .vim("y")), .init("> <", "indent", .vim(">")), .init("~ u U", "case", .vim("~")),
                .init("Esc", "normal", .vim("<Esc>")), .init("o", "other end", .vim("o")), .init("iw ip", "select word/para"),
                .init("J", "join", .vim("J")), .init(":", "ex on range", .vim(":")),
            ]
            if ctx == .visualLine { out.removeAll { $0.keys == "iw ip" } }
            return out
        case .visualBlock:
            return [
                .init("I A", "insert on lines"), .init("c", "change"), .init("d y", "cut/copy"),
                .init("$", "to line end"), .init("o O", "corners"), .init("r", "replace"), .init("Esc", "normal"),
            ]
        case .operatorPending:
            return operatorMotions
        case .commandLine:
            return [
                .init("⏎", "run"), .init("Esc", "cancel"), .init("↑ ↓", "history"), .init("^R{r}", "register"),
                .init(":s/a/b/g", "replace"), .init(":g/x/d", "global"), .init(":norm", "keys on lines"),
            ]
        case .search:
            return [
                .init("⏎", "search"), .init("Esc", "cancel"), .init("↑ ↓", "history"), .init("^R{r}", "register"),
                .init("\\c \\C", "case"), .init("\\< \\>", "word"),
            ]
        case .substituteConfirm:
            return [
                .init("y", "replace"), .init("n", "skip"), .init("a", "all"), .init("l", "this, stop"), .init("q Esc", "stop"),
            ]
        case .palette:
            return [.init("↑ ↓ ⌃n ⌃p", "select"), .init("⏎", "run"), .init("Esc", "close"), .init(":", "commands only")]
        case .prompt:
            return [.init("⏎", "confirm"), .init("Esc", "cancel"), .init("a/b/name", "in folders"), .init("dir/", "folder")]
        case .filter:
            return [.init("⏎", "keep filter"), .init("↑ ↓", "move"), .init("Esc", "clear"), .init("n N", "next/prev (after ⏎)")]
        case .confirm:
            return [.init("y ⏎", "confirm"), .init("n Esc", "cancel")]
        case .help:
            return [.init("any key", "close")]
        case .explorer, .reader, .preview, .sidebar, .home, .hover, .books:
            return []
        }
    }

    /// Which-key completions for a pending key sequence, or nil when the
    /// default legend applies.
    static func pendingItems(_ p: VimPendingInfo, extras: Extras) -> [LegendItem]? {
        let leader = displayLeader(extras.leader)
        if p.awaiting == .mapping || p.display == leader || p.display == extras.leader {
            let maps = extras.leaderMaps.map { LegendItem(leader + $0.keys, describeRhs($0.label)) }
            if p.display == leader || p.display == extras.leader {
                return maps.isEmpty ? [.init("\(leader)…", "no leader mappings")] : maps
            }
            return [.init(p.display + "…", "mapping"), .init("Esc", "cancel")]
        }
        switch p.awaiting {
        case .gPrefix: return vimG
        case .zPrefix: return vimZ
        case .bigZPrefix: return vimBigZ
        case .register: return registers
        case .markSet: return [.init("a–z", "set mark"), .init("A–Z", "file mark")]
        case .markJump:
            return [
                .init("a–z", "to mark"), .init("' `", "previous spot"), .init("< >", "last selection"),
                .init(".", "last change"), .init("^", "last insert"), .init("[ ]", "last change/yank"),
            ]
        case .findChar: return [.init("{char}", "target"), .init("; ,", "repeat after")]
        case .replaceChar: return [.init("{char}", "replace with"), .init("Esc", "cancel")]
        case .textObject: return textObjects
        case .macroRecord: return [.init("a–z", "record into"), .init("A–Z", "append to")]
        case .macroPlay: return [.init("a–z", "play"), .init("@", "repeat last"), .init(":", "repeat ex command")]
        case .bracket: return [.init("[( [{", "unmatched open"), .init("]) ]}", "unmatched close"), .init("]p [p", "put")]
        case .motion:
            var out = operatorMotions
            if let op = p.op {
                let k = op.keys
                out.insert(.init(k.count == 1 ? k + k : k + String(k.last!), "whole line"), at: 0)
            }
            return out
        case .mapping, .none:
            if let n = p.count, p.op == nil {
                return [
                    .init("\(n)j \(n)k", "\(n) lines"), .init("\(n)w", "\(n) words"), .init("\(n)dd", "delete \(n)"),
                    .init("\(n)G", "line \(n)"), .init("\(n)x", "\(n) chars"), .init("\(n).", "repeat ×\(n)"),
                ]
            }
            return nil
        }
    }

    /// `<Space>` → `␣`; other leaders as typed.
    public static func displayLeader(_ leader: String) -> String {
        leader == "<Space>" ? "␣" : leader
    }

    /// Friendly description of a mapping rhs.
    public static func describeRhs(_ rhs: String) -> String {
        if rhs.hasPrefix(":") {
            var body = String(rhs.dropFirst())
            if body.hasSuffix("<CR>") { body = String(body.dropLast(4)) }
            let name = String(body.prefix(while: { $0.isLetter }))
            let known: [String: String] = [
                "w": "save", "write": "save", "q": "close", "quit": "close", "wq": "close", "x": "close",
                "noh": "clear search", "nohlsearch": "clear search", "reg": "registers", "marks": "marks",
            ]
            if let k = known[name], body == name { return k }
            return ":" + body
        }
        return rhs.count > 14 ? String(rhs.prefix(13)) + "…" : rhs
    }
}

public extension CommandLegend {
    /// Canvas keys (SPEC-PARTE2 §5b–6): `-` is the explorer everywhere;
    /// zoom lives on `+ = zi ⌘+`, `_ zo ⌘-`, fit on `0 zf`.
    static let canvasItems: [LegendItem] = [
        LegendItem("-", "explorer", .keys("-"), tip: "The floating explorer — `-` opens it everywhere, a canvas or board too"),
        LegendItem("+ = zi", "zoom in", .keys("+"), tip: "Zoom in: + = zi ⌘+ (pinch, ⌘-scroll)"),
        LegendItem("_ zo", "zoom out", .keys("_"), tip: "Zoom out: _ zo ⌘- (pinch, ⌘-scroll)"),
        LegendItem("0 zf", "fit", .keys("0"), tip: "Fit every node"),
        LegendItem("Tab", "next node", .keys("Tab")),
        LegendItem("hjkl", "pan"),
    ]

    /// Board keys in Reading / Edit: `-` is the explorer here too.
    static let boardItems: [LegendItem] = [
        LegendItem("-", "explorer", .keys("-"), tip: "The floating explorer — `-` opens it everywhere, a board too"),
        LegendItem("hjkl", "card / column"),
        LegendItem("HJKL", "move card"),
    ]
}
