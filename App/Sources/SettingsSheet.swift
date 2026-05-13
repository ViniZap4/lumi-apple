import SwiftUI
import LumiKit

/// User preferences UI. Currently scoped to the vim-flavored navigation
/// toggles requested in F.1, but laid out so future toggles (autocorrect,
/// font size, autosave, etc.) drop into the same form without restructuring.
///
/// Opens via the toolbar gear icon. On macOS the standard Cmd+, keyboard
/// shortcut also opens it through `LumiApp.commands`.
struct SettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var prefs = appState.preferences

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("settings")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
            }

            section("vim navigation") {
                Toggle(isOn: $prefs.vimNavigationInList) {
                    settingRow(
                        title: "Vim keys in note list",
                        detail: "j/k move selection · l or ↩ opens · h collapses folders · gg / G jump to top / bottom"
                    )
                }
                Toggle(isOn: $prefs.jjEscapeMapping) {
                    settingRow(
                        title: "Map jj to escape in insert mode",
                        detail: "typing j j in quick succession exits insert (deletes the buffered j). useful when ESC is far from home row."
                    )
                }
                Toggle(isOn: $prefs.jkScrollInView) {
                    settingRow(
                        title: "j / k scroll in read mode",
                        detail: "while previewing a note, j scrolls down a line and k scrolls up."
                    )
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 320)
        .background(theme.background)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.overlayBackground)
            )
        }
    }

    private func settingRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.text)
            Text(detail)
                .font(.caption)
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
