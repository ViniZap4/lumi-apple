import Foundation

/// Where the keyboard is: decides which keys the command legend shows.
public enum LegendContext: String, Sendable, Hashable, CaseIterable {
    case explorer, reader
    case normal, insert, replace
    case visual, visualLine, visualBlock
    case operatorPending
    case commandLine, search
    case substituteConfirm
    case palette, prompt, confirm, filter, books, help
}

public struct LegendItem: Sendable, Hashable {
    public var keys: String
    public var label: String

    public init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
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

        public init(leader: String = "\\", leaderMaps: [LegendItem] = [], escapeSequences: [String] = [], recording: Character? = nil) {
            self.leader = leader
            self.leaderMaps = leaderMaps
            self.escapeSequences = escapeSequences
            self.recording = recording
        }
    }

    // MARK: Shell (explorer / reader)

    static let shellG: [LegendItem] = [
        .init("gg", "top"), .init("ge", "bottom"), .init("gh", "book root"), .init("g1–9", "book n"),
    ]
    static let shellZ: [LegendItem] = [.init("zp", "preview"), .init("zh", "book root")]

    /// Explorer / reader legend; `pending` is the shell keymap's pending
    /// keys (`g`, `z`, a count).
    public static func shellItems(_ ctx: LegendContext, pending: String = "") -> [LegendItem] {
        let digits = pending.prefix(while: { $0.isASCII && $0.isNumber })
        let chord = pending.dropFirst(digits.count)
        if chord == "g" { return shellG }
        if chord == "z" { return shellZ }
        if !digits.isEmpty {
            return ctx == .explorer
                ? [.init("\(digits)j", "down \(digits)"), .init("\(digits)k", "up \(digits)"), .init("Esc", "cancel")]
                : [.init("\(digits)j", "scroll \(digits)"), .init("\(digits)k", "scroll \(digits) up")]
        }
        if ctx == .explorer {
            return [
                .init("j k", "move"), .init("h l", "folder"), .init("⏎", "open"), .init("e", "edit"),
                .init("/", "filter"), .init("a", "new"), .init("r", "rename"), .init("d", "delete"),
                .init("y p", "copy"), .init("H L", "history"), .init("f", "hints"), .init("space", "commands"), .init("?", "keys"),
            ]
        }
        return [
            .init("j k", "scroll"), .init("d u", "half page"), .init("gg G", "top/end"), .init("e i", "edit"),
            .init("q h", "back"), .init("y", "copy"), .init("F", "hints"), .init("space", "commands"), .init("?", "keys"),
        ]
    }

    // MARK: Editor (vim)

    static let vimG: [LegendItem] = [
        .init("gg", "top"), .init("gj gk", "display line"), .init("ge", "word end back"), .init("g_", "last char"),
        .init("gu gU g~", "case"), .init("gv", "reselect"), .init("gJ", "join"), .init("gp gP", "put, after"),
        .init("gi", "insert again"), .init("g* g#", "search part"), .init("g&", ":s all lines"),
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
        case .explorer, .reader:
            return shellItems(ctx, pending: pending.display)
        default:
            break
        }

        if [.normal, .visual, .visualLine, .visualBlock, .operatorPending].contains(ctx), !pending.isEmpty {
            if let c = pendingItems(pending, extras: extras) { return c }
        }

        switch ctx {
        case .normal:
            var out: [LegendItem] = [
                .init("i a o", "insert"), .init("v V ^V", "visual"), .init("d c y", "cut/change/copy"),
                .init("p", "paste"), .init("u ^R", "undo/redo"), .init(".", "repeat"),
                .init("/ n", "search"), .init(":", "command"), .init("q @", "macro"),
            ]
            if let r = extras.recording { out.insert(.init("q", "stop recording @\(r)"), at: 0) }
            if !extras.leaderMaps.isEmpty { out.append(.init(displayLeader(extras.leader), "leader")) }
            return out
        case .insert:
            let esc = extras.escapeSequences.isEmpty ? "Esc" : "Esc " + extras.escapeSequences.joined(separator: " ")
            return [
                .init(esc, "normal"), .init("^W", "delete word"), .init("^U", "delete line"),
                .init("^R{r}", "paste register"), .init("^O", "one command"), .init("^T ^D", "indent"),
            ]
        case .replace:
            return [.init("Esc", "normal"), .init("⌫", "restore"), .init("^R{r}", "paste register")]
        case .visual, .visualLine:
            var out: [LegendItem] = [
                .init("y d c", "copy/cut/change"), .init("> <", "indent"), .init("~ u U", "case"),
                .init("iw ip i(", "select"), .init("o", "other end"), .init("J", "join"),
                .init(":", "range command"), .init("Esc", "normal"),
            ]
            if ctx == .visualLine { out.remove(at: 3) }
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
            return [.init("↑ ↓ ⌃n ⌃p", "select"), .init("⏎", "run"), .init("Esc", "close")]
        case .prompt:
            return [.init("⏎", "confirm"), .init("Esc", "cancel"), .init("a/b/name", "in folders"), .init("dir/", "folder")]
        case .filter:
            return [.init("⏎", "keep filter"), .init("↑ ↓", "move"), .init("Esc", "clear"), .init("n N", "next/prev (after ⏎)")]
        case .confirm:
            return [.init("y ⏎", "confirm"), .init("n Esc", "cancel")]
        case .books:
            return [.init("j k", "move"), .init("⏎ l", "open"), .init("g1–9", "book n"), .init("R", "refresh"), .init("Esc", "back")]
        case .help:
            return [.init("any key", "close")]
        case .explorer, .reader:
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
