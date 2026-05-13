import SwiftUI
import LumiKit

/// Contextual key-hint strip pinned at the bottom of the window — same
/// idea as TUI's status bar / web's footer. Lists the most relevant
/// shortcuts for the current screen so users don't have to keep menus
/// open. Hidden via Preferences › Chrome › Keybinds bar.
struct KeybindsBar: View {
    let context: Context
    @Environment(\.theme) private var theme

    enum Context {
        case tree
        case noteView
        case noteEdit
    }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.label) { item in
                keyHint(item)
            }
            Spacer()
            Text("⌘, settings")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(theme.overlayBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    private var items: [KeyHint] {
        switch context {
        case .tree:
            return [
                .init(key: "j/k", label: "move"),
                .init(key: "l ↩", label: "open"),
                .init(key: "h ⎋", label: "back"),
                .init(key: "g/G", label: "top/bottom"),
                .init(key: "⌘O", label: "switcher"),
            ]
        case .noteView:
            return [
                .init(key: "j/k", label: "scroll"),
                .init(key: "⌃d/⌃u", label: "half-page"),
                .init(key: "g/G", label: "top/bottom"),
                .init(key: "⌘E", label: "edit"),
                .init(key: "⎋", label: "back"),
            ]
        case .noteEdit:
            return [
                .init(key: "i a o", label: "insert"),
                .init(key: "⎋", label: "normal"),
                .init(key: "h j k l", label: "move"),
                .init(key: "⌘S", label: "save"),
                .init(key: "⇧⌘E", label: "read"),
            ]
        }
    }

    @ViewBuilder
    private func keyHint(_ item: KeyHint) -> some View {
        HStack(spacing: 4) {
            Text(item.key)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(theme.background)
                .foregroundStyle(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(item.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
    }
}

private struct KeyHint {
    let key: String
    let label: String
}
