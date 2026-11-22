import SwiftUI

// Platform-neutral pieces of the link-hover tooltip pipeline. The
// producer (`LinkAwareTextView`) is AppKit-only because it needs an
// NSTextView for per-glyph link rects, but the consumer side —
// `MarkdownReader`'s global overlay, the preference key it reads, the
// coordinate-space name and the bubble view — compiles on every
// platform. On iOS/visionOS nothing publishes an anchor, so the overlay
// simply never shows.

/// The styled bubble itself. Matches the rest of the app: themed
/// background, monospaced caption text, thin border, soft drop
/// shadow. `.fixedSize()` lets the bubble grow to its content's
/// width up to a sane cap and wrap to multiple lines when the path
/// is deep.
public struct LinkTooltipBubble: View {
    public init(label: String) { self.label = label }

    let label: String
    @Environment(\.theme) private var theme

    public var body: some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(theme.text)
            // Wrap onto multiple lines (up to four) so long paths read
            // properly instead of getting middle-truncated. The
            // `.fixedSize(horizontal: false, vertical: true)` plus the
            // outer `maxWidth: tooltipMaxWidth` cap lets the bubble
            // shrink horizontally to the path's natural width when it
            // fits on one line, and wrap when it doesn't.
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                // Two-layer background gives the bubble a real "card"
                // feel that reads on every theme:
                //   1. Solid `theme.background` underlay so the bubble
                //      is fully opaque even when the page content is
                //      using `theme.overlayBackground`.
                //   2. A faint `theme.accent` tint over it for a hint
                //      of theme colour without competing with the
                //      label text.
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.background)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accent.opacity(0.07))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.accent.opacity(0.40), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 5)
            .frame(maxWidth: linkTooltipMaxWidth, alignment: .leading)
    }
}

/// Upper bound on the tooltip's width as a free constant so consumers
/// outside this file (the global overlay in `MarkdownReader`) can
/// align their x-clamp with the bubble's actual max width.
public let linkTooltipMaxWidth: CGFloat = 360


/// Tooltip handoff between `LinkAwareTextView` and the
/// `MarkdownReader`-level overlay. Carries the path label plus the
/// hovered link's rect already translated into the reader's named
/// coordinate space.
///
/// We don't use `Anchor<CGPoint>` here even though it's the more
/// idiomatic SwiftUI primitive — SwiftUI's `.offset` modifier moves
/// rendered glyphs but doesn't move `Anchor` values (anchors track
/// the view's *layout* position, not its rendered position). Doing
/// the coord conversion by hand via `GeometryReader` + `.frame
/// (in: .named(...))` gives us the link's actual on-screen rect.
public struct LinkHoverAnchor: Equatable, Sendable {
    public let label: String
    public let linkRect: CGRect

    public init(label: String, linkRect: CGRect) {
        self.label = label
        self.linkRect = linkRect
    }
}

public struct LinkHoverAnchorPreferenceKey: PreferenceKey {
    public static let defaultValue: LinkHoverAnchor? = nil
    public static func reduce(
        value: inout LinkHoverAnchor?,
        nextValue: () -> LinkHoverAnchor?
    ) {
        // First non-nil wins. With the tooltip pinned to a single
        // link at a time, this is what we want — a single hover
        // tracked across an entire reader.
        value = value ?? nextValue()
    }
}

/// Name of the coordinate space `MarkdownReader` attaches to its
/// scrolling content. `LinkAwareTextView` uses it to convert local
/// link rects into reader-space rects so the global tooltip overlay
/// has the right (x, y) to render at.
public let linkTooltipReaderCoordinateSpace = "lumi.markdownReader"
