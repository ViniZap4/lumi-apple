import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit

/// Drop-in plain-text editor for users who turn vim off. Same NSTextView
/// surface as the vim bridge (themed, no rich text) but without the engine
/// intercepting keystrokes — letting macOS's native key handling, system
/// shortcuts, and Apple Intelligence Writing Tools work as expected.
public struct PlainTextEditor: NSViewRepresentable {
    @Binding public var text: String
    @Environment(\.theme) private var theme

    public init(text: Binding<String>) {
        self._text = text
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        if #available(macOS 15.2, *) {
            // Default Writing Tools behavior — system handles surfacing
            // proofreading, rewrite, summarize, and Image Playground when
            // the user invokes them from menu or context.
            textView.writingToolsBehavior = .default
        }
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textColor = NSColor(theme.text)
        textView.insertionPointColor = NSColor(theme.primary)
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            // Restore caret if it's still in range; otherwise let it
            // fall through to AppKit's default (end of buffer).
            if selection.location <= (text as NSString).length {
                textView.setSelectedRange(selection)
            }
        }
        // One-shot first-responder grab so the user can type
        // immediately after switching to edit mode. Same pattern as
        // VimTextViewBridge.
        if !context.coordinator.didAutoFocus {
            context.coordinator.didAutoFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        var didAutoFocus: Bool = false
        init(_ parent: PlainTextEditor) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let new = textView.string
            if new != parent.text {
                parent.text = new
            }
        }
    }
}

#elseif canImport(UIKit)
import UIKit

/// iOS / iPadOS / visionOS plain editor — same role as the macOS variant.
public struct PlainTextEditor: UIViewRepresentable {
    @Binding public var text: String
    @Environment(\.theme) private var theme

    public init(text: Binding<String>) { self._text = text }

    public func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = text
        return textView
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
        textView.textColor = UIColor(theme.text)
        if textView.text != text {
            let range = textView.selectedRange
            textView.text = text
            if range.location <= (text as NSString).length {
                textView.selectedRange = range
            }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        public func textViewDidChange(_ textView: UITextView) {
            if textView.text != parent.text { parent.text = textView.text }
        }
    }
}
#endif
