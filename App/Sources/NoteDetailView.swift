import SwiftUI
import LumiKit
import LumiUI

struct NoteDetailView: View {
    let note: Note
    let baseURL: URL?
    let vaultRoot: URL

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var mode: Mode = .view

    enum Mode: Hashable { case view, edit }

    var body: some View {
        @Bindable var editor = appState.editor
        VStack(spacing: 0) {
            DetailToolbar(
                mode: $mode,
                editor: editor,
                onSave: { editor.save() },
                onReload: { editor.reloadFromDisk(vaultRoot: vaultRoot) },
                onForceSave: { editor.forceSave() },
                onDiscard: { editor.discard() }
            )
            Divider().background(theme.separator)
            content(editor: editor)
        }
        .background(theme.background)
        .navigationTitle(note.title)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func content(editor: EditorState) -> some View {
        switch mode {
        case .view:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(note.title)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if !note.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(note.tags, id: \.self) { tag in
                                TagChip(tag: tag)
                            }
                        }
                    }
                    let source = editor.isDirty ? editor.currentText : note.content
                    let document = MarkdownParser.parse(source, baseURL: baseURL)
                    MarkdownView(document)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .edit:
            PlainEditor(text: Binding(
                get: { editor.currentText },
                set: { editor.currentText = $0 }
            ))
        }
    }
}

private struct DetailToolbar: View {
    @Binding var mode: NoteDetailView.Mode
    let editor: EditorState
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
