import SwiftUI
import LumiKit
import LumiUI

struct NoteDetailView: View {
    let entry: NoteEntry
    let baseURL: URL?
    let vaultRoot: URL

    /// Display title: prefer the editor's parsed frontmatter title when
    /// available, fall back to the filename-derived NoteEntry.title.
    private var displayTitle: String {
        appState.editor.frontmatter.title ?? entry.title
    }

    private var displayTags: [String] {
        appState.editor.frontmatter.tags
    }

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var mode: Mode = .view
    @State private var vimMode: VimMode = .normal

    enum Mode: Hashable { case view, edit }

    var body: some View {
        @Bindable var editor = appState.editor
        VStack(spacing: 0) {
            DetailToolbar(
                mode: $mode,
                editor: editor,
                vimMode: vimMode,
                onSave: { editor.save() },
                onReload: { editor.reloadFromDisk(vaultRoot: vaultRoot) },
                onForceSave: { editor.forceSave() },
                onDiscard: { editor.discard() }
            )
            Divider().background(theme.separator)
            content(editor: editor)
        }
        .background(theme.background)
        .navigationTitle(displayTitle)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func content(editor: EditorState) -> some View {
        switch mode {
        case .view:
            ReadModeScroll(jkEnabled: appState.preferences.jkScrollInView) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(displayTitle)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if !displayTags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(displayTags, id: \.self) { tag in
                                TagChip(tag: tag)
                            }
                        }
                    }
                    let document = MarkdownParser.parse(editor.currentText, baseURL: baseURL)
                    MarkdownView(document)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .edit:
            VimEditor(
                text: Binding(
                    get: { editor.currentText },
                    set: { editor.currentText = $0 }
                ),
                onModeChange: { vimMode = $0 },
                onEffect: { effect in
                    handleVimEffect(effect, editor: editor)
                },
                jjEscapeEnabled: appState.preferences.jjEscapeMapping
            )
            .overlay(alignment: .top) {
                editModeStripe
            }
        }
    }

    /// Thin colored stripe along the top of the editor area. Color reflects
    /// the active vim mode so the user always knows what keys will do at a
    /// glance — green for normal, blue for insert, amber for visual, accent
    /// for command-line. Subtle but always visible.
    @ViewBuilder
    private var editModeStripe: some View {
        Rectangle()
            .fill(editModeColor)
            .frame(height: 3)
    }

    private var editModeColor: Color {
        switch vimMode {
        case .insert: return theme.primary
        case .visual: return theme.warning
        case .commandLine: return theme.accent
        case .normal: return theme.info
        }
    }

    private func handleVimEffect(_ effect: VimEffect, editor: EditorState) {
        switch effect {
        case .save(force: false):
            editor.save()
        case .save(force: true):
            editor.forceSave()
        case .saveAndClose(let force):
            if force { editor.forceSave() } else { editor.save() }
            // Only switch to view when the save settled cleanly (not in a
            // conflict). Non-force :wq with a conflict keeps the user in edit
            // so they can resolve it.
            if case .conflict = editor.status {
                return
            }
            mode = .view
        case .close(force: false):
            // Vim's :q refuses to quit a dirty buffer. Mirror that by staying
            // in edit mode; the user can :q! to discard or :w to save first.
            if !editor.isDirty {
                mode = .view
            }
        case .close(force: true):
            editor.discard()
            mode = .view
        }
    }
}

private struct DetailToolbar: View {
    @Binding var mode: NoteDetailView.Mode
    let editor: EditorState
    let vimMode: VimMode
    let onSave: () -> Void
    let onReload: () -> Void
    let onForceSave: () -> Void
    let onDiscard: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $mode) {
                    Image(systemName: "doc.text").tag(NoteDetailView.Mode.view)
                    Image(systemName: "square.and.pencil").tag(NoteDetailView.Mode.edit)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                if mode == .edit {
                    VimModeBadge(vimMode: vimMode)
                }

                Spacer()

                StatusLabel(editor: editor)

                Button(action: onSave) {
                    Label("Save", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty)
                .foregroundStyle(editor.isDirty ? theme.primary : theme.textDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if case .conflict = editor.status {
                ConflictBanner(
                    onReload: onReload,
                    onForceSave: onForceSave,
                    onDiscard: onDiscard
                )
            } else if case let .error(message) = editor.status {
                ErrorBanner(message: message)
            }
        }
    }
}

/// macOS-focused scroll container that supports `j` / `k` keyboard scrolling
/// when the host enables it via preferences. iOS falls back to a plain
/// ScrollView with no key intercept (tap/drag/scroll wheel still work
/// everywhere).
///
/// `anchorFraction` tracks the desired top-of-view position as a 0…1 fraction
/// of the content's height. `j` and `k` nudge it; `gg` / `G` jump to the
/// edges. SwiftUI's `ScrollViewProxy.scrollTo(_:anchor:)` is the only knob we
/// have on stock ScrollView, so we ride that — it's approximate but feels
/// right at the reading granularity we care about.
private struct ReadModeScroll<Content: View>: View {
    let jkEnabled: Bool
    @ViewBuilder let content: () -> Content

    /// Step size as a fraction of content height per j/k press. Small enough
    /// that holding the key produces smooth-ish movement; big enough that a
    /// few presses traverse a typical note.
    private let stepFraction: CGFloat = 0.05

    @State private var anchorFraction: CGFloat = 0
    @FocusState private var scrollFocused: Bool

    var body: some View {
        #if os(macOS)
        ScrollViewReader { proxy in
            ScrollView {
                content()
                    .id("readContent")
            }
            .focusable()
            .focused($scrollFocused)
            .onAppear { if jkEnabled { scrollFocused = true } }
            .onKeyPress(phases: .down) { press in
                guard jkEnabled else { return .ignored }
                switch press.characters {
                case "j":
                    nudge(by: stepFraction, proxy: proxy)
                    return .handled
                case "k":
                    nudge(by: -stepFraction, proxy: proxy)
                    return .handled
                case "g":
                    anchorFraction = 0
                    withAnimation { proxy.scrollTo("readContent", anchor: .top) }
                    return .handled
                case "G":
                    anchorFraction = 1
                    withAnimation { proxy.scrollTo("readContent", anchor: .bottom) }
                    return .handled
                default:
                    return .ignored
                }
            }
        }
        #else
        ScrollView { content() }
        #endif
    }

    #if os(macOS)
    private func nudge(by delta: CGFloat, proxy: ScrollViewProxy) {
        anchorFraction = max(0, min(1, anchorFraction + delta))
        withAnimation(.linear(duration: 0.08)) {
            proxy.scrollTo("readContent", anchor: UnitPoint(x: 0, y: anchorFraction))
        }
    }
    #endif
}

private struct VimModeBadge: View {
    let vimMode: VimMode
    @Environment(\.theme) private var theme

    var body: some View {
        let (label, fg, bg) = parts(for: vimMode)
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
            )
            .foregroundStyle(fg)
    }

    private func parts(for mode: VimMode) -> (String, Color, Color) {
        switch mode {
        case .normal:
            return (vimMode.label, theme.background, theme.accent)
        case .insert:
            return (vimMode.label, theme.background, theme.primary)
        case .visual:
            return (vimMode.label, theme.background, theme.warning)
        case .commandLine:
            return (vimMode.label, theme.background, theme.accent)
        }
    }
}

private struct StatusLabel: View {
    let editor: EditorState
    @Environment(\.theme) private var theme

    var body: some View {
        let (icon, text, color) = labelParts(for: editor)
        return HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text)
                .font(.system(.caption2, design: .monospaced))
        }
        .foregroundStyle(color)
    }

    private func labelParts(for editor: EditorState) -> (icon: String?, text: String, color: Color) {
        if editor.isDirty {
            return ("circle.fill", "modified", theme.warning)
        }
        switch editor.status {
        case .saved:
            return ("checkmark.circle", "saved", theme.info)
        case .saving:
            return ("arrow.up.doc", "saving…", theme.textDim)
        case .conflict:
            return ("exclamationmark.triangle", "external change", theme.error)
        case .error:
            return ("xmark.circle", "error", theme.error)
        case .idle, .loaded:
            return (nil, "", theme.textDim)
        }
    }
}

private struct ConflictBanner: View {
    let onReload: () -> Void
    let onForceSave: () -> Void
    let onDiscard: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.error)
            Text("file changed on disk since last load")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
            Spacer()
            Button("Reload", action: onReload).buttonStyle(.borderless)
            Button("Overwrite", action: onForceSave).buttonStyle(.borderless)
            Button("Discard", action: onDiscard).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.overlayBackground)
    }
}

private struct ErrorBanner: View {
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.error)
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.overlayBackground)
    }
}

private struct TagChip: View {
    let tag: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(tag)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(theme.overlayBackground)
                    .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
            )
            .foregroundStyle(theme.accent)
    }
}

struct NoteDetailEmpty: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.textDim)
            Text("select a note")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
