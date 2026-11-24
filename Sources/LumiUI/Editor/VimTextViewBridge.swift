import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Font/colour attributes for the editor's markdown highlighting.
@MainActor
struct EditorStyler {
    let theme: ThemeTokens
    let fontSize: CGFloat

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
         .foregroundColor: PlatformColor(theme.text)]
    }

    func attributes(for style: MarkdownSyntaxStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading:
            return [.foregroundColor: PlatformColor(theme.accent),
                    .font: PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)]
        case .bold:
            return [.foregroundColor: PlatformColor(theme.primary),
                    .font: PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)]
        case .inlineCode:
            return [.foregroundColor: PlatformColor(theme.warning)]
        case .fence, .quote, .bullet, .frontmatterDelimiter:
            return [.foregroundColor: PlatformColor(theme.textDim)]
        case .link:
            return [.foregroundColor: PlatformColor(theme.primary)]
        }
    }

    /// Re-highlight `range` (whole lines) of `storage` in place.
    func highlight(_ storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        for span in MarkdownSyntaxHighlighter.spans(in: storage.string as NSString, range: range) {
            storage.addAttributes(attributes(for: span.style), range: span.range)
        }
        storage.endEditing()
    }
}

/// Shared TextKit 2 plumbing for the two platform text views: ranged
/// storage edits with incremental (dirty-paragraph) highlighting.
@MainActor
enum EditorStorage {
    static func apply(_ edits: [TextEdit], to storage: NSTextStorage, styler: EditorStyler, highlight: Bool = true,
                      baseAttributes: [NSAttributedString.Key: Any]? = nil) -> NSRange? {
        storage.beginEditing()
        for e in edits {
            guard e.location + e.length <= storage.length else { continue }
            storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.replacement, attributes: baseAttributes ?? styler.baseAttributes))
        }
        storage.endEditing()
        guard highlight else { return nil }
        guard let dirty = MarkdownSyntaxHighlighter.dirtyRange(for: edits, in: storage.string as NSString) else { return nil }
        styler.highlight(storage, range: dirty)
        return dirty
    }
}

#if canImport(AppKit)

/// macOS bridge: a TextKit 2 `NSTextView` in a properly configured
/// `NSScrollView`. The view is driven by `VimController` through ranged
/// edits; printable input goes through `interpretKeyEvents` so dead keys
/// and IMEs work; SwiftUI updates only touch styling and selection
/// colours — never the text.
struct VimTextViewBridge: NSViewRepresentable {
    let controller: VimController
    let mode: VimMode
    let highlights: [NSRange]
    let theme: ThemeTokens
    let showLineNumbers: Bool
    let relativeLineNumbers: Bool
    var fontSize: CGFloat = 13
    var lineWrapping: Bool = true
    /// Visual-block selection (one range per line).
    var blockRanges: [NSRange] = []
    /// Draw a block cursor in normal mode (preference).
    var blockCursor: Bool = true
    /// Source or Live Preview.
    var presentation: EditorPresentation = .source
    /// ⌘-click on a Live Preview link.
    var onOpenLink: ((LiveLink) -> Void)?
    /// Pointer over / off a Live Preview link (window-content rect).
    var onHoverLink: ((LiveLink?, CGRect) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = VimAppKitTextView(usingTextLayoutManager: true)
        textView.styler = EditorStyler(theme: theme, fontSize: fontSize)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        if #available(macOS 15.2, *) {
            textView.writingToolsBehavior = .default
        }

        // Scroll-view configuration (the default init leaves the text
        // view at zero size with no width tracking).
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        textView.attach(controller)

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimAppKitTextView else { return }
        textView.updateTheme(EditorStyler(theme: theme, fontSize: fontSize))
        textView.onOpenLink = onOpenLink
        textView.onHoverLink = onHoverLink
        textView.applyPresentation(presentation, theme: theme)
        textView.applyWrapping(lineWrapping, in: scrollView)
        textView.caretColor = NSColor(mode == .insert || !controller.vimEnabled ? theme.primary : theme.accent)
        textView.cursorColors = VimCursorColors(
            normal: NSColor(theme.accent), insert: NSColor(theme.primary),
            replace: NSColor(theme.warning), inverted: NSColor(theme.background)
        )
        textView.blockCursorPreference = blockCursor
        textView.yankColor = NSColor(theme.accent)
        textView.remoteFlashColor = NSColor(theme.info)
        // Vim visual selection is drawn as a rendering attribute (like
        // the block selection) so it shows whatever the focus state —
        // AppKit greys out an unfocused native selection, which on some
        // themes all but disappears. The native selection stays (⌘C)
        // with a clear tint; outside visual mode (mouse drags, plain
        // editing) it is the normal accent.
        let visual = controller.vimEnabled && mode.isVisual
        textView.selectedTextAttributes = [.backgroundColor: visual ? NSColor.clear : NSColor(theme.editorSelection)]
        textView.isEditable = controller.isEditable
        textView.applyRenderingHighlights(
            search: highlights, searchColor: NSColor(theme.warning).withAlphaComponent(0.35),
            block: blockRanges, blockColor: NSColor(theme.editorSelection)
        )
        textView.updateCursor()

        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.theme = theme
            ruler.showRelative = relativeLineNumbers
            // Line numbers are a Source affordance; Live Preview reads
            // like the page.
            let rulers = showLineNumbers && !presentation.isLive
            if scrollView.rulersVisible != rulers {
                scrollView.rulersVisible = rulers
            }
            ruler.needsDisplay = true
        }
        textView.focusOnce()
    }
}

/// TextKit 2 text view driven by `VimController`.
final class VimAppKitTextView: NSTextView, EditorTextSurface {
    private(set) weak var controller: VimController?
    var styler: EditorStyler?
    /// The vim cursor overlay (block / bar / underline / half block).
    let cursorView = VimCursorView()
    var cursorColors = VimCursorColors(normal: .systemBlue, insert: .systemBlue, replace: .systemOrange, inverted: .textBackgroundColor)
    var blockCursorPreference = true
    /// Colour for the system caret when it shows (IME composition).
    var caretColor: NSColor = .systemBlue
    private(set) var cursorStyle = VimCursorStyle(shape: .block, blinks: false)
    private var blinkTimer: Timer?
    private var blinkOn = true
    /// True while the controller writes into the storage.
    private var applyingEngineChange = false
    private var updatingMarkedText = false
    private var settingSelection = false
    private var pendingExternalEdit: TextEdit?
    private var appliedHighlights: [NSRange] = []
    private var didAutoFocus = false
    /// Last range re-highlighted after an edit (tests).
    private(set) var lastHighlightedRange: NSRange?

    // MARK: Live Preview

    /// Live Preview styler; nil in Source.
    private(set) var live: LivePreviewStyler?
    private(set) var presentation: EditorPresentation = .source
    private let liveDelegate = LiveLayoutDelegate()
    private(set) var liveOverlays: LiveWidgetOverlays?
    /// ⌘-click on a Live Preview link.
    var onOpenLink: ((LiveLink) -> Void)?
    /// Pointer over / off a Live Preview link (hover card).
    var onHoverLink: ((LiveLink?, CGRect) -> Void)?
    private var liveHoverArea: NSTrackingArea?
    private var lastHoverLinkRange: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let liveHoverArea { removeTrackingArea(liveHoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        liveHoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard live != nil, let onHoverLink, let storage = textStorage, storage.length > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: point)
        var hit: (LiveLink, NSRange)?
        for c in [idx, idx - 1] where c >= 0 && c < storage.length {
            var range = NSRange()
            if let box = storage.attribute(.lumiLiveLink, at: c, longestEffectiveRange: &range,
                                           in: NSRange(location: 0, length: storage.length)) as? LiveLinkBox,
               box.link != .inert, let rect = segmentRect(range), rect.insetBy(dx: -2, dy: -2).contains(point) {
                hit = (box.link, range)
                break
            }
        }
        guard hit?.1 != lastHoverLinkRange else { return }
        lastHoverLinkRange = hit?.1
        if let hit, let rect = segmentRect(hit.1) {
            onHoverLink(hit.0, windowContentRect(rect))
        } else {
            onHoverLink(nil, .zero)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if lastHoverLinkRange != nil {
            lastHoverLinkRange = nil
            onHoverLink?(nil, .zero)
        }
    }

    /// First glyph-segment rect of a character range (view coordinates).
    private func segmentRect(_ range: NSRange) -> CGRect? {
        guard let tlm = textLayoutManager, let content = tlm.textContentManager,
              let s = content.location(content.documentRange.location, offsetBy: range.location),
              let e = content.location(s, offsetBy: range.length), let tr = NSTextRange(location: s, end: e) else { return nil }
        var out: CGRect?
        let origin = textContainerOrigin
        tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
            out = frame.offsetBy(dx: origin.x, dy: origin.y)
            return false
        }
        return out
    }

    private func windowContentRect(_ rect: CGRect) -> CGRect {
        guard let content = window?.contentView else { return rect }
        var r = content.convert(rect, from: self)
        if !content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
        return r
    }

    /// The font the cursor overlay and line metrics fall back to.
    var editorFont: NSFont {
        live?.baseFont ?? (styler?.baseAttributes[.font] as? NSFont) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    /// Attributes for freshly inserted text.
    private var insertionAttributes: [NSAttributedString.Key: Any]? { live?.baseAttributes }

    /// Switch Source ⇄ Live (or re-theme Live). Only attributes change;
    /// the characters never do.
    func applyPresentation(_ new: EditorPresentation, theme: ThemeTokens) {
        let themeChanged = live.map { $0.theme != theme } ?? false
        guard new != presentation || themeChanged else { return }
        presentation = new
        guard let storage = textStorage, let tlm = textLayoutManager else { return }
        applyingEngineChange = true
        defer { applyingEngineChange = false }
        switch new {
        case .source:
            live = nil
            liveOverlays?.removeAll()
            liveOverlays = nil
            tlm.delegate = nil
            let styler = self.styler ?? EditorStyler(theme: theme, fontSize: 13)
            storage.beginEditing()
            storage.setAttributes(styler.baseAttributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            styler.highlight(storage, range: NSRange(location: 0, length: storage.length))
            typingAttributes = styler.baseAttributes
        case let .live(options):
            let styler = LivePreviewStyler(theme: theme, options: options)
            styler.containerWidth = max(1, (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 5))
            live = styler
            tlm.delegate = liveDelegate
            let style = MarkdownRenderStyle(theme: theme, scale: options.scale, fontFamily: options.fontFamily, tasksInteractive: true)
            if let overlays = liveOverlays {
                overlays.environment = MarkdownHostedEnvironment(style: style, linkAction: .systemDefault, vaultRoot: options.vaultRoot, embedDepth: 0)
                overlays.removeAll()
            } else {
                let overlays = LiveWidgetOverlays(environment: MarkdownHostedEnvironment(style: style, linkAction: .systemDefault, vaultRoot: options.vaultRoot, embedDepth: 0))
                overlays.textView = self
                overlays.onHeight = { [weak self] payload, height in
                    guard let self, let storage = self.textStorage, let live = self.live else { return }
                    if live.widgetMeasured(payload, height: height, storage: storage) {
                        // Fragments below the grown widget move: lay the
                        // viewport out again before placing overlays.
                        self.textLayoutManager?.textViewportLayoutController.layoutViewport()
                        self.liveOverlays?.setNeedsLayout()
                        self.scheduleCursorUpdate()
                    }
                }
                overlays.onActivate = { [weak self] location in self?.activateWidget(at: location) }
                liveOverlays = overlays
            }
            styler.restyleAll(storage, selection: liveSelection)
            typingAttributes = styler.baseAttributes
        }
        tlm.invalidateLayout(for: tlm.documentRange)
        updateLiveInsets()
        needsDisplay = true
        liveOverlays?.setNeedsLayout()
        scheduleCursorUpdate()
    }

    /// Ranges whose lines show raw syntax: the selection, the vim cursor
    /// and any visual range.
    var liveSelection: [NSRange] {
        var out = [selectedRange()]
        if let c = controller {
            out.append(NSRange(location: c.cursorUTF16Offset, length: 0))
            out += c.visualHighlightRanges
        }
        return out
    }

    /// The cursor / selection may have moved onto or off lines.
    func refreshLive() {
        guard let live, let storage = textStorage else { return }
        let wasApplying = applyingEngineChange
        applyingEngineChange = true
        if live.selectionChanged(storage, selection: liveSelection) {
            liveOverlays?.setNeedsLayout()
        }
        applyingEngineChange = wasApplying
    }

    private func liveTextChanged(_ edits: [TextEdit]) {
        guard let live, let storage = textStorage else { return }
        let wasApplying = applyingEngineChange
        applyingEngineChange = true
        live.textChanged(storage, edits: edits, selection: liveSelection)
        applyingEngineChange = wasApplying
        liveOverlays?.setNeedsLayout()
    }

    /// Reading measure: centre a column of the reader's width.
    private func updateLiveInsets() {
        if case let .live(options) = presentation {
            let width = enclosingScrollView?.contentSize.width ?? bounds.width
            let column = min(width, CGFloat(options.readingWidth) + 2 * 28)
            let inset = NSSize(width: max(28, (width - column) / 2 + 28), height: 28)
            if textContainerInset != inset { textContainerInset = inset }
            live?.containerWidth = max(1, (textContainer?.size.width ?? width) - 2 * (textContainer?.lineFragmentPadding ?? 5))
        } else if textContainerInset != NSSize(width: 12, height: 12) {
            textContainerInset = NSSize(width: 12, height: 12)
        }
    }

    /// A widget was clicked: put the cursor at the start of its source.
    private func activateWidget(at location: Int) {
        guard let controller else { return }
        window?.makeFirstResponder(self)
        controller.userMovedSelection(to: NSRange(location: location, length: 0))
        controller.showEngineSelection(scroll: false)
        if !controller.vimEnabled { showSelection(NSRange(location: location, length: 0), scroll: false) }
    }

    /// Live Preview mouse: a task box toggles (one character, cursor
    /// untouched); ⌘-click follows a link. Returns true when handled.
    private func handleLiveClick(_ event: NSEvent) -> Bool {
        guard live != nil, let storage = textStorage, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let idx = characterIndexForInsertion(at: point)
        guard idx != NSNotFound else { return false }
        let candidates = [idx, idx - 1, idx + 1].filter { $0 >= 0 && $0 < storage.length }
        // Task boxes.
        for c in candidates {
            var run = NSRange()
            guard let marker = storage.attribute(.lumiLiveMarker, at: c, longestEffectiveRange: &run,
                                                 in: NSRange(location: 0, length: storage.length)) as? LiveMarkerBox,
                  case .task = marker.kind,
                  let fragment = tlm.textLayoutFragment(for: local) as? LiveLayoutFragment
            else { continue }
            let fragStart = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
            guard let box = fragment.taskBoxRect(forLocation: run.location, fragmentLocation: fragStart), box.contains(local) else { continue }
            if let controller, controller.isEditable,
               let edit = LivePreview.taskToggle(storage.string as NSString, at: run.location) {
                controller.applyProgrammaticEdit(edit)
            }
            return true
        }
        // ⌘-click links.
        if event.modifierFlags.contains(.command) {
            for c in candidates {
                if let box = storage.attribute(.lumiLiveLink, at: c, effectiveRange: nil) as? LiveLinkBox, box.link != .inert {
                    if case let .external(href) = box.link, let safe = LivePreview.safeHref(href), let url = URL(string: safe) {
                        if let onOpenLink { onOpenLink(.external(safe)) } else { NSWorkspace.shared.open(url) }
                    } else {
                        onOpenLink?(box.link)
                    }
                    return true
                }
            }
        }
        return false
    }

    func attach(_ controller: VimController) {
        self.controller = controller
        controller.surface = self
        if cursorView.superview == nil { addSubview(cursorView) }
        applyingEngineChange = true
        let styler = self.styler ?? EditorStyler(theme: .tokyoNight, fontSize: 13)
        textStorage?.setAttributedString(NSAttributedString(string: controller.buffer.text, attributes: insertionAttributes ?? styler.baseAttributes))
        if let storage = textStorage {
            if let live {
                live.restyleAll(storage, selection: liveSelection)
            } else {
                styler.highlight(storage, range: NSRange(location: 0, length: storage.length))
            }
        }
        applyingEngineChange = false
        controller.showEngineSelection(scroll: false)
    }

    func updateTheme(_ styler: EditorStyler) {
        let fontChanged = self.styler?.fontSize != styler.fontSize
        guard self.styler?.theme != styler.theme || fontChanged else { return }
        self.styler = styler
        // Live Preview re-themes through `applyPresentation`.
        guard live == nil else { return }
        typingAttributes = styler.baseAttributes
        if let storage = textStorage {
            let full = NSRange(location: 0, length: storage.length)
            if fontChanged {
                storage.beginEditing()
                storage.setAttributes(styler.baseAttributes, range: full)
                storage.endEditing()
            }
            styler.highlight(storage, range: full)
        }
    }

    private var wrapsLines = true

    /// Soft wrap on/off (`set wrap`): off lets long lines run and adds a
    /// horizontal scroller.
    func applyWrapping(_ wrap: Bool, in scrollView: NSScrollView) {
        guard wrap != wrapsLines else { return }
        wrapsLines = wrap
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        autoresizingMask = wrap ? [.width] : []
        textContainer?.widthTracksTextView = wrap
        textContainer?.containerSize = NSSize(
            width: wrap ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if wrap { frame.size.width = scrollView.contentSize.width }
    }

    func focusOnce() {
        guard !didAutoFocus else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: EditorTextSurface

    func applyEdits(_ edits: [TextEdit]) {
        guard let storage = textStorage, let styler else { return }
        applyingEngineChange = true
        lastHighlightedRange = EditorStorage.apply(edits, to: storage, styler: styler, highlight: live == nil,
                                                   baseAttributes: insertionAttributes)
        invalidateLineStarts()
        applyingEngineChange = false
        if live != nil { liveTextChanged(edits) }
        if !appliedHighlights.isEmpty || !appliedBlock.isEmpty { reapplyRenderingHighlights() }
    }

    func showSelection(_ range: NSRange, scroll: Bool) {
        let length = (string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - min(range.location, length))))
        settingSelection = true
        setSelectedRange(clamped)
        settingSelection = false
        refreshLive()
        if scroll {
            if let c = controller, clamped.length > 0 {
                scrollRangeToVisible(c.cursorCharacterRange)
            } else {
                scrollRangeToVisible(clamped)
            }
        }
        updateCursor()
    }

    var currentSelection: NSRange { selectedRange() }

    func discardMarkedText() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        dropMarkedText()
    }

    /// Remove the provisional marked text from the view without
    /// committing it. (`NSTextView.unmarkText` would commit it by calling
    /// `insertText` re-entrantly.) The buffer never contained it.
    private func dropMarkedText() {
        guard hasMarkedText() else { return }
        applyingEngineChange = true
        updatingMarkedText = true
        super.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        if hasMarkedText() { super.unmarkText() }
        updatingMarkedText = false
        applyingEngineChange = false
    }

    // MARK: Key routing

    /// The first click into an inactive window places the caret too
    /// (click-to-focus, SPEC-PARTE2 §3: no dead first clicks).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.onUserInteraction?()
        if handleLiveClick(event) { return }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.onUserInteraction?()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        controller?.onUserInteraction?()
        guard let controller, controller.vimEnabled else { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.command) || hasMarkedText() {
            // Shortcuts bubble up; an IME composition owns every key
            // (including Esc, which cancels it).
            super.keyDown(with: event)
            return
        }
        if let input = VimKeyMapper.directInput(for: event) {
            controller.send(input)
            return
        }
        // Printable keys: the input system resolves dead keys / IME and
        // calls insertText / setMarkedText / doCommand.
        interpretKeyEvents([event])
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let controller, controller.vimEnabled else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if hasMarkedText() {
            // Composition committed (dead key, IME): drop the provisional
            // marked text — it never entered the buffer — then type the
            // result through the engine.
            dropMarkedText()
            controller.showEngineSelection(scroll: false)
        } else if replacementRange.location != NSNotFound, replacementRange.length > 0,
                  controller.state.mode == .insert {
            // Press-and-hold accent menu replaces the previous character.
            let edit = TextEdit(location: replacementRange.location, length: replacementRange.length, replacement: text)
            applyEdits([edit])
            controller.applyExternalEdit(edit)
            controller.showEngineSelection(scroll: false)
            return
        }
        controller.insertTyped(text)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let controller, controller.vimEnabled else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        updatingMarkedText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updatingMarkedText = false
    }

    override func unmarkText() {
        guard let controller, controller.vimEnabled, hasMarkedText(), !applyingEngineChange else {
            super.unmarkText()
            return
        }
        // Composition committed without insertText (e.g. focus change):
        // move the composed text from the view into the buffer.
        let composed = (string as NSString).substring(with: markedRange())
        dropMarkedText()
        controller.showEngineSelection(scroll: false)
        controller.insertTyped(composed)
    }

    override func doCommand(by selector: Selector) {
        guard let controller, controller.vimEnabled else {
            super.doCommand(by: selector)
            return
        }
        if let input = VimKeyMapper.input(forCommand: NSStringFromSelector(selector)) {
            controller.send(input)
        }
        // Any other selector is swallowed: native editing commands would
        // change the text behind the engine's back.
    }

    // MARK: Edits AppKit makes itself (paste, cut, drop, dictation, Writing Tools, plain typing)

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if applyingEngineChange || updatingMarkedText { return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) }
        guard let controller, controller.isEditable else { return false }
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if let replacementString, !hasMarkedText() {
            pendingExternalEdit = TextEdit(location: affectedCharRange.location, length: affectedCharRange.length, replacement: replacementString)
        }
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateLineStarts()
        guard let edit = pendingExternalEdit else { return }
        pendingExternalEdit = nil
        controller?.applyExternalEdit(edit)
        if live != nil {
            liveTextChanged([edit])
        } else if let storage = textStorage, let styler,
           let dirty = MarkdownSyntaxHighlighter.dirtyRange(for: [edit], in: storage.string as NSString) {
            styler.highlight(storage, range: dirty)
        }
        controller?.showEngineSelection(scroll: true)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !settingSelection, !applyingEngineChange, !updatingMarkedText, !hasMarkedText(),
              !stillSelecting, let controller,
              let first = ranges.first?.rangeValue
        else { return }
        // A click (or a finished drag) moves the engine cursor; a drag
        // selection stays visible for Cmd-C until the next engine move.
        controller.userMovedSelection(to: first)
        refreshLive()
        updateCursor()
    }

    @objc func undo(_ sender: Any?) { controller?.undo() }
    @objc func redo(_ sender: Any?) { controller?.redo() }

    override func copy(_ sender: Any?) {
        if let text = controller?.visualSelectionText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        super.copy(sender)
    }

    // MARK: Search + block highlights (TextKit 2 rendering attributes — no storage edits)

    private var highlightColor: NSColor = .systemYellow
    private var appliedBlock: [NSRange] = []
    private var blockColor: NSColor = .selectedTextBackgroundColor

    func applySearchHighlights(_ ranges: [NSRange], color: NSColor) {
        applyRenderingHighlights(search: ranges, searchColor: color, block: appliedBlock, blockColor: blockColor)
    }

    func applyRenderingHighlights(search: [NSRange], searchColor: NSColor, block: [NSRange], blockColor: NSColor) {
        guard search != appliedHighlights || searchColor != highlightColor || block != appliedBlock || blockColor != self.blockColor else { return }
        highlightColor = searchColor
        appliedHighlights = search
        appliedBlock = block
        self.blockColor = blockColor
        reapplyRenderingHighlights()
        refreshLive()
    }

    private func reapplyRenderingHighlights() {
        guard let tlm = textLayoutManager, let content = tlm.textContentManager else { return }
        tlm.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        let length = (string as NSString).length
        for (ranges, color) in [(appliedHighlights, highlightColor), (appliedBlock, blockColor)] {
            for r in ranges where NSMaxRange(r) <= length {
                guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                      let end = content.location(start, offsetBy: r.length),
                      let range = NSTextRange(location: start, end: end)
                else { continue }
                tlm.addRenderingAttribute(.backgroundColor, value: color, for: range)
            }
        }
    }

    // MARK: Cursor (mode-shaped overlay)

    /// Frame of the character cell at `range` (UTF-16) in view
    /// coordinates. Empty ranges (line end, empty line, end of text) get
    /// a one-cell-wide frame at the insertion point.
    func cellRect(for range: NSRange) -> NSRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let length = (string as NSString).length
        let loc = min(range.location, length)
        let font = editorFont
        let cellWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 5
        guard let start = tcm.location(tcm.documentRange.location, offsetBy: loc) else { return nil }
        let len = min(range.length, length - loc)
        let end = len > 0 ? tcm.location(start, offsetBy: len) : start
        guard let end, let textRange = NSTextRange(location: start, end: end) else { return nil }
        tlm.ensureLayout(for: textRange)
        var frame: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, f, _, _ in
            frame = frame.map { $0.union(f) } ?? f
            return len > 0
        }
        if var f = frame, f.height > 0 {
            f.origin.x += origin.x
            f.origin.y += origin.y
            if len == 0 || f.width < 1 { f.size.width = cellWidth }
            return f
        }
        // No line fragment (empty text, or the empty line after a final
        // newline): place the cell after the previous character's line.
        if loc > 0, let prev = cellRect(for: NSRange(location: loc - 1, length: 1)) {
            if (string as NSString).character(at: loc - 1) == 10 {
                return NSRect(x: origin.x + padding, y: prev.maxY, width: cellWidth, height: prev.height)
            }
            return NSRect(x: prev.maxX, y: prev.minY, width: cellWidth, height: prev.height)
        }
        return NSRect(x: origin.x + padding, y: origin.y, width: cellWidth, height: lineHeight)
    }

    /// Tests / offscreen renders: pretend the view has keyboard focus.
    var focusOverride: Bool?

    private var isEditorFocused: Bool {
        if let focusOverride { return focusOverride }
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Re-resolve the cursor shape for the current mode and move the
    /// overlay to the cursor's cell.
    func updateCursor() {
        guard let controller, controller.vimEnabled else {
            cursorView.isHidden = true
            stopBlink()
            setSystemCaret(visible: true)
            return
        }
        let style = VimCursorStyle.resolve(
            mode: controller.state.mode,
            pending: controller.state.pending,
            hasMarkedText: hasMarkedText(),
            vimEnabled: true,
            isFocused: isEditorFocused,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            blockCursor: blockCursorPreference
        )
        cursorStyle = style
        setSystemCaret(visible: style.usesSystemCaret)
        guard !style.usesSystemCaret, style.shape != .hidden else {
            cursorView.isHidden = true
            stopBlink()
            return
        }
        let range = controller.cursorCharacterRange
        guard let rect = cellRect(for: range) else {
            cursorView.isHidden = true
            return
        }
        cursorView.shape = style.shape
        cursorView.color = cursorColors.color(for: style.shape, mode: controller.state.mode)
        cursorView.thickness = style.shape == .bar ? 2 : max(2, floor(rect.height / 9))
        if range.length > 0, style.shape == .block || style.shape == .halfBlock {
            let text = (string as NSString).substring(with: range)
            let font = (textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? editorFont
            cursorView.glyph = text == "\t" ? nil : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: cursorColors.inverted])
        } else {
            cursorView.glyph = nil
        }
        if cursorView.frame != rect {
            // Smooth caret (SPEC-PARTE2 §1): a 60 ms glide between nearby
            // cells; jumps, Reduce Motion and offscreen views are instant.
            let old = cursorView.frame
            let near = old.width > 0 && abs(old.midY - rect.midY) < 64 && abs(old.midX - rect.midX) < 260
            if near, window != nil, !cursorView.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.06
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    cursorView.animator().frame = rect
                }
            } else {
                cursorView.frame = rect
            }
        }
        cursorView.isHidden = false
        restartBlink(style.blinks)
    }

    private func setSystemCaret(visible: Bool) {
        let color = visible ? caretColor : NSColor.clear
        if insertionPointColor != color { insertionPointColor = color }
        if #available(macOS 14.0, *) {
            for case let indicator as NSTextInsertionIndicator in subviews {
                indicator.displayMode = visible ? .automatic : .hidden
            }
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Our overlay draws the vim cursor; the system caret only shows
        // for plain editing and IME composition.
        guard controller?.vimEnabled != true || cursorStyle.usesSystemCaret else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    private func restartBlink(_ blinks: Bool) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        cursorView.alphaValue = 1
        guard blinks else { return }
        let timer = Timer(timeInterval: VimCursorStyle.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blinkOn.toggle()
                self.cursorView.alphaValue = self.blinkOn ? 1 : 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorView.alphaValue = 1
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        scheduleCursorUpdate()
        if ok { controller?.onFocus?() }
        return ok
    }

    func focusEditor() {
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        scheduleCursorUpdate()
        return ok
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func clipScrolled() {
        controller?.onViewportScroll?()
        liveOverlays?.setNeedsLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        } else {
            stopBlink()
        }
    }

    @objc private func windowKeyChanged() { updateCursor() }

    private var cursorUpdateScheduled = false

    /// Coalesced, deferred update for layout-time callbacks (never force
    /// TextKit layout from inside a layout pass).
    func scheduleCursorUpdate() {
        guard !cursorUpdateScheduled else { return }
        cursorUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cursorUpdateScheduled = false
            self.updateCursor()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if controller != nil { scheduleCursorUpdate() }
        if live != nil, widthChanged {
            updateLiveInsets()
            liveOverlays?.setNeedsLayout()
        }
    }

    // MARK: Viewport (H M L, page keys, zz, gj gk)

    func visibleRange() -> NSRange? {
        let vr = visibleRect
        guard vr.height > 0 else { return nil }
        let top = characterIndexForInsertion(at: NSPoint(x: vr.minX + 1, y: vr.minY + 1))
        let bottom = characterIndexForInsertion(at: NSPoint(x: vr.minX + 1, y: vr.maxY - 2))
        guard top != NSNotFound, bottom != NSNotFound else { return nil }
        return NSRange(location: min(top, bottom), length: abs(bottom - top))
    }

    func displayLineOffset(from: Int, count: Int) -> Int? {
        guard let rect = cellRect(for: NSRange(location: from, length: 0)) else { return nil }
        let y = rect.midY + CGFloat(count) * rect.height
        guard y >= 0, y <= bounds.maxY else { return nil }
        let idx = characterIndexForInsertion(at: NSPoint(x: rect.minX + 1, y: y))
        return idx == NSNotFound ? nil : idx
    }

    func scrollCursor(to position: VimScrollPosition, cursor: Int) {
        guard let sv = enclosingScrollView, let r = cellRect(for: NSRange(location: cursor, length: 0)) else { return }
        let visible = sv.contentView.bounds
        var y: CGFloat
        switch position {
        case .top: y = r.minY - textContainerOrigin.y
        case .center: y = r.midY - visible.height / 2
        case .bottom: y = r.maxY - visible.height + textContainerOrigin.y
        }
        y = max(0, min(y, max(0, frame.height - visible.height)))
        sv.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func scrollLines(_ lines: Int) {
        guard let sv = enclosingScrollView else { return }
        let font = editorFont
        let lh = ceil(font.ascender - font.descender + font.leading)
        let visible = sv.contentView.bounds
        let y = max(0, min(visible.minY + CGFloat(lines) * lh, max(0, frame.height - visible.height)))
        sv.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // MARK: Split preview scroll sync

    private var lineStartsCache: [Int]?

    /// UTF-16 offset where each source line starts (cached per text).
    private var lineStarts: [Int] {
        if let lineStartsCache { return lineStartsCache }
        var starts = [0]
        let ns = string as NSString
        let n = ns.length
        var i = 0
        var buf = [unichar](repeating: 0, count: 4096)
        while i < n {
            let len = min(4096, n - i)
            ns.getCharacters(&buf, range: NSRange(location: i, length: len))
            for k in 0..<len where buf[k] == 10 { starts.append(i + k + 1) }
            i += len
        }
        lineStartsCache = starts
        return starts
    }

    func invalidateLineStarts() { lineStartsCache = nil }

    func viewportTopLine() -> Double? {
        guard let sv = enclosingScrollView, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let clip = sv.contentView.bounds
        if clip.minY <= 1 { return -1 }
        if clip.maxY >= frame.height - 2 { return .infinity }
        let y = clip.minY - textContainerOrigin.y
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return nil }
        let offset = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
        let starts = lineStarts
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        let f = frag.layoutFragmentFrame
        let frac = f.height > 0 ? min(1, max(0, (y - f.minY) / f.height)) : 0
        return Double(lo) + Double(frac)
    }

    func scrollViewport(toLine line: Double) {
        guard let sv = enclosingScrollView, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return }
        let visible = sv.contentView.bounds
        let maxY = max(0, frame.height - visible.height)
        var y: CGFloat
        if line <= 0 {
            y = 0
        } else if !line.isFinite {
            y = maxY
        } else {
            let starts = lineStarts
            let n = min(starts.count - 1, max(0, Int(line.rounded(.down))))
            let frac = CGFloat(line - Double(n))
            guard let loc = tcm.location(tcm.documentRange.location, offsetBy: starts[n]) else { return }
            if let upTo = NSTextRange(location: tcm.documentRange.location, end: loc) { tlm.ensureLayout(for: upTo) }
            guard let frag = tlm.textLayoutFragment(for: loc) else { return }
            let f = frag.layoutFragmentFrame
            y = f.minY + frac * f.height + textContainerOrigin.y
        }
        y = max(0, min(y, maxY))
        guard abs(visible.minY - y) > 1 else { return }
        sv.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // MARK: Yank highlight

    var yankColor: NSColor = .systemTeal
    var remoteFlashColor: NSColor = .systemBlue
    private var yankFlashView: YankFlashView?
    private var remoteFlashView: YankFlashView?

    func flashRemote(_ ranges: [NSRange]) {
        // Short and soft; nothing under Reduce Motion.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let rects = flashRects(ranges)
        guard !rects.isEmpty else { return }
        remoteFlashView?.removeFromSuperview()
        let view = YankFlashView(frame: bounds, rects: rects, color: remoteFlashColor.withAlphaComponent(0.55))
        addSubview(view, positioned: .below, relativeTo: cursorView)
        remoteFlashView = view
        view.run(reduceMotion: false) { [weak self, weak view] in
            view?.removeFromSuperview()
            if self?.remoteFlashView === view { self?.remoteFlashView = nil }
        }
    }

    private func flashRects(_ ranges: [NSRange]) -> [CGRect] {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return [] }
        let length = (string as NSString).length
        var rects: [CGRect] = []
        let origin = textContainerOrigin
        for r in ranges.prefix(32) where r.length > 0 && NSMaxRange(r) <= length {
            guard let start = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                  let end = tcm.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                if frame.width > 0.5 { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        return rects
    }

    func flashYank(_ ranges: [NSRange]) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return }
        let length = (string as NSString).length
        var rects: [CGRect] = []
        let origin = textContainerOrigin
        for r in ranges where r.length > 0 && NSMaxRange(r) <= length {
            guard let start = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                  let end = tcm.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            tlm.ensureLayout(for: range)
            tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                if frame.width > 0.5 { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        guard !rects.isEmpty else { return }
        yankFlashView?.removeFromSuperview()
        let view = YankFlashView(frame: bounds, rects: rects, color: yankColor)
        addSubview(view, positioned: .below, relativeTo: cursorView)
        yankFlashView = view
        view.run(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self, weak view] in
            view?.removeFromSuperview()
            if self?.yankFlashView === view { self?.yankFlashView = nil }
        }
    }
}

/// Neovim-style yank highlight: the yanked text flashes in the accent
/// tint and fades (220 ms). With Reduce Motion it is a short static
/// tint (150 ms) instead. Non-interactive overlay; never edits text.
final class YankFlashView: NSView {
    static let duration: TimeInterval = 0.22
    static let staticDuration: TimeInterval = 0.15
    let rects: [CGRect]
    let color: NSColor

    init(frame: NSRect, rects: [CGRect], color: NSColor) {
        self.rects = rects
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not coded") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.42).setFill()
        for r in rects where r.intersects(dirtyRect) {
            NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
        }
    }

    func run(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        if reduceMotion {
            alphaValue = 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.staticDuration) { MainActor.assumeIsolated { completion() } }
            return
        }
        alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }
}

#elseif canImport(UIKit)

/// iOS / iPadOS / visionOS bridge: a TextKit 2 `UITextView` driven by
/// `VimController`. Soft-keyboard and hardware text arrive through
/// `UITextInput` (`insertText`, marked text), and `updateUIView` never
/// writes the text — so keyboard edits can't be overwritten.
struct VimTextViewBridge: UIViewRepresentable {
    let controller: VimController
    let mode: VimMode
    let highlights: [NSRange]
    let theme: ThemeTokens
    let showLineNumbers: Bool
    let relativeLineNumbers: Bool
    var fontSize: CGFloat = 16
    var lineWrapping: Bool = true
    var blockRanges: [NSRange] = []
    var blockCursor: Bool = true
    var presentation: EditorPresentation = .source
    var onOpenLink: ((LiveLink) -> Void)?
    var onHoverLink: ((LiveLink?, CGRect) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var view: VimUIKitTextView?

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            view?.shouldAccept(range: range, replacement: text) ?? true
        }

        func textViewDidChange(_ textView: UITextView) {
            view?.commitExternalEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            view?.userChangedSelection()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            view?.controller?.onViewportScroll?()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            view?.controller?.onUserInteraction?()
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = VimUIKitTextView(usingTextLayoutManager: true)
        textView.styler = EditorStyler(theme: theme, fontSize: fontSize)
        textView.delegate = context.coordinator
        context.coordinator.view = textView
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocapitalizationType = .none
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let bar = VimAccessoryBar()
        bar.onTap = { [weak textView] action in textView?.handleAccessory(action) }
        textView.accessoryBar = bar
        let cmdBar = VimCommandLineAccessoryBar()
        cmdBar.onTap = { [weak textView] action in textView?.handleCommandLineAccessory(action) }
        textView.commandLineBar = cmdBar
        #if !os(visionOS)
        textView.inputAccessoryView = bar
        #endif
        textView.attach(controller)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let view = textView as? VimUIKitTextView else { return }
        view.updateTheme(EditorStyler(theme: theme, fontSize: fontSize))
        // One selection accent app-wide (explorer row, reader, editor).
        view.tintColor = UIColor(theme.accent)
        view.cursorColors = VimCursorColors(
            normal: UIColor(theme.accent), insert: UIColor(theme.primary),
            replace: UIColor(theme.warning), inverted: UIColor(theme.background)
        )
        view.blockCursorPreference = blockCursor
        view.applyAccessoryTheme(theme)
        view.isEditable = controller.isEditable
        view.yankColor = UIColor(theme.accent)
        view.applyRenderingHighlights(
            search: highlights, searchColor: UIColor(theme.warning).withAlphaComponent(0.35),
            block: blockRanges, blockColor: UIColor(theme.editorSelection)
        )
        view.updateCursor()

        if case let .commandLine(prefix, buffer) = mode {
            view.commandLineBar?.prefix = prefix
            view.commandLineBar?.buffer = buffer
            #if !os(visionOS)
            if view.inputAccessoryView !== view.commandLineBar {
                view.inputAccessoryView = view.commandLineBar
                view.reloadInputViews()
            }
            #endif
        } else {
            #if !os(visionOS)
            if view.inputAccessoryView !== view.accessoryBar {
                view.inputAccessoryView = view.accessoryBar
                view.reloadInputViews()
            }
            #endif
        }
    }
}

final class VimUIKitTextView: UITextView, EditorTextSurface {
    private(set) weak var controller: VimController?
    var styler: EditorStyler?
    let cursorView = VimCursorView()
    var cursorColors = VimCursorColors(normal: .systemBlue, insert: .systemBlue, replace: .systemOrange, inverted: .systemBackground)
    var blockCursorPreference = true
    private(set) var cursorStyle = VimCursorStyle(shape: .block, blinks: false)
    private var blinkTimer: Timer?
    private var blinkOn = true
    var accessoryBar: VimAccessoryBar?
    var commandLineBar: VimCommandLineAccessoryBar?
    private var applyingEngineChange = false
    private var settingSelection = false
    private var pendingExternalEdit: TextEdit?
    private var appliedHighlights: [NSRange] = []
    private var highlightColor: UIColor = .systemYellow
    private(set) var lastHighlightedRange: NSRange?

    func attach(_ controller: VimController) {
        self.controller = controller
        controller.surface = self
        if cursorView.superview == nil { addSubview(cursorView) }
        let styler = self.styler ?? EditorStyler(theme: .tokyoNight, fontSize: 16)
        applyingEngineChange = true
        textStorage.setAttributedString(NSAttributedString(string: controller.buffer.text, attributes: styler.baseAttributes))
        styler.highlight(textStorage, range: NSRange(location: 0, length: textStorage.length))
        applyingEngineChange = false
        typingAttributes = styler.baseAttributes
        controller.showEngineSelection(scroll: false)
    }

    func updateTheme(_ styler: EditorStyler) {
        let fontChanged = self.styler?.fontSize != styler.fontSize
        guard self.styler?.theme != styler.theme || fontChanged else { return }
        self.styler = styler
        typingAttributes = styler.baseAttributes
        let full = NSRange(location: 0, length: textStorage.length)
        if fontChanged { textStorage.setAttributes(styler.baseAttributes, range: full) }
        styler.highlight(textStorage, range: full)
    }

    func applyAccessoryTheme(_ theme: ThemeTokens) {
        accessoryBar?.apply(theme: theme)
        commandLineBar?.apply(theme: theme)
    }

    // MARK: EditorTextSurface

    func applyEdits(_ edits: [TextEdit]) {
        guard let styler else { return }
        applyingEngineChange = true
        inputDelegate?.textWillChange(self)
        lastHighlightedRange = EditorStorage.apply(edits, to: textStorage, styler: styler)
        inputDelegate?.textDidChange(self)
        applyingEngineChange = false
        if !appliedHighlights.isEmpty || !appliedBlock.isEmpty { reapplyRenderingHighlights() }
    }

    func showSelection(_ range: NSRange, scroll: Bool) {
        let length = textStorage.length
        let loc = min(range.location, length)
        let clamped = NSRange(location: loc, length: min(range.length, length - loc))
        if selectedRange != clamped {
            settingSelection = true
            selectedRange = clamped
            settingSelection = false
            if scroll { scrollRangeToVisible(controller?.cursorCharacterRange ?? clamped) }
        }
        updateCursor()
    }

    var currentSelection: NSRange { selectedRange }

    /// Remove the provisional marked text without committing it (the
    /// buffer never contained it).
    func discardMarkedText() {
        guard markedTextRange != nil else { return }
        applyingEngineChange = true
        super.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        super.unmarkText()
        applyingEngineChange = false
    }

    // MARK: Text input (soft keyboard, hardware text, dead keys, IME)

    override func insertText(_ text: String) {
        guard let controller, controller.vimEnabled else { super.insertText(text); return }
        guard controller.isEditable else { return }
        if markedTextRange != nil { discardMarkedText() }
        controller.insertTyped(text)
    }

    override func deleteBackward() {
        guard let controller, controller.vimEnabled else { super.deleteBackward(); return }
        if markedTextRange != nil { super.deleteBackward(); return }
        controller.send(.backspace)
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        applyingEngineChange = controller?.vimEnabled == true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        applyingEngineChange = false
    }

    override func unmarkText() {
        guard let controller, controller.vimEnabled, let marked = markedTextRange, !applyingEngineChange else {
            super.unmarkText()
            return
        }
        // Commit of a composition: the composed text is in the view but
        // not in the buffer — move it through the engine.
        let composed = text(in: marked) ?? ""
        discardMarkedText()
        controller.insertTyped(composed)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let controller, controller.vimEnabled, markedTextRange == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command) else { continue }
            if let input = VimKeyMapper.directInput(for: key) {
                controller.send(input)
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Edits UIKit makes itself (paste, autocorrect, dictation, plain typing)

    func shouldAccept(range: NSRange, replacement: String) -> Bool {
        if applyingEngineChange { return true }
        guard let controller, controller.isEditable else { return false }
        if markedTextRange == nil {
            pendingExternalEdit = TextEdit(location: range.location, length: range.length, replacement: replacement)
        }
        return true
    }

    func commitExternalEdit() {
        guard let edit = pendingExternalEdit else { return }
        pendingExternalEdit = nil
        controller?.applyExternalEdit(edit)
        if let styler, let dirty = MarkdownSyntaxHighlighter.dirtyRange(for: [edit], in: textStorage.string as NSString) {
            styler.highlight(textStorage, range: dirty)
        }
        controller?.showEngineSelection(scroll: true)
    }

    func userChangedSelection() {
        guard !settingSelection, !applyingEngineChange, markedTextRange == nil, let controller else { return }
        controller.userMovedSelection(to: selectedRange)
        updateCursor()
    }

    // MARK: Accessory bars

    fileprivate func handleAccessory(_ action: VimAccessoryAction) {
        guard let controller else { return }
        switch action {
        case .escape: controller.send(.escape)
        case .colon: controller.send(.character(":"))
        case .slash: controller.send(.character("/"))
        case .semicolon: controller.send(.character(";"))
        case .comma: controller.send(.character(","))
        }
    }

    fileprivate func handleCommandLineAccessory(_ action: VimCommandLineAccessoryAction) {
        guard let controller else { return }
        switch action {
        case .cancel: controller.send(.escape)
        case .done: controller.send(.return)
        }
    }

    // MARK: Search + block highlights (TextKit 2 rendering attributes)

    private var appliedBlock: [NSRange] = []
    private var blockColor: UIColor = .systemBlue

    func applySearchHighlights(_ ranges: [NSRange], color: UIColor) {
        applyRenderingHighlights(search: ranges, searchColor: color, block: appliedBlock, blockColor: blockColor)
    }

    func applyRenderingHighlights(search: [NSRange], searchColor: UIColor, block: [NSRange], blockColor: UIColor) {
        guard search != appliedHighlights || searchColor != highlightColor || block != appliedBlock || blockColor != self.blockColor else { return }
        highlightColor = searchColor
        appliedHighlights = search
        appliedBlock = block
        self.blockColor = blockColor
        reapplyRenderingHighlights()
    }

    private func reapplyRenderingHighlights() {
        guard let tlm = textLayoutManager, let content = tlm.textContentManager else { return }
        tlm.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        for (ranges, color) in [(appliedHighlights, highlightColor), (appliedBlock, blockColor)] {
            for r in ranges where NSMaxRange(r) <= textStorage.length {
                guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                      let end = content.location(start, offsetBy: r.length),
                      let range = NSTextRange(location: start, end: end)
                else { continue }
                tlm.addRenderingAttribute(.backgroundColor, value: color, for: range)
            }
        }
    }

    // MARK: Cursor (mode-shaped overlay; the system caret hides)

    func cellRect(for range: NSRange) -> CGRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let length = textStorage.length
        let loc = min(range.location, length)
        let font = (styler?.baseAttributes[.font] as? UIFont) ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
        let cellWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        let padding = textContainer.lineFragmentPadding
        guard let start = tcm.location(tcm.documentRange.location, offsetBy: loc) else { return nil }
        let len = min(range.length, length - loc)
        let end = len > 0 ? tcm.location(start, offsetBy: len) : start
        guard let end, let textRange = NSTextRange(location: start, end: end) else { return nil }
        tlm.ensureLayout(for: textRange)
        var frame: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, f, _, _ in
            frame = frame.map { $0.union(f) } ?? f
            return len > 0
        }
        if var f = frame, f.height > 0 {
            f.origin.x += origin.x
            f.origin.y += origin.y
            if len == 0 || f.width < 1 { f.size.width = cellWidth }
            return f
        }
        if loc > 0, let prev = cellRect(for: NSRange(location: loc - 1, length: 1)) {
            if (textStorage.string as NSString).character(at: loc - 1) == 10 {
                return CGRect(x: origin.x + padding, y: prev.maxY, width: cellWidth, height: prev.height)
            }
            return CGRect(x: prev.maxX, y: prev.minY, width: cellWidth, height: prev.height)
        }
        return CGRect(x: origin.x + padding, y: origin.y, width: cellWidth, height: font.lineHeight)
    }

    func updateCursor() {
        guard let controller, controller.vimEnabled else {
            cursorView.isHidden = true
            stopBlink()
            return
        }
        let style = VimCursorStyle.resolve(
            mode: controller.state.mode,
            pending: controller.state.pending,
            hasMarkedText: markedTextRange != nil,
            vimEnabled: true,
            isFocused: isFirstResponder,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            blockCursor: blockCursorPreference
        )
        let systemChanged = style.usesSystemCaret != cursorStyle.usesSystemCaret
        cursorStyle = style
        if systemChanged { setNeedsLayout() }
        guard !style.usesSystemCaret, style.shape != .hidden, let rect = cellRect(for: controller.cursorCharacterRange) else {
            cursorView.isHidden = true
            stopBlink()
            return
        }
        let range = controller.cursorCharacterRange
        cursorView.shape = style.shape
        cursorView.color = cursorColors.color(for: style.shape, mode: controller.state.mode)
        cursorView.thickness = style.shape == .bar ? 2 : max(2, floor(rect.height / 9))
        if range.length > 0, style.shape == .block || style.shape == .halfBlock {
            let text = (textStorage.string as NSString).substring(with: range)
            let font = (textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
                ?? (styler?.baseAttributes[.font] as? UIFont) ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
            cursorView.glyph = text == "\t" ? nil : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: cursorColors.inverted])
        } else {
            cursorView.glyph = nil
        }
        if cursorView.frame != rect { cursorView.frame = rect }
        cursorView.isHidden = false
        bringSubviewToFront(cursorView)
        restartBlink(style.blinks)
    }

    /// Hide the system caret while our overlay draws the cursor.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let base = super.caretRect(for: position)
        guard controller?.vimEnabled == true, !cursorStyle.usesSystemCaret else { return base }
        return CGRect(x: base.minX, y: base.minY, width: 0, height: 0)
    }

    private func restartBlink(_ blinks: Bool) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        cursorView.alpha = 1
        guard blinks else { return }
        let timer = Timer(timeInterval: VimCursorStyle.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blinkOn.toggle()
                self.cursorView.alpha = self.blinkOn ? 1 : 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorView.alpha = 1
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateCursor()
        if ok { controller?.onFocus?() }
        return ok
    }

    func focusEditor() {
        _ = becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateCursor()
        return ok
    }

    private var lastLayoutWidth: CGFloat = 0
    private var cursorUpdateScheduled = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-place the cursor when the width (wrapping) changes — deferred,
        // so TextKit layout is never forced from inside a layout pass.
        guard controller != nil, bounds.width != lastLayoutWidth, !cursorUpdateScheduled else { return }
        lastLayoutWidth = bounds.width
        cursorUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.cursorUpdateScheduled = false
            self?.updateCursor()
        }
    }

    // MARK: Viewport

    func visibleRange() -> NSRange? {
        let top = closestPosition(to: CGPoint(x: textContainerInset.left + 1, y: contentOffset.y + 1))
        let bottom = closestPosition(to: CGPoint(x: textContainerInset.left + 1, y: contentOffset.y + bounds.height - 2))
        guard let top, let bottom else { return nil }
        let a = offset(from: beginningOfDocument, to: top), b = offset(from: beginningOfDocument, to: bottom)
        return NSRange(location: min(a, b), length: abs(b - a))
    }

    func displayLineOffset(from: Int, count: Int) -> Int? {
        guard let rect = cellRect(for: NSRange(location: from, length: 0)) else { return nil }
        let y = rect.midY + CGFloat(count) * rect.height
        guard y >= 0, y <= contentSize.height else { return nil }
        guard let pos = closestPosition(to: CGPoint(x: rect.minX + 1, y: y)) else { return nil }
        return offset(from: beginningOfDocument, to: pos)
    }

    func scrollCursor(to position: VimScrollPosition, cursor: Int) {
        guard let r = cellRect(for: NSRange(location: cursor, length: 0)) else { return }
        let h = bounds.height
        var y: CGFloat
        switch position {
        case .top: y = r.minY - textContainerInset.top
        case .center: y = r.midY - h / 2
        case .bottom: y = r.maxY - h + textContainerInset.bottom
        }
        y = max(-adjustedContentInset.top, min(y, max(0, contentSize.height - h)))
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
    }

    func scrollLines(_ lines: Int) {
        let font = (styler?.baseAttributes[.font] as? UIFont) ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
        let h = bounds.height
        let y = max(-adjustedContentInset.top, min(contentOffset.y + CGFloat(lines) * font.lineHeight, max(0, contentSize.height - h)))
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
    }

    override func copy(_ sender: Any?) {
        if let text = controller?.visualSelectionText {
            UIPasteboard.general.string = text
            return
        }
        super.copy(sender)
    }

    // MARK: Split preview scroll sync

    func viewportTopLine() -> Double? {
        let maxY = max(0, contentSize.height - bounds.height)
        if contentOffset.y <= 1 { return -1 }
        if contentOffset.y >= maxY - 2 { return .infinity }
        guard let pos = closestPosition(to: CGPoint(x: textContainerInset.left + 1, y: contentOffset.y + 1)) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: pos)
        let ns = text as NSString
        var line = 0
        var i = 0
        while i < min(offset, ns.length) {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: min(offset, ns.length) - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }
        return Double(line)
    }

    func scrollViewport(toLine line: Double) {
        let maxY = max(0, contentSize.height - bounds.height)
        var y: CGFloat
        if line <= 0 { y = 0 } else if !line.isFinite { y = maxY } else {
            let ns = text as NSString
            var start = 0
            var n = Int(line.rounded(.down))
            while n > 0 {
                let r = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
                if r.location == NSNotFound { break }
                start = r.location + 1
                n -= 1
            }
            guard let rect = cellRect(for: NSRange(location: start, length: 0)) else { return }
            y = rect.minY + CGFloat(line - line.rounded(.down)) * rect.height - textContainerInset.top
        }
        y = max(0, min(y, maxY))
        guard abs(contentOffset.y - y) > 1 else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
    }

    // MARK: Yank highlight

    var yankColor: UIColor = .systemTeal
    private var yankFlashView: UIView?

    func flashYank(_ ranges: [NSRange]) {
        var rects: [CGRect] = []
        let length = (text as NSString).length
        for r in ranges where r.length > 0 && NSMaxRange(r) <= length {
            guard let start = position(from: beginningOfDocument, offset: r.location),
                  let end = position(from: start, offset: r.length),
                  let range = textRange(from: start, to: end) else { continue }
            for sel in selectionRects(for: range) where sel.rect.width > 0.5 { rects.append(sel.rect) }
        }
        guard !rects.isEmpty else { return }
        yankFlashView?.removeFromSuperview()
        let overlay = UIView(frame: CGRect(origin: .zero, size: contentSize))
        overlay.isUserInteractionEnabled = false
        for r in rects {
            let v = UIView(frame: r.insetBy(dx: -1, dy: 0))
            v.backgroundColor = yankColor.withAlphaComponent(0.42)
            v.layer.cornerRadius = 2
            overlay.addSubview(v)
        }
        addSubview(overlay)
        yankFlashView = overlay
        let done: (Bool) -> Void = { [weak self, weak overlay] _ in
            overlay?.removeFromSuperview()
            if self?.yankFlashView === overlay { self?.yankFlashView = nil }
        }
        if UIAccessibility.isReduceMotionEnabled {
            overlay.alpha = 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done(true) }
        } else {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut], animations: { overlay.alpha = 0 }, completion: done)
        }
    }
}

#endif
