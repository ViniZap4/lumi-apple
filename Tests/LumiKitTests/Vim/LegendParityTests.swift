import Foundation
import Testing
@testable import LumiKit

/// The Mac legend against the web's (`web-client/src/lib/legend.ts`):
/// same fitting algorithm, same contexts, same priority order. The web
/// tables are copied here; keys the Mac does not have are listed with
/// the reason, and Mac-only extras are allowed only where noted.
@Suite("Command legend — web parity")
struct LegendParityTests {
    // MARK: fitLegend

    @Test("everything fits: all shown, no overflow")
    func fitsAll() {
        let r = CommandLegend.fit(widths: [40, 50, 60], available: 200, gap: 10, reserve: 12)
        #expect(r.shown == [0, 1, 2] && !r.overflow)
        // Exactly the room: 40 + 50 + 60 + 2·10 = 170.
        #expect(CommandLegend.fit(widths: [40, 50, 60], available: 170, gap: 10).shown == [0, 1, 2])
    }

    @Test("overflow keeps priority order, skips a wide item, keeps the marker's room")
    func greedy() {
        // room = 150 - 12 - 10 = 128: 40, (+10+90 no), +10+30 = 80, +10+30 = 120.
        let r = CommandLegend.fit(widths: [40, 90, 30, 30, 30], available: 150, gap: 10, reserve: 12)
        #expect(r.shown == [0, 2, 3] && r.overflow)
        // Nothing fits at all.
        let none = CommandLegend.fit(widths: [300], available: 100, gap: 10, reserve: 12)
        #expect(none.shown.isEmpty && none.overflow)
        #expect(CommandLegend.fit(widths: [], available: 10, gap: 10).shown.isEmpty)
    }

    // MARK: Context tables

    /// Web keys, in web order.
    static let web: [String: [String]] = [
        "float": ["j k", "h l", "⏎", "⌃v", "⌃s", "/", "a r d", "y p", "Esc q", "f", "gb", "e", "⇧F10", "gg G", "H L", ".", "zp"],
        "books": ["j k", "⏎ l", "h", "g1–9", "a", "gh", "R", "Esc q"],
        "hover": ["j k", "⏎", "⌃w f", "⌃w F", "Esc"],
        "paneW": ["v", "s", "h j k l", "q", "o", "=", "f ⏎", "F", "w", "p", "< > + -", "Esc"],
        "home": ["-", "a", "j k", "gb", "[ ]", "space", "?", "F", "H L", ":", "R", ","],
        "reader": ["j k", "d u", "- h", "e i", "gg G", "q", "⌃w v", "K", "gf", "H L", "y", "F", "space", "?", "a r",
                   "gb", "⌘E", ":", "[ ]", ","],
        "preview": ["j k", "d u", "{ }", "/", "f", "q ⌃h", "y", "gg G", "n N", "⏎ gf", "K", "-", "space b", "⌃w w"],
        "insert": ["Esc", "[[", "⌘K", "⌘V", "⌃w", "⌃u", "⌃o", "⌘E"],
        "visual": ["y d c", "> <", "~ u U", "⌘K", "Esc", "o", "iw ip", "J", ":"],
        "normal": ["i a o", "v V", "dd yy p", "u ⌃r", "/ n", "\\l", "- \\e", ":q", "gf K", "⌃w v", "⌘E", "ciw", ".",
                   ">> <<", "* #", "za", "gg G", "ma 'a", "\"a", "zz", "⌘⇧E", ":"],
    ]

    /// Web keys the Mac spells differently (web → Mac).
    static let renamed: [String: String] = [
        "- h": "-", "- \\e": "-", "⌘⇧E": "⌥⌘L ⌥⌘S", ",": "⌘,", "space b": "space",
    ]

    /// Web keys with no Mac binding, per context (and why).
    static let notOnMac: [String: Set<String>] = [
        "float": ["⇧F10"],                 // the context-menu key: right-click on the Mac
        "books": ["g1–9", "a", "gh", "R"],   // the Mac books level has no jump / create / refresh keys
        "reader": ["a r"],                  // create / rename live in the explorer on the Mac
        "insert": ["⌘K", "⌘V"],            // web-only link helpers
        "visual": ["⌘K"],
        "normal": ["\\l", "za"],           // web leader link; no folds on the Mac
    ]

    /// Per-context spellings that differ (web → Mac).
    static let renamedIn: [String: [String: String]] = [
        "hover": ["Esc": "Esc q"],
    ]

    static func mac(_ ctx: String) -> [String] {
        switch ctx {
        case "float": return CommandLegend.floatItems.map(\.keys)
        case "books": return CommandLegend.booksItems.map(\.keys)
        case "hover": return CommandLegend.hoverItems.map(\.keys)
        case "paneW": return CommandLegend.windowCommands.map(\.keys)
        case "home": return CommandLegend.shellItems(.home).map(\.keys)
        case "reader": return CommandLegend.shellItems(.reader).map(\.keys)
        case "preview": return CommandLegend.shellItems(.preview).map(\.keys)
        case "insert": return CommandLegend.items(.insert).map(\.keys)
        case "visual": return CommandLegend.items(.visual).map(\.keys)
        case "normal": return CommandLegend.items(.normal).map(\.keys)
        default: return []
        }
    }

    @Test("every web item the Mac supports is in the Mac legend, in the web's order", arguments: Array(web.keys).sorted())
    func parity(_ ctx: String) {
        let mac = Self.mac(ctx)
        let skip = Self.notOnMac[ctx] ?? []
        let expected = Self.web[ctx]!.filter { !skip.contains($0) }.map { Self.renamedIn[ctx]?[$0] ?? Self.renamed[$0] ?? $0 }
        var at = 0
        for k in expected {
            guard let i = mac[at...].firstIndex(of: k) else {
                Issue.record("\(ctx): \(k) missing or out of order — mac: \(mac)")
                return
            }
            at = i + 1
        }
        // Mac-only extras stay a minority: the line reads like the web's.
        #expect(mac.count <= expected.count + 6, "\(ctx): \(mac.count) vs \(expected.count)")
    }

    @Test("clickable items carry actions; the Mac adds ⌃w z")
    func actions() {
        #expect(CommandLegend.windowCommands.first { $0.keys == "z" }?.action == .app("zoom"))
        #expect(CommandLegend.shellItems(.reader).first?.action == .keys("j"))
        #expect(CommandLegend.items(.normal).first?.action == .vim("i"))
        #expect(CommandLegend.floatItems.first { $0.keys == "⌃v" }?.action == .keys("⌃v"))
        // Pending completions still come first.
        #expect(CommandLegend.shellItems(.reader, pending: "^W").map(\.keys) == CommandLegend.windowCommands.map(\.keys))
        #expect(CommandLegend.shellItems(.preview, pending: "g").map(\.keys) == ["gg"])
        #expect(CommandLegend.shellItems(.preview, pending: "3").map(\.keys) == ["3j", "3}", "Esc"])
    }

    @Test("Source mode adds the preview key; split + panes the read-preview key")
    func normalExtras() {
        let plain = CommandLegend.items(.normal).map(\.keys)
        let source = CommandLegend.items(.normal, extras: .init(source: true)).map(\.keys)
        #expect(!plain.contains("\\p") && source.contains("\\p"))
        let split = CommandLegend.items(.normal, extras: .init(source: true, split: true, pane: LegendItem("⌃h ⌃l", "panes"))).map(\.keys)
        #expect(split.contains("⌃l") && split.contains("⌥⌘P"))
    }
}
