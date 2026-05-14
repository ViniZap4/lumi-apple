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
/// newline-bounded logical line gets a label).
final class LineNumberRulerView: NSRulerView {
    var showRelative: Bool = false {
        didSet { needsDisplay = true }
    }

    var theme: ThemeTokens? {
        didSet { needsDisplay = true }
    }

    /// Cached observers torn down on dealloc / clientView swap. Marked
    /// `nonisolated(unsafe)` so the non-isolated `deinit` can release
    /// the tokens. Observers are only mutated from the main actor
    /// (in `attach(to:scrollView:)`).
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        attach(to: textView, scrollView: scrollView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        // Notification observers retain `self`; release them before the
        // ruler is deallocated.
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func attach(to textView: NSTextView, scrollView: NSScrollView) {
        let center = NotificationCenter.default
        // Selection changes — needed for current-line highlight and for
        // recalculating relative offsets without waiting for a SwiftUI
        // diff to run `updateNSView`.
        observers.append(center.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
        // Any text change → recount lines.
        observers.append(center.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
        // Scrolls inside the clip view shift our bounds; AppKit redraws
        // automatically on bounds change but only if posts are enabled.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
        // Font size / wrap width changes alter every line's Y.
        textView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true })
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
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

        // Force the layout for the *visible* region — without this,
        // glyphs deep into the document may still be at their old
        // positions (or not laid out at all yet) which is what causes
        // numbers to drift downward and then disappear once we reach
        // unlaid-out glyphs.
        let visibleRect = scrollView?.documentVisibleRect ?? textView.visibleRect
        layoutManager.ensureLayout(forBoundingRect: visibleRect, in: textContainer)

        // Cursor's line number (1-based).
        let cursorLocation = min(textView.selectedRange().location, totalLength)
        let cursorLine = lineNumber(at: cursorLocation, in: nsText)

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let currentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

        // We compute a line number per labeled fragment by counting
        // newlines from offset 0. This is intentionally simple — earlier
        // attempts to track a running counter across wrap continuations
        // drifted out of sync (a skipped continuation left newlines
        // unconsumed, so the *next* logical line inherited the previous
        // line's number). Recomputing per labeled fragment keeps us
        // correct; the cost is bounded by visible-line count × document
        // size, which is fine for normal notes.
        _ = charRange // (kept for clarity of bounding intent)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragCharRange = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let lineStart = nsText.lineRange(for: NSRange(location: fragCharRange.location, length: 0)).location
            // Only label the leading fragment of each logical line —
            // soft-wrap continuations share the same line number with
            // the leading fragment and stay un-labeled.
            guard fragCharRange.location == lineStart else { return }

            let line = self.lineNumber(at: fragCharRange.location, in: nsText)

            // Fragment rect is in textContainer coords; convert through
            // the textView so the clip-view scroll offset is handled
            // automatically.
            let pointInText = NSPoint(x: 0, y: fragRect.minY + textView.textContainerOrigin.y)
            let y = self.convert(pointInText, from: textView).y

            // Off-screen → still nothing to draw, but we *do* want to
            // bail before any text rendering for the cheap fast-path.
            if y + fragRect.height < rect.minY || y > rect.maxY { return }

            let isCurrent = line == cursorLine
            let displayed: Int
            if self.showRelative {
                displayed = isCurrent ? line : abs(line - cursorLine)
            } else {
                displayed = line
            }

            if isCurrent {
                currentBgColor.setFill()
                NSRect(x: 0, y: y, width: self.ruleThickness, height: fragRect.height).fill()
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? currentFont : baseFont,
                .foregroundColor: isCurrent ? strongColor : dimColor
            ]
            let label = "\(displayed)" as NSString
            let size = label.size(withAttributes: attrs)
            let drawY = y + max(0, (fragRect.height - size.height) / 2)
            label.draw(
                at: NSPoint(x: self.ruleThickness - size.width - 8, y: drawY),
                withAttributes: attrs
            )
        }

        // Numbers for the trailing empty-line phantom (file ends with `\n`).
        if totalLength > 0 && nsText.character(at: totalLength - 1) == 0x0A {
            let lastLine = lineNumber(at: totalLength, in: nsText)
            let usedHeight = layoutManager.usedRect(for: textContainer).maxY
            let pointInText = NSPoint(x: 0, y: usedHeight + textView.textContainerOrigin.y)
            let y = convert(pointInText, from: textView).y
            if y >= rect.minY && y <= rect.maxY {
                let isCurrent = lastLine == cursorLine
                let displayed: Int = showRelative
                    ? (isCurrent ? lastLine : abs(lastLine - cursorLine))
                    : lastLine
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isCurrent ? currentFont : baseFont,
                    .foregroundColor: isCurrent ? strongColor : dimColor
                ]
                let label = "\(displayed)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(
                    at: NSPoint(x: ruleThickness - size.width - 8, y: y),
                    withAttributes: attrs
                )
            }
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
