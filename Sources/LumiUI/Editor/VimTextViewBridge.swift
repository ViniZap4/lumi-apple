import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit

/// macOS bridge: hosts a custom `NSTextView` inside an `NSScrollView`. Every
/// keyDown is intercepted and dispatched through the vim engine; the text view
/// is therefore driven entirely by the engine, never by AppKit's own text
/// input pipeline.
struct VimTextViewBridge: NSViewRepresentable {
    let text: String
    let selection: NSRange
    let isInsertMode: Bool
    let highlights: [NSRange]
    let controller: VimController
    let theme: ThemeTokens
    let showLineNumbers: Bool
    let relativeLineNumbers: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Selection the bridge last applied to AppKit. Lets us tell
        /// "vim moved the cursor" from "the user dragged a mouse
        /// selection" — we only re-apply when the engine's intended
        /// selection actually changed, so manual drag-to-copy persists
        /// long enough for Cmd-C to run against it.
        var lastAppliedSelection: NSRange?
        /// One-shot flag: the very first time the text view ends up in
        /// a window we grab first responder so the user can start
        /// typing without an extra click. Subsequent updates leave
        /// responder alone (otherwise toolbar interactions would steal
        /// and restore focus on every render).
        var didAutoFocus: Bool = false
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = VimAppKitTextView()
        textView.controller = controller
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        if #available(macOS 15.2, *) {
            // Writing Tools (Apple Intelligence) — the user can invoke
            // proofread / rewrite / summarize via the Edit menu or the
            // contextual menu on selected text. Vim's intercepted keys
            // are unaffected because Writing Tools surfaces through
            // menus, not keystrokes.
            textView.writingToolsBehavior = .default
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        // Attach the line-number gutter eagerly. It hides itself
        // (rulersVisible = false) when the preference is off; keeping
        // one instance around avoids tearing down rulers on every
        // toggle.
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimAppKitTextView else { return }
        textView.textColor = NSColor(theme.text)
        // Caret always visible — earlier version hid it in normal mode and
        // relied on the 1-char selection block, which left the cursor
        // invisible at end-of-line / empty-buffer positions where the
        // block can't render. Now the caret stays as a fallback; the
        // tinted selection background still gives the block-cursor look
        // when there's a character under the cursor.
        textView.insertionPointColor = isInsertMode
            ? NSColor(theme.primary)
            : NSColor(theme.accent)
        // Selection highlight — same vibrant accent across modes so
        // user-driven drag selections (for Cmd-C copy) are clearly
        // visible. Foreground is anchored on theme.background to keep
        // contrast high on busy themes where text + accent would blur.
        textView.selectedTextAttributes = [
            .backgroundColor: isInsertMode
                ? NSColor(theme.primary).withAlphaComponent(0.30)
                : NSColor(theme.accent).withAlphaComponent(0.55),
            .foregroundColor: isInsertMode
                ? NSColor(theme.text)
                : NSColor(theme.background)
        ]

        if textView.string != text {
            textView.string = text
        }
        // Re-apply syntax highlighting on EVERY update, not just on text
        // change. Previously it was gated, which meant mode toggles /
        // selection changes / hlsearch decoration could clobber the
        // syntax foreground colors and we'd never restore them.
        applySyntaxHighlighting(to: textView.textStorage, text: text)
        applyHighlights(to: textView.textStorage, color: NSColor(theme.warning).withAlphaComponent(0.35))

        // Line-number gutter — toggled with the preference. When relative
        // numbering flips, the ruler re-draws via its `didSet`.
        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.theme = theme
            ruler.showRelative = relativeLineNumbers
            if scrollView.rulersVisible != showLineNumbers {
                scrollView.rulersVisible = showLineNumbers
            }
            ruler.needsDisplay = true
        }
        // Only force the selection when the engine actually moved — a
        // user mouse-drag updates `textView.selectedRange()` directly
        // and we don't want SwiftUI's next `updateNSView` to immediately
        // collapse that back onto the engine's cursor.
        let coord = context.coordinator
        if coord.lastAppliedSelection != selection {
            textView.setSelectedRange(selection)
            // Keep the cursor on-screen — without this the user can navigate
            // (j/k, gg/G, /search) and the cursor walks past the visible
            // region with the viewport stuck where it was.
            textView.scrollRangeToVisible(selection)
            coord.lastAppliedSelection = selection
        }

        // Grab first responder on initial display so the user can
        // start typing immediately after switching to edit mode. We
        // defer to the next runloop turn so the window is in place;
        // makeNSView fires before the view is mounted in a window.
        if !coord.didAutoFocus {
            coord.didAutoFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    /// Cheap, line-by-line markdown highlighting. Avoids running the full
    /// MarkdownParser on every keystroke; instead it scans regex-friendly
    /// patterns (heading prefix, fenced/inline code, bold/italic, link
    /// brackets) and applies foreground colors via the text storage's
    /// attribute system. Heavy parsing happens only in the read pane.
    private func applySyntaxHighlighting(to storage: NSTextStorage?, text: String) {
        guard let storage else { return }
        let ns = storage.mutableString
        let fullRange = NSRange(location: 0, length: ns.length)
        // Start from base text color — clears any stale highlights from a
        // previous edit. (Background hlsearch decoration runs afterwards.)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor(theme.text), range: fullRange)

        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        storage.addAttribute(.font, value: baseFont, range: fullRange)

        for (pattern, color, fontWeight) in Self.markdownPatterns(theme: theme) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let r = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: r)
                if let weight = fontWeight {
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: weight), range: r)
                }
            }
        }
        storage.endEditing()
    }

    private static func markdownPatterns(theme: ThemeTokens) -> [(String, NSColor, NSFont.Weight?)] {
        let primary = NSColor(theme.primary)
        let accent = NSColor(theme.accent)
        let dim = NSColor(theme.textDim)
        let warning = NSColor(theme.warning)
        return [
            // Heading lines: `^#+ heading text` → accent, bold.
            ("^#{1,6} .*$", accent, .semibold),
            // Bold via **text**.
            ("\\*\\*[^*\\n]+\\*\\*", primary, .bold),
            // Inline code via `code`.
            ("`[^`\\n]+`", warning, nil),
            // Fenced code block delimiters.
            ("^```.*$", dim, nil),
            // Block-quote markers and lines.
            ("^>\\s.*$", dim, nil),
            // Markdown link `[text](url)`.
            ("\\[[^\\]]+\\]\\([^)]+\\)", primary, nil),
            // List bullets at line start.
            ("^\\s*[-*+]\\s", dim, nil),
            // Frontmatter delimiters.
            ("^---$", dim, nil),
        ]
    }

    private func applyHighlights(to storage: NSTextStorage?, color: NSColor) {
        guard let storage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        for highlight in highlights where NSMaxRange(highlight) <= storage.length {
            storage.addAttribute(.backgroundColor, value: color, range: highlight)
        }
    }
}

final class VimAppKitTextView: NSTextView {
    weak var controller: VimController?

    override func keyDown(with event: NSEvent) {
        guard let controller else { super.keyDown(with: event); return }

        // Let Cmd-modified shortcuts (Cmd+S save, Cmd+W close, …) bubble up.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if let input = VimKeyMapper.map(event: event, mode: controller.state.mode) {
            Task { @MainActor in controller.send(input) }
            return
        }
        super.keyDown(with: event)
    }
}

#elseif canImport(UIKit)
import UIKit

/// iOS / iPadOS / visionOS bridge.
struct VimTextViewBridge: UIViewRepresentable {
    let text: String
    let selection: NSRange
    let isInsertMode: Bool
    let highlights: [NSRange]
    let controller: VimController
    let theme: ThemeTokens
    // Accepted on iOS for API parity with macOS; line-number gutter is
    // mac-only for now since UIKit's UITextView has no equivalent ruler.
    let showLineNumbers: Bool
    let relativeLineNumbers: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = VimUIKitTextView()
        textView.controller = controller
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // Soft-keyboard accessory bar (ESC, :, /, ;, ,). Hardware keyboards
        // surface the same bar as the iPadOS shortcut bar at the screen edge.
        let bar = VimAccessoryBar()
        bar.onTap = { [weak textView] action in
            textView?.handleAccessory(action)
        }
        textView.accessoryBar = bar

        // Alternate bar shown while in command-line mode: prefix + buffer
        // mirror plus Cancel/Done.
        let cmdBar = VimCommandLineAccessoryBar()
        cmdBar.onTap = { [weak textView] action in
            textView?.handleCommandLineAccessory(action)
        }
        textView.commandLineBar = cmdBar

        textView.inputAccessoryView = bar
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let view = textView as? VimUIKitTextView else { return }
        view.textColor = UIColor(theme.text)
        // tintColor drives both the insertion caret AND the selection
        // background on UITextView, so normal-mode block cursor (1-char
        // selection from VimController.selectionUTF16Range) appears in
        // accent; insert-mode caret in primary.
        view.tintColor = UIColor(isInsertMode ? theme.primary : theme.accent)
        view.applyAccessoryTheme(theme)

        if view.text != text {
            view.text = text
        }
        // Re-apply syntax highlighting on every update (see macOS comment).
        applySyntaxHighlightingIOS(to: view.textStorage, text: text)
        applyHighlights(to: view.textStorage, color: UIColor(theme.warning).withAlphaComponent(0.35))
        if view.selectedRange != selection {
            view.selectedRange = selection
            view.scrollRangeToVisible(selection)
        }

        // Swap accessory views based on the engine mode.
        if case let .commandLine(prefix, buffer) = controller.state.mode {
            view.commandLineBar?.prefix = prefix
            view.commandLineBar?.buffer = buffer
            if view.inputAccessoryView !== view.commandLineBar {
                view.inputAccessoryView = view.commandLineBar
                view.reloadInputViews()
            }
        } else {
            if view.inputAccessoryView !== view.accessoryBar {
                view.inputAccessoryView = view.accessoryBar
                view.reloadInputViews()
            }
        }
    }
}

final class VimUIKitTextView: UITextView {
    weak var controller: VimController?
    var accessoryBar: VimAccessoryBar?
    var commandLineBar: VimCommandLineAccessoryBar?

    func applyAccessoryTheme(_ theme: ThemeTokens) {
        accessoryBar?.apply(theme: theme)
        commandLineBar?.apply(theme: theme)
    }

    fileprivate func handleAccessory(_ action: VimAccessoryAction) {
        guard let controller else { return }
        let input: VimInput
        switch action {
        case .escape: input = .escape
        case .colon: input = .character(":")
        case .slash: input = .character("/")
        case .semicolon: input = .character(";")
        case .comma: input = .character(",")
        }
        controller.send(input)
    }

    fileprivate func handleCommandLineAccessory(_ action: VimCommandLineAccessoryAction) {
        guard let controller else { return }
        switch action {
        case .cancel: controller.send(.escape)
        case .done: controller.send(.return)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let controller else { super.pressesBegan(presses, with: event); return }
        for press in presses {
            guard let key = press.key else { continue }
            if key.modifierFlags.contains(.command) {
                super.pressesBegan(presses, with: event)
                return
            }
            if let input = VimKeyMapper.map(key: key, mode: controller.state.mode) {
                Task { @MainActor in controller.send(input) }
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

private extension VimTextViewBridge {
    func applyHighlights(to storage: NSTextStorage, color: UIColor) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        for highlight in highlights where NSMaxRange(highlight) <= storage.length {
            storage.addAttribute(.backgroundColor, value: color, range: highlight)
        }
    }

    /// iOS variant of the markdown syntax highlighter. Same patterns as
    /// macOS; uses UIFont + UIColor.
    func applySyntaxHighlightingIOS(to storage: NSTextStorage, text: String) {
        let ns = storage.mutableString
        let fullRange = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: UIColor(theme.text), range: fullRange)
        let baseFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        storage.addAttribute(.font, value: baseFont, range: fullRange)

        let primary = UIColor(theme.primary)
        let accent = UIColor(theme.accent)
        let dim = UIColor(theme.textDim)
        let warning = UIColor(theme.warning)
        let patterns: [(String, UIColor, UIFont.Weight?)] = [
            ("^#{1,6} .*$", accent, .semibold),
            ("\\*\\*[^*\\n]+\\*\\*", primary, .bold),
            ("`[^`\\n]+`", warning, nil),
            ("^```.*$", dim, nil),
            ("^>\\s.*$", dim, nil),
            ("\\[[^\\]]+\\]\\([^)]+\\)", primary, nil),
            ("^\\s*[-*+]\\s", dim, nil),
            ("^---$", dim, nil),
        ]
        for (pattern, color, fontWeight) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let r = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: r)
                if let weight = fontWeight {
                    storage.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 16, weight: weight), range: r)
                }
            }
        }
        storage.endEditing()
    }
}

#endif
