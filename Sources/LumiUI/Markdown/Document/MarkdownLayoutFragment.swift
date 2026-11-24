import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Supplies `MarkdownLayoutFragment` for paragraphs carrying block chrome.
/// Plain paragraphs get the stock fragment, so the common path pays one
/// attribute lookup and nothing else.
final class MarkdownLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           let decorations = paragraph.attributedString.attribute(.lumiDecorations, at: 0, effectiveRange: nil) as? [MarkdownDecoration],
           !decorations.isEmpty {
            return MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange, decorations: decorations)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// Layout fragment that paints block chrome (code background + language
/// label, quote bar + tint, horizontal rule, tag capsules) behind its
/// text. Geometry is derived from the fragment's own line fragments and
/// paragraph style, so it is correct at any width and needs no
/// out-of-band measurement.
final class MarkdownLayoutFragment: NSTextLayoutFragment {
    let decorations: [MarkdownDecoration]

    init(textElement: NSTextElement, range: NSTextRange?, decorations: [MarkdownDecoration]) {
        self.decorations = decorations
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not coded") }

    // MARK: Geometry

    private var linesBounds: CGRect {
        textLineFragments.reduce(CGRect.null) { $0.union($1.typographicBounds) }
    }

    private var containerWidth: CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? 0
        return width > 0 ? width : layoutFragmentFrame.maxX
    }

    /// Chrome rect for `deco` in fragment-local coordinates.
    func rect(for deco: MarkdownDecoration) -> CGRect {
        let lines = linesBounds
        guard !lines.isNull else { return .null }
        // TextKit 2 stacks fragments edge to edge, paragraph spacing
        // included, so interior edges run to the fragment bounds and
        // neighbouring paragraphs of one container draw as one piece.
        let top = deco.isFirst ? lines.minY - deco.padding : 0
        let bottom = deco.isLast ? lines.maxY + deco.padding : layoutFragmentFrame.height
        let minX = deco.indent - layoutFragmentFrame.minX
        let maxX = containerWidth - layoutFragmentFrame.minX
        return CGRect(x: minX, y: top, width: max(0, maxX - minX), height: max(0, bottom - top))
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        for deco in decorations {
            switch deco.kind {
            case .pills:
                bounds = bounds.insetBy(dx: -8, dy: -4)
            case .headingRule:
                let lines = linesBounds
                if !lines.isNull {
                    bounds = bounds.union(CGRect(x: deco.indent - layoutFragmentFrame.minX, y: lines.maxY,
                                                 width: containerWidth, height: deco.padding + 2))
                }
            case .footnotes:
                let lines = linesBounds
                if !lines.isNull {
                    bounds = bounds.union(CGRect(x: deco.indent - layoutFragmentFrame.minX, y: lines.minY - deco.padding - 2,
                                                 width: containerWidth, height: deco.padding + 2))
                }
            default:
                let r = rect(for: deco)
                if !r.isNull { bounds = bounds.union(r.insetBy(dx: -2, dy: -2)) }
            }
        }
        return bounds
    }

    // MARK: Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        // Outermost container first so inner chrome paints on top.
        for deco in decorations.reversed() {
            let r = rect(for: deco).offsetBy(dx: point.x, dy: point.y)
            guard !r.isNull else { continue }
            switch deco.kind {
            case let .codeBlock(language):
                drawCodeBlock(r, deco: deco, language: language, in: context)
            case .quote:
                drawQuote(r, deco: deco, in: context)
            case .rule:
                let y = (r.midY).rounded(.down)
                let line = CGRect(x: r.minX, y: y, width: r.width, height: 1)
                if deco.padding > 0 {
                    // `hr`: fades in and out at the ends.
                    drawGradient(line, colors: [deco.fill.withAlphaComponent(0), deco.fill, deco.fill, deco.fill.withAlphaComponent(0)],
                                 locations: [0, 0.15, 0.85, 1], in: context)
                } else {
                    context.setFillColor(deco.fill.cgColor)
                    context.fill(line)
                }
            case .chips:
                drawChips(at: point, deco: deco, in: context)
            case let .callout(foldable, open):
                drawCallout(r, deco: deco, foldable: foldable, open: open, at: point, in: context)
            case .headingRule:
                let lines = linesBounds
                guard !lines.isNull else { continue }
                let y = (point.y + lines.maxY + deco.padding).rounded(.down)
                let x0 = point.x + deco.indent - layoutFragmentFrame.minX
                let width = containerWidth - deco.indent
                drawGradient(CGRect(x: x0, y: y, width: width, height: 1),
                             colors: [deco.fill, deco.fill, deco.fill.withAlphaComponent(0)], locations: [0, 0.55, 1], in: context)
            case .footnotes:
                let lines = linesBounds
                guard !lines.isNull else { continue }
                let y = (point.y + lines.minY - deco.padding).rounded(.down)
                let x0 = point.x + deco.indent - layoutFragmentFrame.minX
                context.setFillColor(deco.fill.cgColor)
                context.fill(CGRect(x: x0, y: y, width: containerWidth - deco.indent, height: 1))
            case .pills:
                drawPills(at: point, in: context)
            }
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    private func drawCodeBlock(_ r: CGRect, deco: MarkdownDecoration, language: String?, in context: CGContext) {
        let radius: CGFloat = 10
        let path = CGPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(deco.fill.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(deco.stroke.cgColor)
        context.setLineWidth(0.5)
        context.strokePath()

        guard let language, let font = deco.labelFont else { return }
        let label = NSAttributedString(string: language, attributes: [
            .font: font,
            .foregroundColor: deco.labelColor,
        ])
        let size = label.size()
        let origin = CGPoint(x: r.maxX - size.width - 12, y: r.minY + 6)
        guard origin.x > r.minX + 40 else { return }
        drawString(label, at: origin, in: context)
    }

    private func drawQuote(_ r: CGRect, deco: MarkdownDecoration, in context: CGContext) {
        context.setFillColor(deco.stroke.cgColor)
        context.fill(CGRect(x: r.minX, y: r.minY, width: 3, height: r.height))
    }

    /// Callout box: tinted fill, hairline border, 3 pt left bar in the
    /// kind's colour; a chevron on the (first) title line when foldable.
    private func drawCallout(_ r: CGRect, deco: MarkdownDecoration, foldable: Bool, open: Bool, at point: CGPoint, in context: CGContext) {
        let radius: CGFloat = 8
        // Interior paragraphs draw their slice square-edged so the slices
        // join into one box: round only the container's real ends.
        let top = deco.isFirst ? radius : 0
        let bottom = deco.isLast ? radius : 0
        let path = Self.roundedPath(r, top: top, bottom: bottom)
        context.saveGState()
        context.addPath(path)
        context.setFillColor(deco.fill.cgColor)
        context.fillPath()
        // Border: the full rounded outline, clipped to this slice.
        context.addPath(path)
        context.clip()
        let extendTop: CGFloat = deco.isFirst ? 0 : 20
        let extendBottom: CGFloat = deco.isLast ? 0 : 20
        let outline = CGRect(x: r.minX + 0.5, y: r.minY + 0.5 - extendTop,
                             width: r.width - 1, height: r.height - 1 + extendTop + extendBottom)
        context.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(deco.stroke.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setFillColor(deco.labelColor.cgColor)
        context.fill(CGRect(x: r.minX, y: r.minY, width: 3, height: r.height))
        context.restoreGState()

        guard foldable, deco.isFirst, let first = textLineFragments.first, let font = deco.labelFont else { return }
        let b = first.typographicBounds
        let chevron = NSAttributedString(string: "\u{203A}", attributes: [.font: font, .foregroundColor: deco.labelColor])
        let size = chevron.size()
        let cx = r.maxX - 1.05 * font.pointSize - size.width / 2
        let cy = point.y + b.midY
        context.saveGState()
        context.translateBy(x: cx, y: cy)
        if open { context.rotate(by: .pi / 2) }
        drawString(chevron, at: CGPoint(x: -size.width / 2, y: -size.height / 2), in: context)
        context.restoreGState()
    }

    private static func roundedPath(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
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

    private func drawGradient(_ r: CGRect, colors: [MarkdownPlatformColor], locations: [CGFloat], in context: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations)
        else { return }
        context.saveGState()
        context.clip(to: r)
        context.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
        context.restoreGState()
    }

    /// Rounded backgrounds behind `.lumiPill` runs (inline code, kbd,
    /// mark), one per line the run occupies.
    private func drawPills(at point: CGPoint, in context: CGContext) {
        Self.drawPills(textLineFragments, at: point, in: context)
    }

    /// Shared with Live Preview's fragment (one prose system).
    static func drawPills(_ lines: [NSTextLineFragment], at point: CGPoint, in context: CGContext) {
        for line in lines {
            let attributed = line.attributedString
            let range = line.characterRange
            guard range.length > 0, NSMaxRange(range) <= attributed.length else { continue }
            let ns = attributed.string as NSString
            attributed.enumerateAttribute(.lumiPill, in: range, options: []) { value, sub, _ in
                guard let pill = value as? MarkdownPill else { return }
                var end = NSMaxRange(sub)
                while end > sub.location, ns.character(at: end - 1) == 10 || ns.character(at: end - 1) == 0x2028 { end -= 1 }
                guard end > sub.location else { return }
                let x0 = line.locationForCharacter(at: sub.location).x
                var x1 = line.locationForCharacter(at: end).x
                // The run's trailing kern pads it: measure to the glyph.
                if let kern = attributed.attribute(.kern, at: end - 1, effectiveRange: nil) as? CGFloat, pill.kind != .mark {
                    x1 -= kern
                }
                guard x1 > x0 else { return }
                let font = attributed.attribute(.font, at: sub.location, effectiveRange: nil) as? MarkdownPlatformFont
                let size = font?.pointSize ?? 13
                let ascender = font?.ascender ?? size * 0.8
                let descender = font?.descender ?? -size * 0.2
                let b = line.typographicBounds
                let baseline = point.y + b.minY + line.glyphOrigin.y
                let padX: CGFloat
                let padY: CGFloat
                switch pill.kind {
                case .code: padX = 0.4 * size; padY = 0.16 * size
                case .kbd: padX = 0.45 * size; padY = 0.2 * size
                case .mark: padX = 0.12 * size; padY = 0.04 * size
                }
                var offset: CGFloat = 0
                if let bo = attributed.attribute(.baselineOffset, at: sub.location, effectiveRange: nil) as? CGFloat { offset = bo }
                let rect = CGRect(x: point.x + b.minX + x0 - padX,
                                  y: baseline - offset - ascender - padY,
                                  width: (x1 - x0) + 2 * padX,
                                  height: ascender - descender + 2 * padY)
                let radius: CGFloat = pill.kind == .mark ? 3 : 5
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(pill.fill.cgColor)
                context.fillPath()
                if let stroke = pill.stroke {
                    context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
                    context.setStrokeColor(stroke.cgColor)
                    context.setLineWidth(1)
                    context.strokePath()
                    if pill.kind == .kbd {
                        // Heavier bottom edge (`border-bottom-width: 2px`).
                        context.setFillColor(stroke.cgColor)
                        context.fill(CGRect(x: rect.minX + 3, y: rect.maxY - 1.5, width: rect.width - 6, height: 1.5))
                    }
                }
            }
        }
    }

    /// Capsules behind tag runs. Positions come from the line fragments'
    /// own caret offsets, so they follow the real glyph layout.
    private func drawChips(at point: CGPoint, deco: MarkdownDecoration, in context: CGContext) {
        for line in textLineFragments {
            let attributed = line.attributedString
            let range = line.characterRange
            guard range.length > 0, NSMaxRange(range) <= attributed.length else { continue }
            attributed.enumerateAttribute(.lumiChip, in: range, options: []) { value, sub, _ in
                guard value != nil else { return }
                let x0 = line.locationForCharacter(at: sub.location).x
                let x1 = line.locationForCharacter(at: NSMaxRange(sub)).x
                let b = line.typographicBounds
                let chip = CGRect(
                    x: point.x + b.minX + x0 - 6,
                    y: point.y + b.minY - 2,
                    width: (x1 - x0) + 12,
                    height: b.height + 4
                )
                let path = CGPath(roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2, transform: nil)
                context.addPath(path)
                context.setFillColor(deco.fill.cgColor)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(deco.stroke.cgColor)
                context.setLineWidth(0.5)
                context.strokePath()
            }
        }
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
}
