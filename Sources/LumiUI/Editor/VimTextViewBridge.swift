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
    let controller: VimController
    let theme: ThemeTokens

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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimAppKitTextView else { return }
        textView.textColor = NSColor(theme.text)
        textView.insertionPointColor = NSColor(isInsertMode ? theme.primary : theme.accent)

        if textView.string != text {
            textView.string = text
        }
        if textView.selectedRange() != selection {
            textView.setSelectedRange(selection)
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

        if let input = VimKeyMapper.map(event: event) {
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
    let controller: VimController
    let theme: ThemeTokens

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
        textView.inputAccessoryView = bar
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let view = textView as? VimUIKitTextView else { return }
        view.textColor = UIColor(theme.text)
        view.tintColor = UIColor(isInsertMode ? theme.primary : theme.accent)
        view.applyAccessoryTheme(theme)

        if view.text != text {
            view.text = text
        }
        if view.selectedRange != selection {
            view.selectedRange = selection
        }
    }
}

final class VimUIKitTextView: UITextView {
    weak var controller: VimController?
    var accessoryBar: VimAccessoryBar?

    func applyAccessoryTheme(_ theme: ThemeTokens) {
        accessoryBar?.apply(theme: theme)
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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let controller else { super.pressesBegan(presses, with: event); return }
        for press in presses {
            guard let key = press.key else { continue }
            if key.modifierFlags.contains(.command) {
                super.pressesBegan(presses, with: event)
                return
            }
            if let input = VimKeyMapper.map(key: key) {
                Task { @MainActor in controller.send(input) }
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

#endif
