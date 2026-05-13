import SwiftUI
import LumiKit
import LumiUI

/// User preferences. Sections roughly mirror the TUI's `view_config`:
/// Appearance, Editor, Vim, Navigation. Each toggle binds straight to
/// LumiPreferences; values persist to UserDefaults as they change.
struct SettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var prefs = appState.preferences
        @Bindable var bound = appState

        VStack(spacing: 0) {
            header
            Divider().background(theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appearanceSection(themeBinding: $bound.theme)
                    editorSection(
                        defaultOpenMode: $prefs.defaultOpenMode,
                        editorFontSize: $prefs.editorFontSize,
                        showLineNumbers: $prefs.showLineNumbers,
                        relativeLineNumbers: $prefs.relativeLineNumbers,
                        editorSyntaxColor: $prefs.editorSyntaxColor
                    )
                    vimSection(
                        vimBlockCursor: $prefs.vimBlockCursor,
                        jjEscapeMapping: $prefs.jjEscapeMapping,
                        vimNavigationInList: $prefs.vimNavigationInList,
                        jkScrollInView: $prefs.jkScrollInView
                    )
                    navigationSection(previewLines: $prefs.previewLines)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(theme.background)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(theme.primary)
            Text("settings")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.overlayBackground)
    }

    // MARK: - Appearance

    @ViewBuilder
    private func appearanceSection(themeBinding: Binding<LumiTheme>) -> some View {
        sectionContainer(title: "appearance", icon: "paintbrush.fill") {
            VStack(alignment: .leading, spacing: 12) {
                pickerRow(
                    title: "Theme",
                    detail: "12 built-in themes shared with the web and TUI clients.",
                    selection: themeBinding,
                    options: LumiTheme.allCases,
                    label: { $0.label }
                )
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorSection(
        defaultOpenMode: Binding<LumiPreferences.DefaultOpenMode>,
        editorFontSize: Binding<Double>,
        showLineNumbers: Binding<Bool>,
        relativeLineNumbers: Binding<Bool>,
        editorSyntaxColor: Binding<Bool>
    ) -> some View {
        sectionContainer(title: "editor", icon: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 12) {
                pickerRow(
                    title: "Default open mode",
                    detail: "What mode a freshly-tapped note lands in.",
                    selection: defaultOpenMode,
                    options: LumiPreferences.DefaultOpenMode.allCases,
                    label: { $0.label }
                )
                stepperRow(
                    title: "Editor font size",
                    detail: "Body font size for both the editor and the read pane.",
                    value: editorFontSize,
                    in: 11.0...22.0,
                    step: 1.0,
                    format: { String(format: "%.0f pt", $0) }
                )
                toggleRow(
                    title: "Show line numbers",
                    detail: "Gutter line numbers in the vim editor.",
                    isOn: showLineNumbers
                )
                toggleRow(
                    title: "Relative line numbers",
                    detail: "Vim's `relativenumber`. Useful for `10j` style jumps.",
                    isOn: relativeLineNumbers
                )
                toggleRow(
                    title: "Markdown syntax color in editor",
                    detail: "Highlight headings, code, bold, links while editing.",
                    isOn: editorSyntaxColor
                )
            }
        }
    }

    // MARK: - Vim

    @ViewBuilder
    private func vimSection(
        vimBlockCursor: Binding<Bool>,
        jjEscapeMapping: Binding<Bool>,
        vimNavigationInList: Binding<Bool>,
        jkScrollInView: Binding<Bool>
    ) -> some View {
        sectionContainer(title: "vim", icon: "command") {
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(
                    title: "Block cursor in normal mode",
                    detail: "Tinted block over the character under the cursor, like in terminal vim.",
                    isOn: vimBlockCursor
                )
                toggleRow(
                    title: "Map jj to escape (insert mode)",
                    detail: "Typing j j in quick succession exits insert and removes the buffered j.",
                    isOn: jjEscapeMapping
                )
                toggleRow(
                    title: "Vim keys in note list",
                    detail: "j/k move · l or ↩ opens · h collapses · gg / G top / bottom.",
                    isOn: vimNavigationInList
                )
                toggleRow(
                    title: "j / k scroll in read mode",
                    detail: "Hold to keep scrolling; ⌃d / ⌃u half-page; g / G top / bottom.",
                    isOn: jkScrollInView
                )
            }
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private func navigationSection(previewLines: Binding<Int>) -> some View {
        sectionContainer(title: "navigation", icon: "rectangle.3.group") {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow(
                    title: "Preview body lines",
                    detail: "Max lines shown in the three-column browser's preview pane.",
                    value: Binding<Double>(
                        get: { Double(previewLines.wrappedValue) },
                        set: { previewLines.wrappedValue = Int($0) }
                    ),
                    in: 5.0...80.0,
                    step: 5.0,
                    format: { "\(Int($0)) lines" }
                )
            }
        }
    }

    // MARK: - Section container

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .textCase(.uppercase)
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.overlayBackground)
                )
        }
    }

    // MARK: - Reusable rows

    @ViewBuilder
    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            settingLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private func pickerRow<Value: Hashable & Identifiable, S: Sequence>(
        title: String,
        detail: String,
        selection: Binding<Value>,
        options: S,
        label: @escaping (Value) -> String
    ) -> some View where S.Element == Value {
        HStack(alignment: .top) {
            settingLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(Array(options)) { opt in
                    Text(label(opt)).tag(opt)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private func stepperRow(
        title: String,
        detail: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(alignment: .top) {
            settingLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            Stepper(value: value, in: range, step: step) {
                Text(format(value.wrappedValue))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .frame(minWidth: 90, alignment: .trailing)
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func settingLabel(title: String, detail: String) -> some View {
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

private extension LumiTheme {
    /// Friendly display label for the theme menu picker. Title-cases the
    /// underlying slug (e.g. "tokyo-night" → "Tokyo night").
    var label: String {
        rawValue
            .replacingOccurrences(of: "-", with: " ")
            .capitalizedFirst()
    }
}

private extension String {
    func capitalizedFirst() -> String {
        guard let first = self.first else { return self }
        return first.uppercased() + dropFirst()
    }
}

