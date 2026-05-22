import SwiftUI
import LumiKit

/// The reading-pane wrapper used to display a parsed markdown document with
/// title, tags, comfortable measure, stagger cascade, link tooltips, and a
/// yank-flash overlay. Lives in LumiUI so both the local-vault
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

    @Environment(\.theme) private var theme
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
        yankFlashTrigger: Date? = nil
    ) {
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

    public var body: some View {
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
                                MarkdownReaderTagChip(tag: tag)
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
                // Auto-disable stagger when block count exceeds the threshold —
                // continuous fire-on-materialise during scroll is both visually
                // noisy and expensive on large docs.
                let useStagger = contentAnimations
                    && parsed.blocks.count <= largeMarkdownBlockThreshold
                MarkdownView(parsed, indexOffset: 2)
                    .environment(\.markdownScale, scale)
                    .environment(\.markdownFontFamily, fontFamily)
                    .environment(\.markdownStagger, useStagger)
            } else {
                Text("loading…")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .environment(\.markdownStagger, contentAnimations)
        .environment(\.markdownVaultRoot, vaultRoot)
        // Intercept link taps for SwiftUI Text-based renderers. NSTextView
        // path uses `markdownLinkAction` below — both reuse the same
        // closure so the routing logic stays in one place.
        .environment(\.openURL, OpenURLAction { url in
            if let onInAppLink, onInAppLink(url) {
                return .handled
            }
            return .systemAction
        })
        .environment(\.markdownLinkAction, MarkdownLinkAction { url in
            onInAppLink?(url) ?? false
        })
        .padding(.horizontal, 48)
        .padding(.top, 32)
        .padding(.bottom, 40)
        .frame(maxWidth: readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        // Yank-flash overlay. Non-interactive so it doesn't swallow
        // selection-drags or clicks. Animates opacity → 0 on every change
        // of `yankFlashTrigger`.
        .overlay {
            if yankFlashTrigger != nil {
                Rectangle()
                    .fill(theme.warning)
                    .opacity(yankFlashOpacity)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.45), value: yankFlashOpacity)
            }
        }
        // Coordinate space that `LinkAwareTextView` converts its local
        // link rect into. The tooltip overlay below shares the same space.
        .coordinateSpace(name: linkTooltipReaderCoordinateSpace)
        // Global link-tooltip overlay. Each `LinkAwareTextView` publishes
        // the hovered link's rect through `LinkHoverAnchorPreferenceKey`;
        // this overlay reads that rect and places the themed bubble just
        // below the link. Sibling of the LazyVStack child tree so the
        // bubble's appearance can't cascade back into per-block layout
        // passes (which would nudge the link away from the cursor on
        // hover — the bug the F.54→F.56 series chased).
        .overlayPreferenceValue(LinkHoverAnchorPreferenceKey.self) { value in
            GeometryReader { proxy in
                MarkdownReaderLinkTooltipOverlay(hover: value, maxWidth: proxy.size.width)
            }
            .allowsHitTesting(false)
        }
        .onAppear { reparseIfNeeded() }
        .onChange(of: text) { _, _ in reparseIfNeeded() }
        .onChange(of: yankFlashTrigger) { _, _ in
            guard yankFlashTrigger != nil else { return }
            // Two-step: instant peak, then drain to zero on the next tick.
            // The modifier's animation curve handles the actual fade —
            // without the tick, SwiftUI coalesces the up + down into a
            // single transition with no visible flash.
            yankFlashOpacity = 0.28
            Task { @MainActor in
                yankFlashOpacity = 0
            }
        }
    }

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

        // Always async — the parse plus its follow-up LazyVStack
        // materialisation (WKWebView spawns per math paragraph,
        // NSTextView setup per link paragraph) blocks the main thread
        // for tens to a couple hundred milliseconds otherwise. Off-loading
        // keeps the link-click itself responsive; old content stays on
        // screen during the parse.
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

// MARK: - Private chrome (file-internal so other LumiUI files don't pick
// them up — these are MarkdownReader implementation details, not a
// general-purpose component surface.)

private struct MarkdownReaderTagChip: View {
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

/// Renders the active link-hover tooltip as a global overlay above the
/// reader's content. Reads the `LinkHoverAnchorPreferenceKey` value that
/// `LinkAwareTextView` publishes (forwarded into the `hover` prop from
/// the MarkdownReader's `.overlayPreferenceValue` builder).
///
/// We take the preference value as a prop rather than reading it via
/// `.onPreferenceChange` here because the overlay is a sibling of the
/// LinkAwareTextView's published preference — only the
/// `.overlayPreferenceValue` builder on the underlying view can see it.
/// Mirroring into `@State` via `.onChange` gives the SwiftUI `.transition`
/// modifier identity changes to animate against, so the bubble fades +
/// scales in / out cleanly when hover starts and ends.
private struct MarkdownReaderLinkTooltipOverlay: View {
    let hover: LinkHoverAnchor?
    let maxWidth: CGFloat
    @State private var displayed: LinkHoverAnchor?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let displayed {
                LinkTooltipBubble(label: displayed.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(
                        x: max(0, min(max(0, maxWidth - linkTooltipMaxWidth), displayed.linkRect.minX)),
                        y: displayed.linkRect.maxY + 8
                    )
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading))
                    )
            }
        }
        .onAppear { displayed = hover }
        .onChange(of: hover) { _, new in
            withAnimation(.easeOut(duration: 0.16)) {
                displayed = new
            }
        }
    }
}
