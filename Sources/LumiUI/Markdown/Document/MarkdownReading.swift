import Foundation
import LumiKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// One thing hint mode can click inside a rendered note.
public struct MarkdownHintTarget {
    public enum Kind: Sendable, Hashable { case link, task, copy }
    public let kind: Kind
    /// Window-content coordinates, top-left origin (SwiftUI `.global`).
    public let rect: CGRect
    public let action: @MainActor () -> Void
}

/// Keyboard reading of a rendered note (the reader and the split
/// preview): heading jumps, find, copy, following links and hint
/// targets. Works on the scroll view the reader hands out
/// (`MarkdownScrollViewSink`, `SplitScrollSync.previewScrollView`), so
/// the app never sees the TextKit internals.
@MainActor
public enum MarkdownReading {
    public enum FindOp: Sendable { case show, next, previous, hide }

    #if canImport(AppKit)
    private static func controller(_ scrollView: NSScrollView?) -> MarkdownDocumentController? {
        (scrollView?.documentView as? MarkdownDocumentNSTextView)?.owner
    }

    /// Scroll offsets (clip-view y) of the headings, top to bottom.
    public static func headingOffsets(in scrollView: NSScrollView?) -> [CGFloat] {
        guard let c = controller(scrollView) else { return [] }
        return c.headingOffsets()
    }

    /// Find bar (`/`) and next / previous match (`n` / `N`).
    public static func find(_ op: FindOp, in scrollView: NSScrollView?) {
        guard let tv = scrollView?.documentView as? NSTextView else { return }
        let action: NSTextFinder.Action
        switch op {
        case .show: action = .showFindInterface
        case .next: action = .nextMatch
        case .previous: action = .previousMatch
        case .hide: action = .hideFindInterface
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv.performTextFinderAction(item)
    }

    /// Hide the find bar. False when it was not showing.
    @discardableResult
    public static func closeFind(in scrollView: NSScrollView?) -> Bool {
        guard let scrollView, scrollView.isFindBarVisible else { return false }
        find(.hide, in: scrollView)
        scrollView.isFindBarVisible = false
        if let tv = scrollView.documentView { tv.window?.makeFirstResponder(tv) }
        return true
    }

    /// Copy the selection (attachments yield their markdown). False when
    /// nothing is selected.
    @discardableResult
    public static func copySelection(in scrollView: NSScrollView?) -> Bool {
        guard let tv = scrollView?.documentView as? NSTextView, tv.selectedRange().length > 0 else { return false }
        tv.copy(nil)
        return true
    }

    /// Follow the link under the selection (after a find or a click).
    @discardableResult
    public static func followSelectedLink(in scrollView: NSScrollView?) -> Bool {
        guard let c = controller(scrollView) else { return false }
        return c.followLink(at: c.textView.selectedRange().location)
    }

    /// Links, task checkboxes and code copy buttons on screen.
    public static func hintTargets(in scrollView: NSScrollView?) -> [MarkdownHintTarget] {
        controller(scrollView)?.hintTargets() ?? []
    }
    #else
    public static func headingOffsets(in scrollView: UIScrollView?) -> [CGFloat] { [] }
    public static func find(_ op: FindOp, in scrollView: UIScrollView?) {
        if op == .show, let tv = scrollView as? UITextView { tv.findInteraction?.presentFindNavigator(showingReplace: false) }
    }
    @discardableResult
    public static func closeFind(in scrollView: UIScrollView?) -> Bool { false }
    @discardableResult
    public static func copySelection(in scrollView: UIScrollView?) -> Bool {
        guard let tv = scrollView as? UITextView, tv.selectedRange.length > 0 else { return false }
        tv.copy(nil)
        return true
    }
    @discardableResult
    public static func followSelectedLink(in scrollView: UIScrollView?) -> Bool { false }
    public static func hintTargets(in scrollView: UIScrollView?) -> [MarkdownHintTarget] { [] }
    #endif
}

#if canImport(AppKit)
extension MarkdownDocumentController {
    /// Clip-view offsets of the heading blocks (a little air above).
    func headingOffsets() -> [CGFloat] {
        guard let doc = renderedDocument, let tlm = textView.textLayoutManager,
              let tops = MarkdownDocumentInteraction.blockTops(layoutManager: tlm, renderer: renderer, blockCount: doc.blocks.count)
        else { return [] }
        let originY = textView.textContainerOrigin.y
        var out: [CGFloat] = []
        for (i, block) in doc.blocks.enumerated() where i < tops.count {
            if case .heading = block { out.append(max(0, tops[i] + originY - 16)) }
        }
        return out
    }

    /// Click the link at `index` (internal `lumi-` links, notes, URLs).
    func followLink(at index: Int) -> Bool {
        guard let storage = textView.textStorage, index >= 0 else { return false }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let link = storage.attribute(.link, at: candidate, effectiveRange: nil) {
                click(link, at: candidate)
                return true
            }
        }
        return false
    }

    private func click(_ link: Any, at index: Int) {
        if let url = link as? URL, url.scheme?.hasPrefix("lumi-") == true {
            _ = handleInternal(url, at: index)
            return
        }
        // Runs the delegate (in-app routing) and falls back to NSWorkspace.
        textView.clicked(onLink: link, at: index)
    }

    func hintTargets() -> [MarkdownHintTarget] {
        guard let storage = textView.textStorage, storage.length > 0,
              let tlm = textView.textLayoutManager, let content = tlm.textContentManager else { return [] }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let lo = textView.characterIndexForInsertion(at: CGPoint(x: visible.minX, y: visible.minY))
        let hi = textView.characterIndexForInsertion(at: CGPoint(x: visible.maxX, y: visible.maxY))
        let start = max(0, min(lo, hi) - 1)
        let end = min(storage.length, max(lo, hi) + 1)
        var out: [MarkdownHintTarget] = []
        if end > start {
            storage.enumerateAttribute(.link, in: NSRange(location: start, length: end - start), options: []) { value, range, _ in
                guard let value,
                      let s = content.location(content.documentRange.location, offsetBy: range.location),
                      let e = content.location(s, offsetBy: range.length),
                      let textRange = NSTextRange(location: s, end: e) else { return }
                var first: CGRect?
                tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                    first = frame.offsetBy(dx: origin.x, dy: origin.y)
                    return false
                }
                guard let rect = first, visible.intersects(rect), let win = toWindow(rect) else { return }
                let isTask = (value as? URL)?.scheme == "lumi-task" || (value as? String)?.hasPrefix("lumi-task") == true
                let location = range.location
                out.append(MarkdownHintTarget(kind: isTask ? .task : .link, rect: win) { [weak self] in
                    self?.click(value, at: location)
                })
            }
        }
        for (attachment, frame) in overlays.mountedViews {
            guard case let .code(_, code) = attachment.payload, visible.intersects(frame) else { continue }
            // The copy button sits at the right end of the code header.
            let button = CGRect(x: frame.maxX - 64, y: max(frame.minY, visible.minY), width: 56, height: 22)
            guard let win = toWindow(button) else { continue }
            out.append(MarkdownHintTarget(kind: .copy, rect: win) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            })
        }
        return out
    }

    /// Text-view rect → window content coordinates, top-left origin.
    private func toWindow(_ rect: CGRect) -> CGRect? {
        guard let content = textView.window?.contentView else { return nil }
        var r = content.convert(rect, from: textView)
        if !content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
        return r
    }
}
#endif
