import SwiftUI
import LumiKit

/// Reader interactions shared by the AppKit and UIKit document surfaces:
/// task checkboxes, foldable callouts and in-document anchors (`#…`
/// heading links, footnote refs and back-links). Internal links use the
/// private `lumi-task:`, `lumi-callout:` and `lumi-fn:` schemes the
/// builder stamps on the runs; they never leave the reader.
@MainActor
final class MarkdownDocumentInteraction {
    enum Outcome {
        /// Not one of ours: route to the host / system.
        case external
        /// Handled (or deliberately ignored).
        case handled
        /// Callout fold state changed: re-render with `transform`.
        case rerender
        /// Scroll to the run carrying this `.lumiAnchor`.
        case scroll(String)
    }

    /// Callouts the user folded / unfolded (by `MarkdownCalloutKey`).
    private(set) var toggledCallouts: Set<Int> = []
    /// The host's task toggle (global task index), nil when read-only.
    var onToggleTask: ((Int) -> Void)?
    /// The document as parsed (before fold overrides).
    var document: MarkdownDocument?

    /// `document` with the user's fold overrides applied.
    func transform(_ document: MarkdownDocument) -> MarkdownDocument {
        self.document = document
        return MarkdownCalloutKey.apply(toggledCallouts, to: document)
    }

    func handle(_ url: URL, at charIndex: Int, renderer: MarkdownDocumentRenderer) -> Outcome {
        switch url.scheme {
        case "lumi-task":
            guard let onToggleTask, let ordinal = Int(url.lastPathComponent),
                  let document, let block = renderer.blockIndex(atCharacter: charIndex),
                  block < document.blocks.count else { return .handled }
            onToggleTask(MarkdownCalloutKey.taskCount(Array(document.blocks[..<block])) + ordinal)
            return .handled
        case "lumi-callout":
            guard let key = Int(url.lastPathComponent) else { return .handled }
            if toggledCallouts.contains(key) { toggledCallouts.remove(key) } else { toggledCallouts.insert(key) }
            return .rerender
        case "lumi-fn":
            let id = url.lastPathComponent
            return .scroll(url.host == "ref" ? "fn-\(id)" : "fnref-\(id)")
        case nil where url.fragment != nil && url.path.isEmpty:
            return .scroll(url.fragment ?? "")
        default:
            if url.absoluteString.hasPrefix("#") { return .scroll(String(url.absoluteString.dropFirst())) }
            return .external
        }
    }

    /// Character range of the first run anchored `name` (also tries the
    /// web's `h-` heading prefix, so `[x](#intro)` finds `## Intro`).
    static func anchorRange(_ name: String, in storage: NSAttributedString) -> NSRange? {
        let wanted = [name, name.hasPrefix("h-") ? name : "h-" + name, MarkdownText.slug(name)]
        var found: NSRange?
        storage.enumerateAttribute(.lumiAnchor, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            if let v = value as? String, wanted.contains(v) {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Top of each top-level block's first line fragment (text-container
    /// coordinates), index-aligned with the document's blocks.
    static func blockTops(layoutManager: NSTextLayoutManager, renderer: MarkdownDocumentRenderer, blockCount: Int) -> [CGFloat]? {
        guard let tcm = layoutManager.textContentManager else { return nil }
        layoutManager.ensureLayout(for: tcm.documentRange)
        var tops: [CGFloat] = []
        tops.reserveCapacity(blockCount)
        for i in 0..<blockCount {
            guard let offset = renderer.characterOffset(ofBlock: i),
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: offset),
                  let frag = layoutManager.textLayoutFragment(for: loc) else { return nil }
            // The fragment frame includes paragraph spacing before; the
            // block "starts" where its first line does.
            let lineTop = frag.textLineFragments.first.map { frag.layoutFragmentFrame.minY + $0.typographicBounds.minY }
            tops.append(lineTop ?? frag.layoutFragmentFrame.minY)
        }
        return tops
    }

    /// Frame (text-container coordinates) of the fragment holding `range`.
    static func frame(of range: NSRange, layoutManager: NSTextLayoutManager) -> CGRect? {
        guard let tcm = layoutManager.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: range.location) else { return nil }
        if let upTo = NSTextRange(location: tcm.documentRange.location, end: loc) { layoutManager.ensureLayout(for: upTo) }
        return layoutManager.textLayoutFragment(for: loc)?.layoutFragmentFrame
    }
}

/// What the split preview's scroll sync needs from the rendered pane.
@MainActor
protocol SplitPreviewSurface: AnyObject {
    /// Top offset of each top-level block in scroll coordinates.
    func blockTops(blockCount: Int) -> [CGFloat]?
    var previewContentHeight: CGFloat { get }
    var previewViewportHeight: CGFloat { get }
    var previewScrollOffset: CGFloat { get }
    func setPreviewScrollOffset(_ y: CGFloat)
}

/// Source ⇄ split-preview scroll sync (web `SourceSplit.svelte` +
/// `lib/scroll-sync.ts`). Editor lines map to rendered block offsets
/// through the blocks' source lines; only the pane the user last
/// touched drives, so the two never ping-pong.
@MainActor
public final class SplitScrollSync {
    public init() {}

    public private(set) weak var editor: VimController?
    weak var preview: SplitPreviewSurface?
    private var document: MarkdownDocument?
    private var anchors: [ScrollSync.Anchor] = []
    public private(set) var leader: ScrollSync.Side = .source
    private var pending: ScrollSync.Side?
    /// False while the panes are tabs (narrow window): nothing to sync.
    public var isActive = true

    public func attach(editor: VimController) {
        self.editor = editor
        editor.onViewportScroll = { [weak self] in self?.scrolled(.source) }
        editor.onUserInteraction = { [weak self] in self?.claim(.source) }
    }

    func attach(preview: SplitPreviewSurface) {
        self.preview = preview
    }

    public func claim(_ side: ScrollSync.Side) { leader = side }

    func scrolled(_ side: ScrollSync.Side) {
        guard side == leader else { return }
        schedule(side)
    }

    /// The preview re-rendered (or an attachment changed height):
    /// re-measure the anchors and keep the preview on the editor.
    func previewDidLayout(_ document: MarkdownDocument) {
        self.document = document
        remeasure()
        if leader == .source { schedule(.source) }
    }

    func remeasure() {
        guard let preview, let document, let tops = preview.blockTops(blockCount: document.blocks.count) else { return }
        var raw: [ScrollSync.Anchor] = []
        for (i, top) in tops.enumerated() where i < document.sourceLines.count {
            raw.append(.init(line: Double(document.sourceLines[i]), top: Double(top)))
        }
        anchors = ScrollSync.normalize(raw, totalLines: document.lineCount, contentHeight: Double(preview.previewContentHeight))
    }

    private func schedule(_ side: ScrollSync.Side) {
        guard isActive else { return }
        let already = pending != nil
        pending = side
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let side = self.pending else { return }
            self.pending = nil
            side == .source ? self.syncFromEditor() : self.syncFromPreview()
        }
    }

    private func syncFromEditor() {
        guard let editor, let preview, let line = editor.viewportTopLine() else { return }
        let maxY = max(0, preview.previewContentHeight - preview.previewViewportHeight)
        let target: CGFloat
        if line < 0 { target = 0 } else if !line.isFinite { target = maxY } else {
            target = min(maxY, CGFloat(ScrollSync.offset(forLine: line, anchors: anchors)))
        }
        if abs(preview.previewScrollOffset - target) > 1 { preview.setPreviewScrollOffset(target) }
    }

    private func syncFromPreview() {
        guard let editor, let preview else { return }
        let y = preview.previewScrollOffset
        let maxY = max(0, preview.previewContentHeight - preview.previewViewportHeight)
        if y <= 1 { editor.scrollViewport(toLine: 0); return }
        if y >= maxY - 2 { editor.scrollViewport(toLine: .infinity); return }
        editor.scrollViewport(toLine: ScrollSync.line(forOffset: Double(y), anchors: anchors))
    }

    /// Toggle task `index` through the open editor (one ranged edit on
    /// its buffer, its text view and its CRDT). False when no editor is
    /// attached or there is no such task.
    @discardableResult
    public func toggleTask(_ index: Int) -> Bool {
        guard let editor, editor.isEditable, let edit = MarkdownTasks.toggle(in: editor.buffer.text, index: index) else { return false }
        editor.applyProgrammaticEdit(edit)
        return true
    }
}

public extension EnvironmentValues {
    /// Split preview coordinator: the editor and the preview in a split
    /// register with it.
    @Entry var splitScrollSync: SplitScrollSync? = nil
}
