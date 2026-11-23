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
/// Typography follows the web's prose system (`app.css` `.md-body`):
/// one body size with an em-based rhythm, a modular heading scale with
/// tight leading and more space above than below, hanging list markers,
/// quiet quotes, coloured callouts, pill inline code / kbd / mark.
///
/// Pure function of `(block, style)` — no view state, no environment —
/// which is what makes the per-block fragment cache in
/// `MarkdownDocumentRenderer` sound.
@MainActor
final class MarkdownAttributedBuilder {
    let style: MarkdownRenderStyle
    let palette: MarkdownPalette
    private let fonts: MarkdownFontBook
    /// Task checkboxes seen so far in the current top-level block.
    private var taskOrdinal = 0

    init(style: MarkdownRenderStyle) {
        self.style = style
        self.palette = MarkdownPalette(style.theme)
        self.fonts = MarkdownFontBook(family: style.fontFamily)
    }

    private struct Context {
        var indent: CGFloat = 0
        var textColor: MarkdownPlatformColor
        /// Extra right inset (callouts pad their content on both sides).
        var tailInset: CGFloat = 0
        var listDepth = 0
        /// Inside a done task: struck through.
        var strike = false
    }

    private var rootContext: Context { Context(indent: 0, textColor: palette.text) }

    // MARK: - Public entry points

    /// Fragment for a top-level block, trailing block gap included.
    func fragment(for block: MarkdownBlock) -> NSAttributedString {
        taskOrdinal = 0
        let out = build(block, rootContext)
        let after: CGFloat
        switch block {
        case let .heading(level, inline) where !InlineRenderer.containsMath(inline):
            after = style.headingSpacingAfter(level) + (level == 2 ? 0.4 * style.headingSize(2) + 1 : 0)
        default:
            after = style.blockGap
        }
        adjustLastParagraph(out) { $0.paragraphSpacing += after }
        return out
    }

    /// Title + tag chips + hairline rule rendered at the top of the note,
    /// inside the same text flow so the whole page selects as one. An
    /// empty title (the body opens with the same `# Title`) shows only
    /// the tags.
    func header(title: String, tags: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !title.isEmpty {
            let font = fonts.font(size: style.titleSize, weight: .bold)
            let run = NSAttributedString(string: title, attributes: [
                .font: font,
                .foregroundColor: palette.text,
                .kern: -0.022 * style.titleSize,
            ])
            out.append(paragraph(run, ctx: rootContext, after: 0.45 * style.em) {
                $0.lineSpacing = self.lineGap(font, leading: 1.16)
            })
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
            let chips = paragraph(line, ctx: Context(indent: 8 * style.s, textColor: palette.text), before: 4 * style.s, after: 12 * style.s) {
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
        guard out.length > 0 else { return out }
        out.append(rule(ctx: rootContext, color: palette.rule, before: 0.6 * style.em, after: 1.5 * style.em, fade: false))
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
            return heading(level: level, inline: inline, ctx: ctx)

        case let .paragraph(inline):
            if InlineRenderer.containsMath(inline) {
                return attachmentParagraph(.mathParagraph(inline: inline), source: plainSource(inline), ctx: ctx)
            }
            let run = inlineText(inline, base: InlineBase(size: style.em, weight: .regular, color: ctx.textColor, strike: ctx.strike))
            let font = fonts.font(size: style.em)
            return paragraph(run, ctx: ctx) { $0.lineSpacing = self.lineGap(font, leading: self.style.leading) }

        case let .codeBlock(language, code):
            let lang = language.map { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "" }?.lowercased()
            switch lang {
            case "mermaid":
                return attachmentParagraph(.mermaid(code: code), source: "```mermaid\n\(code)```", ctx: ctx)
            case "math", "latex", "tex":
                return attachmentParagraph(.mathBlock(latex: code), source: "```\(lang ?? "")\n\(code)```", ctx: ctx)
            default:
                let fence = "```" + (lang ?? "")
                return attachmentParagraph(.code(language: lang.flatMap { $0.isEmpty ? nil : $0 }, code: code),
                                           source: "\(fence)\n\(code.hasSuffix("\n") ? code : code + "\n")```", ctx: ctx)
            }

        case let .blockQuote(blocks):
            var inner = ctx
            inner.indent += style.quoteIndent
            inner.textColor = palette.dim
            let out = stack(blocks, ctx: inner, gap: style.rhythm)
            wrap(out, in: MarkdownDecoration(
                kind: .quote, indent: ctx.indent, padding: style.quotePadding,
                fill: .clear, stroke: palette.quoteBar, labelColor: palette.dim
            ))
            return out

        case let .callout(callout):
            return self.callout(callout, ctx: ctx)

        case let .unorderedList(items):
            return list(items, ordered: false, start: 1, ctx: ctx)

        case let .orderedList(start, items):
            return list(items, ordered: true, start: start, ctx: ctx)

        case .thematicBreak:
            let m = max(0, 2.4 * style.em - style.rhythm)
            return rule(ctx: ctx, color: palette.rule, before: m, after: m, fade: true)

        case let .media(ref):
            var source = "![\(ref.alt)](\(ref.url.absoluteString)"
            if let title = ref.title { source += " \"\(title)\"" }
            source += ")"
            return attachmentParagraph(.media(ref), source: source, ctx: ctx, before: 0.3 * style.em)

        case let .mathBlock(latex):
            return attachmentParagraph(.mathBlock(latex: latex), source: "$$\(latex)$$", ctx: ctx)

        case let .table(table):
            return attachmentParagraph(.table(table), source: tableSource(table), ctx: ctx)

        case let .footnotes(items):
            return footnotes(items, ctx: ctx)
        }
    }

    private func heading(level: Int, inline: [InlineNode], ctx: Context) -> NSMutableAttributedString {
        let size = style.headingSize(level)
        let color: MarkdownPlatformColor
        switch level {
        case 5: color = palette.dim
        case 6: color = palette.marker
        default: color = ctx.textColor
        }
        let nodes = level >= 5 ? uppercased(inline) : inline
        let run = NSMutableAttributedString(attributedString: inlineText(nodes, base: InlineBase(
            size: size, weight: level == 1 ? .bold : .semibold, color: color,
            tracking: MarkdownRenderStyle.headingTracking(level) * size
        )))
        if run.length > 0 {
            run.addAttribute(.lumiAnchor, value: MarkdownText.slug(MarkdownParser.plainText(inline)), range: NSRange(location: 0, length: run.length))
        }
        let font = fonts.font(size: size, weight: .semibold)
        let out = paragraph(run, ctx: ctx, before: style.headingSpacingBefore(level)) {
            $0.lineSpacing = self.lineGap(font, leading: MarkdownRenderStyle.headingLeading(level))
            #if canImport(AppKit)
            $0.headerLevel = level
            #endif
        }
        if level == 2 {
            wrap(out, in: MarkdownDecoration(
                kind: .headingRule, indent: ctx.indent, padding: 0.4 * size,
                fill: palette.rule, stroke: palette.rule, labelColor: palette.rule
            ), pad: false)
        }
        return out
    }

    private func uppercased(_ nodes: [InlineNode]) -> [InlineNode] {
        nodes.map { node in
            switch node {
            case let .text(s): return .text(s.uppercased())
            case let .strong(c): return .strong(uppercased(c))
            case let .emphasis(c): return .emphasis(uppercased(c))
            case let .strikethrough(c): return .strikethrough(uppercased(c))
            case let .mark(c): return .mark(uppercased(c))
            case let .link(d, c): return .link(destination: d, children: uppercased(c))
            default: return node
            }
        }
    }

    /// Sibling blocks inside a container, separated by `gap`.
    private func stack(_ blocks: [MarkdownBlock], ctx: Context, gap: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let part = build(block, ctx)
            if i < blocks.count - 1 {
                var g = gap
                if case let .heading(level, _) = block { g = style.headingSpacingAfter(level) }
                adjustLastParagraph(part) { $0.paragraphSpacing += g }
            }
            out.append(part)
        }
        if out.length == 0 {
            out.append(paragraph(NSAttributedString(string: " "), ctx: ctx))
        }
        return out
    }

    // MARK: Callouts

    private func callout(_ c: MarkdownCallout, ctx: Context) -> NSMutableAttributedString {
        let color = palette.callout(c.kind)
        let titleColor = MarkdownPalette.mix(color, palette.text, 0.72)
        let titleSize = 0.95 * style.em
        let foldable = c.fold != .none
        let open = c.fold != .closed

        var inner = ctx
        inner.indent += 3 + style.calloutPaddingH
        inner.tailInset += style.calloutPaddingH

        // Title: icon + text, semibold, tinted.
        let title = NSMutableAttributedString()
        let iconFont = fonts.font(size: titleSize, weight: .semibold)
        let icon = NSMutableAttributedString(attachment: calloutIcon(kind: c.kind, color: color, font: iconFont))
        icon.addAttribute(.font, value: iconFont, range: NSRange(location: 0, length: icon.length))
        icon.addAttribute(.lumiSourceText, value: "[!\(c.rawKind)]\(c.fold == .open ? "+" : c.fold == .closed ? "-" : "") ", range: NSRange(location: 0, length: icon.length))
        title.append(icon)
        title.append(NSAttributedString(string: "\u{2002}", attributes: [.font: iconFont]))
        let titleNodes: [InlineNode] = c.title.isEmpty
            ? [.text(c.rawKind.prefix(1).uppercased() + c.rawKind.dropFirst())]
            : c.title
        title.append(inlineText(titleNodes, base: InlineBase(size: titleSize, weight: .semibold, color: titleColor)))
        if foldable, let url = URL(string: "lumi-callout://toggle/\(MarkdownCalloutKey.key(c))") {
            title.addAttribute(.link, value: url, range: NSRange(location: 0, length: title.length))
        }
        let titlePara = paragraph(title, ctx: inner) {
            $0.lineSpacing = self.lineGap(iconFont, leading: 1.35)
            if foldable { $0.tailIndent -= 1.4 * self.style.em }
        }
        let out = titlePara
        if !open { taskOrdinal += MarkdownCalloutKey.taskCount(c.blocks) }
        if open, !c.blocks.isEmpty {
            adjustLastParagraph(out) { $0.paragraphSpacing += 0.35 * self.style.em }
            out.append(stack(c.blocks, ctx: inner, gap: style.rhythm))
        }
        wrap(out, in: MarkdownDecoration(
            kind: .callout(foldable: foldable, open: open), indent: ctx.indent, padding: style.calloutPaddingV,
            fill: color.withAlphaComponent(0.07), stroke: color.withAlphaComponent(0.24), labelColor: color,
            labelFont: fonts.font(size: titleSize, weight: .semibold)
        ))
        return out
    }

    private func calloutIcon(kind: String, color: MarkdownPlatformColor, font: MarkdownPlatformFont) -> NSTextAttachment {
        let name: String
        switch kind {
        case "warning", "danger": name = "exclamationmark.triangle"
        case "tip", "success": name = "checkmark"
        case "question": name = "questionmark.circle"
        case "todo": name = "circle.dashed"
        case "example": name = "list.bullet"
        case "quote": name = "quote.opening"
        case "abstract": name = "doc.text"
        default: name = "info.circle"
        }
        let attachment = NSTextAttachment()
        #if canImport(AppKit)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.92, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: kind)?.withSymbolConfiguration(config)
        #else
        let config = UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.92, weight: .semibold)
        attachment.image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal)
        attachment.accessibilityLabel = kind
        #endif
        let side = font.pointSize
        let size = attachment.image?.size ?? CGSize(width: side, height: side)
        let h = min(side, size.height)
        let w = size.height > 0 ? size.width * h / size.height : side
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
        return attachment
    }

    // MARK: Lists

    private func list(_ items: [ListItemContent], ordered: Bool, start: Int, ctx: Context) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var inner = ctx
        inner.indent += style.listMarkerColumn
        inner.listDepth += 1
        if ctx.strike {
            // A list nested in a done task reads normally (web).
            inner.strike = false
            inner.textColor = palette.text
        }
        let digits = String(start + items.count - 1).count
        for (index, item) in items.enumerated() {
            // Marker first: a checkbox's ordinal must precede the ones of
            // tasks nested inside its item.
            let marker = markerRun(item: item, ordered: ordered, number: start + index, depth: ctx.listDepth, digits: digits)
            var itemCtx = inner
            if item.checkbox == .checked {
                itemCtx.textColor = palette.dim
                itemCtx.strike = true
            }
            let content = stack(item.blocks, ctx: itemCtx, gap: 0.4 * style.em)
            let firstPara = (content.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            let firstIsText = content.length > 0
                && content.attribute(.attachment, at: 0, effectiveRange: nil) == nil
                && content.attribute(.lumiDecorations, at: 0, effectiveRange: nil).map({ ($0 as? [MarkdownDecoration])?.allSatisfy { $0.kind == .pills } ?? false }) ?? true
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

    private func markerRun(item: ListItemContent, ordered: Bool, number: Int, depth: Int, digits: Int) -> NSAttributedString {
        let font = fonts.font(size: style.em)
        let out = NSMutableAttributedString(string: "\t", attributes: [.font: font])
        if let checkbox = item.checkbox {
            let checked = checkbox == .checked
            let glyph = NSMutableAttributedString(attachment: checkboxAttachment(checked: checked, font: font))
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .lumiSourceText: checked ? "[x] " : "[ ] ",
                .lumiTask: taskOrdinal,
            ]
            if style.tasksInteractive, let url = URL(string: "lumi-task://toggle/\(taskOrdinal)") {
                attrs[.link] = url
            }
            taskOrdinal += 1
            glyph.addAttributes(attrs, range: NSRange(location: 0, length: glyph.length))
            out.append(glyph)
        } else if ordered {
            let size = 0.94 * style.em
            out.append(NSAttributedString(string: "\(number).", attributes: [
                .font: MarkdownPlatformFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: palette.marker,
            ]))
        } else {
            let glyph: String
            switch depth {
            case 0: glyph = "•"
            case 1: glyph = "◦"
            default: glyph = "▪"
            }
            out.append(NSAttributedString(string: glyph, attributes: [
                .font: font,
                .foregroundColor: palette.marker,
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
        let attachment = NSTextAttachment()
        let side = (1.02 * font.pointSize).rounded()
        attachment.image = Self.checkboxImage(
            checked: checked, side: side,
            border: palette.text.withAlphaComponent(0.38), fill: palette.primary, check: palette.background
        )
        #if canImport(UIKit)
        attachment.accessibilityLabel = checked ? "checked" : "unchecked"
        #endif
        attachment.bounds = CGRect(x: 0, y: -0.15 * font.pointSize, width: side, height: side)
        checkboxes[checked] = attachment
        return attachment
    }

    /// The web's task checkbox: rounded square, 1.5 pt border; checked →
    /// primary fill with a background-coloured tick.
    static func checkboxImage(checked: Bool, side: CGFloat, border: MarkdownPlatformColor, fill: MarkdownPlatformColor, check: MarkdownPlatformColor) -> MarkdownPlatformImage {
        let draw: (CGContext) -> Void = { cg in
            let rect = CGRect(x: 0.75, y: 0.75, width: side - 1.5, height: side - 1.5)
            let path = CGPath(roundedRect: rect, cornerWidth: side * 0.3, cornerHeight: side * 0.3, transform: nil)
            if checked {
                cg.addPath(path)
                cg.setFillColor(fill.cgColor)
                cg.fillPath()
                cg.setStrokeColor(check.cgColor)
                cg.setLineWidth(max(1.6, side * 0.12))
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.move(to: CGPoint(x: side * 0.27, y: side * 0.52))
                cg.addLine(to: CGPoint(x: side * 0.44, y: side * 0.68))
                cg.addLine(to: CGPoint(x: side * 0.74, y: side * 0.34))
                cg.strokePath()
            } else {
                cg.addPath(path)
                cg.setStrokeColor(border.cgColor)
                cg.setLineWidth(1.5)
                cg.strokePath()
            }
        }
        #if canImport(AppKit)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            if let cg = NSGraphicsContext.current?.cgContext { draw(cg) }
            return true
        }
        #else
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in draw(ctx.cgContext) }
        #endif
    }

    // MARK: Rules, attachments, footnotes

    private func rule(ctx: Context, color: MarkdownPlatformColor, before: CGFloat, after: CGFloat, fade: Bool) -> NSMutableAttributedString {
        let run = NSAttributedString(string: "\u{00A0}", attributes: [.font: fonts.font(size: 4)])
        let out = paragraph(run, ctx: ctx, before: before, after: after)
        let deco = MarkdownDecoration(kind: .rule, indent: ctx.indent, padding: fade ? 1 : 0,
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
        return paragraph(run, ctx: ctx, before: before) { $0.tailIndent = -ctx.tailInset }
    }

    private func spokenText(for payload: MarkdownBlockAttachment.Payload) -> String {
        switch payload {
        case let .mathBlock(latex): return "math: \(latex)"
        case let .mathParagraph(inline), let .mathHeading(inline, _): return plainSource(inline)
        case .mermaid: return "mermaid diagram"
        case let .media(ref):
            let label = ref.alt.isEmpty ? "media: \(ref.url.lastPathComponent)" : ref.alt
            return ref.title.map { "\(label). \($0)" } ?? label
        case let .code(language, code): return "\(language ?? "code") block: \(code)"
        case let .table(t): return "table, \(t.header.count) columns, \(t.rows.count) rows"
        }
    }

    private func tableSource(_ t: MarkdownTable) -> String {
        func row(_ cells: [[InlineNode]]) -> String {
            "| " + cells.map { plainSource($0).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let sep = "| " + t.alignments.map { a -> String in
            switch a {
            case .left: return ":--"
            case .center: return ":-:"
            case .right: return "--:"
            case .none: return "---"
            }
        }.joined(separator: " | ") + " |"
        return ([row(t.header), sep] + t.rows.map(row)).joined(separator: "\n")
    }

    private func footnotes(_ items: [MarkdownFootnote], ctx: Context) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let size = 0.875 * style.em
        let font = fonts.font(size: size)
        var inner = ctx
        inner.indent += 1.6 * size
        inner.textColor = palette.dim
        for (i, item) in items.enumerated() {
            let line = NSMutableAttributedString(string: "\t", attributes: [.font: font])
            line.append(NSAttributedString(string: "\(item.number).", attributes: [
                .font: MarkdownPlatformFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: palette.marker,
            ]))
            line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            line.append(inlineText(item.inline, base: InlineBase(size: size, weight: .regular, color: palette.dim)))
            var back: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.primary]
            if let url = URL(string: "lumi-fn://back/\(item.id)") { back[.link] = url }
            line.append(NSAttributedString(string: " ", attributes: [.font: font]))
            line.append(NSAttributedString(string: "\u{21A9}\u{FE0E}", attributes: back))
            line.addAttribute(.lumiAnchor, value: "fn-\(item.id)", range: NSRange(location: 0, length: line.length))
            let para = paragraph(line, ctx: inner, before: i == 0 ? max(0, 3 * style.em - style.rhythm) : 0, after: i < items.count - 1 ? 0.35 * size : 0) {
                $0.firstLineHeadIndent = ctx.indent
                $0.tabStops = [
                    NSTextTab(textAlignment: .right, location: ctx.indent + 1.15 * size),
                    NSTextTab(textAlignment: .left, location: inner.indent),
                ]
                $0.lineSpacing = self.lineGap(font, leading: 1.6)
            }
            out.append(para)
        }
        // Hairline above the list (`border-top`, `padding-top: 1.1em`).
        let firstRange = (out.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let existing = (out.attribute(.lumiDecorations, at: 0, effectiveRange: nil) as? [MarkdownDecoration]) ?? []
        out.addAttribute(.lumiDecorations, value: existing + [MarkdownDecoration(
            kind: .footnotes, indent: ctx.indent, padding: 1.1 * size,
            fill: palette.rule, stroke: palette.rule, labelColor: palette.rule
        )], range: firstRange)
        mutateParagraphStyle(out, range: firstRange) { $0.paragraphSpacingBefore += 1.1 * size }
        return out
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
        var tracking: CGFloat = 0
        var marked = false
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
                next.color = palette.dim
                appendInline(children, state: next, into: out)
            case let .mark(children):
                var next = state
                next.marked = true
                appendInline(children, state: next, into: out)
            case let .code(s):
                var attrs = textAttributes(state)
                let size = 0.86 * state.size
                attrs[.font] = fonts.font(size: size, weight: state.bold ? .semibold : .regular, monospaced: true)
                attrs[.foregroundColor] = state.link == nil ? palette.text : palette.primary
                attrs[.lumiPill] = MarkdownPill(kind: .code, fill: palette.inlineBackground)
                attrs.removeValue(forKey: .kern)
                appendPadded(s, attrs: attrs, pad: 0.4 * size, into: out)
            case let .kbd(s):
                var attrs = textAttributes(state)
                let size = 0.78 * state.size
                attrs[.font] = fonts.font(size: size, weight: .medium, monospaced: true)
                attrs[.foregroundColor] = palette.text
                attrs[.baselineOffset] = 0.08 * state.size
                attrs[.lumiPill] = MarkdownPill(kind: .kbd, fill: palette.codeBackground, stroke: palette.codeBorder)
                appendPadded(s, attrs: attrs, pad: 0.5 * size, into: out)
            case let .footnoteRef(id, number):
                var attrs = textAttributes(state)
                let size = 0.72 * state.size
                attrs[.font] = MarkdownPlatformFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
                attrs[.baselineOffset] = 0.42 * state.size
                attrs[.foregroundColor] = palette.primary
                attrs.removeValue(forKey: .underlineStyle)
                if let url = URL(string: "lumi-fn://ref/\(id)") { attrs[.link] = url }
                attrs[.lumiAnchor] = "fnref-\(id)"
                attrs[.lumiSourceText] = "[^\(id)]"
                out.append(NSAttributedString(string: "\u{2009}\(number)", attributes: attrs))
            case let .link(destination, children):
                var next = state
                next.link = Self.url(from: destination)
                next.color = palette.primary
                appendInline(children, state: next, into: out)
            case let .image(_, alt):
                var attrs = textAttributes(state)
                attrs[.foregroundColor] = palette.dim
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

    /// Append a pill run with `pad` of breathing room on both sides
    /// (kern on the previous character and on the run's last one), so
    /// the drawn background never touches the neighbouring glyphs.
    private func appendPadded(_ s: String, attrs: [NSAttributedString.Key: Any], pad: CGFloat, into out: NSMutableAttributedString) {
        guard !s.isEmpty else { return }
        if out.length > 0 {
            let last = NSRange(location: out.length - 1, length: 1)
            let existing = (out.attribute(.kern, at: last.location, effectiveRange: nil) as? CGFloat) ?? 0
            out.addAttribute(.kern, value: existing + pad, range: last)
        }
        let run = NSMutableAttributedString(string: s, attributes: attrs)
        let tail = (s as NSString).length
        run.addAttribute(.kern, value: pad, range: NSRange(location: tail - 1, length: 1))
        out.append(run)
    }

    private func textAttributes(_ s: InlineBase) -> [NSAttributedString.Key: Any] {
        let weight: MarkdownPlatformFont.Weight = s.bold ? (s.weight.rawValue >= MarkdownPlatformFont.Weight.semibold.rawValue ? .heavy : .semibold) : s.weight
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: s.size, weight: weight, italic: s.italic),
            .foregroundColor: s.color,
        ]
        if s.tracking != 0 { attrs[.kern] = s.tracking }
        if s.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = s.link == nil ? palette.marker : palette.linkLine
        }
        if s.marked {
            attrs[.lumiPill] = MarkdownPill(kind: .mark, fill: palette.markBackground)
        }
        if let link = s.link {
            attrs[.link] = link
            let isInternal = link.isFileURL || link.scheme == nil
            attrs[.underlineStyle] = isInternal
                ? NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                : NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = palette.linkLine
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
            case let .mark(c): out += "==\(plainSource(c))=="
            case let .code(s): out += "`\(s)`"
            case let .kbd(s): out += "<kbd>\(s)</kbd>"
            case let .footnoteRef(id, _): out += "[^\(id)]"
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

    /// Extra line spacing that turns `font`'s natural line height into
    /// `leading` × its size (CSS `line-height`).
    private func lineGap(_ font: MarkdownPlatformFont, leading: CGFloat) -> CGFloat {
        #if canImport(AppKit)
        let natural = font.ascender - font.descender + font.leading
        #else
        let natural = font.lineHeight
        #endif
        return max(0, font.pointSize * leading - natural)
    }

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
            : [.font: fonts.font(size: style.em)]
        var hasPills = false
        out.enumerateAttribute(.lumiPill, in: NSRange(location: 0, length: out.length), options: []) { value, _, stop in
            if value != nil { hasPills = true; stop.pointee = true }
        }
        out.append(NSAttributedString(string: "\n", attributes: terminatorAttrs))
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = ctx.indent
        ps.headIndent = ctx.indent
        ps.tailIndent = -ctx.tailInset
        ps.paragraphSpacingBefore = before
        ps.paragraphSpacing = after
        configure?(ps)
        let full = NSRange(location: 0, length: out.length)
        out.addAttribute(.paragraphStyle, value: ps, range: full)
        if hasPills {
            out.addAttribute(.lumiDecorations, value: [MarkdownDecoration(
                kind: .pills, indent: 0, padding: 0, fill: .clear, stroke: .clear, labelColor: .clear
            )], range: full)
        }
        return out
    }

    /// Stamp `deco` on every paragraph of `s` (outermost container last),
    /// flagging the first / last paragraph so the chrome is padded and
    /// rounded only at the container's real edges, then make sure those
    /// edges have room for the padding.
    private func wrap(_ s: NSMutableAttributedString, in deco: MarkdownDecoration, pad: Bool = true) {
        var ranges: [NSRange] = []
        (s.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: s.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, _, enclosing, _ in ranges.append(enclosing) }
        for (i, range) in ranges.enumerated() {
            let existing = (s.attribute(.lumiDecorations, at: range.location, effectiveRange: nil) as? [MarkdownDecoration]) ?? []
            s.addAttribute(.lumiDecorations, value: existing + [deco.with(isFirst: i == 0, isLast: i == ranges.count - 1)], range: range)
        }
        guard pad, let first = ranges.first, let last = ranges.last else { return }
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

/// Fold identity of a callout: everything but its fold state, so the
/// reader can remember "the user opened this one" across re-renders.
enum MarkdownCalloutKey {
    static func key(_ c: MarkdownCallout) -> Int {
        var h = Hasher()
        h.combine(c.kind)
        h.combine(c.rawKind)
        h.combine(c.title)
        h.combine(c.blocks)
        return h.finalize()
    }

    /// `document` with the callouts in `toggled` flipped open ↔ closed.
    static func apply(_ toggled: Set<Int>, to document: MarkdownDocument) -> MarkdownDocument {
        guard !toggled.isEmpty else { return document }
        return MarkdownDocument(
            blocks: document.blocks.map { flip($0, toggled) },
            baseURL: document.baseURL,
            sourceLines: document.sourceLines,
            lineCount: document.lineCount
        )
    }

    private static func flip(_ block: MarkdownBlock, _ toggled: Set<Int>) -> MarkdownBlock {
        switch block {
        case var .callout(c):
            if c.fold != .none, toggled.contains(key(c)) { c.fold = c.fold == .open ? .closed : .open }
            c.blocks = c.blocks.map { flip($0, toggled) }
            return .callout(c)
        case let .blockQuote(blocks):
            return .blockQuote(blocks: blocks.map { flip($0, toggled) })
        case let .unorderedList(items):
            return .unorderedList(items: items.map { ListItemContent(checkbox: $0.checkbox, blocks: $0.blocks.map { flip($0, toggled) }) })
        case let .orderedList(start, items):
            return .orderedList(start: start, items: items.map { ListItemContent(checkbox: $0.checkbox, blocks: $0.blocks.map { flip($0, toggled) }) })
        default:
            return block
        }
    }

    /// Task checkboxes in `blocks` (document order, nested included).
    static func taskCount(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { n, b in
            switch b {
            case let .unorderedList(items), let .orderedList(_, items):
                return n + items.reduce(0) { $0 + ($1.checkbox == nil ? 0 : 1) + taskCount($1.blocks) }
            case let .blockQuote(inner): return n + taskCount(inner)
            case let .callout(c): return n + taskCount(c.blocks)
            default: return n
            }
        }
    }
}
