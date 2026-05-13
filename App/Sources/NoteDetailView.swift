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

    @State private var vimMode: VimMode = .normal

    /// Read-vs-edit toggle is hoisted to AppState so the global toolbar
    /// renders the picker alongside theme/settings/etc. Local binding so
    /// the existing view code below reads `mode` as before.
    private var mode: NoteDisplayMode {
        appState.editorMode
    }

    var body: some View {
        @Bindable var editor = appState.editor
        VStack(spacing: 0) {
            // Slim status bar (no mode picker — that's hoisted to the
            // RootView toolbar so it sits next to the theme/settings/etc.
            // buttons). Keeps save/conflict status close to the content.
            DetailStatusBar(
                editor: editor,
                vimMode: vimMode,
                inEditMode: mode == .edit,
                onSave: { editor.save() },
                onReload: { editor.reloadFromDisk(vaultRoot: vaultRoot) },
                onForceSave: { editor.forceSave() },
                onDiscard: { editor.discard() }
            )
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
                MarkdownReader(
                    title: displayTitle,
                    tags: displayTags,
                    text: editor.currentText,
                    baseURL: baseURL
                )
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
            appState.editorMode = .view
        case .close(force: false):
            // Vim's :q refuses to quit a dirty buffer. Mirror that by staying
            // in edit mode; the user can :q! to discard or :w to save first.
            if !editor.isDirty {
                appState.editorMode = .view
            }
        case .close(force: true):
            editor.discard()
            appState.editorMode = .view
        }
    }
}

/// Compact status bar inside the note pane. Shows the vim-mode badge when
/// editing, the editor status (modified / saved / conflict / error), and
/// a Cmd-S save button. Mode toggle is *not* here — it lives in the global
/// toolbar so all chrome is centralized at the top of the window.
private struct DetailStatusBar: View {
    let editor: EditorState
    let vimMode: VimMode
    let inEditMode: Bool
    let onSave: () -> Void
    let onReload: () -> Void
    let onForceSave: () -> Void
    let onDiscard: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if inEditMode {
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
            .padding(.vertical, 6)
            .background(theme.background)

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

/// Renders the parsed markdown document for read-mode. Memoizes the parse
/// step so each scroll/repaint doesn't re-parse the whole note — for large
/// notes the parser is the dominant cost. We key the cache on the raw text
/// string; SwiftUI calls `body` whenever editor.currentText flips, so the
/// `.onChange` reruns the parser only then.
private struct MarkdownReader: View {
    let title: String
    let tags: [String]
    let text: String
    let baseURL: URL?
    @Environment(\.theme) private var theme
    @State private var parsed: MarkdownDocument?
    @State private var parsedFor: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Header: oversized title + thin tag row + subtle separator.
            // Tight stack so the body's whitespace stays consistent.
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold, design: .default))
                    .foregroundStyle(theme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(tag: tag)
                        }
                    }
                }
            }
            .padding(.bottom, 4)

            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)
                .padding(.bottom, 2)

            if let parsed {
                MarkdownView(parsed)
            } else {
                Text("loading…")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .padding(.bottom, 80)
        // Narrower max width for comfortable measure — ~70–75 chars of body
        // at our default size. Centered in the available pane via the
        // outer infinity frame.
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear { reparseIfNeeded() }
        .onChange(of: text) { _, _ in reparseIfNeeded() }
    }

    private func reparseIfNeeded() {
        guard text != parsedFor else { return }
        parsedFor = text
        parsed = MarkdownParser.parse(text, baseURL: baseURL)
    }
}

/// macOS-focused scroll container that supports `j` / `k` keyboard scrolling
/// when the host enables it via preferences. iOS falls back to a plain
/// ScrollView with no key intercept (tap/drag/scroll wheel still work
/// everywhere).
///
/// Key handling lives at the SwiftUI level (`.onKeyPress`) — earlier
/// attempts to intercept inside `NSScrollView.keyDown` failed because the
/// hosted SwiftUI subtree grabs first-responder for itself, so the scroll
/// view never sees the key event. Going through SwiftUI's focus model
/// works regardless.
private struct ReadModeScroll<Content: View>: View {
    let jkEnabled: Bool
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool

    var body: some View {
        #if os(macOS)
        let host = NativeScrollHost(content: content)
        host
            .focusable()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(phases: .down) { press in
                guard jkEnabled else { return .ignored }
                let lineStep: CGFloat = 24
                switch press.characters {
                case "j": host.coordinator.scroll(by: lineStep); return .handled
                case "k": host.coordinator.scroll(by: -lineStep); return .handled
                case "d": host.coordinator.scrollHalfPage(direction: 1); return .handled
                case "u": host.coordinator.scrollHalfPage(direction: -1); return .handled
                case "g": host.coordinator.scrollTo(.top); return .handled
                case "G": host.coordinator.scrollTo(.bottom); return .handled
                default: return .ignored
                }
            }
        #else
        ScrollView { content() }
        #endif
    }
}

#if os(macOS)
import AppKit

/// NSScrollView host that reuses one `NSHostingController` across SwiftUI
/// updates. Previous version recreated the host on every `updateNSView`,
/// leaving dangling Auto Layout constraints anchored to deallocated views
/// — those crashed the app the moment scrolling tried to lay out content
/// for a freshly-opened note.
///
/// The hosting controller's `rootView` is mutated in place via the
/// coordinator, which is the supported pattern for SwiftUI-in-AppKit hosts.
///
/// The coordinator is exposed up to the SwiftUI wrapper so `.onKeyPress`
/// handlers can call scroll methods directly. Without this, key events
/// would never reach an `NSScrollView.keyDown` override because the hosted
/// SwiftUI subtree always grabs first-responder for itself.
private struct NativeScrollHost<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    /// Built once on view init; the same instance is handed to
    /// `makeCoordinator` so external callers (the SwiftUI wrapper) can
    /// reach it via `host.coordinator.scroll(by:)`.
    let coordinator = Coordinator()

    func makeCoordinator() -> Coordinator { coordinator }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .allowed
        scroll.scrollerStyle = .overlay

        let host = NSHostingController(rootView: AnyView(content()))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator.host = host
        coordinator.scrollView = scroll

        scroll.documentView = host.view

        // Pin the hosted view's width to the clip view so it never grows
        // horizontally (only vertically as content reflows for scrolling).
        NSLayoutConstraint.activate([
            host.view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Mutate the existing host's root view — SwiftUI diffs the underlying
        // tree, no AppKit subview thrashing.
        coordinator.host?.rootView = AnyView(content())
    }

    /// Exposed to the SwiftUI wrapper for keyboard-driven scrolling. Methods
    /// here drive the underlying NSScrollView with native animation.
    final class Coordinator {
        var host: NSHostingController<AnyView>?
        weak var scrollView: NSScrollView?

        enum Edge { case top, bottom }

        func scroll(by dy: CGFloat) {
            guard let view = scrollView,
                  let doc = view.documentView
            else { return }
            let clip = view.contentView
            let current = clip.bounds.origin
            let maxY = max(0, doc.bounds.height - clip.bounds.height)
            let nextY = max(0, min(maxY, current.y + dy))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: current.x, y: nextY))
            } completionHandler: { [weak view] in
                view?.reflectScrolledClipView(clip)
            }
        }

        func scrollHalfPage(direction sign: CGFloat) {
            guard let view = scrollView else { return }
            let page = view.bounds.height - 40
            scroll(by: sign * page / 2)
        }

        func scrollTo(_ edge: Edge) {
            guard let view = scrollView,
                  let doc = view.documentView
            else { return }
            let clip = view.contentView
            let y: CGFloat
            switch edge {
            case .top: y = 0
            case .bottom: y = max(0, doc.bounds.height - clip.bounds.height)
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        }
    }
}
#endif

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
