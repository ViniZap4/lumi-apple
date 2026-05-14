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
                        relativeLineNumbers: appState.preferences.relativeLineNumbers
                    )
                    .overlay(alignment: .top) { editModeStripe }
                } else {
                    PlainTextEditor(text: Binding(
                        get: { editor.currentText },
                        set: { editor.currentText = $0 }
                    ))
                }
            }
            .id(entry.relativePath)
            .transition(
                appState.preferences.contentAnimations
                    ? .opacity
                    : .identity
            )
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
        switch appState.liveVimMode {
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
    @Environment(AppState.self) private var appState
    @State private var parsed: MarkdownDocument?
    @State private var parsedFor: String = ""

    private var scale: Double { appState.preferences.readingScale }

    private var fontFamilyEnv: MarkdownFontFamily {
        switch appState.preferences.readingFontFamily {
        case .system: return .system
        case .serif: return .serif
        case .monospace: return .monospace
        }
    }

    var body: some View {
        // The header items (title, tags, separator) live in the same
        // stagger pipeline as the markdown blocks so the page assembles
        // top-down on mount. Each block animates independently via
        // `StaggeredBlock`; the cascade is gated by
        // `preferences.contentAnimations`.
        VStack(alignment: .leading, spacing: 22 * scale) {
            StaggeredBlock(index: 0) {
                VStack(alignment: .leading, spacing: 10 * scale) {
                    Text(title)
                        .font(.system(size: 34 * scale, weight: .bold, design: .default))
                        .foregroundStyle(theme.primary)
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
            }

            StaggeredBlock(index: 1) {
                Rectangle()
                    .fill(theme.border)
                    .frame(height: 0.5)
                    .padding(.bottom, 2)
            }

            if let parsed {
                MarkdownView(parsed, indexOffset: 2)
                    .environment(\.markdownScale, scale)
                    .environment(\.markdownFontFamily, fontFamilyEnv)
                    .environment(\.markdownStagger, appState.preferences.contentAnimations)
            } else {
                Text("loading…")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .environment(\.markdownStagger, appState.preferences.contentAnimations)
        .padding(.horizontal, 48)
        .padding(.top, 32)
        .padding(.bottom, 40)
        // Comfortable measure. Width is user-tunable via the toolbar
        // ("Reading width") and persists in preferences.
        .frame(maxWidth: appState.preferences.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear { reparseIfNeeded() }
        .onChange(of: text) { _, _ in reparseIfNeeded() }
    }

    private func reparseIfNeeded() {
        guard text != parsedFor else { return }
        parsedFor = text
        // For tiny notes the cost of an async hop dwarfs the parse, so
        // keep the synchronous path for those. Above ~32 KB the parse
        // can stutter the UI (we're holding the main actor while
        // walking AST nodes); offload to a background task. SwiftUI
        // shows the existing parsed view until the new document
        // arrives — no flash to empty.
        if text.count < 32_000 {
            parsed = MarkdownParser.parse(text, baseURL: baseURL)
            return
        }
        let snapshot = text
        let url = baseURL
        Task.detached(priority: .userInitiated) {
            let document = MarkdownParser.parse(snapshot, baseURL: url)
            await MainActor.run {
                // Only apply if the user hasn't moved on to a newer
                // text since we started — protects against stale
                // overwrites if they typed fast in edit mode and we
                // race a stale parse home.
                if parsedFor == snapshot {
                    parsed = document
                }
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
    @Environment(AppState.self) private var appState

    var body: some View {
        #if os(macOS)
        // The scroll coordinator lives on AppState so the App-init
        // NSEvent monitor (registered before SwiftUI builds its
        // sidebar / list typeahead monitors) has a stable handle to
        // call into. Without that, SwiftUI's own keyDown monitor for
        // List typeahead would fire first when the sidebar held
        // focus, beep on "no matching item", and only then yield to
        // our monitor.
        NativeScrollHost(coordinator: appState.readCoordinator, content: content)
        #else
        ScrollView { content() }
        #endif
    }
}

#if canImport(AppKit)
/// Single NSEvent local monitor for every read-mode scroll key.
/// Handles both plain-key bindings (j/k/g/G/d/u/f/b) and Ctrl-letter
/// shortcuts (⌃D/U/F/B/T/G).
///
/// Installed at App init (before SwiftUI's view tree builds its own
/// monitors for List typeahead etc.), which puts it first in the
/// NSEvent dispatch order. Without that, when the sidebar held focus
/// SwiftUI's typeahead monitor would fire first on `j`, beep on "no
/// matching item", then yield to our monitor — the beep we couldn't
/// silence by returning nil because it already played.
///
/// `isActive` is consulted on every event so the monitor only consumes
/// while a note is open in read mode. It passes everything through
/// otherwise. The closures call into a shared ReadModeCoordinator on
/// AppState so the monitor never has a stale scrollView reference.
@MainActor
final class ReadKeyMonitor {
    private let isActive: @MainActor () -> Bool
    private let glide: (Int) -> Void
    private let halfPage: (Int) -> Void
    private let fullPage: (Int) -> Void
    private let scrollToEdge: (ReadModeCoordinator.Edge) -> Void
    private let closeNote: () -> Void
    nonisolated(unsafe) private var token: Any?

    init(
        isActive: @escaping @MainActor () -> Bool,
        glide: @escaping @MainActor (Int) -> Void,
        halfPage: @escaping @MainActor (Int) -> Void,
        fullPage: @escaping @MainActor (Int) -> Void,
        scrollToEdge: @escaping @MainActor (ReadModeCoordinator.Edge) -> Void,
        closeNote: @escaping @MainActor () -> Void
    ) {
        self.isActive = isActive
        self.glide = glide
        self.halfPage = halfPage
        self.fullPage = fullPage
        self.scrollToEdge = scrollToEdge
        self.closeNote = closeNote
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Editable text input always wins — we never want to shadow
        // typing into the quick switcher / settings / etc.
        if let textResponder = NSApp.keyWindow?.firstResponder as? NSText,
           textResponder.isEditable {
            return event
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = mods.contains(.command)
        let hasOpt = mods.contains(.option)
        let hasCtrl = mods.contains(.control)
        let hasShift = mods.contains(.shift)
        if hasCmd || hasOpt { return event }

        // The scroll bindings get consumed *regardless* of whether
        // we'd actually scroll right now — passing them through to the
        // sidebar's NSCollectionView meant typeahead beeped on "no
        // matching item", which is what the user heard when they
        // clicked the sidebar then pressed ⌃U. We just won't *do*
        // anything when there's no note open in read mode.
        let active = isActive()

        // Resolve the "letter" the user pressed in a way that survives
        // non-US layouts AND the Ctrl-letter quirk where
        // `charactersIgnoringModifiers` can return an empty string or a
        // dead-key character. Order of trust:
        //   1. event.charactersIgnoringModifiers — gives the layout-
        //      resolved letter when present (most reliable for plain
        //      keys).
        //   2. event.characters → ASCII control code → letter. For
        //      Ctrl+U the ASCII control is 0x15; subtracting 0x40 from
        //      the uppercase form gives 0x15 → 'u'. Covers cases where
        //      step 1 returns "" because AppKit didn't synthesize a
        //      layout char for the Ctrl combo.
        let letter: String? = {
            if let s = event.charactersIgnoringModifiers?.lowercased(), !s.isEmpty, s.count == 1 {
                return s
            }
            if hasCtrl,
               let firstScalar = event.characters?.unicodeScalars.first {
                let v = firstScalar.value
                if v >= 0x01 && v <= 0x1A {
                    return String(Unicode.Scalar(v + 0x60)!) // 0x01 → 'a' …
                }
            }
            return nil
        }()

        // Escape / Backspace — handled specially: in read mode either
        // one closes the note and returns to the tree browser. Outside
        // read mode they pass through so the system handles them
        // (cancel buttons, sheet dismissal, text-field deletion).
        if event.keyCode == 53 || event.keyCode == 51 {
            if active {
                closeNote()
                return nil
            }
            return event
        }

        // Other structural keys pass through.
        let passThroughKeyCodes: Set<UInt16> = [
            36, 76,        // return / keypad enter
            48,            // tab
            123, 124, 125, 126 // arrows
        ]
        if passThroughKeyCodes.contains(event.keyCode) { return event }

        // If we couldn't resolve a letter, only consume when active
        // (a note is open in read mode). Outside read mode unknown
        // keys flow through so the rest of the app behaves normally.
        guard let letter else { return active ? nil : event }

        // Scroll-key set the monitor "owns". Outside read mode we
        // still consume them — performing no scroll — so the sidebar
        // typeahead doesn't beep on them.
        let isScrollKey: Bool
        if hasCtrl {
            isScrollKey = ["d", "u", "f", "b", "t", "g"].contains(letter)
            if active {
                switch letter {
                case "d": halfPage(1)
                case "u": halfPage(-1)
                case "f": fullPage(1)
                case "b": fullPage(-1)
                case "t": halfPage(1)
                case "g": scrollToEdge(hasShift ? .bottom : .top)
                default: break
                }
            }
        } else {
            isScrollKey = ["j", "k", "d", "u", "f", "b", "g"].contains(letter)
            if active {
                let lineStep = 22
                switch letter {
                case "j": glide(lineStep)
                case "k": glide(-lineStep)
                case "d": halfPage(1)
                case "u": halfPage(-1)
                case "f": fullPage(1)
                case "b": fullPage(-1)
                case "g": scrollToEdge(hasShift ? .bottom : .top)
                default: break
                }
            }
        }

        if isScrollKey { return nil }
        // Other letters: in read mode swallow (no input destination
        // for a read-only note); otherwise pass through so the rest
        // of the app sees them.
        return active ? nil : event
    }
}
#endif

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
        context.coordinator.host?.rootView = AnyView(content())
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
                    view?.reflectScrolledClipView(clip)
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
            // Timer callback is non-sendable; bounce onto the main actor
            // before touching coordinator state. Capture `self` weakly so
            // a dropped view tears the loop down.
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                Task { @MainActor [weak self] in
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
        HStack(spacing: 4) {
            Image(systemName: "number")
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.7)
            Text(tag)
                .font(.system(.caption, design: .rounded).weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(theme.accent.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(theme.accent.opacity(0.25), lineWidth: 0.5)
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
