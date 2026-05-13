import SwiftUI
import LumiKit
import LumiUI

/// Two-pane settings: sections list on the left, current section's controls
/// on the right. Matches the macOS System Settings convention and gives
/// future sections room to grow without scrolling-through-everything.
struct SettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    enum Section: String, CaseIterable, Identifiable {
        case appearance, editor, vim, navigation, chrome
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .editor: return "Editor"
            case .vim: return "Vim"
            case .navigation: return "Navigation"
            case .chrome: return "Chrome"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintbrush.fill"
            case .editor: return "square.and.pencil"
            case .vim: return "command"
            case .navigation: return "rectangle.3.group"
            case .chrome: return "macwindow"
            }
        }
    }

    @State private var selected: Section = .appearance

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().background(theme.border)
            contentPane
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(theme.background)
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(theme.textDim)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(theme.primary)
                Text("settings")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(Section.allCases) { section in
                Button {
                    selected = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                            .foregroundStyle(selected == section ? theme.background : theme.textDim)
                        Text(section.label)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(selected == section ? theme.background : theme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected == section ? theme.accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 200, alignment: .topLeading)
        .background(theme.overlayBackground)
    }

    // MARK: - Content pane

    @ViewBuilder
    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader
                switch selected {
                case .appearance: appearanceSection
                case .editor: editorSection
                case .vim: vimSection
                case .navigation: navigationSection
                case .chrome: chromeSection
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selected.label.lowercased())
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(theme.textDim)
        }
        .padding(.bottom, 8)
    }

    private var headerSubtitle: String {
        switch selected {
        case .appearance: return "themes, colors, light/dark mode"
        case .editor: return "fonts, line numbers, syntax color, default open mode"
        case .vim: return "vim-style key bindings throughout the app"
        case .navigation: return "tree browser preview density"
        case .chrome: return "what's shown around the content — bars, badges"
        }
    }

    // MARK: - Sections
    //
    // Each section grabs @Bindable inside its own scope so the row-level
    // `$prefs.field` returns a real `Binding`. Trying to pass `Bindable<T>`
    // across function boundaries crosses the wires — Bindable is the
    // *property-wrapper* projection, not a Binding, and the row helpers
    // (Toggle, Picker, Stepper) need a concrete Binding<Field>.

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var prefs = appState.preferences
        @Bindable var bound = appState
        VStack(alignment: .leading, spacing: 14) {
            pickerRow(
                title: "Mode",
                detail: "Follow system uses your macOS appearance; explicit overrides the system.",
                selection: $prefs.themeMode,
                options: LumiPreferences.ThemeMode.allCases,
                label: { $0.label }
            )
            pickerRow(
                title: "Theme",
                detail: "Active theme palette. Shared with web and TUI clients.",
                selection: $bound.theme,
                options: LumiTheme.allCases,
                label: { $0.label }
            )
        }
    }

    @ViewBuilder
    private var editorSection: some View {
        @Bindable var prefs = appState.preferences
        VStack(alignment: .leading, spacing: 14) {
            pickerRow(
                title: "Default open mode",
                detail: "What mode a freshly-tapped note lands in.",
                selection: $prefs.defaultOpenMode,
                options: LumiPreferences.DefaultOpenMode.allCases,
                label: { $0.label }
            )
            stepperRow(
                title: "Editor font size",
                detail: "Body font size for both the editor and the read pane.",
                value: $prefs.editorFontSize,
                in: 11.0...22.0,
                step: 1.0,
                format: { String(format: "%.0f pt", $0) }
            )
            toggleRow(
                title: "Show line numbers",
                detail: "Gutter line numbers in the vim editor.",
                isOn: $prefs.showLineNumbers
            )
            toggleRow(
                title: "Relative line numbers",
                detail: "Vim's `relativenumber`. Useful for `10j` style jumps.",
                isOn: $prefs.relativeLineNumbers
            )
            toggleRow(
                title: "Markdown syntax color",
                detail: "Highlight headings, code, bold, links while editing.",
                isOn: $prefs.editorSyntaxColor
            )
        }
    }

    @ViewBuilder
    private var vimSection: some View {
        @Bindable var prefs = appState.preferences
        VStack(alignment: .leading, spacing: 14) {
            toggleRow(
                title: "Block cursor in normal mode",
                detail: "Tinted block over the character under the cursor, like terminal vim.",
                isOn: $prefs.vimBlockCursor
            )
            toggleRow(
                title: "Map jj to escape (insert)",
                detail: "Typing j j in quick succession exits insert and removes the buffered j.",
                isOn: $prefs.jjEscapeMapping
            )
            toggleRow(
                title: "Vim keys in note tree",
                detail: "j/k move · l or ↩ opens · h collapses · gg / G top / bottom.",
                isOn: $prefs.vimNavigationInList
            )
            toggleRow(
                title: "j / k scroll in read mode",
                detail: "Hold to keep scrolling; ⌃d / ⌃u half-page; g / G top / bottom.",
                isOn: $prefs.jkScrollInView
            )
        }
    }

    @ViewBuilder
    private var navigationSection: some View {
        @Bindable var prefs = appState.preferences
        VStack(alignment: .leading, spacing: 14) {
            stepperRow(
                title: "Preview body lines",
                detail: "Max lines shown in the three-column browser's preview pane.",
                value: Binding<Double>(
                    get: { Double(prefs.previewLines) },
                    set: { prefs.previewLines = Int($0) }
                ),
                in: 5.0...80.0,
                step: 5.0,
                format: { "\(Int($0)) lines" }
            )
        }
    }

    @ViewBuilder
    private var chromeSection: some View {
        @Bindable var prefs = appState.preferences
        VStack(alignment: .leading, spacing: 14) {
            toggleRow(
                title: "Keybinds bar",
                detail: "Contextual key hints along the bottom of the window — same idea as TUI's status bar.",
                isOn: $prefs.showKeybindsBar
            )
        }
    }

    // MARK: - Reusable rows

    @ViewBuilder
    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        rowContainer {
            HStack(alignment: .top) {
                settingLabel(title: title, detail: detail)
                Spacer(minLength: 12)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
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
        rowContainer {
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
        rowContainer {
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
    }

    @ViewBuilder
    private func rowContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.overlayBackground)
            )
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
