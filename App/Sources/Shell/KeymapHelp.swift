import SwiftUI
import LumiUI

/// `?` overlay: the whole keymap on one card. Any key closes it.
struct KeymapHelpOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    static let sections: [(String, [(String, String)])] = [
        ("Explorer (floating)", [
            ("-  <leader>e  :explore", "open it (reader, editor, home)"), ("⌘\\  toolbar", "open it (mouse)"),
            ("j k  h l  gg G", "move / folders"), ("⏎", "open here"), ("⌃v  ⌃s", "open in split / stacked"),
            ("/  n N", "filter"), ("a r d  y p", "new, rename, delete, copy"), ("gb  h at the root", "books level"),
            ("⎋  q  click outside", "close (⎋ clears a filter first)"),
        ]),
        ("Links and preview", [
            ("gf  ⏎ on a link", "follow here"), ("⌃w f  ⌃w ⏎", "follow into a split"), ("⌃w F", "follow, stacked"),
            ("⌘-click  ⇧⌘-click", "split / stacked"), ("K", "hover card"), ("hover 350 ms", "hover card (mouse)"),
            ("card: j k d u", "scroll"), ("card: ⏎  ⌃w f/F", "open / split"), ("card: ⎋ q", "close"),
        ]),
        ("Note", [
            ("i  e  ⌘E", "edit (vim)"), ("⌥⌘L  ⌥⌘S", "Live / Source"), ("q", "close the pane / note"),
            ("j k  d u", "scroll"), ("gg  G", "top / bottom"), ("y", "copy selection"),
            (":q  :wq", "leave / close the pane"), ("\\p  :preview split", "preview beside source"),
        ]),
        ("Splits", [
            ("⌃w v  :vsplit [note]", "split side by side"), ("⌃w s  :split [note]", "split stacked"),
            ("⌃w q  :q  :close", "close pane"), ("⌃w o  :only", "only this pane"), ("⌃w =", "equal sizes"),
            ("⌃w < >  ⌃w + -", "narrower / wider, shorter / taller"), ("drag a divider", "resize"),
        ]),
        ("Panes", [
            ("⌃h ⌃j ⌃k ⌃l", "pane that way"), ("⌃w h j k l", "same, vim style"),
            ("⌃w w  ⌃w W", "next / previous pane"), ("⌃w p", "last pane"),
            ("click", "focus that pane"), ("insert mode", "⌃h ⌫  ⌃j newline"),
        ]),
        ("App", [
            ("space  :  ⌘K", "command palette"), ("gb  ⇧⌘B", "switch book"), ("[  ]", "previous / next book"),
            ("⌃1–9  g1–9", "book by number"), ("⌥⌘,", "book settings"), ("⌘,  :settings", "settings"),
            ("f  F", "hints: click by label"), ("?", "this help"),
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
        .background(ElevatedSurface())
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
