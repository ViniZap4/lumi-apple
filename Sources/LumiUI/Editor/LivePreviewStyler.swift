import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// How the editor shows markdown: raw (`source`, monospace with syntax
/// colour) or Obsidian-style **Live Preview** (web `editMode: 'live'`).
public enum EditorPresentation: Equatable, Sendable {
    case source
    case live(LivePreviewOptions)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

/// What Live Preview needs besides the text: the reader's prose style
/// (one prose system — reader, split preview and Live Preview share it)
/// and where relative images resolve.
public struct LivePreviewOptions: Equatable, Sendable {
    public var scale: Double
    public var fontFamily: MarkdownFontFamily
    /// Directory relative image paths resolve against (the note's folder).
    public var baseURL: URL?
    /// Book root: local images outside it never load.
    public var vaultRoot: URL?
    /// Measure (pt) of the text column, like the reader's reading width.
    public var readingWidth: Double

    public init(scale: Double = 1, fontFamily: MarkdownFontFamily = .system, baseURL: URL? = nil, vaultRoot: URL? = nil, readingWidth: Double = 760) {
        self.scale = scale
        self.fontFamily = fontFamily
        self.baseURL = baseURL
        self.vaultRoot = vaultRoot
        self.readingWidth = readingWidth
    }
}

extension NSAttributedString.Key {
    /// `LiveLineDecoration` — per-line chrome drawn by `LiveLayoutFragment`.
    static let lumiLiveLine = NSAttributedString.Key("lumi.live.line")
    /// `LiveLinkBox` — where a Live Preview link goes (⌘-click).
    static let lumiLiveLink = NSAttributedString.Key("lumi.live.link")
    /// `LiveMarkerBox` — a bullet / task box drawn over its (transparent)
    /// source characters.
    static let lumiLiveMarker = NSAttributedString.Key("lumi.live.marker")
    /// `LiveWidgetBox` — the anchor line of a block widget.
    static let lumiLiveWidget = NSAttributedString.Key("lumi.live.widget")
}

/// Link target, boxed for attribute storage.
final class LiveLinkBox: NSObject {
    let link: LiveLink
    init(_ link: LiveLink) { self.link = link }
    override func isEqual(_ object: Any?) -> Bool { (object as? LiveLinkBox)?.link == link }
    override var hash: Int { link.hashValue }
}

/// Bullet / task box drawn by the fragment.
final class LiveMarkerBox: NSObject {
    enum Kind: Hashable { case bullet(level: Int), task(checked: Bool) }
    let kind: Kind
    let color: MarkdownPlatformColor
    let accent: MarkdownPlatformColor
    let border: MarkdownPlatformColor
    init(_ kind: Kind, color: MarkdownPlatformColor, accent: MarkdownPlatformColor, border: MarkdownPlatformColor) {
        self.kind = kind
        self.color = color
        self.accent = accent
        self.border = border
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? LiveMarkerBox else { return false }
        return o.kind == kind && o.color == color && o.accent == accent && o.border == border
    }
    override var hash: Int { kind.hashValue }
}

/// A block widget anchored on a line: the reader's view of a table, code
/// block, math, diagram or image, shown in the space reserved after the
/// (collapsed) line.
final class LiveWidgetBox: NSObject {
    let payload: MarkdownBlockAttachment.Payload
    /// Line index range of the source (to put the cursor into it).
    let height: CGFloat
    init(payload: MarkdownBlockAttachment.Payload, height: CGFloat) {
        self.payload = payload
        self.height = height
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? LiveWidgetBox else { return false }
        return o.payload == payload && o.height == height
    }
    override var hash: Int { payload.hashValue }
}

/// Per-line chrome. Value-equal so attribute runs coalesce.
final class LiveLineDecoration: NSObject {
    enum Kind: Hashable {
        case none
        case code(first: Bool, last: Bool, fence: Bool)
        case frontmatter(first: Bool, last: Bool)
        case rule
        case widget
    }
    let kind: Kind
    let quoteDepth: Int
    /// Callout box slice; nil outside callouts.
    let callout: Callout?
    let hasPills: Bool
    let hasMarkers: Bool
    let palette: Colors

    struct Callout: Hashable {
        var kind: String
        var label: String
        var first: Bool
        var last: Bool
        var foldable: Bool
        var title: Bool
        /// Draw the kind label (the title text is empty).
        var drawsLabel: Bool
    }

    struct Colors: Hashable {
        var panel: MarkdownPlatformColor
        var panelBorder: MarkdownPlatformColor
        var rule: MarkdownPlatformColor
        var quoteBar: MarkdownPlatformColor
        var calloutColor: MarkdownPlatformColor
        var calloutTitle: MarkdownPlatformColor
        var em: CGFloat
        var quoteIndent: CGFloat
        var calloutPadH: CGFloat
        var calloutPadV: CGFloat
        var codePadV: CGFloat
    }

    init(kind: Kind, quoteDepth: Int, callout: Callout?, hasPills: Bool, hasMarkers: Bool, palette: Colors) {
        self.kind = kind
        self.quoteDepth = quoteDepth
        self.callout = callout
        self.hasPills = hasPills
        self.hasMarkers = hasMarkers
        self.palette = palette
    }

    var drawsNothing: Bool { kind == .none && quoteDepth == 0 && callout == nil && !hasPills && !hasMarkers }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? LiveLineDecoration else { return false }
        return o.kind == kind && o.quoteDepth == quoteDepth && o.callout == callout && o.hasPills == hasPills
            && o.hasMarkers == hasMarkers && o.palette == palette
    }
    override var hash: Int {
        var h = Hasher()
        h.combine(kind)
        h.combine(quoteDepth)
        h.combine(callout)
        return h.finalize()
    }
}

/// Turns `LivePreview` plans into text-storage **attributes** (never
/// characters): fonts, colours, paragraph styles, hidden syntax (a
/// near-zero font and a clear colour), plus the chrome attributes the
/// layout fragment and the widget overlays read.
///
/// Incremental: it remembers each line's plan key and, after an edit or
/// a cursor move, restyles only the lines whose key changed (edited
/// lines, lines entering / leaving the cursor, groups whose reveal state
/// flipped). Plans are line-relative, so lines below an edit keep their
/// key and are not touched.
@MainActor
final class LivePreviewStyler {
    let options: LivePreviewOptions
    let theme: ThemeTokens
    /// Block widgets (tables, code, math, images) render as views; false
    /// where no overlay host exists (the block then stays source).
    let widgetsEnabled: Bool
    let style: MarkdownRenderStyle
    let palette: MarkdownPalette
    let fonts: MarkdownFontBook

    private(set) var lines: [LiveLine] = []
    private var keys: [LineKey] = []
    private(set) var active: Set<Int> = []
    /// Natural heights measured by the overlays, keyed by payload + width.
    private var widgetHeights: [HeightKey: CGFloat] = [:]
    /// Text-container width (for widget height lookups).
    var containerWidth: CGFloat = 700
    /// Lines restyled by the last pass (tests).
    private(set) var lastRestyled: [Int] = []

    struct HeightKey: Hashable {
        let payload: MarkdownBlockAttachment.Payload
        let width: Int
    }

    init(theme: ThemeTokens, options: LivePreviewOptions, widgetsEnabled: Bool = true) {
        self.theme = theme
        self.options = options
        self.widgetsEnabled = widgetsEnabled
        self.style = MarkdownRenderStyle(theme: theme, scale: options.scale, fontFamily: options.fontFamily, tasksInteractive: true)
        self.palette = MarkdownPalette(theme)
        self.fonts = MarkdownFontBook(family: options.fontFamily)
    }

    // MARK: Fonts

    var baseFont: MarkdownPlatformFont { fonts.font(size: style.em) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: palette.text, .paragraphStyle: bodyParagraph()]
    }

    private static let hiddenFont = MarkdownPlatformFont.systemFont(ofSize: 0.01)

    private func lineGap(_ font: MarkdownPlatformFont, leading: CGFloat) -> CGFloat {
        #if canImport(AppKit)
        let natural = font.ascender - font.descender + font.leading
        #else
        let natural = font.lineHeight
        #endif
        return max(0, font.pointSize * leading - natural)
    }

    private func bodyParagraph() -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineGap(baseFont, leading: style.leading)
        return ps
    }

    // MARK: Passes

    /// Style the whole storage (first attach, theme / font change).
    func restyleAll(_ storage: NSTextStorage, selection: [NSRange]) {
        let ns = storage.string as NSString
        lines = LivePreview.scan(ns)
        active = LivePreview.activeLines(selection, in: lines)
        keys = computeKeys(lines: lines, active: active)
        storage.beginEditing()
        for i in lines.indices { apply(i, storage: storage, text: ns) }
        storage.endEditing()
        lastRestyled = Array(lines.indices)
    }

    /// After ranged `edits` (sequential, in the new text's coordinates
    /// for each step) and the new selection.
    func textChanged(_ storage: NSTextStorage, edits: [TextEdit], selection: [NSRange]) {
        let ns = storage.string as NSString
        let oldCount = lines.count
        let oldKeys = keys
        let newLines = LivePreview.scan(ns)
        let newActive = LivePreview.activeLines(selection, in: newLines)
        let newKeys = computeKeys(lines: newLines, active: newActive)
        // Edited span in the new text (UTF-16), over-approximated for a
        // list of sequential edits; every line-count change lies inside
        // it, so lines below shift by the line-count delta.
        var lo16 = Int.max, hi16 = -1
        for (j, e) in edits.enumerated() {
            let later = edits[(j + 1)...].reduce(0) { $0 + max(0, $1.delta) }
            lo16 = min(lo16, e.location)
            hi16 = max(hi16, e.location + e.replacementLength + later)
        }
        let shift = newLines.count - oldCount
        var lo = 0, hi = newLines.count - 1
        if lo16 != Int.max {
            lo = LivePreview.lineIndex(of: lo16, in: newLines)
            hi = LivePreview.lineIndex(of: min(hi16, ns.length), in: newLines)
        }
        var dirty = Set<Int>()
        for i in lo...max(lo, hi) where i < newLines.count {
            dirty.insert(i)
            // An edit inside a group changes its widget: restyle it whole.
            if let g = newLines[i].group { for j in g.first...g.last { dirty.insert(j) } }
        }
        for i in newLines.indices where !dirty.contains(i) {
            let old = i < lo ? i : i - shift
            if old < 0 || old >= oldKeys.count || oldKeys[old] != newKeys[i] { dirty.insert(i) }
        }
        lines = newLines
        keys = newKeys
        active = newActive
        restyle(dirty.sorted(), storage: storage, text: ns)
    }

    /// The cursor / selection moved. Returns true when lines restyled.
    @discardableResult
    func selectionChanged(_ storage: NSTextStorage, selection: [NSRange]) -> Bool {
        guard !lines.isEmpty, (storage.string as NSString).length == (lines.last.map { $0.start + $0.length } ?? 0) else { return false }
        let newActive = LivePreview.activeLines(selection, in: lines)
        guard newActive != active else { return false }
        let newKeys = computeKeys(lines: lines, active: newActive)
        var dirty: [Int] = []
        for i in lines.indices where newKeys[i] != keys[i] { dirty.append(i) }
        active = newActive
        keys = newKeys
        guard !dirty.isEmpty else { return false }
        restyle(dirty, storage: storage, text: storage.string as NSString)
        return true
    }

    /// An overlay measured its widget. Returns true when the reserved
    /// space changed (the anchor line was restyled).
    @discardableResult
    func widgetMeasured(_ payload: MarkdownBlockAttachment.Payload, height: CGFloat, storage: NSTextStorage) -> Bool {
        let key = HeightKey(payload: payload, width: Int(containerWidth.rounded()))
        if let old = widgetHeights[key], abs(old - height) < 0.5 { return false }
        widgetHeights[key] = height
        MarkdownAttachmentHeightCache.store(height, for: payload, width: containerWidth, scale: options.scale)
        let ns = storage.string as NSString
        var targets: [Int] = []
        for i in lines.indices {
            if case let .widget(w)? = currentStyle(i, text: ns), self.payload(for: w) == payload { targets.append(i) }
        }
        guard !targets.isEmpty else { return false }
        restyle(targets, storage: storage, text: ns)
        return true
    }

    func reservedHeight(for payload: MarkdownBlockAttachment.Payload) -> CGFloat {
        if let h = widgetHeights[HeightKey(payload: payload, width: Int(containerWidth.rounded()))] { return h }
        if let h = MarkdownAttachmentHeightCache.height(for: payload, width: containerWidth, scale: options.scale) { return h }
        return MarkdownBlockAttachment.estimatedHeight(for: payload, scale: CGFloat(options.scale))
    }

    private func restyle(_ indices: [Int], storage: NSTextStorage, text: NSString) {
        guard !indices.isEmpty else { lastRestyled = []; return }
        storage.beginEditing()
        for i in indices where i < lines.count { apply(i, storage: storage, text: text) }
        storage.endEditing()
        lastRestyled = indices
    }

    // MARK: Keys

    /// Everything a line's look depends on besides its own text.
    struct LineKey: Equatable {
        var kind: LiveLineKind
        var quote: LiveQuote?
        var groupBefore: Int
        var groupAfter: Int
        var active: Bool
        var revealed: Bool
    }

    private func computeKeys(lines: [LiveLine], active: Set<Int>) -> [LineKey] {
        let revealed = LivePreview.revealedGroups(active, in: lines)
        return lines.indices.map { i in
            let l = lines[i]
            return LineKey(kind: l.kind, quote: l.quote,
                           groupBefore: l.group.map { i - $0.first } ?? -1,
                           groupAfter: l.group.map { $0.last - i } ?? -1,
                           active: active.contains(i),
                           revealed: !widgetsEnabled || (l.group.map(revealed.contains) ?? false))
        }
    }

    private func isRevealed(_ i: Int) -> Bool {
        guard i < keys.count else { return true }
        return keys[i].revealed
    }

    private func currentStyle(_ i: Int, text: NSString) -> LiveLineStyle? {
        guard i < lines.count else { return nil }
        return LivePreview.plan(i, lines: lines, text: text, active: active.contains(i), groupRevealed: isRevealed(i)).style
    }

    // MARK: Widgets

    func payload(for widget: LiveWidget) -> MarkdownBlockAttachment.Payload? {
        switch widget {
        case let .code(language, code): return .code(language: language, code: code)
        case let .math(latex): return .mathBlock(latex: latex)
        case let .mermaid(code): return .mermaid(code: code)
        case let .table(source):
            if case let .table(t)? = MarkdownParser.parse(source).blocks.first { return .table(t) }
            return nil
        case let .image(source):
            guard case let .media(ref)? = MarkdownParser.parse(source, baseURL: options.baseURL).blocks.first,
                  ref.kind == .image, Self.imageAllowed(ref.url, vaultRoot: options.vaultRoot) else { return nil }
            return .media(ref)
        }
    }

    /// Images load from https or from inside the book; anything else
    /// (http, file paths outside the book, other schemes) stays source.
    static func imageAllowed(_ url: URL, vaultRoot: URL?) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "file":
            guard let root = vaultRoot else { return false }
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path
            let p = url.standardizedFileURL.resolvingSymlinksInPath().path
            return p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        default:
            return false
        }
    }

    // MARK: Attributes

    /// Per-UTF-16-unit inline flags, folded into attribute runs.
    private struct Flags: Equatable {
        var hide = false
        var marker = false
        var strong = false
        var em = false
        var strike = false
        var code = false
        var mark = false
        var footnote = false
        var link: LiveLink?
        var bullet = false
        var task: Bool?
    }

    private struct LineContext {
        var size: CGFloat
        var weight: MarkdownPlatformFont.Weight
        var mono: Bool
        var color: MarkdownPlatformColor
        var tracking: CGFloat = 0
    }

    private func apply(_ i: Int, storage: NSTextStorage, text: NSString) {
        let line = lines[i]
        let isActive = active.contains(i)
        var plan = LivePreview.plan(i, lines: lines, text: text, active: isActive, groupRevealed: isRevealed(i))
        // A widget whose source cannot render (an unsafe image, a broken
        // table) stays plain text.
        var widgetPayload: MarkdownBlockAttachment.Payload?
        if case let .widget(w) = plan.style {
            if widgetsEnabled, let p = payload(for: w) {
                widgetPayload = p
            } else if case .image = w {
                plan = LivePreview.plan(i, lines: lines, text: text, active: true, groupRevealed: true)
            } else {
                plan = LivePreview.plan(i, lines: lines, text: text, active: isActive, groupRevealed: true)
            }
        }
        let terminator = line.start + line.length < text.length ? 1 : 0
        let full = NSRange(location: line.start, length: line.length + terminator)
        guard NSMaxRange(full) <= storage.length else { return }

        // Line context (font / colour / paragraph).
        var ctx = LineContext(size: style.em, weight: .regular, mono: false, color: palette.text)
        let ps = NSMutableParagraphStyle()
        var indent: CGFloat = 0
        var tail: CGFloat = 0
        var decoKind: LiveLineDecoration.Kind = .none
        var collapsed = false

        switch plan.style {
        case .body:
            ps.lineSpacing = lineGap(fonts.font(size: style.em), leading: style.leading)
        case let .heading(level):
            let size = style.headingSize(level)
            ctx.size = size
            ctx.weight = level == 1 ? .bold : .semibold
            ctx.tracking = MarkdownRenderStyle.headingTracking(level) * size
            ctx.color = level == 5 ? palette.dim : level == 6 ? palette.marker : palette.text
            ps.lineSpacing = lineGap(fonts.font(size: size, weight: .semibold), leading: MarkdownRenderStyle.headingLeading(level))
            ps.paragraphSpacingBefore = i == 0 ? 0 : max(0, (level <= 2 ? 0.55 : 0.45) * size)
            ps.paragraphSpacing = 0.1 * size
            #if canImport(AppKit)
            ps.headerLevel = level
            #endif
        case let .code(fence, first, last):
            ctx.mono = true
            ctx.size = fence ? 0.75 * style.em : style.codeSize
            ctx.color = fence ? palette.marker : palette.text
            let font = fonts.font(size: style.codeSize, monospaced: true)
            ps.lineSpacing = lineGap(font, leading: 1.6)
            if fence {
                ps.minimumLineHeight = font.pointSize * 1.6
            }
            indent = style.codePaddingH
            tail = style.codePaddingH
            ps.paragraphSpacingBefore = first ? 0.6 * style.codePaddingV : 0
            ps.paragraphSpacing = last ? 0.6 * style.codePaddingV : 0
            decoKind = .code(first: first, last: last, fence: fence)
        case .source:
            ctx.mono = true
            ctx.size = 0.86 * style.em
            ps.lineSpacing = lineGap(fonts.font(size: ctx.size, monospaced: true), leading: 1.6)
        case let .frontmatter(first, last):
            ctx.mono = true
            ctx.size = 0.8 * style.em
            ctx.color = palette.dim
            ps.lineSpacing = lineGap(fonts.font(size: ctx.size, monospaced: true), leading: 1.5)
            indent = 0.9 * style.em
            tail = 0.9 * style.em
            ps.paragraphSpacingBefore = first ? 0.5 * style.em : 0
            ps.paragraphSpacing = last ? 0.9 * style.em : 0
            decoKind = .frontmatter(first: first, last: last)
        case .collapsed:
            collapsed = true
        case .widget:
            collapsed = true
            decoKind = .widget
            if let p = widgetPayload {
                ps.paragraphSpacingBefore = 0.3 * style.em
                ps.paragraphSpacing = reservedHeight(for: p) + 0.3 * style.em
            }
        case .rule:
            ctx.color = .clear
            ps.lineSpacing = lineGap(baseFont, leading: style.leading)
            ps.paragraphSpacingBefore = 0.6 * style.em
            ps.paragraphSpacing = 0.6 * style.em
            decoKind = .rule
        case .ruleSource:
            ctx.color = palette.marker
            ps.lineSpacing = lineGap(baseFont, leading: style.leading)
            ps.paragraphSpacingBefore = 0.6 * style.em
            ps.paragraphSpacing = 0.6 * style.em
        }

        // Quote / callout container.
        var calloutDeco: LiveLineDecoration.Callout?
        if let q = plan.quote, !collapsed {
            if let c = q.callout {
                indent += 3 + style.calloutPaddingH
                tail += style.calloutPaddingH
                if plan.calloutFirst { ps.paragraphSpacingBefore = max(ps.paragraphSpacingBefore, style.calloutPaddingV + 0.2 * style.em) }
                if plan.calloutLast { ps.paragraphSpacing = max(ps.paragraphSpacing, style.calloutPaddingV + 0.2 * style.em) }
                let titleEmpty = c.isTitle && (line.length <= c.markerOffset + c.markerLength
                    || text.substring(with: NSRange(location: line.start + c.markerOffset + c.markerLength,
                                                    length: line.length - c.markerOffset - c.markerLength)).trimmingCharacters(in: .whitespaces).isEmpty)
                if c.isTitle {
                    ctx.weight = .semibold
                    ctx.size = 0.95 * style.em
                    ctx.color = MarkdownPalette.mix(palette.callout(c.kind), palette.text, 0.72)
                    indent += 1.45 * ctx.size
                }
                calloutDeco = .init(kind: c.kind, label: c.rawKind.prefix(1).uppercased() + c.rawKind.dropFirst(),
                                    first: plan.calloutFirst, last: plan.calloutLast, foldable: c.foldable,
                                    title: c.isTitle, drawsLabel: titleEmpty && !isActive)
            } else {
                indent += CGFloat(q.depth) * style.quoteIndent
                if ctx.color == palette.text { ctx.color = palette.dim }
            }
        }
        if plan.taskDone, !collapsed { ctx.color = palette.dim }

        // Lists: hanging indent so wrapped lines align with the text.
        var listMarker: LiveMarkerBox?
        if let item = plan.list, !collapsed {
            let step = 1.55 * style.em
            let lead = CGFloat(item.level) * step
            ps.headIndent = indent + lead + (item.taskOffset != nil ? 1.6 : item.ordered ? 1.4 : 1.15) * style.em
            if plan.drawsMarker {
                listMarker = item.taskOffset != nil
                    ? LiveMarkerBox(.task(checked: item.checked),
                                    color: palette.marker, accent: palette.primary, border: palette.marker)
                    : LiveMarkerBox(.bullet(level: item.level), color: palette.marker, accent: palette.primary, border: palette.marker)
            }
        } else {
            ps.headIndent = indent
        }
        ps.firstLineHeadIndent = indent
        ps.tailIndent = -tail

        // Build the flag array.
        let n = line.length
        var flags = [Flags](repeating: Flags(), count: n)
        for span in plan.spans {
            let lo = max(0, span.range.location), hi = min(n, NSMaxRange(span.range))
            guard lo < hi else { continue }
            for k in lo..<hi {
                switch span.style {
                case .hide: flags[k].hide = true
                case .marker: flags[k].marker = true
                case .strong: flags[k].strong = true
                case .emphasis: flags[k].em = true
                case .strike: flags[k].strike = true
                case .code: flags[k].code = true
                case .mark: flags[k].mark = true
                case let .link(l): flags[k].link = l
                case .footnote: flags[k].footnote = true
                case .bullet: flags[k].bullet = true
                case let .taskBox(checked): flags[k].task = checked
                }
            }
        }

        let hasPills = flags.contains { ($0.code || $0.mark) && !$0.hide }
        let decoration = LiveLineDecoration(
            kind: decoKind, quoteDepth: (plan.quote?.callout == nil && !collapsed) ? (plan.quote?.depth ?? 0) : 0,
            callout: collapsed ? nil : calloutDeco, hasPills: hasPills, hasMarkers: listMarker != nil,
            palette: colors(calloutKind: calloutDeco?.kind)
        )

        // Base attributes for the whole line (terminator included: TextKit
        // reads paragraph attributes there for empty lines).
        if collapsed {
            let cps = NSMutableParagraphStyle()
            cps.minimumLineHeight = 0.01
            cps.maximumLineHeight = 0.01
            cps.paragraphSpacingBefore = ps.paragraphSpacingBefore
            cps.paragraphSpacing = ps.paragraphSpacing
            var attrs: [NSAttributedString.Key: Any] = [
                .font: Self.hiddenFont, .foregroundColor: MarkdownPlatformColor.clear, .paragraphStyle: cps,
                .lumiLiveLine: decoration,
            ]
            if let widgetPayload { attrs[.lumiLiveWidget] = LiveWidgetBox(payload: widgetPayload, height: reservedHeight(for: widgetPayload)) }
            storage.setAttributes(attrs, range: full)
            return
        }

        let lineFont = font(for: Flags(), ctx: ctx)
        var lineAttrs: [NSAttributedString.Key: Any] = [
            .font: lineFont, .foregroundColor: ctx.color, .paragraphStyle: ps, .lumiLiveLine: decoration,
        ]
        if ctx.tracking != 0 { lineAttrs[.kern] = ctx.tracking }
        storage.setAttributes(lineAttrs, range: full)

        // Inline runs.
        var k = 0
        let codeTokens = codeColors(plan: plan, line: line, text: text)
        while k < n {
            var e = k + 1
            while e < n, flags[e] == flags[k] { e += 1 }
            let f = flags[k]
            let r = NSRange(location: line.start + k, length: e - k)
            if f != Flags() {
                storage.addAttributes(attributes(for: f, ctx: ctx, marker: listMarker), range: r)
            }
            k = e
        }
        for (range, color) in codeTokens {
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: line.start + range.location, length: range.length))
        }
        // Leading whitespace of list lines: widen so nesting reads (a
        // proportional space is ~0.28 em).
        if let item = plan.list, item.indent > 0 {
            let lead = NSRange(location: line.start + (plan.quote?.prefixLength ?? 0), length: item.indent)
            if NSMaxRange(lead) <= line.start + n {
                storage.addAttribute(.kern, value: 0.5 * style.em, range: lead)
            }
        }
    }

    private func font(for f: Flags, ctx: LineContext) -> MarkdownPlatformFont {
        var size = ctx.size
        var weight = ctx.weight
        var mono = ctx.mono
        if f.code, !ctx.mono {
            mono = true
            size = ctx.size * 0.86
        }
        if f.footnote { size = ctx.size * 0.75 }
        if f.strong { weight = weight == .bold ? .heavy : (ctx.weight == .semibold ? .bold : .semibold) }
        return fonts.font(size: size, weight: weight, italic: f.em, monospaced: mono)
    }

    private func attributes(for f: Flags, ctx: LineContext, marker: LiveMarkerBox?) -> [NSAttributedString.Key: Any] {
        if f.hide {
            return [.font: Self.hiddenFont, .foregroundColor: MarkdownPlatformColor.clear, .kern: 0]
        }
        var a: [NSAttributedString.Key: Any] = [.font: font(for: f, ctx: ctx)]
        if f.marker { a[.foregroundColor] = palette.marker }
        if f.strike {
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            a[.foregroundColor] = palette.dim
        }
        if f.code {
            a[.foregroundColor] = f.marker ? palette.marker : palette.text
            if !f.marker {
                a[.lumiPill] = MarkdownPill(kind: .code, fill: palette.inlineBackground)
            }
        }
        if f.mark, !f.marker { a[.lumiPill] = MarkdownPill(kind: .mark, fill: palette.markBackground) }
        if f.footnote {
            a[.foregroundColor] = palette.primary
            a[.baselineOffset] = 0.42 * ctx.size
        }
        if let link = f.link, !f.marker {
            a[.foregroundColor] = palette.primary
            a[.underlineStyle] = link == .inert ? 0 : NSUnderlineStyle.single.rawValue
            a[.underlineColor] = palette.linkLine
            a[.lumiLiveLink] = LiveLinkBox(link)
            #if canImport(AppKit)
            switch link {
            case let .external(href): a[.toolTip] = "\(href) — ⌘-click to open"
            case let .note(href): a[.toolTip] = "\(href) — ⌘-click to open the note"
            case .inert: break
            }
            #endif
        }
        if f.bullet, let marker {
            a[.foregroundColor] = MarkdownPlatformColor.clear
            a[.lumiLiveMarker] = marker
            a[.kern] = 0.7 * style.em
        }
        if f.task != nil, let marker {
            a[.foregroundColor] = MarkdownPlatformColor.clear
            a[.lumiLiveMarker] = marker
            // Three narrow cells ≈ the box plus its gap.
            a[.font] = fonts.font(size: 0.6 * style.em, monospaced: true)
            a[.kern] = 0.05 * style.em
        }
        return a
    }

    /// Syntax colours inside a revealed code line.
    private func codeColors(plan: LiveLinePlan, line: LiveLine, text: NSString) -> [(NSRange, MarkdownPlatformColor)] {
        guard case let .code(fence, _, _) = plan.style, !fence, case let .code(info) = line.kind, line.length > 0 else { return [] }
        let src = text.substring(with: line.range)
        return CodeHighlighter.tokens(src, language: info.isEmpty ? nil : info).compactMap { t in
            guard NSMaxRange(t.range) <= line.length else { return nil }
            return (t.range, tokenColor(t.kind))
        }
    }

    private func tokenColor(_ kind: CodeHighlighter.Kind) -> MarkdownPlatformColor {
        switch kind {
        case .keyword: return palette.secondary
        case .string, .inserted: return palette.accent
        case .number: return palette.warning
        case .comment: return palette.marker
        case .function: return palette.info
        case .type, .heading: return palette.primary
        case .property: return MarkdownPalette.mix(palette.info, palette.text, 0.7)
        case .tag, .deleted: return palette.error
        case .punctuation: return palette.dim
        }
    }

    private func colors(calloutKind: String?) -> LiveLineDecoration.Colors {
        let c = calloutKind.map { palette.callout($0) } ?? palette.primary
        return .init(panel: palette.text.withAlphaComponent(0.045), panelBorder: palette.codeBorder, rule: palette.rule,
                     quoteBar: palette.quoteBar, calloutColor: c,
                     calloutTitle: MarkdownPalette.mix(c, palette.text, 0.72),
                     em: style.em, quoteIndent: style.quoteIndent, calloutPadH: style.calloutPaddingH,
                     calloutPadV: style.calloutPaddingV, codePadV: style.codePaddingV)
    }
}
