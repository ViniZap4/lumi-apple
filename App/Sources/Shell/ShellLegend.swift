import SwiftUI
import LumiKit
import LumiUI

extension AppState {
    /// Where the keyboard is, for the command legend.
    var legendContext: LegendContext {
        if showHelp { return .help }
        if showPalette { return .palette }
        if explorer.pendingDelete != nil { return .confirm }
        if let prompt = explorer.prompt {
            if case .filter = prompt.kind { return .filter }
            return .prompt
        }
        if hoverCard?.keyboard == true { return .hover }
        if showFloatingExplorer { return floatingLevel == .books ? .books : .explorer }
        if let leaf = focusedSecondary {
            if paneView(leaf).isEditing {
                return preferences.vimEnabled ? (paneVim[leaf]?.legendContext ?? .normal) : .insert
            }
            return .reader
        }
        if focusedPane == .preview { return .preview }
        switch surface {
        case .empty: return .books
        case .explorer: return .home
        case .reader: return .reader
        case .editor: return preferences.vimEnabled ? liveVimStatus.legendContext : .insert
        }
    }

    /// The legend line's items for the current context and pending keys,
    /// in priority order (the line fits as many as the width allows).
    var legendItems: [LegendItem] {
        let ctx = legendContext
        switch ctx {
        case .explorer, .reader, .preview, .sidebar, .home, .hover, .books:
            var items = CommandLegend.shellItems(ctx, pending: shellPending, pane: ctx == .sidebar ? nil : paneLegendItem)
            if isSplit, ctx == .reader || ctx == .preview, shellPending.isEmpty {
                items.insert(zoomLegendItem, at: min(items.count, 8))
            }
            return items
        default:
            let s = focusedSecondary.flatMap { paneVim[$0] } ?? liveVimStatus
            let editor = surface == .editor && !showPalette && !showHelp
            let ed = focusedSecondary.flatMap { paneEditors[$0]?.value } ?? activeEditor
            if editor, ed?.paneKeys.awaitingWindowCommand == true {
                return CommandLegend.windowCommands
            }
            let extras = CommandLegend.Extras(
                leader: s.leader,
                leaderMaps: s.leaderMaps.map { LegendItem($0.keys, $0.rhs) },
                escapeSequences: s.escapeSequences,
                recording: s.recording,
                source: noteViewMode == .source && focusedSecondary == nil,
                split: splitPreviewShown && focusedSecondary == nil,
                pane: editor ? paneLegendItem : nil
            )
            var items = CommandLegend.items(ctx, pending: editor ? s.pending : VimPendingInfo(), extras: extras)
            if ctx == .normal, editor, isSplit { items.insert(zoomLegendItem, at: min(items.count, 9)) }
            if ctx == .insert, !preferences.vimEnabled {
                items = [LegendItem("⌘E", "reading", .app("reading")), LegendItem("⌘Z", "undo")]
            }
            return items
        }
    }

    private var zoomLegendItem: LegendItem {
        LegendItem("⌃w z", isZoomed ? "unzoom" : "zoom", .app("zoom"),
                   tip: "Zoom the pane to the whole note area and back (tmux prefix z) — also :zoom, double-click the header")
    }

    /// Pending keys to echo at the start of the legend (`"a2d`, `g`, `5`).
    var legendPending: String {
        switch legendContext {
        case .explorer, .reader, .preview, .sidebar, .home: return shellPending
        case .normal, .visual, .visualLine, .visualBlock, .operatorPending:
            let ed = focusedSecondary.flatMap { paneEditors[$0]?.value } ?? activeEditor
            if ed?.paneKeys.awaitingWindowCommand == true { return "^W" }
            return (focusedSecondary.flatMap { paneVim[$0] } ?? liveVimStatus).pending.display
        default: return ""
        }
    }

    /// Items for the floating explorer's footer: the navigation legend of
    /// whatever it is doing (files, books, filter, prompt, confirm).
    var floatingLegendItems: [LegendItem] {
        if explorer.pendingDelete != nil { return CommandLegend.items(.confirm) }
        if let prompt = explorer.prompt {
            if case .filter = prompt.kind { return CommandLegend.items(.filter) }
            return CommandLegend.items(.prompt)
        }
        if floatingLevel == .books { return CommandLegend.booksItems }
        return CommandLegend.shellItems(.explorer, pending: shellPending)
    }

    /// `3/12` in the floating explorer's footer.
    var floatingStat: String? {
        if floatingLevel == .books {
            let groups = bookGroups
            guard groups.indices.contains(booksGroupCursor) else { return nil }
            let n = groups[booksGroupCursor].books.count
            return n == 0 ? "0 books" : "\(min(booksCursor, n - 1) + 1)/\(n)"
        }
        let n = explorer.nav.entries.count
        return n == 0 ? "0 items" : "\(explorer.nav.cursor + 1)/\(n)"
    }

    /// A click on a legend item: the same as typing its keys.
    func runLegendAction(_ action: LegendAction) {
        switch action {
        case let .keys(keys):
            for stroke in Self.strokes(keys) { _ = handleShellKey(stroke) }
        case let .vim(notation):
            let ed = focusedSecondary.flatMap { paneEditors[$0]?.value } ?? activeEditor
            guard let ed, let inputs = VimInput.parse(notation: notation) else { return }
            ed.focusTextView()
            for i in inputs { ed.send(i) }
        case let .ex(command):
            if command == "q" { closeFocusedPane() } else { performHostCommand(command) }
        case let .app(id):
            switch id {
            case "vsplit": splitPane(.vertical)
            case "hsplit": splitPane(.horizontal)
            case "closePane": closeFocusedPane()
            case "onlyPane": onlyPane()
            case "equalPanes": performLayout(.equalize)
            case "zoom": toggleZoom()
            case "panes": _ = performPane(.next)
            case "explorer": openFloatingExplorer()
            case "books": openFloatingExplorer(level: .books)
            case "hints": startHints()
            case "settings": showSettings = true
            case "reading": setEditing(false)
            case "toggleMode": setNoteViewMode(noteViewMode == .live ? .source : .live)
            case "readPreview": focusPane(.preview)
            default: break
            }
        }
    }

    /// Legend key text → key strokes (`gg`, `⏎`, `Esc`, `⌃v`, ` `).
    static func strokes(_ keys: String) -> [KeyStroke] {
        switch keys {
        case "⏎": return [.key(.enter)]
        case "Esc": return [.key(.escape)]
        default: break
        }
        if keys.hasPrefix("⌃"), keys.count == 2 { return [.char(String(keys.last!), control: true)] }
        return keys.map { KeyStroke(String($0)) }
    }
}

/// The bottom legend line (web parity): fitted to the width, clickable,
/// "⋯" only when something is left out.
struct ShellLegendLine: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        LegendLine(items: appState.legendItems, pending: appState.legendPending) { appState.runLegendAction($0) }
            .padding(.horizontal, 12)
            .frame(height: ShellMetrics.legendHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(theme.background)
            .overlay(alignment: .top) { Hairline() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command legend")
    }
}

/// The floating explorer's footer: its own navigation legend with the
/// item count.
struct FloatingExplorerLegend: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        LegendLine(items: appState.floatingLegendItems, pending: appState.shellPending, stat: appState.floatingStat) {
            appState.runLegendAction($0)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Explorer keys")
    }
}
