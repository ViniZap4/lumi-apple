import SwiftUI
import LumiUI

/// `?` overlay: the whole keymap on one card. Any key closes it.
struct KeymapHelpOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    static let sections: [(String, [(String, String)])] = [
        ("Explore", [
            ("j k  ↓ ↑", "move"), ("h  ←  -", "up a folder"), ("l  →  ⏎", "open / enter"),
            ("gg  G", "top / bottom"), ("⌃d ⌃u", "half page"), ("5j", "count"),
            ("H  L", "folder history"), ("~  gh", "book root"),
            ("/", "filter in place"), ("n  N", "next / prev match"), ("⎋", "clear filter"),
        ]),
        ("Files", [
            ("a", "new note (a/b/name, dir/)"), ("r", "rename"), ("d", "delete (confirm)"),
            ("y  p", "yank / paste copy"), (".", "show hidden"), ("zp", "preview column"),
            ("R", "refresh"), ("⇧F10  right-click", "context menu"), ("drag", "note onto a folder: move"),
        ]),
        ("Note", [
            ("⏎  l", "read"), ("i  e  ⌘E", "edit (vim)"), ("q  h  ⎋", "back to explorer"),
            ("j k  d u", "scroll"), ("gg  G", "top / bottom"), ("y", "copy selection"),
            (":q  :wq", "leave the editor"), ("\\p  :preview split", "preview beside source"),
        ]),
        ("App", [
            ("space  :  ⌘K", "command palette"), ("[  ]", "previous / next book"),
            ("⌃1–9  g1–9", "book by number"), ("⌘\\", "sidebar"), ("⌥⌘,", "book settings"),
            ("⌘,  ,  :settings", "settings"), ("f  F", "hints: click by label"), ("?", "this help"),
        ]),
        ("Panes", [
            ("⌃h  ⌃l", "pane left / right"), ("⌃j  ⌃k", "pane down / up (narrow split)"),
            ("⌃h", "at the left edge: books"), ("⌃w h j k l", "same, vim style"),
            ("⌃w w  ⌃w W", "next / previous pane"), ("⌃w p", "last pane"),
            ("click", "focus that pane"), ("insert mode", "⌃h ⌫  ⌃j newline"),
        ]),
        ("Preview (focused)", [
            ("j k  d u  ␣ b", "scroll (editor follows)"), ("{ }  [[ ]]", "previous / next heading"),
            ("gg  G", "top / bottom"), ("/  n N", "find"), ("f", "links, boxes, copy"),
            ("⏎", "follow link at selection"), ("y", "copy selection"), ("q  ⎋  ⌃h  i", "back to the editor"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("keys")
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.text)
                Spacer()
                Text("any key to close")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 18) {
                GridRow {
                    section(Self.sections[0])
                    section(Self.sections[1])
                }
                GridRow {
                    section(Self.sections[2])
                    section(Self.sections[3])
                }
                GridRow {
                    section(Self.sections[4])
                    section(Self.sections[5])
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.background)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        )
        .onTapGesture { appState.showHelp = false }
    }

    private func section(_ s: (String, [(String, String)])) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(s.0.uppercased())
                .font(ShellFont.small)
                .foregroundStyle(theme.accent)
                .padding(.bottom, 2)
            ForEach(Array(s.1.enumerated()), id: \.offset) { _, kv in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(kv.0)
                        .font(ShellFont.chromeBold)
                        .foregroundStyle(theme.text)
                        .frame(width: 104, alignment: .leading)
                    Text(kv.1)
                        .font(ShellFont.chrome)
                        .foregroundStyle(theme.textDim)
                }
            }
        }
    }
}
