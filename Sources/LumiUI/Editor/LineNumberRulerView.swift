import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit

/// Line-number gutter for the vim editor. Renders absolute or relative
/// (`relativenumber`) numbers aligned with the visible line fragments.
///
/// Coordinate notes — the ruler view's bounds are kept in sync with the
/// scroll's clip view, so drawing at `y = fragmentRect.minY +
/// textContainerOrigin.y` lands at the same on-screen Y as the rendered
/// text fragment. We enumerate fragments via the layout manager so wrap
/// continuations stay un-numbered (only the leading fragment of each
/// newline-bounded logical line gets a label). TextKit 2 only — it
/// enumerates `NSTextLayoutFragment`s and never touches `layoutManager`.
final class LineNumberRulerView: NSRulerView {
    var showRelative: Bool = false {
        didSet { needsDisplay = true }
    }

    var theme: ThemeTokens? {
        didSet { needsDisplay = true }
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        attach(to: textView, scrollView: scrollView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Selector-based observers: the `@objc` handler inherits NSView's
    /// main-actor isolation (all four notifications are posted on the
    /// main thread by AppKit), and NotificationCenter drops selector
    /// observers automatically when the ruler deallocates — so there's
    /// no token array for a nonisolated `deinit` to touch and no
    /// `@Sendable` block reaching into main-actor state.
    private func attach(to textView: NSTextView, scrollView: NSScrollView) {
        let center = NotificationCenter.default
        let redraw = #selector(setNeedsRedraw(_:))
        // Selection changes — needed for current-line highlight and for
        // recalculating relative offsets without waiting for a SwiftUI
        // diff to run `updateNSView`.
        center.addObserver(self, selector: redraw, name: NSTextView.didChangeSelectionNotification, object: textView)
        // Any text change → recount lines.
        center.addObserver(self, selector: redraw, name: NSText.didChangeNotification, object: textView)
        // Scrolls inside the clip view shift our bounds; AppKit redraws
        // automatically on bounds change but only if posts are enabled.
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: redraw, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Font size / wrap width changes alter every line's Y.
        textView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: redraw, name: NSView.frameDidChangeNotification, object: textView)
    }

    @objc private func setNeedsRedraw(_ note: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // TextKit 2 only: touching `textView.layoutManager` would silently
        // downgrade the view to TextKit 1.
        guard let textView = clientView as? NSTextView,
              let tlm = textView.textLayoutManager,
              let content = tlm.textContentManager
        else { return }

        let theme = self.theme
        let bgColor: NSColor = theme.map { NSColor($0.background) } ?? .windowBackgroundColor
        let dimColor: NSColor = theme.map { NSColor($0.textDim).withAlphaComponent(0.65) } ?? .secondaryLabelColor
        let strongColor: NSColor = theme.map { NSColor($0.accent) } ?? .labelColor
        let currentBgColor: NSColor = theme.map { NSColor($0.accent).withAlphaComponent(0.08) } ?? NSColor.clear
        let dividerColor: NSColor = theme.map { NSColor($0.border).withAlphaComponent(0.5) } ?? .gridColor

        bgColor.setFill()
        bounds.fill()
        dividerColor.setStroke()
        NSBezierPath.defaultLineWidth = 0.5
        NSBezierPath.strokeLine(
            from: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY),
            to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY)
        )

        let nsText = textView.string as NSString
        let totalLength = nsText.length
        let cursorLine = lineNumber(at: min(textView.selectedRange().location, totalLength), in: nsText)
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let currentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect

        func drawLabel(line: Int, top: CGFloat, height: CGFloat) {
            let y = convert(NSPoint(x: 0, y: top + origin.y), from: textView).y
            if y + height < rect.minY || y > rect.maxY { return }
            let isCurrent = line == cursorLine
            let displayed = showRelative ? (isCurrent ? line : abs(line - cursorLine)) : line
            if isCurrent {
                currentBgColor.setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: height).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? currentFont : baseFont,
                .foregroundColor: isCurrent ? strongColor : dimColor
            ]
            let label = "\(displayed)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + max(0, (height - size.height) / 2)), withAttributes: attrs)
        }

        // Each TextKit 2 layout fragment is one paragraph (logical line);
        // soft-wrapped continuations live inside it and stay unlabeled.
        let startPoint = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let startLocation = tlm.textLayoutFragment(for: startPoint)?.rangeInElement.location ?? content.documentRange.location
        let startOffset = content.offset(from: content.documentRange.location, to: startLocation)
        var line = lineNumber(at: startOffset, in: nsText)
        var lastFragment: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY - origin.y > visible.maxY { return false }
            let firstLineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            drawLabel(line: line, top: frame.minY, height: firstLineHeight)
            line += 1
            lastFragment = fragment
            return true
        }
        // Trailing empty line after a final newline: TextKit 2 renders it
        // as an extra line fragment inside the last paragraph.
        if totalLength > 0, nsText.character(at: totalLength - 1) == 0x0A,
           let last = lastFragment, let extra = last.textLineFragments.last,
           last.textLineFragments.count > 1, extra.characterRange.length == 0 {
            drawLabel(line: lineNumber(at: totalLength, in: nsText),
                      top: last.layoutFragmentFrame.minY + extra.typographicBounds.minY,
                      height: extra.typographicBounds.height)
        }
    }

    /// Line number for an offset (1-based). O(offset) but called once
    /// per visible logical-line fragment — bounded by document size.
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
