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
            let r = rect(for: deco)
            if !r.isNull { bounds = bounds.union(r.insetBy(dx: -2, dy: -2)) }
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
                let y = (r.midY).rounded(.down) + 0.5
                context.setFillColor(deco.fill.cgColor)
                context.fill(CGRect(x: r.minX, y: y - 0.5, width: r.width, height: 1))
            case .chips:
                drawChips(at: point, deco: deco, in: context)
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
        context.setFillColor(deco.fill.cgColor)
        context.fill(r)
        context.setFillColor(deco.stroke.cgColor)
        context.fill(CGRect(x: r.minX, y: r.minY, width: 3, height: r.height))
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
