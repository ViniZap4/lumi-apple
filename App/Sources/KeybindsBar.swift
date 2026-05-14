import SwiftUI
import LumiKit

/// Contextual key-hint strip pinned at the bottom of the window — same
/// idea as TUI's status bar / web's footer. Lists the full set of
/// shortcuts for the current screen so users don't have to keep menus
/// open. Hidden via Preferences › Chrome › Keybinds bar.
///
/// The bindings overflow horizontally inside a scroll view so we can
/// list every command without truncating; the user can scroll the bar
/// itself with a trackpad swipe.
struct KeybindsBar: View {
    let context: Context
    @Environment(\.theme) private var theme

    enum Context {
        case tree
        case noteView
        case noteEdit
    }

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                        if idx > 0 {
                            Rectangle()
                                .fill(theme.border.opacity(0.6))
                                .frame(width: 1, height: 12)
                        }
                        HStack(spacing: 10) {
                            ForEach(group, id: \.label) { item in
                                keyHint(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.02),
                        .init(color: .black, location: 0.98),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            Text("⌘,")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.background.opacity(0.5))
                )
                .help("Settings (⌘,)")
                .padding(.trailing, 12)
        }
        .padding(.vertical, 6)
        .background(theme.overlayBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 0.5)
        }
    }

    /// Categorised binding groups. Each inner array is one category;
    /// the renderer draws a thin divider between them so the eye can
    /// scan by topic.
    private var groups: [[KeyHint]] {
        switch context {
        case .tree:
            return [
                [   // navigation
                    .init(key: "j/k", label: "move"),
                    .init(key: "l ↩", label: "open"),
                    .init(key: "h ⎋ ⌫", label: "back"),
                ],
                [   // jumps
                    .init(key: "gg", label: "top"),
                    .init(key: "G", label: "bottom"),
                ],
                [   // preview
                    .init(key: "J/K", label: "preview ↑↓"),
                ],
                [   // file ops
                    .init(key: "n", label: "new note"),
                    .init(key: "N", label: "new folder"),
                    .init(key: "r", label: "rename"),
                    .init(key: "d", label: "delete"),
                    .init(key: "D", label: "duplicate"),
                ],
                [   // app
                    .init(key: "⌘O", label: "switcher"),
                    .init(key: "⌘E", label: "edit"),
                    .init(key: "⌘D", label: "read/edit"),
                    .init(key: "⇧⌘H", label: "home"),
                ],
            ]
        case .noteView:
            return [
                [   // line scroll
                    .init(key: "j/k", label: "line"),
                    .init(key: "↑/↓", label: "line"),
                ],
                [   // page scroll
                    .init(key: "d/u", label: "half"),
                    .init(key: "⌃d/⌃u", label: "half"),
                    .init(key: "f/b", label: "page"),
                    .init(key: "⌃f/⌃b", label: "page"),
                    .init(key: "⌃t", label: "half ↓"),
                ],
                [   // jumps
                    .init(key: "g/⌃g", label: "top"),
                    .init(key: "G/⇧⌃g", label: "bottom"),
                ],
                [   // mode
                    .init(key: "⌘E", label: "edit"),
                    .init(key: "⌘D", label: "toggle"),
                    .init(key: "⎋ ⌫", label: "back"),
                ],
                [   // app
                    .init(key: "⌘O", label: "switcher"),
                    .init(key: "⇧⌘H", label: "home"),
                ],
            ]
        case .noteEdit:
            return [
                [   // modes
                    .init(key: "i/a", label: "insert"),
                    .init(key: "I/A", label: "ins line"),
                    .init(key: "o/O", label: "open line"),
                    .init(key: "⎋ / jj", label: "normal"),
                    .init(key: "v/V", label: "visual"),
                    .init(key: "r", label: "replace 1"),
                ],
                [   // movement — char
                    .init(key: "h j k l", label: "move"),
                    .init(key: "w b e", label: "word"),
                    .init(key: "0 ^ $", label: "line"),
                    .init(key: "gg/G", label: "doc"),
                ],
                [   // page scroll
                    .init(key: "⌃d/⌃u", label: "half pg"),
                    .init(key: "⌃f/⌃b", label: "page"),
                ],
                [   // operators
                    .init(key: "d c y", label: "del/chg/yank"),
                    .init(key: "p P", label: "paste"),
                    .init(key: "x", label: "del char"),
                    .init(key: "J", label: "join"),
                    .init(key: "~", label: "case"),
                ],
                [   // text objects
                    .init(key: "iw aw", label: "word"),
                    .init(key: "i\" a\"", label: "quote"),
                    .init(key: "i( a)", label: "paren"),
                    .init(key: "i[ a]", label: "bracket"),
                    .init(key: "i{ a}", label: "brace"),
                ],
                [   // find / search
                    .init(key: "f F t T", label: "find char"),
                    .init(key: "; ,", label: "repeat"),
                    .init(key: "/ ?", label: "search"),
                    .init(key: "n N", label: "next/prev"),
                    .init(key: "* #", label: "word"),
                ],
                [   // history / repeat
                    .init(key: "u", label: "undo"),
                    .init(key: "⌃r", label: "redo"),
                    .init(key: ".", label: "repeat"),
                ],
                [   // marks / registers / macros
                    .init(key: "m`", label: "mark"),
                    .init(key: "'`", label: "jump"),
                    .init(key: "\"a", label: "register"),
                    .init(key: "q @", label: "macro"),
                ],
                [   // ex
                    .init(key: ":w", label: "save"),
                    .init(key: ":q", label: "close"),
                    .init(key: ":wq", label: "save+close"),
                    .init(key: ":noh", label: "no-hl"),
                ],
                [   // app
                    .init(key: "⌘S", label: "save"),
                    .init(key: "⇧⌘E", label: "read"),
                    .init(key: "⌘D", label: "toggle"),
                ],
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
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct KeyHint {
    let key: String
    let label: String
}
