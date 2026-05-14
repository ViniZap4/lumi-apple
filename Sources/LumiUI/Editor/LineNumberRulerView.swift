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

        // Soft divider on the right edge.
        dividerColor.setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        edge.lineWidth = 0.5
        edge.stroke()

        let nsText = textView.string as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else { return }

        // Cursor's line number — used to determine current-line styling
        // and relative deltas.
        let cursorLine = lineNumber(at: min(textView.selectedRange().location, totalLength), in: nsText)

        // The visible portion of the document (in textView coordinates).
        let visibleRect = scrollView?.contentView.bounds ?? bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible character.
        var line = lineNumber(at: charRange.location, in: nsText)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let currentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

        var charIndex = nsText.lineRange(for: NSRange(location: charRange.location, length: 0)).location
        let endLocation = min(NSMaxRange(charRange), totalLength)
        let inset = textView.textContainerInset.height
        let textViewOrigin = textView.frame.origin

        while charIndex <= endLocation {
            let lineRange = nsText.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            guard lineGlyphRange.length > 0 || charIndex == totalLength else {
                charIndex = NSMaxRange(lineRange)
                line += 1
                continue
            }
            let fragRect = layoutManager.lineFragmentRect(
                forGlyphAt: lineGlyphRange.location,
                effectiveRange: nil
            )

            // Convert fragment rect → ruler-view coordinates.
            // Fragment rect is in textContainer coords; offset by inset
            // and the textView's origin within the scrollView.
            let clientY = fragRect.minY + inset + textViewOrigin.y
            let rulerPoint = NSPoint(x: 0, y: clientY)
            let p = convert(rulerPoint, from: superview)

            let isCurrent = line == cursorLine
            let displayed: Int
            if showRelative {
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
            let drawRect = NSRect(
                x: ruleThickness - size.width - 8,
                y: p.y,
                width: size.width,
                height: size.height
            )
            label.draw(in: drawRect, withAttributes: attrs)

            charIndex = NSMaxRange(lineRange)
            line += 1
            if charIndex >= totalLength { break }
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
