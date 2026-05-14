import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit

/// A line-number gutter attached to the vim editor's scroll view. Renders
/// numbers aligned with the visible portion of the document, supporting
/// both absolute and relative (vim's `relativenumber`) modes.
///
/// Drawing strategy: walk the line-fragment rects produced by the
/// layout manager so wrapped soft-lines don't get extra numbers — only
/// the first fragment of each newline-bounded line is labeled.
final class LineNumberRulerView: NSRulerView {
    /// Toggle relative vs absolute numbering. In relative mode the current
    /// line shows its absolute number (like `number` + `relativenumber`),
    /// matching vim's combined display.
    var showRelative: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Theme tokens for foreground / background / current-line color.
    var theme: ThemeTokens? {
        didSet { needsDisplay = true }
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        let theme = self.theme
        let bgColor: NSColor = theme.map { NSColor($0.background) } ?? .windowBackgroundColor
        let dimColor: NSColor = theme.map { NSColor($0.textDim).withAlphaComponent(0.7) } ?? .secondaryLabelColor
        let strongColor: NSColor = theme.map { NSColor($0.accent) } ?? .labelColor
        let dividerColor: NSColor = theme.map { NSColor($0.border) } ?? .gridColor

        bgColor.setFill()
        bounds.fill()

        dividerColor.setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        edge.lineWidth = 0.5
        edge.stroke()

        let nsText = textView.string as NSString
        let totalLength = nsText.length

        // Cursor's line number (1-based).
        let cursorLine = lineNumber(at: min(textView.selectedRange().location, totalLength), in: nsText)

        // Visible portion of the document — in textView (a.k.a.
        // documentView) coordinates, which is the same coordinate space
        // the ruler uses for drawing once the scrollView has translated
        // its bounds. Note: `scrollView?.documentVisibleRect` gives us
        // the visible area in documentView coords directly, which is
        // exactly what we need to feed back into `lineFragmentRect`'s
        // result for proper Y alignment.
        let visibleRect = scrollView?.documentVisibleRect ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let currentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        // textContainerOrigin = textContainerInset offset of the
        // container relative to the textView's frame origin. We add it
        // so the line numbers sit precisely next to the rendered text
        // baseline rather than 12pt above.
        let containerOrigin = textView.textContainerOrigin

        // Walk the line-fragment rects in the visible glyph range.
        // Enumerate gives us one callback per visual line (handles soft
        // wraps automatically — but we still only label the first
        // fragment of each newline-bounded logical line).
        var labeledLine: Int = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let lineRange = nsText.lineRange(for: NSRange(location: charRange.location, length: 0))
            // Skip soft-wrapped continuations — only label when this
            // fragment starts at the beginning of a logical line.
            guard charRange.location == lineRange.location else { return }

            let line = self.lineNumber(at: charRange.location, in: nsText)
            guard line != labeledLine else { return }
            labeledLine = line

            // Convert the fragment rect (in textContainer coords) into
            // the documentView coord space — which is the same space
            // the ruler is scrolled with, so Y maps 1:1 onto our
            // drawing.
            let y = fragRect.minY + containerOrigin.y

            let isCurrent = line == cursorLine
            let displayed: Int
            if self.showRelative {
                displayed = isCurrent ? line : abs(line - cursorLine)
            } else {
                displayed = line
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? currentFont : font,
                .foregroundColor: isCurrent ? strongColor : dimColor
            ]
            let label = "\(displayed)" as NSString
            let size = label.size(withAttributes: attrs)
            // Vertically center within the fragment so multi-line
            // heights still produce nicely-aligned numbers.
            let drawY = y + (fragRect.height - size.height) / 2
            let drawRect = NSRect(
                x: self.ruleThickness - size.width - 8,
                y: drawY,
                width: size.width,
                height: size.height
            )
            label.draw(in: drawRect, withAttributes: attrs)
        }

        // Trailing newline → label one more line so the user sees the
        // last (empty) logical line numbered too. AppKit doesn't emit a
        // fragment for it.
        if totalLength > 0 && nsText.character(at: totalLength - 1) == 0x0A {
            let lastLine = lineNumber(at: totalLength, in: nsText)
            if lastLine != labeledLine {
                let usedRect = layoutManager.usedRect(for: textContainer)
                let y = usedRect.maxY + containerOrigin.y
                if visibleRect.contains(NSPoint(x: visibleRect.midX, y: y)) {
                    let isCurrent = lastLine == cursorLine
                    let displayed: Int = showRelative
                        ? (isCurrent ? lastLine : abs(lastLine - cursorLine))
                        : lastLine
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: isCurrent ? currentFont : font,
                        .foregroundColor: isCurrent ? strongColor : dimColor
                    ]
                    let label = "\(displayed)" as NSString
                    let size = label.size(withAttributes: attrs)
                    label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
                }
            }
        }
    }

    /// Count line breaks up to (and excluding) `offset`. Returns the
    /// 1-based line number containing `offset`.
    private func lineNumber(at offset: Int, in text: NSString) -> Int {
        var line = 1
        let upper = min(offset, text.length)
        var i = 0
        while i < upper {
            if text.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }
}
#endif
