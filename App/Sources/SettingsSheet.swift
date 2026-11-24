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
                    // textDim was nearly invisible on light themes;
                    // dial up to 60 % text so the dismiss target is
                    // findable everywhere without screaming.
                    .foregroundStyle(theme.text.opacity(0.6))
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
                let isSelected = selected == section
                Button {
                    selected = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                            // Subtle accent treatment instead of fully-
                            // filled accent + theme.background text. The
                            // previous combo produced weak perceptual
                            // contrast on saturated-accent themes like
                            // tokyo-night (light-cyan accent + dark-navy
                            // text reads as a low-vibration pair even
                            // though the hex values pass a strict ratio).
                            .foregroundStyle(isSelected ? theme.accent : theme.text.opacity(0.75))
                        Text(section.label)
                            .font(.system(.body, design: .monospaced).weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? theme.accent : theme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? theme.accent.opacity(0.18) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isSelected ? theme.accent.opacity(0.45) : Color.clear, lineWidth: 0.5)
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
            // Subtitle moved from `theme.textDim` to dimmed `theme.text`
            // so the breadcrumb-style hint stays legible on light themes.
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(theme.text.opacity(0.65))
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
            pickerRow(
                title: "Reading font",
                detail: "Body font in the read pane. Editor stays monospaced.",
                selection: $prefs.readingFontFamily,
                options: LumiPreferences.ReadingFontFamily.allCases,
                label: { $0.label }
            )
            toggleRow(
                title: "Animate transitions",
                detail: "Short fades and slides between explorer, reader and editor, splits and overlays.",
                isOn: $prefs.contentAnimations
            )
            pickerRow(
                title: "Movimento",
                detail: "Completo: springs, overshoot and ambient light. Suave: the same moves, calmer. Reduzido: instant changes (also when the system's Reduce Motion is on).",
                selection: $prefs.motionLevel,
                options: MotionLevel.allCases,
                label: { $0.label }
            )
            pickerRow(
                title: "Largura de leitura",
                detail: "Text column of the reader, Live Preview and split preview. Total fills the pane.",
                selection: $prefs.readingMeasure,
                options: ReadingMeasure.allCases,
                label: { $0.label }
            )
            pickerRow(
                title: "Densidade",
                detail: "Row height in the explorer and lists.",
                selection: $prefs.density,
                options: ShellDensity.allCases,
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
            pickerRow(
                title: "Editing mode",
                detail: "Live Preview renders markdown as you type and shows the syntax only on the cursor's line; Source shows it all. :live / :source switch, and the last choice is kept.",
                selection: $prefs.editMode,
                options: LumiPreferences.EditMode.allCases,
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
                title: "Enable vim mode",
                detail: "Off turns the editor into a plain text field with system shortcuts and Writing Tools. On routes every keystroke through the vim engine.",
                isOn: $prefs.vimEnabled
            )
            toggleRow(
                title: "Block cursor in normal mode",
                detail: "The cursor follows the mode: block in normal and visual, half block while an operator waits, underline in replace, bar in insert. Off keeps a bar everywhere.",
                isOn: $prefs.vimBlockCursor
            )
            toggleRow(
                title: "Map jj to escape (insert)",
                detail: "Typing j j in quick succession exits insert and removes the buffered j.",
                isOn: $prefs.jjEscapeMapping
            )
            EscapeSequencesRow(prefs: appState.preferences)
            stepperRow(
                title: "Escape sequence timeout",
                detail: "How long the editor waits for the next key of a sequence.",
                value: Binding<Double>(
                    get: { Double(prefs.escapeTimeoutMs) },
                    set: { prefs.escapeTimeoutMs = Int($0) }
                ),
                in: Double(EscapeSequences.timeoutMinMs)...Double(EscapeSequences.timeoutMaxMs),
                step: 50,
                format: { "\(Int($0)) ms" }
            )
            toggleRow(
                title: "Wrap long lines",
                detail: "Soft wrap in the editor (vim's `wrap`). Off scrolls horizontally.",
                isOn: $prefs.lineWrapping
            )
            VimrcEditorRow(prefs: appState.preferences)
        }
    }

    @ViewBuilder
    private var navigationSection: some View {
        @Bindable var prefs = appState.preferences
        VStack(alignment: .leading, spacing: 14) {
            toggleRow(
                title: "Preview column",
                detail: "Render the note under the cursor in the explorer's third column (zp).",
                isOn: $prefs.explorerShowPreview
            )
            toggleRow(
                title: "Show hidden files",
                detail: "List dot-files and dot-folders in the explorer (.).",
                isOn: Binding(
                    get: { prefs.explorerShowHidden },
                    set: {
                        prefs.explorerShowHidden = $0
                        appState.explorer.setShowHidden($0)
                    }
                )
            )
            toggleRow(
                title: "j / k scroll in read mode",
                detail: "Hold to keep scrolling; ⌃d / ⌃u half-page; gg / G top / bottom.",
                isOn: $prefs.jkScrollInView
            )
            toggleRow(
                title: "⌃h ⌃j ⌃k ⌃l move between panes",
                detail: "Between split panes and the split preview by position, like vim windows and vim-tmux-navigator. In the editor: normal and visual mode only, unless your .vimrc maps the key. ⌃w h/j/k/l, ⌃w w and ⌃w p always work; ⌃w v / s split, ⌃w q closes, ⌃w o keeps one, ⌃w = equalises, ⌃w < > + - resize, ⌃w z zooms (tmux).",
                isOn: $prefs.ctrlHJKLPanes
            )
            toggleRow(
                title: "Hover link previews",
                detail: "Rest the pointer on a note link for a moment to see the note in a card (Open / Split). K on a link opens it from the keyboard either way; external links only show their address.",
                isOn: $prefs.hoverPreviews
            )
            toggleRow(
                title: "Leaving the preview moves the cursor",
                detail: "Back from the focused split preview (q, ⌃h), the editor cursor lands on the first line you were reading.",
                isOn: $prefs.previewReturnMovesCursor
            )
        }
    }

    @ViewBuilder
    private var chromeSection: some View {
        @Bindable var prefs = appState.preferences
        VStack(alignment: .leading, spacing: 14) {
            toggleRow(
                title: "Command legend",
                detail: "One line above the status bar with the keys that matter right now — explorer, reader, each vim mode, prompts — and the continuations while a key sequence is pending (g, z, d, \", counts, leader).",
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            // The description used to be `theme.textDim` which on every
            // dark theme sat just above the row background's overlay
            // tint — borderline unreadable in the screenshot the user
            // flagged. Bump to a dimmed `theme.text` so the explanation
            // text reads everywhere without competing with the title.
            Text(detail)
                .font(.caption)
                .foregroundStyle(theme.text.opacity(0.7))
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

/// Insert-mode escape sequences (`jk`, `ff`), same rules as the web.
private struct EscapeSequencesRow: View {
    @Bindable var prefs: LumiPreferences
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Escape sequences")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.text)
            Text("Keys typed quickly in insert mode that act as Esc (e.g. jk, ff). Up to \(EscapeSequences.maxCount).")
                .font(.caption)
                .foregroundStyle(theme.text.opacity(0.7))
            HStack(spacing: 6) {
                ForEach(prefs.escapeSequences, id: \.self) { seq in
                    HStack(spacing: 4) {
                        Text(seq).font(.system(.callout, design: .monospaced))
                        Button {
                            prefs.escapeSequences.removeAll { $0 == seq }
                        } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(theme.border, lineWidth: 0.5))
                }
                TextField("add…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit(add)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(theme.error)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.overlayBackground))
    }

    private func add() {
        switch EscapeSequences.validate(draft) {
        case let .success(v):
            if prefs.escapeSequences.count >= EscapeSequences.maxCount {
                error = "At most \(EscapeSequences.maxCount) sequences."
                return
            }
            if !prefs.escapeSequences.contains(v) { prefs.escapeSequences.append(v) }
            draft = ""
            error = nil
        case let .failure(e):
            error = e.message
        }
    }
}

/// Per-device `.vimrc` editor: live per-line diagnostics while typing,
/// applied to every editor on Save (web parity). The text is parsed by
/// `Vimrc` — a safe subset that never executes anything.
private struct VimrcEditorRow: View {
    @Bindable var prefs: LumiPreferences
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        let parsed = Vimrc.parse(draft)
        let dirty = draft != prefs.vimrc
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(".vimrc")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(dirty ? "unsaved" : "applied")
                    .font(.caption)
                    .foregroundStyle(dirty ? theme.warning : theme.textDim)
            }
            Text("Mappings (map, nnoremap, inoremap, vnoremap … unmap), let mapleader, and set number / relativenumber / wrap / expandtab / tabstop / shiftwidth. Parsed, never executed; saved on this device only.")
                .font(.caption)
                .foregroundStyle(theme.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 150, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.background))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 0.5))
            if !parsed.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(parsed.diagnostics.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("L\(d.line)")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(theme.textDim)
                                .frame(minWidth: 30, alignment: .trailing)
                            Text(d.severity.rawValue)
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .foregroundStyle(color(d.severity))
                            Text(d.message)
                                .font(.caption)
                                .foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Save") { prefs.vimrc = draft }
                    .disabled(!dirty)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Revert") { draft = prefs.vimrc }
                    .disabled(!dirty)
                Button("Insert example") { draft = Vimrc.example }
                    .disabled(!draft.isEmpty)
                Spacer()
                Text("\(parsed.maps.count) mapping\(parsed.maps.count == 1 ? "" : "s") · leader \(parsed.leader)\(parsed.errorCount > 0 ? " · \(parsed.errorCount) error\(parsed.errorCount == 1 ? "" : "s")" : "")")
                    .font(.caption)
                    .foregroundStyle(parsed.errorCount > 0 ? theme.error : theme.textDim)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.overlayBackground))
        .onAppear {
            if !loaded {
                draft = prefs.vimrc
                loaded = true
            }
        }
    }

    private func color(_ s: VimrcDiagnostic.Severity) -> Color {
        switch s {
        case .error: return theme.error
        case .warning: return theme.warning
        case .info: return theme.info
        }
    }
}
