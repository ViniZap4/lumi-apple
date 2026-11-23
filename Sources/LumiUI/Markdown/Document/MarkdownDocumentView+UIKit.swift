#if canImport(UIKit)
import UIKit
import SwiftUI
import LumiKit

/// iOS / iPadOS / visionOS document surface: the same single-attributed-
/// string TextKit 2 pipeline as macOS, on a non-editable `UITextView`.
/// Gets native cross-paragraph selection, link taps, Find, VoiceOver in
/// document order and (new on these platforms) hardware-keyboard
/// scrolling.
final class MarkdownDocumentUITextView: UITextView {
    var readingWidth: CGFloat = 720 {
        didSet { if oldValue != readingWidth { setNeedsLayout() } }
    }
    var keyboardScrolling = true
    var onLayout: (() -> Void)?
    private var lastInsetWidth: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastInsetWidth {
            lastInsetWidth = bounds.width
            let h = markdownHorizontalInset(viewWidth: bounds.width, readingWidth: readingWidth)
            let inset = UIEdgeInsets(top: 32, left: h, bottom: 40, right: h)
            if textContainerInset != inset { textContainerInset = inset }
        }
        // UIScrollView lays out on every scroll tick — exactly when the
        // attachment overlays need repositioning.
        onLayout?()
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return super.copy(sender) }
        UIPasteboard.general.string = textStorage.lumiCopyText(in: range)
    }

    // MARK: Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard keyboardScrolling else { return super.keyCommands }
        let commands: [(String, UIKeyModifierFlags, String)] = [
            ("j", [], "line down"), ("k", [], "line up"),
            ("d", [], "half page down"), ("u", [], "half page up"),
            ("f", [], "page down"), ("b", [], "page up"),
            (" ", [], "page down"),
            ("g", [], "top"), ("g", .shift, "bottom"),
        ]
        let mine = commands.map { input, flags, title in
            let command = UIKeyCommand(title: title, action: #selector(scrollKey(_:)), input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return (super.keyCommands ?? []) + mine
    }

    @objc private func scrollKey(_ command: UIKeyCommand) {
        let page = bounds.height - 40
        let maxY = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        var y = contentOffset.y
        switch (command.input ?? "", command.modifierFlags.contains(.shift)) {
        case ("j", _): y += 44
        case ("k", _): y -= 44
        case ("d", _): y += page / 2
        case ("u", _): y -= page / 2
        case ("f", _), (" ", _): y += page
        case ("b", _): y -= page
        case ("g", false): y = -adjustedContentInset.top
        case ("g", true): y = maxY
        default: return
        }
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(-adjustedContentInset.top, y), maxY)), animated: true)
    }
}

@MainActor
final class MarkdownDocumentController: NSObject, UITextViewDelegate {
    let textView: MarkdownDocumentUITextView
    let renderer = MarkdownDocumentRenderer()
    private let layoutDelegate = MarkdownLayoutDelegate()
    let overlays: MarkdownAttachmentOverlays
    private var linkAction: MarkdownLinkAction = .systemDefault
    private var style: MarkdownRenderStyle?
    private var hostedEnvKey: HostedEnvKey?
    private var sinkAttached = false

    private struct HostedEnvKey: Equatable {
        let style: MarkdownRenderStyle
        let vaultRoot: URL?
        let embedDepth: Int
    }

    override init() {
        textView = MarkdownDocumentUITextView(usingTextLayoutManager: true)
        overlays = MarkdownAttachmentOverlays(environment: MarkdownHostedEnvironment(
            style: MarkdownRenderStyle(theme: LumiTheme.defaultDark.tokens),
            linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0
        ))
        super.init()
        let tv = textView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.alwaysBounceVertical = true
        tv.dataDetectorTypes = []
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = false
        tv.delegate = self
        tv.textLayoutManager?.delegate = layoutDelegate
        tv.accessibilityLabel = "Note"

        overlays.container = tv
        overlays.layoutManager = tv.textLayoutManager
        overlays.containerOrigin = { [weak tv] in
            guard let tv else { return .zero }
            return CGPoint(x: tv.textContainerInset.left, y: tv.textContainerInset.top)
        }
        overlays.visibleRect = { [weak tv] in
            guard let tv else { return .zero }
            return CGRect(origin: tv.contentOffset, size: tv.bounds.size)
        }
        overlays.relayout = { [weak self] in
            guard let self else { return }
            self.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            self.overlays.layout()
        }
        tv.onLayout = { [weak self] in self?.overlays.layout() }
    }

    func update(
        header: MarkdownHeader?,
        document: MarkdownDocument,
        style newStyle: MarkdownRenderStyle,
        readingWidth: CGFloat,
        linkAction: MarkdownLinkAction,
        vaultRoot: URL?,
        embedDepth: Int,
        keyboardScrolling: Bool
    ) {
        self.linkAction = linkAction
        textView.readingWidth = readingWidth
        textView.keyboardScrolling = keyboardScrolling
        if style != newStyle {
            style = newStyle
            let palette = MarkdownPalette(newStyle.theme)
            textView.linkTextAttributes = [
                .foregroundColor: palette.primary,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            // Same selection accent as the editor and the explorer row.
            textView.tintColor = UIColor(newStyle.theme.accent)
        }
        let envKey = HostedEnvKey(style: newStyle, vaultRoot: vaultRoot, embedDepth: embedDepth)
        if envKey != hostedEnvKey {
            hostedEnvKey = envKey
            overlays.environment = MarkdownHostedEnvironment(
                style: newStyle,
                linkAction: MarkdownLinkAction { [weak self] url in self?.linkAction.handle(url) ?? false },
                vaultRoot: vaultRoot,
                embedDepth: embedDepth
            )
        }
        guard let update = renderer.update(header: header, document: document, style: newStyle) else { return }
        let storage = textView.textStorage
        let apply = { storage.replaceCharacters(in: update.range, with: update.replacement) }
        if let content = textView.textLayoutManager?.textContentManager {
            content.performEditingTransaction(apply)
        } else {
            apply()
        }
        overlays.retain(only: Self.liveAttachments(in: storage))
        textView.setNeedsLayout()
    }

    static func liveAttachments(in storage: NSAttributedString) -> Set<ObjectIdentifier> {
        var live = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if let attachment = value as? MarkdownBlockAttachment { live.insert(ObjectIdentifier(attachment)) }
        }
        return live
    }

    func attachSink(_ sink: MarkdownScrollViewSink?) {
        guard let sink, !sinkAttached else { return }
        sinkAttached = true
        sink.attach(textView)
    }

    // Route link taps through the host first (in-app note links), then
    // fall back to the system default action.
    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        let action = linkAction
        return UIAction { _ in
            if !action.handle(url) {
                UIApplication.shared.open(url)
            }
        }
    }
}

struct MarkdownDocumentView: UIViewRepresentable {
    let header: MarkdownHeader?
    let document: MarkdownDocument
    let style: MarkdownRenderStyle
    let readingWidth: CGFloat
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.markdownVaultRoot) private var vaultRoot
    @Environment(\.markdownScrollViewSink) private var scrollSink
    @Environment(\.markdownEmbedDepth) private var embedDepth
    @Environment(\.markdownKeyboardScrolling) private var keyboardScrolling

    func makeCoordinator() -> MarkdownDocumentController { MarkdownDocumentController() }

    func makeUIView(context: Context) -> MarkdownDocumentUITextView {
        push(to: context.coordinator)
        return context.coordinator.textView
    }

    func updateUIView(_ uiView: MarkdownDocumentUITextView, context: Context) {
        push(to: context.coordinator)
    }

    static func dismantleUIView(_ uiView: MarkdownDocumentUITextView, coordinator: MarkdownDocumentController) {
        coordinator.overlays.removeAll()
    }

    private func push(to controller: MarkdownDocumentController) {
        controller.update(
            header: header, document: document, style: style, readingWidth: readingWidth,
            linkAction: linkAction, vaultRoot: vaultRoot, embedDepth: embedDepth,
            keyboardScrolling: keyboardScrolling
        )
        controller.attachSink(scrollSink)
    }
}
#endif
