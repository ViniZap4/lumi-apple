import Testing
import Foundation
@testable import LumiKit

@Suite("Shell keymap — pending keys for the legend")
struct ShellLegendPendingTests {
    @Test("count and chord prefixes are exposed, then cleared")
    func pending() {
        var k = ShellKeymap()
        #expect(k.pendingDisplay == "")
        _ = k.feed(.char("5"), context: .explorer, now: 0)
        #expect(k.pendingDisplay == "5")
        _ = k.feed(.char("j"), context: .explorer, now: 0)
        #expect(k.pendingDisplay == "")
        _ = k.feed(.char("g"), context: .explorer, now: 0)
        #expect(k.pendingDisplay == "g")
        #expect(CommandLegend.shellItems(.explorer, pending: k.pendingDisplay).map(\.keys).first == "gg")
        _ = k.feed(.char("g"), context: .explorer, now: 0.1)
        #expect(k.pendingDisplay == "")
    }
}

@Suite("Preferences — per-device vimrc")
@MainActor
struct VimrcPreferenceTests {
    @Test("saved next to apple.yaml, parsed, and reloaded")
    func persists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-vimrc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PreferencesStore(fileURL: dir.appendingPathComponent("apple.yaml"))
        let prefs = LumiPreferences(store: store)
        #expect(prefs.vimrc == "")
        prefs.vimrc = "let mapleader=\",\"\nnnoremap <leader>w :w<CR>\nfrob"
        #expect(prefs.parsedVimrc.maps.count == 1)
        #expect(prefs.parsedVimrc.diagnostics(forLine: 3).first?.severity == .error)
        let saved = try String(contentsOf: dir.appendingPathComponent("apple.vimrc"), encoding: .utf8)
        #expect(saved.hasPrefix("let mapleader"))
        let reloaded = LumiPreferences(store: PreferencesStore(fileURL: dir.appendingPathComponent("apple.yaml")))
        #expect(reloaded.parsedVimrc.leader == ",")
    }
}

@Suite("Legend — panes and preview")
struct PaneLegendTests {
    @Test("preview and sidebar contexts have their own lines")
    func contexts() {
        let preview = CommandLegend.shellItems(.preview).map(\.keys)
        #expect(preview.contains("{ }"))
        #expect(preview.contains("q ⌃h"))
        #expect(preview.last == "?")
        let sidebar = CommandLegend.shellItems(.sidebar).map(\.keys)
        #expect(sidebar.contains("⏎ l"))
        #expect(CommandLegend.items(.preview).map(\.keys) == preview)
    }

    @Test("^W pending shows the window commands; [ shows heading jumps")
    func chords() {
        #expect(CommandLegend.shellItems(.explorer, pending: "^W") == CommandLegend.windowCommands)
        #expect(CommandLegend.shellItems(.preview, pending: "[").map(\.keys) == ["[[", "]]"])
    }

    @Test("the pane hint lands before ?")
    func paneItem() {
        let items = CommandLegend.shellItems(.reader, pane: LegendItem("⌃h ⌃l", "panes"))
        #expect(items[items.count - 2] == LegendItem("⌃h ⌃l", "panes"))
        #expect(items.last?.keys == "?")
    }
}
