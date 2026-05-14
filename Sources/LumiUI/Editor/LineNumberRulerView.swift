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

        // Compute the line number of the first visible character ONCE.
        // Subsequent fragments increment by counting newlines in the
        // bytes we skip past — O(charRange.length) per draw instead of
        // O(N²) over the whole document, which is what made the gutter
        // fall behind in large notes.
        var currentLine = lineNumber(at: charRange.location, in: nsText)
        var lastLabeled = -1

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let fragCharRange = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let lineStart = nsText.lineRange(for: NSRange(location: fragCharRange.location, length: 0)).location
            // Only label the first fragment of each logical line.
            guard fragCharRange.location == lineStart else { return }
            guard currentLine != lastLabeled else { return }
            lastLabeled = currentLine

            // Convert the fragment rect from textContainer coords into
            // ruler coords. `convert(_:from: textView)` handles both the
            // textContainerOrigin offset and the clip-view scroll, so
            // this works at any scroll depth — the prior arithmetic
            // missed the scroll component which is why numbers drifted
            // off the screen.
            let pointInText = NSPoint(x: 0, y: fragRect.minY + textView.textContainerOrigin.y)
            let pointInRuler = self.convert(pointInText, from: textView)
            let y = pointInRuler.y

            // Don't draw outside the dirty rect. Cheap fast-path that
            // matters for very long documents.
            if y + fragRect.height < rect.minY || y > rect.maxY {
                self.advance(line: &currentLine, after: fragCharRange, in: nsText)
                return
            }

            let isCurrent = currentLine == cursorLine
            let displayed: Int
            if self.showRelative {
                displayed = isCurrent ? currentLine : abs(currentLine - cursorLine)
            } else {
                displayed = currentLine
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

            self.advance(line: &currentLine, after: fragCharRange, in: nsText)
        }

        // Numbers for the trailing empty-line phantom (file ends with `\n`).
        if totalLength > 0 && nsText.character(at: totalLength - 1) == 0x0A {
            let lastLine = lineNumber(at: totalLength, in: nsText)
            if lastLine != lastLabeled {
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
    }

    /// O(1) per-fragment line increment: counts newlines in the
    /// fragment's character range so the running line number stays
    /// correct without recomputing from offset 0 each time.
    private func advance(line: inout Int, after fragCharRange: NSRange, in text: NSString) {
        let upper = min(NSMaxRange(fragCharRange), text.length)
        var i = fragCharRange.location
        while i < upper {
            if text.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
    }

    /// One-shot line number lookup for the cursor + first visible
    /// fragment. O(offset) but called only twice per draw.
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
