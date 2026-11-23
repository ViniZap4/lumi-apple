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
    static func apply(_ edits: [TextEdit], to storage: NSTextStorage, styler: EditorStyler) -> NSRange? {
        storage.beginEditing()
        for e in edits {
            guard e.location + e.length <= storage.length else { continue }
            storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.replacement, attributes: styler.baseAttributes))
        }
        storage.endEditing()
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
        let isInsert = mode == .insert || !controller.vimEnabled
        textView.updateTheme(EditorStyler(theme: theme, fontSize: fontSize))
        textView.applyWrapping(lineWrapping, in: scrollView)
        textView.insertionPointColor = isInsert ? NSColor(theme.primary) : NSColor(theme.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: isInsert
                ? NSColor(theme.primary).withAlphaComponent(0.30)
                : NSColor(theme.accent).withAlphaComponent(0.55),
            .foregroundColor: isInsert ? NSColor(theme.text) : NSColor(theme.background)
        ]
        textView.isEditable = controller.isEditable
        textView.applySearchHighlights(highlights, color: NSColor(theme.warning).withAlphaComponent(0.35))

        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.theme = theme
            ruler.showRelative = relativeLineNumbers
            if scrollView.rulersVisible != showLineNumbers {
                scrollView.rulersVisible = showLineNumbers
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
    /// True while the controller writes into the storage.
    private var applyingEngineChange = false
    private var updatingMarkedText = false
    private var settingSelection = false
    private var pendingExternalEdit: TextEdit?
    private var appliedHighlights: [NSRange] = []
    private var didAutoFocus = false
    /// Last range re-highlighted after an edit (tests).
    private(set) var lastHighlightedRange: NSRange?

    func attach(_ controller: VimController) {
        self.controller = controller
        controller.surface = self
        applyingEngineChange = true
        let styler = self.styler ?? EditorStyler(theme: .tokyoNight, fontSize: 13)
        textStorage?.setAttributedString(NSAttributedString(string: controller.buffer.text, attributes: styler.baseAttributes))
        if let storage = textStorage {
            styler.highlight(storage, range: NSRange(location: 0, length: storage.length))
        }
        applyingEngineChange = false
        controller.showEngineSelection(scroll: false)
    }

    func updateTheme(_ styler: EditorStyler) {
        let fontChanged = self.styler?.fontSize != styler.fontSize
        guard self.styler?.theme != styler.theme || fontChanged else { return }
        self.styler = styler
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
        lastHighlightedRange = EditorStorage.apply(edits, to: storage, styler: styler)
        applyingEngineChange = false
        if !appliedHighlights.isEmpty { reapplySearchHighlights() }
    }

    func showSelection(_ range: NSRange, scroll: Bool) {
        let length = (string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - min(range.location, length))))
        settingSelection = true
        setSelectedRange(clamped)
        settingSelection = false
        if scroll { scrollRangeToVisible(clamped) }
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

    override func keyDown(with event: NSEvent) {
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
        guard let edit = pendingExternalEdit else { return }
        pendingExternalEdit = nil
        controller?.applyExternalEdit(edit)
        if let storage = textStorage, let styler,
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
    }

    @objc func undo(_ sender: Any?) { controller?.undo() }
    @objc func redo(_ sender: Any?) { controller?.redo() }

    // MARK: Search highlights (TextKit 2 rendering attributes — no storage edits)

    private var highlightColor: NSColor = .systemYellow

    func applySearchHighlights(_ ranges: [NSRange], color: NSColor) {
        guard ranges != appliedHighlights || color != highlightColor else { return }
        highlightColor = color
        appliedHighlights = ranges
        reapplySearchHighlights()
    }

    private func reapplySearchHighlights() {
        guard let tlm = textLayoutManager, let content = tlm.textContentManager else { return }
        tlm.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        let length = (string as NSString).length
        for r in appliedHighlights where NSMaxRange(r) <= length {
            guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                  let end = content.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end)
            else { continue }
            tlm.addRenderingAttribute(.backgroundColor, value: highlightColor, for: range)
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
        let isInsert = mode == .insert || !controller.vimEnabled
        view.updateTheme(EditorStyler(theme: theme, fontSize: fontSize))
        view.tintColor = UIColor(isInsert ? theme.primary : theme.accent)
        view.applyAccessoryTheme(theme)
        view.isEditable = controller.isEditable
        view.applySearchHighlights(highlights, color: UIColor(theme.warning).withAlphaComponent(0.35))

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
        if !appliedHighlights.isEmpty { reapplySearchHighlights() }
    }

    func showSelection(_ range: NSRange, scroll: Bool) {
        let length = textStorage.length
        let loc = min(range.location, length)
        let clamped = NSRange(location: loc, length: min(range.length, length - loc))
        guard selectedRange != clamped else { return }
        settingSelection = true
        selectedRange = clamped
        settingSelection = false
        if scroll { scrollRangeToVisible(clamped) }
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

    // MARK: Search highlights (TextKit 2 rendering attributes)

    func applySearchHighlights(_ ranges: [NSRange], color: UIColor) {
        guard ranges != appliedHighlights || color != highlightColor else { return }
        highlightColor = color
        appliedHighlights = ranges
        reapplySearchHighlights()
    }

    private func reapplySearchHighlights() {
        guard let tlm = textLayoutManager, let content = tlm.textContentManager else { return }
        tlm.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        for r in appliedHighlights where NSMaxRange(r) <= textStorage.length {
            guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                  let end = content.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end)
            else { continue }
            tlm.addRenderingAttribute(.backgroundColor, value: highlightColor, for: range)
        }
    }
}

#endif
