import SwiftUI
import LumiKit

/// The reading pane: parses the note (off the main actor, cached by
/// mtime) and renders title, tags and body through one TextKit 2
/// document view with a centred reading column, themed link tooltips,
/// cross-paragraph selection and a yank-flash overlay. The reader is
/// its own scroll view; hosts that drive keyboard scrolling receive it
/// through `\.markdownScrollViewSink`. Lives in LumiUI so both the local-vault
/// `NoteDetailView` and the server-vault `RemoteNoteDetailView` render
/// through the same pipeline.
///
/// The reader is intentionally *unaware* of `AppState`. The host supplies
/// configuration (scale, font, width, animations) and behaviors (in-app
/// link routing, yank-flash trigger) via init parameters. That keeps
/// LumiUI free of `App/` imports and makes the reader testable in
/// isolation.
public struct MarkdownReader: View {
    public let title: String
    public let tags: [String]
    public let text: String

    /// The note's own file URL — used as the `MarkdownDocumentCache` key.
    /// Pass `nil` for non-disk-backed notes (server vaults); cache writes
    /// are skipped when absent.
    public let noteURL: URL?
    /// Resolution base for relative markdown links inside the parsed AST.
    /// Pass the parent directory for local notes; nil for server notes
    /// (slice 3 doesn't support cross-note linking from server vaults).
    public let baseURL: URL?
    /// Active vault root. Threaded into the markdown env so leaf views
    /// (`LinkAwareTextView`) can render in-vault `file://` URLs as
    /// vault-relative paths inside their hover tooltips.
    public let vaultRoot: URL?

    /// True when the host has unsaved in-memory edits. Disables the
    /// document cache (cache is keyed on disk mtime; a hit on a dirty
    /// buffer would surface a pre-edit parse).
    public let isDirty: Bool

    public let scale: Double
    public let fontFamily: MarkdownFontFamily
    /// Kept for API compatibility. The TextKit reader renders the note
    /// as one text flow, so there is no per-block stagger; hosts animate
    /// note switches themselves (`NoteDetailView`'s `.transition`).
    public let contentAnimations: Bool
    public let readingWidth: CGFloat

    /// Optional in-app link handler. Receives every tap/click on a link
    /// inside the rendered markdown. Return `true` if the URL was handled
    /// in-app (the system handler is then skipped); `false` to let the
    /// system handle it (https, mailto, etc.). Pass `nil` to skip in-app
    /// handling entirely.
    public let onInAppLink: ((URL) -> Bool)?

    /// Bump this `Date` to fire a yank-flash overlay (vim `y` / ⌘C copy
    /// feedback). Each change → 0.28 opacity flash that fades to 0 over
    /// 0.45 s. Pass `nil` to disable.
    public let yankFlashTrigger: Date?

    /// Toggle task checkbox `index` (document order). nil → read-only
    /// checkboxes.
    public let onToggleTask: ((Int) -> Void)?
    /// Title + tags above the body (off in the split preview, which
    /// mirrors the source only).
    public let showsHeader: Bool

    @Environment(\.theme) private var theme
    @State private var zoom = MarkdownZoom.shared
    @State private var parsed: MarkdownDocument?
    @State private var parsedFor: String = ""
    @State private var yankFlashOpacity: Double = 0

    public init(
        title: String,
        tags: [String] = [],
        text: String,
        noteURL: URL? = nil,
        baseURL: URL? = nil,
        vaultRoot: URL? = nil,
        isDirty: Bool = false,
        scale: Double = 1.0,
        fontFamily: MarkdownFontFamily = .system,
        contentAnimations: Bool = false,
        readingWidth: CGFloat = 720,
        onInAppLink: ((URL) -> Bool)? = nil,
        yankFlashTrigger: Date? = nil,
        onToggleTask: ((Int) -> Void)? = nil,
        showsHeader: Bool = true
    ) {
        self.onToggleTask = onToggleTask
        self.showsHeader = showsHeader
        self.title = title
        self.tags = tags
        self.text = text
        self.noteURL = noteURL
        self.baseURL = baseURL
        self.vaultRoot = vaultRoot
        self.isDirty = isDirty
        self.scale = scale
        self.fontFamily = fontFamily
        self.contentAnimations = contentAnimations
        self.readingWidth = readingWidth
        self.onInAppLink = onInAppLink
        self.yankFlashTrigger = yankFlashTrigger
    }

    private var style: MarkdownRenderStyle {
        MarkdownRenderStyle(theme: theme, scale: scale, fontFamily: fontFamily, tasksInteractive: onToggleTask != nil)
    }

    /// The header, minus the title when the body already opens with the
    /// same `# Title` (web `startsWithTitle`).
    private var header: MarkdownHeader? {
        guard showsHeader else { return nil }
        let shownTitle = MarkdownText.startsWithTitle(text, title: title) ? "" : title
        if shownTitle.isEmpty && tags.isEmpty { return nil }
        return MarkdownHeader(title: shownTitle, tags: tags)
    }

    public var body: some View {
        // One TextKit 2 document view renders title, tags and body as a
        // single attributed string (see `MarkdownDocumentView`). Until the
        // first parse lands the header renders alone, so opening a note
        // never flashes an empty pane.
        MarkdownDocumentView(
            header: header,
            document: parsed ?? Self.emptyDocument,
            style: style,
            readingWidth: readingWidth,
            onToggleTask: onToggleTask
        )
        .environment(\.markdownVaultRoot, vaultRoot)
        .environment(\.markdownLinkAction, MarkdownLinkAction { url in
            onInAppLink?(url) ?? false
        })
        // Yank-flash overlay. Non-interactive so it doesn't swallow
        // selection-drags or clicks. Animates opacity → 0 on every change
        // of `yankFlashTrigger`.
        .overlay {
            if yankFlashTrigger != nil {
                Rectangle()
                    .fill(theme.accent)
                    .opacity(yankFlashOpacity)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.3), value: yankFlashOpacity)
            }
        }
        .overlay {
            if let item = zoom.item, showsHeader {
                MarkdownZoomOverlay(item: item)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: zoom.item)
        .onAppear { reparseIfNeeded() }
        .onChange(of: text) { _, _ in reparseIfNeeded() }
        .onChange(of: yankFlashTrigger) { _, _ in
            guard yankFlashTrigger != nil else { return }
            // Two-step: instant peak, then drain to zero on the next tick.
            // The modifier's animation curve handles the actual fade —
            // without the tick, SwiftUI coalesces the up + down into a
            // single transition with no visible flash.
            yankFlashOpacity = 0.16
            Task { @MainActor in
                yankFlashOpacity = 0
            }
        }
    }

    private static let emptyDocument = MarkdownDocument(blocks: [])

    // MARK: - Parsing

    private func reparseIfNeeded() {
        guard text != parsedFor else { return }
        parsedFor = text

        // Cache hit path: same noteURL + mtime → reuse the prior parse.
        // Disabled when the buffer is dirty (cache is keyed on disk mtime;
        // in-memory edits don't bump it, so a cache hit would surface a
        // pre-edit parse).
        if !isDirty,
           let url = noteURL,
           url.isFileURL,
           let mtime = Self.mtime(for: url),
           let cached = MarkdownDocumentCache.shared.document(for: url, mtime: mtime) {
            parsed = cached
            return
        }

        // Always async — parsing a large note takes tens of milliseconds
        // (~100 ms for 5k lines); off-loading keeps the link click that
        // opened it responsive. Old content stays on screen meanwhile, and
        // when the parse lands only the blocks that changed are re-rendered.
        let snapshot = text
        let resolveBase = baseURL
        let cacheURL = noteURL
        let canCache = !isDirty
        Task.detached(priority: .userInitiated) {
            let document = MarkdownParser.parse(snapshot, baseURL: resolveBase)
            await MainActor.run {
                // Only apply if no newer text has landed since we started.
                if parsedFor == snapshot {
                    parsed = document
                    if canCache,
                       let url = cacheURL,
                       url.isFileURL,
                       let mtime = Self.mtime(for: url) {
                        MarkdownDocumentCache.shared.store(document, for: url, mtime: mtime)
                    }
                }
            }
        }
    }

    private static func mtime(for url: URL) -> Date? {
        guard url.isFileURL else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}
