import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Turns parsed markdown blocks into TextKit-ready attributed text: one
/// self-contained fragment per top-level block, each ending in a
/// paragraph separator so fragments concatenate (and splice) cleanly.
///
/// Pure function of `(block, style)` — no view state, no environment —
/// which is what makes the per-block fragment cache in
/// `MarkdownDocumentRenderer` sound.
@MainActor
final class MarkdownAttributedBuilder {
    let style: MarkdownRenderStyle
    let palette: MarkdownPalette
    private let fonts: MarkdownFontBook

    init(style: MarkdownRenderStyle) {
        self.style = style
        self.palette = MarkdownPalette(style.theme)
        self.fonts = MarkdownFontBook(family: style.fontFamily)
    }

    private struct Context {
        var indent: CGFloat = 0
        var textColor: MarkdownPlatformColor
    }

    private var rootContext: Context { Context(indent: 0, textColor: palette.text) }

    // MARK: - Public entry points

    /// Fragment for a top-level block, trailing block gap included.
    func fragment(for block: MarkdownBlock) -> NSAttributedString {
        let out = build(block, rootContext)
        adjustLastParagraph(out) { $0.paragraphSpacing += style.blockGap }
        return out
    }

    /// Title + tag chips + hairline rule rendered at the top of the note,
    /// inside the same text flow so the whole page selects as one.
    func header(title: String, tags: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !title.isEmpty {
            let run = NSAttributedString(string: title, attributes: [
                .font: fonts.font(size: style.titleSize, weight: .bold),
                .foregroundColor: palette.primary,
            ])
            out.append(paragraph(run, ctx: rootContext, after: 10 * style.s) { $0.lineSpacing = 2 })
        }
        if !tags.isEmpty {
            let line = NSMutableAttributedString()
            let chipFont = fonts.font(size: 12 * style.s, weight: .medium)
            for (i, tag) in tags.enumerated() {
                if i > 0 {
                    line.append(NSAttributedString(string: "\u{2003}\u{2002}", attributes: [.font: chipFont]))
                }
                line.append(NSAttributedString(string: "#\(tag)", attributes: [
                    .font: chipFont,
                    .foregroundColor: palette.accent,
                    .lumiChip: true,
                ]))
            }
            let chips = paragraph(line, ctx: Context(indent: 8 * style.s, textColor: palette.text), after: 12 * style.s) {
                $0.lineSpacing = 8 * self.style.s
            }
            wrap(chips, in: MarkdownDecoration(
                kind: .chips, indent: 0, padding: 0,
                fill: palette.accent.withAlphaComponent(0.12),
                stroke: palette.accent.withAlphaComponent(0.25),
                labelColor: palette.accent
            ))
            out.append(chips)
        }
        out.append(rule(ctx: rootContext, color: palette.border, before: 2 * style.s, after: 22 * style.s))
        return out
    }

    // MARK: - Blocks

    private func build(_ block: MarkdownBlock, _ ctx: Context) -> NSMutableAttributedString {
        switch block {
        case let .heading(level, inline):
            if InlineRenderer.containsMath(inline) {
                return attachmentParagraph(.mathHeading(inline: inline, level: level), source: plainSource(inline), ctx: ctx,
                                           before: style.headingSpacingBefore(level))
            }
            let run = inlineText(inline, base: InlineBase(
                size: style.headingSize(level), weight: .semibold, color: ctx.textColor
            ))
            return paragraph(run, ctx: ctx, before: style.headingSpacingBefore(level)) {
                $0.lineSpacing = 2
                #if canImport(AppKit)
                $0.headerLevel = level
                #endif
            }

        case let .paragraph(inline):
            if InlineRenderer.containsMath(inline) {
                return attachmentParagraph(.mathParagraph(inline: inline), source: plainSource(inline), ctx: ctx)
            }
            let run = inlineText(inline, base: InlineBase(size: style.bodySize, weight: .regular, color: ctx.textColor))
            return paragraph(run, ctx: ctx) { $0.lineSpacing = self.style.bodyLineSpacing }

        case let .codeBlock(language, code):
            if language?.lowercased() == "mermaid" {
                return attachmentParagraph(.mermaid(code: code), source: "```mermaid\n\(code)```", ctx: ctx)
            }
            return codeBlock(language: language, code: code, ctx: ctx)

        case let .blockQuote(blocks):
            var inner = ctx
            inner.indent += style.quoteIndent
            inner.textColor = ctx.textColor.withAlphaComponent(0.82)
            let out = stack(blocks, ctx: inner, gap: style.quoteGap)
            let deco = MarkdownDecoration(
                kind: .quote, indent: ctx.indent, padding: style.quotePadding,
                fill: palette.accent.withAlphaComponent(0.05),
                stroke: palette.accent.withAlphaComponent(0.6),
                labelColor: palette.textDim
            )
            wrap(out, in: deco)
            return out

        case let .unorderedList(items):
            return list(items, ordered: false, start: 1, ctx: ctx)

        case let .orderedList(start, items):
            return list(items, ordered: true, start: start, ctx: ctx)

        case .thematicBreak:
            return rule(ctx: ctx, color: palette.separator, before: 8 * style.s, after: 8 * style.s)

        case let .media(ref):
            return attachmentParagraph(.media(ref), source: "![\(ref.alt)](\(ref.url.absoluteString))", ctx: ctx)

        case let .mathBlock(latex):
            return attachmentParagraph(.mathBlock(latex: latex), source: "$$\(latex)$$", ctx: ctx)
        }
    }

    /// Sibling blocks inside a container, separated by `gap`.
    private func stack(_ blocks: [MarkdownBlock], ctx: Context, gap: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let part = build(block, ctx)
            if i < blocks.count - 1 {
                adjustLastParagraph(part) { $0.paragraphSpacing += gap }
            }
            out.append(part)
        }
        if out.length == 0 {
            out.append(paragraph(NSAttributedString(string: " "), ctx: ctx))
        }
        return out
    }

    private func codeBlock(language: String?, code: String, ctx: Context) -> NSMutableAttributedString {
        var body = code
        while body.hasSuffix("\n") { body.removeLast() }
        if body.isEmpty { body = " " }
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: markdownLineSeparator)
        let run = NSAttributedString(string: body, attributes: [
            .font: fonts.font(size: style.codeSize, monospaced: true),
            .foregroundColor: ctx.textColor,
        ])
        let pad = style.codePaddingV
        let out = paragraph(run, ctx: ctx, before: pad, after: pad) {
            $0.firstLineHeadIndent = ctx.indent + self.style.codePaddingH
            $0.headIndent = ctx.indent + self.style.codePaddingH
            $0.tailIndent = -self.style.codePaddingH
            $0.lineSpacing = 2 * self.style.s
            $0.lineBreakMode = .byCharWrapping
        }
        let lang = language.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let deco = MarkdownDecoration(
            kind: .codeBlock(language: lang), indent: ctx.indent, padding: pad,
            fill: palette.overlayBackground,
            stroke: palette.border.withAlphaComponent(0.4),
            labelColor: palette.textDim,
            labelFont: fonts.font(size: 10, weight: .medium, monospaced: true)
        )
        wrap(out, in: deco)
        return out
    }

    private func list(_ items: [ListItemContent], ordered: Bool, start: Int, ctx: Context) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var inner = ctx
        inner.indent += style.listMarkerColumn
        for (index, item) in items.enumerated() {
            let content = stack(item.blocks, ctx: inner, gap: style.listItemGap)
            let marker = markerRun(item: item, ordered: ordered, number: start + index)
            let firstPara = (content.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            let firstIsText = content.length > 0
                && content.attribute(.attachment, at: 0, effectiveRange: nil) == nil
                && content.attribute(.lumiDecorations, at: 0, effectiveRange: nil) == nil
            let tabs = [
                NSTextTab(textAlignment: .right, location: ctx.indent + style.listMarkerWidth),
                NSTextTab(textAlignment: .left, location: inner.indent),
            ]
            if firstIsText {
                content.insert(marker, at: 0)
                let range = NSRange(location: 0, length: firstPara.length + marker.length)
                mutateParagraphStyle(content, range: range) {
                    $0.firstLineHeadIndent = ctx.indent
                    $0.tabStops = tabs
                }
            } else {
                let lone = paragraph(marker, ctx: inner, after: 2 * style.s) {
                    $0.firstLineHeadIndent = ctx.indent
                    $0.tabStops = tabs
                }
                content.insert(lone, at: 0)
            }
            if index < items.count - 1 {
                adjustLastParagraph(content) { $0.paragraphSpacing += self.style.listItemGap }
            }
            out.append(content)
        }
        return out
    }

    private func markerRun(item: ListItemContent, ordered: Bool, number: Int) -> NSAttributedString {
        let font = fonts.font(size: style.bodySize)
        let out = NSMutableAttributedString(string: "\t", attributes: [.font: font])
        if let checkbox = item.checkbox {
            let checked = checkbox == .checked
            let glyph = NSMutableAttributedString(attachment: checkboxAttachment(checked: checked, font: font))
            glyph.addAttributes([
                .font: font,
                .lumiSourceText: checked ? "[x] " : "[ ] ",
            ], range: NSRange(location: 0, length: glyph.length))
            out.append(glyph)
        } else {
            out.append(NSAttributedString(string: ordered ? "\(number)." : "•", attributes: [
                .font: ordered ? MarkdownPlatformFont.monospacedDigitSystemFont(ofSize: style.bodySize, weight: .regular) : font,
                .foregroundColor: palette.textDim,
            ]))
        }
        out.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        return out
    }

    /// One shared attachment per checkbox state: image attachments are
    /// stateless, and sharing keeps attribute dictionaries uniquable.
    private var checkboxes: [Bool: NSTextAttachment] = [:]

    private func checkboxAttachment(checked: Bool, font: MarkdownPlatformFont) -> NSTextAttachment {
        if let cached = checkboxes[checked] { return cached }
        let attachment = makeCheckboxAttachment(checked: checked, font: font)
        checkboxes[checked] = attachment
        return attachment
    }

    private func makeCheckboxAttachment(checked: Bool, font: MarkdownPlatformFont) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let name = checked ? "checkmark.square.fill" : "square"
        let color = checked ? palette.accent : palette.textDim
        #if canImport(AppKit)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "checked" : "unchecked")?
            .withSymbolConfiguration(config)
        #else
        let config = UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        attachment.image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        attachment.accessibilityLabel = checked ? "checked" : "unchecked"
        #endif
        let side = font.pointSize * 1.05
        attachment.bounds = CGRect(x: 0, y: font.descender * 0.6, width: side, height: side)
        return attachment
    }

    private func rule(ctx: Context, color: MarkdownPlatformColor, before: CGFloat, after: CGFloat) -> NSMutableAttributedString {
        let run = NSAttributedString(string: "\u{00A0}", attributes: [.font: fonts.font(size: 6)])
        let out = paragraph(run, ctx: ctx, before: before, after: after)
        let deco = MarkdownDecoration(kind: .rule, indent: ctx.indent, padding: 0,
                                      fill: color, stroke: color, labelColor: color)
        wrap(out, in: deco)
        out.addAttribute(.lumiSourceText, value: "---", range: NSRange(location: 0, length: 1))
        return out
    }

    private func attachmentParagraph(
        _ payload: MarkdownBlockAttachment.Payload,
        source: String,
        ctx: Context,
        before: CGFloat = 0
    ) -> NSMutableAttributedString {
        let height = MarkdownAttachmentHeightCache.height(for: payload, width: 0, scale: style.scale)
            ?? MarkdownBlockAttachment.estimatedHeight(for: payload, scale: style.s)
        let attachment = MarkdownBlockAttachment(payload: payload, height: height, spokenText: spokenText(for: payload))
        let run = NSMutableAttributedString(attachment: attachment)
        run.addAttributes([
            .font: fonts.font(size: 1),
            .lumiSourceText: source,
        ], range: NSRange(location: 0, length: run.length))
        return paragraph(run, ctx: ctx, before: before)
    }

    private func spokenText(for payload: MarkdownBlockAttachment.Payload) -> String {
        switch payload {
        case let .mathBlock(latex): return "math: \(latex)"
        case let .mathParagraph(inline), let .mathHeading(inline, _): return plainSource(inline)
        case .mermaid: return "mermaid diagram"
        case let .media(ref): return ref.alt.isEmpty ? "media: \(ref.url.lastPathComponent)" : ref.alt
        }
    }

    // MARK: - Inline

    private struct InlineBase {
        var size: CGFloat
        var weight: MarkdownPlatformFont.Weight
        var color: MarkdownPlatformColor
        var bold = false
        var italic = false
        var strike = false
        var link: URL?
    }

    private func inlineText(_ nodes: [InlineNode], base: InlineBase) -> NSAttributedString {
        let out = NSMutableAttributedString()
        appendInline(nodes, state: base, into: out)
        return out
    }

    private func appendInline(_ nodes: [InlineNode], state: InlineBase, into out: NSMutableAttributedString) {
        for node in nodes {
            switch node {
            case let .text(s):
                out.append(NSAttributedString(string: s, attributes: textAttributes(state)))
            case let .strong(children):
                var next = state
                next.bold = true
                appendInline(children, state: next, into: out)
            case let .emphasis(children):
                var next = state
                next.italic = true
                appendInline(children, state: next, into: out)
            case let .strikethrough(children):
                var next = state
                next.strike = true
                appendInline(children, state: next, into: out)
            case let .code(s):
                var attrs = textAttributes(state)
                attrs[.font] = fonts.font(size: state.size * 0.9, weight: state.bold ? .semibold : .regular, monospaced: true)
                attrs[.foregroundColor] = palette.accent
                attrs[.backgroundColor] = palette.overlayBackground
                out.append(NSAttributedString(string: s, attributes: attrs))
            case let .link(destination, children):
                var next = state
                next.link = Self.url(from: destination)
                next.color = palette.primary
                appendInline(children, state: next, into: out)
            case let .image(_, alt):
                var attrs = textAttributes(state)
                attrs[.foregroundColor] = palette.textDim
                out.append(NSAttributedString(string: alt.isEmpty ? "[image]" : alt, attributes: attrs))
            case let .math(latex, _):
                var attrs = textAttributes(state)
                attrs[.font] = fonts.font(size: state.size * 0.9, monospaced: true)
                attrs[.foregroundColor] = palette.accent
                out.append(NSAttributedString(string: latex, attributes: attrs))
            case .lineBreak:
                out.append(NSAttributedString(string: markdownLineSeparator, attributes: textAttributes(state)))
            case .softBreak:
                out.append(NSAttributedString(string: " ", attributes: textAttributes(state)))
            }
        }
    }

    private func textAttributes(_ s: InlineBase) -> [NSAttributedString.Key: Any] {
        let weight: MarkdownPlatformFont.Weight = s.bold ? (s.weight.rawValue >= MarkdownPlatformFont.Weight.semibold.rawValue ? .heavy : .bold) : s.weight
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: s.size, weight: weight, italic: s.italic),
            .foregroundColor: s.color,
        ]
        if s.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = s.link {
            attrs[.link] = link
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    static func url(from destination: String) -> URL? {
        if let url = URL(string: destination) { return url }
        if let escaped = destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            return URL(string: escaped)
        }
        return nil
    }

    /// Markdown-ish source for an inline tree — what copy and VoiceOver
    /// get for paragraphs that render through KaTeX.
    func plainSource(_ nodes: [InlineNode]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case let .text(s): out += s
            case let .strong(c), let .emphasis(c), let .strikethrough(c): out += plainSource(c)
            case let .code(s): out += "`\(s)`"
            case let .link(_, c): out += plainSource(c)
            case let .image(_, alt): out += alt
            case let .math(latex, display): out += display == .block ? "$$\(latex)$$" : "$\(latex)$"
            case .lineBreak: out += "\n"
            case .softBreak: out += " "
            }
        }
        return out
    }

    // MARK: - Paragraph plumbing

    /// One paragraph: `content` + "\n", with a fresh paragraph style
    /// spanning the whole range (terminator included, which is where
    /// TextKit reads paragraph attributes from for empty lines).
    private func paragraph(
        _ content: NSAttributedString,
        ctx: Context,
        before: CGFloat = 0,
        after: CGFloat = 0,
        configure: ((NSMutableParagraphStyle) -> Void)? = nil
    ) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(attributedString: content)
        let terminatorAttrs: [NSAttributedString.Key: Any] = out.length > 0
            ? out.attributes(at: out.length - 1, effectiveRange: nil).filter { Self.terminatorKeys.contains($0.key) }
            : [.font: fonts.font(size: style.bodySize)]
        out.append(NSAttributedString(string: "\n", attributes: terminatorAttrs))
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = ctx.indent
        ps.headIndent = ctx.indent
        ps.paragraphSpacingBefore = before
        ps.paragraphSpacing = after
        configure?(ps)
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Stamp `deco` on every paragraph of `s` (outermost container last),
    /// flagging the first / last paragraph so the chrome is padded and
    /// rounded only at the container's real edges, then make sure those
    /// edges have room for the padding.
    private func wrap(_ s: NSMutableAttributedString, in deco: MarkdownDecoration) {
        var ranges: [NSRange] = []
        (s.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: s.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, _, enclosing, _ in ranges.append(enclosing) }
        for (i, range) in ranges.enumerated() {
            let existing = (s.attribute(.lumiDecorations, at: range.location, effectiveRange: nil) as? [MarkdownDecoration]) ?? []
            s.addAttribute(.lumiDecorations, value: existing + [deco.with(isFirst: i == 0, isLast: i == ranges.count - 1)], range: range)
        }
        guard let first = ranges.first, let last = ranges.last else { return }
        mutateParagraphStyle(s, range: first) { $0.paragraphSpacingBefore = max($0.paragraphSpacingBefore, deco.padding) }
        mutateParagraphStyle(s, range: last) { $0.paragraphSpacing = max($0.paragraphSpacing, deco.padding) }
    }

    /// Attributes a paragraph terminator inherits from its last run —
    /// typography only, never content (link, attachment, source text)
    /// or run decoration (code background, underline, chip).
    private static let terminatorKeys: Set<NSAttributedString.Key> = [.font, .foregroundColor]

    private func adjustLastParagraph(_ s: NSMutableAttributedString, _ change: (NSMutableParagraphStyle) -> Void) {
        guard s.length > 0 else { return }
        let ns = s.string as NSString
        let range = ns.paragraphRange(for: NSRange(location: s.length - 1, length: 0))
        mutateParagraphStyle(s, range: range, change)
    }

    private func mutateParagraphStyle(_ s: NSMutableAttributedString, range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
        guard range.length > 0 else { return }
        let current = (s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
        let ps = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        change(ps)
        s.addAttribute(.paragraphStyle, value: ps, range: range)
    }
}
