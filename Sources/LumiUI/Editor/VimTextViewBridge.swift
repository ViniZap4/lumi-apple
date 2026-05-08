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
    let cursorOffset: Int
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
        let target = NSRange(location: cursorOffset, length: 0)
        if textView.selectedRange() != target {
            textView.setSelectedRange(target)
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
    let cursorOffset: Int
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
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard let view = textView as? VimUIKitTextView else { return }
        view.textColor = UIColor(theme.text)
        view.tintColor = UIColor(isInsertMode ? theme.primary : theme.accent)

        if view.text != text {
            view.text = text
        }
        let target = NSRange(location: cursorOffset, length: 0)
        if view.selectedRange != target {
            view.selectedRange = target
        }
    }
}

final class VimUIKitTextView: UITextView {
    weak var controller: VimController?

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
