import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// `[MarkdownDecoration]` — block chrome (code background, quote bar,
    /// rule) drawn by `MarkdownLayoutFragment` behind a paragraph.
    static let lumiDecorations = NSAttributedString.Key("lumi.decorations")
    /// `String` — what a copy of this run should put on the pasteboard
    /// instead of its visible characters. Set on attachment characters
    /// (math, diagrams, media) so ⌘C yields the markdown source rather
    /// than U+FFFC.
    static let lumiSourceText = NSAttributedString.Key("lumi.sourceText")
    /// `Bool` — run is a tag chip in the note header. The layout fragment
    /// draws a capsule behind it.
    static let lumiChip = NSAttributedString.Key("lumi.chip")
    /// `MarkdownPill` — rounded background behind an inline run (inline
    /// code, `<kbd>`, `==mark==`), drawn by the layout fragment.
    static let lumiPill = NSAttributedString.Key("lumi.pill")
    /// `String` — in-document anchor (heading slug, `fn-id`, `fnref-id`)
    /// that `#…` links and footnote refs scroll to.
    static let lumiAnchor = NSAttributedString.Key("lumi.anchor")
    /// `Int` — ordinal of a task checkbox inside its top-level block.
    static let lumiTask = NSAttributedString.Key("lumi.task")
}

/// Rounded background for an inline run. Value-equal so attribute
/// dictionaries stay uniquable (see `MarkdownDecoration`).
final class MarkdownPill: NSObject {
    enum Kind: Equatable { case code, kbd, mark }
    let kind: Kind
    let fill: MarkdownPlatformColor
    let stroke: MarkdownPlatformColor?

    init(kind: Kind, fill: MarkdownPlatformColor, stroke: MarkdownPlatformColor? = nil) {
        self.kind = kind
        self.fill = fill
        self.stroke = stroke
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? MarkdownPill else { return false }
        return kind == o.kind && fill == o.fill && stroke == o.stroke
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(String(describing: kind))
        return h.finalize()
    }
}

/// Unicode LINE SEPARATOR. Used for hard breaks and for newlines inside
/// fenced code so a whole code block stays *one* paragraph — therefore
/// one layout fragment — and its rounded background is drawn in one
/// piece instead of per line.
let markdownLineSeparator = "\u{2028}"

/// One layer of block chrome for a paragraph. Builders stamp one per
/// enclosing container (inner first), with `isFirst` / `isLast` telling
/// the fragment whether to round/pad the top and bottom edge or to run
/// flush into the neighbouring paragraph of the same container.
final class MarkdownDecoration: NSObject {
    enum Kind: Equatable {
        case codeBlock(language: String?)
        case quote
        case rule
        /// Header tag line: capsule behind every `.lumiChip` run.
        case chips
        /// Callout box (fill, border, left bar); `foldable` draws a
        /// chevron on the title line, rotated when `open`.
        case callout(foldable: Bool, open: Bool)
        /// Fading hairline under an `h2`.
        case headingRule
        /// Paragraph has `.lumiPill` runs (inline code, kbd, mark).
        case pills
        /// Footnote list: hairline above.
        case footnotes
    }

    let kind: Kind
    /// Container-space x where the chrome starts.
    let indent: CGFloat
    let padding: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let fill: MarkdownPlatformColor
    let stroke: MarkdownPlatformColor
    let labelColor: MarkdownPlatformColor
    let labelFont: MarkdownPlatformFont?

    init(
        kind: Kind,
        indent: CGFloat,
        padding: CGFloat,
        isFirst: Bool = true,
        isLast: Bool = true,
        fill: MarkdownPlatformColor,
        stroke: MarkdownPlatformColor,
        labelColor: MarkdownPlatformColor,
        labelFont: MarkdownPlatformFont? = nil
    ) {
        self.kind = kind
        self.indent = indent
        self.padding = padding
        self.isFirst = isFirst
        self.isLast = isLast
        self.fill = fill
        self.stroke = stroke
        self.labelColor = labelColor
        self.labelFont = labelFont
    }

    // Value semantics for attribute-dictionary uniquing. Foundation
    // interns attribute dictionaries in a global table; with identity
    // equality every paragraph's dictionary was unique and colliding,
    // which made building a large note quadratic.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownDecoration else { return false }
        return kind == other.kind && indent == other.indent && padding == other.padding
            && isFirst == other.isFirst && isLast == other.isLast
            && fill == other.fill && stroke == other.stroke && labelColor == other.labelColor
            && labelFont == other.labelFont
    }

    override var hash: Int {
        var hasher = Hasher()
        switch kind {
        case let .codeBlock(language): hasher.combine(0); hasher.combine(language)
        case .quote: hasher.combine(1)
        case .rule: hasher.combine(2)
        case .chips: hasher.combine(3)
        case let .callout(f, o): hasher.combine(4); hasher.combine(f); hasher.combine(o)
        case .headingRule: hasher.combine(5)
        case .pills: hasher.combine(6)
        case .footnotes: hasher.combine(7)
        }
        hasher.combine(indent)
        hasher.combine(padding)
        hasher.combine(isFirst)
        hasher.combine(isLast)
        return hasher.finalize()
    }

    func with(isFirst: Bool, isLast: Bool) -> MarkdownDecoration {
        MarkdownDecoration(
            kind: kind, indent: indent, padding: padding,
            isFirst: isFirst, isLast: isLast,
            fill: fill, stroke: stroke, labelColor: labelColor, labelFont: labelFont
        )
    }
}

/// Text attachment standing in for a block that can't be expressed as
/// attributed text (KaTeX, Mermaid, images, video, PDF, embeds). It
/// reserves a full-width rectangle in the text flow; the platform text
/// view hosts the real SwiftUI view on top of that rectangle, but only
/// while it is near the viewport (see `MarkdownAttachmentOverlays`).
///
/// Height is owned here, not by SwiftUI state: the hosted view reports
/// its natural height (it is laid out at a fixed width with
/// `fixedSize(vertical:)`, so height never depends on the frame we give
/// it — no feedback loop is possible), the overlay controller writes it
/// to `height` and invalidates layout for this one character.
final class MarkdownBlockAttachment: NSTextAttachment {
    enum Payload: Hashable {
        case mathBlock(latex: String)
        case mathParagraph(inline: [InlineNode])
        case mathHeading(inline: [InlineNode], level: Int)
        case mermaid(code: String)
        case media(MediaReference)
        /// Fenced code: header (language, copy, wrap) + highlighted body.
        case code(language: String?, code: String)
        case table(MarkdownTable)
    }

    let payload: Payload
    /// Last known natural height. Seeded from the shared height cache or
    /// a per-kind estimate, corrected once the hosted view measures.
    var height: CGFloat
    /// Text the attachment stands for, used by VoiceOver.
    let spokenText: String

    init(payload: Payload, height: CGFloat, spokenText: String) {
        self.payload = payload
        self.height = height
        self.spokenText = spokenText
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
        #if canImport(UIKit)
        accessibilityLabel = spokenText
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not coded") }

    static func estimatedHeight(for payload: Payload, scale: CGFloat) -> CGFloat {
        switch payload {
        case .mathBlock: return 40 * scale
        case .mathParagraph: return 26 * scale
        case let .mathHeading(_, level): return (MarkdownRenderStyle.headingBaseSize(level) + 10) * scale
        case .mermaid: return 160
        case let .code(_, code):
            let lines = CGFloat(max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count))
            return (lines * 14.3 * 1.6 + 32 + 28) * scale
        case let .table(t):
            return CGFloat(t.rows.count + 1) * 36 * scale + 2
        case let .media(ref):
            switch ref.kind {
            case .image: return 220
            case .video, .youtube, .vimeo: return 300
            case .pdf: return 420
            case .markdown: return 120
            case .unknown: return 60
            }
        }
    }

    // TextKit 2 sizing: full line width, our height.
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        CGRect(x: 0, y: 0, width: max(1, proposedLineFragment.width), height: max(1, height))
    }

    // Nothing to draw — the hosted view sits on top of this rect.
    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> MarkdownPlatformImage? {
        Self.blank
    }

    #if canImport(AppKit)
    private static let blank = NSImage(size: NSSize(width: 1, height: 1))
    #else
    private static let blank = UIImage()
    #endif
}

#if canImport(AppKit)
typealias MarkdownPlatformImage = NSImage
#else
typealias MarkdownPlatformImage = UIImage
#endif

/// Natural heights measured by hosted attachment views, remembered across
/// re-renders and note switches so a re-opened note lays out at its real
/// height straight away instead of estimate → measure → jump.
@MainActor
enum MarkdownAttachmentHeightCache {
    private struct Key: Hashable {
        let payload: MarkdownBlockAttachment.Payload
        let width: Int
        let scale: Double
    }

    private static var heights: [Key: CGFloat] = [:]

    static func height(for payload: MarkdownBlockAttachment.Payload, width: CGFloat, scale: Double) -> CGFloat? {
        heights[Key(payload: payload, width: Int(width.rounded()), scale: scale)]
            ?? lastHeightAnyWidth[LastKey(payload: payload, scale: scale)]
    }

    static func store(_ height: CGFloat, for payload: MarkdownBlockAttachment.Payload, width: CGFloat, scale: Double) {
        if heights.count > 4_096 { heights.removeAll(keepingCapacity: true) }
        heights[Key(payload: payload, width: Int(width.rounded()), scale: scale)] = height
        if lastHeightAnyWidth.count > 4_096 { lastHeightAnyWidth.removeAll(keepingCapacity: true) }
        lastHeightAnyWidth[LastKey(payload: payload, scale: scale)] = height
    }

    private struct LastKey: Hashable {
        let payload: MarkdownBlockAttachment.Payload
        let scale: Double
    }

    /// Width-agnostic fallback: the last height seen at any width is a far
    /// better seed than a per-kind constant.
    private static var lastHeightAnyWidth: [LastKey: CGFloat] = [:]
}
