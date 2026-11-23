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
        switch surface {
        case .empty: return .books
        case .explorer: return .explorer
        case .reader: return .reader
        case .editor: return preferences.vimEnabled ? liveVimStatus.legendContext : .insert
        }
    }

    /// The legend line's items for the current context and pending keys.
    var legendItems: [LegendItem] {
        let ctx = legendContext
        switch ctx {
        case .explorer, .reader:
            return CommandLegend.shellItems(ctx, pending: shellPending)
        default:
            let s = liveVimStatus
            let editor = surface == .editor && !showPalette && !showHelp
            let extras = CommandLegend.Extras(
                leader: s.leader,
                leaderMaps: s.leaderMaps.map { LegendItem($0.keys, $0.rhs) },
                escapeSequences: s.escapeSequences,
                recording: s.recording
            )
            var items = CommandLegend.items(ctx, pending: editor ? s.pending : VimPendingInfo(), extras: extras)
            if ctx == .normal, editor { items.append(LegendItem("⌘E", "reading")) }
            if ctx == .insert, !preferences.vimEnabled { items = [LegendItem("⌘E", "reading"), LegendItem("⌘Z", "undo")] }
            return items
        }
    }

    /// Pending keys to echo at the start of the legend (`"a2d`, `g`, `5`).
    var legendPending: String {
        switch legendContext {
        case .explorer, .reader: return shellPending
        case .normal, .visual, .visualLine, .visualBlock, .operatorPending:
            return liveVimStatus.pending.display
        default: return ""
        }
    }
}

/// One compact line of the keys that matter right now (which-key style
/// while a sequence is pending). Display only: no buttons, no focus, no
/// hit testing — it can never take a keystroke from the editor.
struct ShellLegendLine: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let items = appState.legendItems
        let pending = appState.legendPending
        HStack(spacing: 14) {
            if !pending.isEmpty {
                Text(pending)
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent))
                    .fixedSize()
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Text(item.keys)
                        .font(ShellFont.chromeBold)
                        .foregroundStyle(theme.accent)
                    Text(item.label)
                        .font(ShellFont.small)
                        .foregroundStyle(theme.textDim)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: ShellMetrics.legendHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(theme.background)
        .overlay(alignment: .top) { Hairline() }
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command legend")
    }
}
