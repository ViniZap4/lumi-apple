import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Live Preview: hands `LiveLayoutFragment` to every line with chrome
/// (code panel, quote bar, callout box, rule, pills, bullets, task
/// boxes); plain lines keep the stock fragment.
final class LiveLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           let deco = paragraph.attributedString.attribute(.lumiLiveLine, at: 0, effectiveRange: nil) as? LiveLineDecoration,
           !deco.drawsNothing {
            return LiveLayoutFragment(textElement: textElement, range: textElement.elementRange, decoration: deco)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// One editor line's chrome, painted behind (panels, bars) and over
/// (bullets, task boxes) its text. Geometry comes from the fragment's
/// own line fragments, so it follows wrapping and any width. Adjacent
/// lines of one block draw edge to edge (TextKit 2 stacks fragments with
/// their paragraph spacing), so a code panel or callout reads as one box.
final class LiveLayoutFragment: NSTextLayoutFragment {
    let decoration: LiveLineDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: LiveLineDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not coded") }

    private var linesBounds: CGRect {
        textLineFragments.reduce(CGRect.null) { $0.union($1.typographicBounds) }
    }

    private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 5 }

    /// Fragment-local x of the text column's left edge. The fragment's
    /// frame starts at the line's own indent, the chrome at the column.
    private var x0: CGFloat { padding - layoutFragmentFrame.minX }

    /// Text-column width (padding excluded).
    private var usableWidth: CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? 0
        let w = width > 0 ? width : layoutFragmentFrame.maxX + padding
        return max(0, w - 2 * padding)
    }

    override var renderingSurfaceBounds: CGRect {
        var b = super.renderingSurfaceBounds
        b = b.union(CGRect(x: x0 - 2, y: -2, width: usableWidth + 4, height: layoutFragmentFrame.height + 4))
        if decoration.hasPills { b = b.insetBy(dx: -8, dy: -4) }
        return b
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let d = decoration
        let p = d.palette
        let lines = linesBounds
        let point = point
        let col = CGPoint(x: point.x + x0, y: point.y)
        let h = layoutFragmentFrame.height
        context.saveGState()

        // Panels (code, frontmatter) and the callout box.
        switch d.kind {
        case let .code(first, last, _):
            panel(top: first ? max(0, lines.minY - 0.55 * p.codePadV) : 0,
                  bottom: last ? min(h, lines.maxY + 0.55 * p.codePadV) : h,
                  first: first, last: last, fill: p.panel, stroke: p.panelBorder, point: col, context: context)
        case let .frontmatter(first, last):
            panel(top: first ? max(0, lines.minY - 0.35 * p.em) : 0,
                  bottom: last ? min(h, lines.maxY + 0.35 * p.em) : h,
                  first: first, last: last, fill: p.panel.withAlphaComponent(0.6 * p.panel.alphaComponentValue), stroke: .clear,
                  point: col, context: context)
        case .rule:
            if !lines.isNull {
                let y = (point.y + lines.midY).rounded(.down)
                let r = CGRect(x: col.x, y: y, width: usableWidth, height: 1.5)
                gradient(r, colors: [p.hrStart.withAlphaComponent(0), p.hrStart, p.hrEnd, p.hrEnd.withAlphaComponent(0)],
                         locations: [0, 0.2, 0.8, 1], in: context)
            }
        case .none, .widget:
            break
        }
        if let c = d.callout { drawCallout(c, lines: lines, point: col, textPoint: point, context: context) }
        if d.quoteDepth > 0, d.callout == nil {
            context.setFillColor(p.quoteFill.cgColor)
            let top = lines.isNull ? 0 : max(0, lines.minY - 0.3 * p.em)
            let bottom = lines.isNull ? h : min(h, lines.maxY + 0.3 * p.em)
            context.fill(CGRect(x: col.x, y: point.y + top, width: usableWidth, height: bottom - top))
        }
        if d.quoteDepth > 0 {
            context.setFillColor(p.quoteBar.cgColor)
            for k in 0..<d.quoteDepth {
                let x = col.x + CGFloat(k) * p.quoteIndent
                context.fill(CGRect(x: x, y: point.y, width: 3, height: h))
            }
        }
        if d.hasPills { MarkdownLayoutFragment.drawPills(textLineFragments, at: point, in: context) }
        context.restoreGState()

        super.draw(at: point, in: context)

        if d.hasMarkers { drawMarkers(at: point, in: context) }
    }

    // MARK: Pieces

    private func panel(top: CGFloat, bottom: CGFloat, first: Bool, last: Bool, fill: MarkdownPlatformColor, stroke: MarkdownPlatformColor,
                       point: CGPoint, context: CGContext) {
        let r = CGRect(x: point.x, y: point.y + top, width: usableWidth, height: max(0, bottom - top))
        let radius: CGFloat = 9
        let path = Self.roundedPath(r, top: first ? radius : 0, bottom: last ? radius : 0)
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        guard stroke != .clear else { return }
        // Side borders always; top / bottom only on the block's ends.
        context.saveGState()
        context.addPath(path)
        context.clip()
        let outline = CGRect(x: r.minX + 0.25, y: r.minY + (first ? 0.25 : -20), width: r.width - 0.5,
                             height: r.height - (first ? 0.25 : -20) - (last ? 0.25 : -20) + (first ? 0 : 0))
        context.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(0.5)
        context.strokePath()
        context.restoreGState()
    }

    private func drawCallout(_ c: LiveLineDecoration.Callout, lines: CGRect, point: CGPoint, textPoint: CGPoint, context: CGContext) {
        let p = decoration.palette
        let h = layoutFragmentFrame.height
        let top = c.first && !lines.isNull ? max(0, lines.minY - p.calloutPadV) : 0
        let bottom = c.last && !lines.isNull ? min(h, lines.maxY + p.calloutPadV) : h
        let r = CGRect(x: point.x, y: point.y + top, width: usableWidth, height: max(0, bottom - top))
        let radius: CGFloat = 8
        let path = Self.roundedPath(r, top: c.first ? radius : 0, bottom: c.last ? radius : 0)
        context.saveGState()
        context.addPath(path)
        context.setFillColor(p.calloutColor.withAlphaComponent(0.07).cgColor)
        context.fillPath()
        context.addPath(path)
        context.clip()
        let outline = CGRect(x: r.minX + 0.5, y: r.minY + 0.5 - (c.first ? 0 : 20), width: r.width - 1,
                             height: r.height - 1 + (c.first ? 0 : 20) + (c.last ? 0 : 20))
        context.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(p.calloutColor.withAlphaComponent(0.24).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setFillColor(p.calloutColor.cgColor)
        context.fill(CGRect(x: r.minX, y: r.minY, width: 3, height: r.height))
        context.restoreGState()

        guard c.title, let first = textLineFragments.first else { return }
        let b = first.typographicBounds
        let size = 0.95 * p.em
        let baseline = textPoint.y + b.minY + first.glyphOrigin.y
        let iconX = point.x + 3 + p.calloutPadH
        let capHeight = MarkdownPlatformFont.systemFont(ofSize: size, weight: .semibold).capHeight
        drawSymbol(Self.calloutSymbol(c.kind), color: p.calloutColor, size: size * 0.92,
                   center: CGPoint(x: iconX + 0.5 * size, y: baseline - capHeight / 2), in: context)
        if c.drawsLabel {
            let label = NSAttributedString(string: c.label, attributes: [
                .font: MarkdownPlatformFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: p.calloutTitle,
            ])
            let ls = label.size()
            drawString(label, at: CGPoint(x: iconX + 1.45 * size, y: baseline - ls.height + (ls.height - capHeight) / 2 - 1), in: context)
        }
        if c.foldable {
            let chevron = NSAttributedString(string: "\u{203A}", attributes: [
                .font: MarkdownPlatformFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: p.calloutColor,
            ])
            let s = chevron.size()
            drawString(chevron, at: CGPoint(x: r.maxX - 1.05 * size - s.width / 2, y: textPoint.y + b.midY - s.height / 2), in: context)
        }
    }

    /// Bullets and task boxes over their transparent source characters.
    private func drawMarkers(at point: CGPoint, in context: CGContext) {
        for line in textLineFragments {
            let attributed = line.attributedString
            let range = line.characterRange
            guard range.length > 0, NSMaxRange(range) <= attributed.length else { continue }
            var seen = Set<Int>()
            attributed.enumerateAttribute(.lumiLiveMarker, in: range, options: []) { value, sub, _ in
                guard let m = value as? LiveMarkerBox, !seen.contains(sub.location) else { return }
                seen.insert(sub.location)
                let x0 = line.locationForCharacter(at: sub.location).x
                let b = line.typographicBounds
                let font = attributed.attribute(.font, at: sub.location, effectiveRange: nil) as? MarkdownPlatformFont
                let em = decoration.palette.em
                let baseline = point.y + b.minY + line.glyphOrigin.y
                _ = font
                let xHeight = MarkdownPlatformFont.systemFont(ofSize: em).xHeight
                let cy = baseline - xHeight / 2 - 0.5
                switch m.kind {
                case let .bullet(level):
                    let cx = point.x + b.minX + x0 + 0.42 * em
                    let dia = 0.34 * em
                    let r = CGRect(x: cx - dia / 2, y: cy - dia / 2, width: dia, height: dia)
                    switch level % 3 {
                    case 0:
                        context.setFillColor(m.color.cgColor)
                        context.fillEllipse(in: r)
                    case 1:
                        context.setStrokeColor(m.color.cgColor)
                        context.setLineWidth(1.2)
                        context.strokeEllipse(in: r.insetBy(dx: 0.6, dy: 0.6))
                    default:
                        context.setFillColor(m.color.cgColor)
                        context.fill(r.insetBy(dx: 0.4, dy: 0.4))
                    }
                case let .task(checked):
                    let side = 0.92 * em
                    let x = point.x + b.minX + x0
                    let box = CGRect(x: x, y: cy - side / 2, width: side, height: side)
                    let path = CGPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 0.26 * side, cornerHeight: 0.26 * side, transform: nil)
                    if checked {
                        context.addPath(path)
                        context.setFillColor(m.accent.cgColor)
                        context.fillPath()
                        let check = CGMutablePath()
                        check.move(to: CGPoint(x: box.minX + 0.26 * side, y: box.midY + 0.02 * side))
                        check.addLine(to: CGPoint(x: box.minX + 0.43 * side, y: box.minY + 0.7 * side))
                        check.addLine(to: CGPoint(x: box.minX + 0.75 * side, y: box.minY + 0.3 * side))
                        context.addPath(check)
                        context.setStrokeColor(MarkdownPlatformColor.white.cgColor)
                        context.setLineWidth(max(1.4, 0.11 * side))
                        context.setLineCap(.round)
                        context.setLineJoin(.round)
                        context.strokePath()
                    } else {
                        context.addPath(path)
                        context.setStrokeColor(m.border.cgColor)
                        context.setLineWidth(1.4)
                        context.strokePath()
                    }
                }
            }
        }
    }

    /// Rect (view-local) of the task box drawn for the marker starting at
    /// `location`, for click handling.
    func taskBoxRect(forLocation location: Int, fragmentLocation: Int) -> CGRect? {
        for line in textLineFragments {
            let attributed = line.attributedString
            let range = line.characterRange
            let local = location - fragmentLocation
            guard local >= range.location, local < NSMaxRange(range), local < attributed.length else { continue }
            let x0 = line.locationForCharacter(at: local).x
            let b = line.typographicBounds
            let em = decoration.palette.em
            let side = 0.92 * em
            let baseline = b.minY + line.glyphOrigin.y
            let cy = baseline - MarkdownPlatformFont.systemFont(ofSize: em).xHeight / 2 - 0.5
            return CGRect(x: layoutFragmentFrame.minX + b.minX + x0 - 3, y: layoutFragmentFrame.minY + cy - side / 2 - 3,
                          width: side + 6, height: side + 6)
        }
        return nil
    }

    static func calloutSymbol(_ kind: String) -> String {
        switch kind {
        case "warning", "danger": return "exclamationmark.triangle"
        case "tip", "success": return "checkmark"
        case "question": return "questionmark.circle"
        case "todo": return "circle.dashed"
        case "example": return "list.bullet"
        case "quote": return "quote.opening"
        case "abstract": return "doc.text"
        default: return "info.circle"
        }
    }

    private func drawSymbol(_ name: String, color: MarkdownPlatformColor, size: CGFloat, center: CGPoint, in context: CGContext) {
        #if canImport(AppKit)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        #else
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let s = image.size
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
        UIGraphicsPopContext()
        #endif
    }

    private func drawString(_ string: NSAttributedString, at origin: CGPoint, in context: CGContext) {
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        string.draw(at: origin)
        UIGraphicsPopContext()
        #endif
    }

    private func gradient(_ r: CGRect, colors: [MarkdownPlatformColor], locations: [CGFloat], in context: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let g = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations) else { return }
        context.saveGState()
        context.clip(to: r)
        context.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
        context.restoreGState()
    }

    static func roundedPath(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY + top))
        if top > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + top, y: r.minY), radius: top) }
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
        if top > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + top), radius: top) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottom))
        if bottom > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - bottom, y: r.maxY), radius: bottom) }
        p.addLine(to: CGPoint(x: r.minX + bottom, y: r.maxY))
        if bottom > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bottom), radius: bottom) }
        p.closeSubpath()
        return p
    }
}

private extension MarkdownPlatformColor {
    var alphaComponentValue: CGFloat {
        var a: CGFloat = 1
        #if canImport(AppKit)
        a = (usingColorSpace(.sRGB) ?? self).alphaComponent
        #else
        getRed(nil, green: nil, blue: nil, alpha: &a)
        #endif
        return a
    }
}
