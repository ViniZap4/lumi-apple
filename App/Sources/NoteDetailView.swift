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


    /// Read-vs-edit toggle is hoisted to AppState so the global toolbar
    /// renders the picker alongside theme/settings/etc. Local binding so
    /// the existing view code below reads `mode` as before.
    private var mode: NoteDisplayMode {
        appState.editorMode
    }

    /// Map the user's preference enum onto LumiUI's `MarkdownFontFamily`.
    /// Kept here (rather than as a free function) so the conversion stays
    /// adjacent to the call site that consumes it.
    private var markdownFontFamilyFromPreferences: MarkdownFontFamily {
        switch appState.preferences.readingFontFamily {
        case .system: return .system
        case .serif: return .serif
        case .monospace: return .monospace
        }
    }

    /// In-app link handler for `MarkdownReader`. Returns `true` when the
    /// URL was a `file://*.md` inside the active vault and we successfully
    /// kicked off in-app navigation. Both link paths (`OpenURLAction` for
    /// SwiftUI Text + `MarkdownLinkAction` for NSTextView) call this so
    /// the routing logic stays in one place.
    private func handleInAppLink(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "md" else {
            return false
        }
        guard let session = appState.session,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return false
        }
        let vaultRoot = session.rootURL.standardizedFileURL
        let resolved = url.standardizedFileURL
        let prefix = vaultRoot.path + "/"
        let relativePath: String
        if resolved.path.hasPrefix(prefix) {
            relativePath = String(resolved.path.dropFirst(prefix.count))
        } else {
            relativePath = resolved.lastPathComponent
        }
        let mtime = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let entry = NoteEntry(url: resolved, relativePath: relativePath, updatedAt: mtime)
        if appState.editor.isDirty { appState.editor.save() }
        appState.editor.load(noteID: relativePath, at: resolved, vaultRoot: vaultRoot)
        appState.selectedNoteID = relativePath
        appState.selectedEntry = entry
        appState.editorMode = .view
        return true
    }

    var body: some View {
        @Bindable var editor = appState.editor
        VStack(spacing: 0) {
            // All status chrome (modified, saved, conflict label, save
            // button, vim mode badge, read/edit picker) lives in the
            // RootView toolbar now. The in-pane DetailStatusBar only
            // renders for full-width banners (conflict resolution prompt,
            // error message) — nothing when the editor is happy.
            if case .conflict = editor.status {
                ConflictBanner(
                    onReload: { editor.reloadFromDisk(vaultRoot: vaultRoot) },
                    onForceSave: { editor.forceSave() },
                    onDiscard: { editor.discard() }
                )
            } else if case let .error(message) = editor.status {
                ErrorBanner(message: message)
            }
            content(editor: editor)
        }
        .background(theme.background)
        // Animates the SwiftUI switch between read / edit branches when
        // the preference is on. Driven by `mode` so toggling the picker
        // (or hitting ⌘E) flips with a brief cross-fade instead of a
        // hard cut.
        // The two animation triggers — `mode` for read↔edit toggle and
        // `entry.relativePath` for note switch — both run the same easing
        // curve. Without the second, .id changes would replace the
        // subtree without firing the inner `.transition` modifiers.
        .animation(
            appState.preferences.contentAnimations
                ? .easeInOut(duration: 0.22)
                : nil,
            value: mode
        )
        .animation(
            appState.preferences.contentAnimations
                ? .easeInOut(duration: 0.22)
                : nil,
            value: entry.relativePath
        )
        .background {
            // ⌘S saves (local notes write to disk; vim :w does the same).
            Button("Save") { editor.save() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
        }
        #if os(iOS) || os(visionOS)
        .navigationTitle(displayTitle)
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
                    noteURL: entry.url,
                    baseURL: baseURL,
                    vaultRoot: vaultRoot,
                    isDirty: editor.isDirty,
                    scale: appState.preferences.readingScale,
                    fontFamily: markdownFontFamilyFromPreferences,
                    contentAnimations: appState.preferences.contentAnimations,
                    readingWidth: appState.preferences.readingWidth,
                    onInAppLink: handleInAppLink,
                    yankFlashTrigger: appState.yankFlashAt,
                    onToggleTask: { appState.toggleTask($0) }
                )
            }
            // Per-note identity: new entry → fresh scroll-host coord,
            // fresh stagger cascade for the header / blocks inside the
            // reader. Combined with `.animation(value: entry.relativePath)`
            // higher up, the swap fades out the old before the new
            // cascades in.
            .id(entry.relativePath)
            .transition(
                appState.preferences.contentAnimations
                    ? .opacity.combined(with: .move(edge: .top))
                    : .identity
            )
        case .edit:
            SourceSplit(
                enabled: appState.preferences.splitPreview,
                text: editor.currentText,
                ratio: Binding(get: { appState.preferences.splitPreviewRatio },
                               set: { appState.preferences.splitPreviewRatio = $0 }),
                scale: appState.preferences.readingScale,
                fontFamily: markdownFontFamilyFromPreferences,
                baseURL: baseURL,
                vaultRoot: vaultRoot,
                onToggleTask: { appState.toggleTask($0) },
                onInAppLink: handleInAppLink,
                focus: appState.splitFocusMarker,
                onSync: { appState.adoptSplit($0) }
            ) {
                editorPane(editor: editor)
            }
            .environment(\.vimControllerSink) { appState.adoptEditor($0) }
            .id(entry.relativePath)
            .transition(
                appState.preferences.contentAnimations
                    ? .opacity
                    : .identity
            )
        }
    }

    @ViewBuilder
    private func editorPane(editor: EditorState) -> some View {
            Group {
                if appState.preferences.vimEnabled {
                    VimEditor(
                        text: Binding(
                            get: { editor.currentText },
                            set: { editor.currentText = $0 }
                        ),
                        onModeChange: { appState.liveVimMode = $0 },
                        onEffect: { effect in
                            handleVimEffect(effect, editor: editor)
                        },
                        jjEscapeEnabled: appState.preferences.jjEscapeMapping,
                        showLineNumbers: appState.preferences.showLineNumbers,
                        relativeLineNumbers: appState.preferences.relativeLineNumbers,
                        options: appState.vimEditorOptions,
                        vimrc: appState.preferences.parsedVimrc,
                        blockCursor: appState.preferences.vimBlockCursor,
                        fileName: entry.relativePath,
                        onStatusChange: { appState.liveVimStatus = $0 }
                    )
                    .readableEditorWidth()
                } else {
                    PlainTextEditor(text: Binding(
                        get: { editor.currentText },
                        set: { editor.currentText = $0 }
                    ))
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
        appState.liveVimMode.chromeColor(theme)
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
        case .scrollCursor, .scrollLines, .displayLines:
            break // handled by the editor view
        case let .host(command):
            appState.performHostCommand(command)
        }
    }
}

/// Compact status bar inside the note pane. Shows only the editor save
/// state + a Cmd-S save button. The vim-mode badge and the read/edit
/// picker both live in the global toolbar now so the chrome stays
/// centralized at the top.
private struct DetailStatusBar: View {
    let editor: EditorState
    let onSave: () -> Void
    let onReload: () -> Void
    let onForceSave: () -> Void
    let onDiscard: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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

/// Wraps content in a state-driven opacity that fades in on appear. Pair
/// with `.id(...)` so each identity change re-runs the mount animation.
/// `animated: false` skips the fade entirely — content lands fully visible
/// on first render with no animation transaction kicked off.
private struct MountFader<Content: View>: View {
    let animated: Bool
    @ViewBuilder let content: () -> Content
    @State private var visible = false

    var body: some View {
        content()
            .opacity(visible ? 1 : (animated ? 0 : 1))
            .onAppear {
                guard animated else { visible = true; return }
                // A trivial async hop lets SwiftUI settle the initial
                // layout pass before we kick off the animation — without
                // it the `withAnimation` block sometimes races the same
                // frame the view first laid out in, producing no fade.
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        visible = true
                    }
                }
            }
    }
}

/// Read-mode container. `MarkdownReader` is its own (TextKit) scroll
/// view, so this no longer wraps it in another one; it just hands the
/// reader's scroll view to the keyboard scroll coordinator (macOS
/// `ReadKeyMonitor` → `ReadModeCoordinator`) and, on iOS / visionOS,
/// tells the reader whether hardware-keyboard j/k scrolling is enabled.
struct ReadModeScroll<Content: View>: View {
    let jkEnabled: Bool
    @ViewBuilder let content: () -> Content
    @Environment(AppState.self) private var appState

    var body: some View {
        let coordinator = appState.readCoordinator
        content()
            .environment(\.markdownScrollViewSink, MarkdownScrollViewSink { scrollView in
                coordinator.attach(scrollView: scrollView)
            })
            .environment(\.markdownKeyboardScrolling, jkEnabled)
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
struct NativeScrollHost<Content: View>: NSViewRepresentable {
    /// Injected from the wrapping view's @State. SwiftUI's
    /// NSViewRepresentable lifecycle calls `makeCoordinator()` once at
    /// the start of the view's life; if we created the Coordinator
    /// inline (`let coordinator = Coordinator()`) every body call
    /// would construct a fresh struct with a brand-new Coordinator,
    /// while SwiftUI kept using the FIRST one — leaving external
    /// callers wiring scroll commands to a dangling instance with no
    /// scrollView reference. The wrapper now holds the coordinator in
    /// @State and hands the same instance in on every body call.
    let coordinator: ReadModeCoordinator
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> ReadModeCoordinator { coordinator }

    /// An `NSHostingController` is a fresh SwiftUI root that inherits no
    /// environment from this representable, so forward the values the
    /// hosted markdown reads — without this the preview pane rendered
    /// light themes with the default dark tokens.
    private func hostedRoot(_ context: Context) -> AnyView {
        AnyView(content().environment(\.theme, context.environment.theme))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .allowed
        scroll.scrollerStyle = .overlay
        // AppKit's default for scroll views inside a window with a unified
        // toolbar is to auto-inset the clip view so content can underflow
        // the toolbar with transparency. That left the note's title hidden
        // behind the toolbar on first mount — initial scroll position
        // y=0 means "top of doc", and the doc's top was the title, which
        // sat behind the toolbar's adjusted inset. Disabling the auto
        // insets pins the scroll origin to the actual top of the content
        // area, exposing the title.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let host = NSHostingController(rootView: hostedRoot(context))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.host = host
        context.coordinator.scrollView = scroll

        scroll.documentView = host.view

        // Pin the hosted view's width to the clip view so it never grows
        // horizontally (only vertically as content reflows for scrolling).
        NSLayoutConstraint.activate([
            host.view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        // Native scroll input (trackpad, mouse wheel, scroll bar drag)
        // takes priority over the keyboard velocity ticker. Without
        // this the user's trackpad gesture fights the easing tick and
        // the view jitters. As soon as AppKit kicks off a live scroll
        // we stop ticking; the next j/k call rehydrates the target.
        let center = NotificationCenter.default
        let coord = context.coordinator
        center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scroll,
            queue: .main
        ) { [weak coord] _ in
            Task { @MainActor in coord?.stopTickerForExternalScroll() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Mutate the existing host's root view via the
        // SwiftUI-managed coordinator (context.coordinator) — same
        // instance every render. The prior version touched
        // `self.coordinator` directly which, when body re-runs, is a
        // fresh unwired Coordinator that hasn't been bound to any
        // hosting controller.
        context.coordinator.host?.rootView = hostedRoot(context)
        // Document height may have changed (different note, font scale,
        // width). Re-anchor the velocity target on the current offset so
        // a stale target doesn't fling us past the new content bounds.
        context.coordinator.syncTargetWithCurrent()
    }
}

/// Read-mode scroll controller. Lives outside `NativeScrollHost` (so the
/// wrapper can hold it in @State without inheriting the generic Content
/// parameter) and outside `Coordinator` (so subscribers can hand a stable
/// reference around without the NSViewRepresentable lifecycle gotchas).
@MainActor
final class ReadModeCoordinator {
        var host: NSHostingController<AnyView>?
        weak var scrollView: NSScrollView?
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?

        /// Adopt a scroll view owned by someone else (the TextKit read
        /// pane). Idempotent per scroll view; native trackpad / wheel
        /// scrolling still cancels the keyboard glide like it does for
        /// `NativeScrollHost`.
        func attach(scrollView newScrollView: NSScrollView) {
            scrollView = newScrollView
            targetY = newScrollView.contentView.bounds.origin.y
            guard observedScrollView !== newScrollView else { return }
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            observedScrollView = newScrollView
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: newScrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.stopTickerForExternalScroll() }
            }
        }

        /// Where we want to be (vertical offset of the clip view's origin).
        /// `glide` adds to this; `tick` slides the actual offset toward it.
        private var targetY: CGFloat = 0
        private var ticker: Timer?

        enum Edge { case top, bottom }

        func scroll(by dy: CGFloat, animated: Bool = true) {
            guard let view = scrollView,
                  let doc = view.documentView
            else { return }
            let clip = view.contentView
            let current = clip.bounds.origin
            let maxY = max(0, doc.bounds.height - clip.bounds.height)
            let nextY = max(0, min(maxY, current.y + dy))
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.10
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    clip.animator().setBoundsOrigin(NSPoint(x: current.x, y: nextY))
                } completionHandler: { [weak view] in
                    // AppKit runs the completion handler on the main
                    // thread; assert that rather than hopping.
                    MainActor.assumeIsolated {
                        view?.reflectScrolledClipView(clip)
                    }
                }
            } else {
                clip.setBoundsOrigin(NSPoint(x: current.x, y: nextY))
                view.reflectScrolledClipView(clip)
            }
        }

        /// Velocity-style smooth scroll. Each call bumps the target offset
        /// and a 60-Hz timer eases the actual offset toward it with
        /// critical damping. Holding a key keeps the target ahead of the
        /// current position so motion stays continuous; releasing the key
        /// stops adding to the target and the timer drains the gap to
        /// zero — no abrupt stops.
        func glide(by dy: CGFloat) {
            guard let view = scrollView,
                  let doc = view.documentView
            else { return }
            let clip = view.contentView
            let maxY = max(0, doc.bounds.height - clip.bounds.height)
            // If no tick is running we start from the current offset, not
            // a stale target.
            if ticker == nil {
                targetY = clip.bounds.origin.y
            }
            targetY = max(0, min(maxY, targetY + dy))
            startTickerIfNeeded()
        }

        private func startTickerIfNeeded() {
            guard ticker == nil else { return }
            // The timer is scheduled on RunLoop.main, so its callback runs
            // on the main thread: assert main-actor isolation instead of
            // hopping through a Task (which added a frame of latency).
            // Capture `self` weakly so a dropped view tears the loop down.
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }

        private func tick() {
            guard let view = scrollView,
                  let doc = view.documentView
            else { stopTicker(); return }
            let clip = view.contentView
            let maxY = max(0, doc.bounds.height - clip.bounds.height)
            // Document may have shrunk since the target was set (different
            // note loaded, font scale changed). Clamp before easing.
            targetY = max(0, min(maxY, targetY))
            let current = clip.bounds.origin.y
            let delta = targetY - current
            // Below half a pixel from target → snap and stop. Avoids the
            // ticker idling forever on sub-pixel residuals.
            if abs(delta) < 0.5 {
                clip.setBoundsOrigin(NSPoint(x: 0, y: targetY))
                view.reflectScrolledClipView(clip)
                stopTicker()
                return
            }
            // Critical-damping factor. Lower = smoother but laggier;
            // higher = snappier. 0.30 feels close to a trackpad scroll.
            let step = delta * 0.30
            clip.setBoundsOrigin(NSPoint(x: 0, y: current + step))
            view.reflectScrolledClipView(clip)
        }

        /// Called after `updateNSView`. If we're not actively ticking,
        /// pull the target back to whatever the actual offset is now so
        /// the next `glide()` builds on a fresh baseline. Without this,
        /// switching notes while no ticker is running can leave a stale
        /// targetY pointing into the previous document's coordinates.
        func syncTargetWithCurrent() {
            guard ticker == nil, let view = scrollView else { return }
            targetY = view.contentView.bounds.origin.y
        }

        private func stopTicker() {
            ticker?.invalidate()
            ticker = nil
        }

        /// Cancels the velocity ticker because the user started a native
        /// scroll (trackpad / wheel / scrollbar drag). The next `glide`
        /// call re-anchors `targetY` to the new clip-view origin.
        func stopTickerForExternalScroll() {
            stopTicker()
            if let view = scrollView {
                targetY = view.contentView.bounds.origin.y
            }
        }

        func scrollHalfPage(direction sign: CGFloat) {
        guard let view = scrollView else { return }
        let page = view.bounds.height - 40
        glide(by: sign * page / 2)
    }

    /// Full-page scroll for ⌃f / ⌃b. Leaves a small overlap so the
    /// user keeps their reading context, mirroring vim.
    func scrollFullPage(direction sign: CGFloat) {
        guard let view = scrollView else { return }
        let page = view.bounds.height - 40
        glide(by: sign * page)
    }

    func scrollTo(_ edge: Edge) {
        guard let view = scrollView,
              let doc = view.documentView
        else { return }
        let clip = view.contentView
        let current = clip.bounds.origin.y
        let target: CGFloat
        switch edge {
        case .top: target = 0
        case .bottom: target = max(0, doc.bounds.height - clip.bounds.height)
        }
        // Use the same ticker as glide() — single source of truth means
        // no race with mid-animation re-renders or with held j/k
        // presses. The critical-damping factor inside `tick()` makes
        // edge jumps ease in over ~10 frames regardless of distance.
        glide(by: target - current)
    }
}
#else

/// Non-macOS stand-in for the AppKit `NativeScrollHost`: a plain SwiftUI
/// `ScrollView`. The keyboard-driven glide/scroll API of
/// `ReadModeCoordinator` has no consumer on iOS/visionOS (there is no
/// `ReadKeyMonitor` there — touch / hardware-keyboard scrolling is the
/// system's), so the coordinator below is a no-op that only exists so
/// shared call sites (`AppState.readCoordinator`, the tree preview pane)
/// compile unguarded.
struct NativeScrollHost<Content: View>: View {
    let coordinator: ReadModeCoordinator
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView { content() }
    }
}

@MainActor
final class ReadModeCoordinator {
    enum Edge { case top, bottom }

    weak var scrollView: UIScrollView?
    func attach(scrollView: UIScrollView) { self.scrollView = scrollView }
    func scroll(by dy: CGFloat, animated: Bool = true) {}
    func glide(by dy: CGFloat) {}
    func syncTargetWithCurrent() {}
    func stopTickerForExternalScroll() {}
    func scrollHalfPage(direction sign: CGFloat) {}
    func scrollFullPage(direction sign: CGFloat) {}
    func scrollTo(_ edge: Edge) {}
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
        case .replace:
            return (vimMode.label, theme.background, theme.error)
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

