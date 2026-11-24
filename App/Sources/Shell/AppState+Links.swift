import Foundation
import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Link routing (SPEC-PARTE2 §3 "Following links")

/// What the hover card shows.
enum HoverTarget: Equatable {
    case note(ExplorerNote)
    case missing(String)
    case external(String)

    var key: String {
        switch self {
        case let .note(n): return "n:" + n.id
        case let .missing(p): return "m:" + p
        case let .external(u): return "u:" + u
        }
    }
}

/// A hover the intent may turn into a card.
struct HoverRequest {
    var target: HoverTarget
    /// Link rect in window-content coordinates (top-left origin).
    var rect: CGRect
    var fromLeaf: PaneLeafID?
    var keyboard: Bool
}

struct HoverCardState: Equatable, Identifiable {
    let id = UUID()
    var target: HoverTarget
    /// The link's rect in the shell's coordinate space.
    var anchor: CGRect
    var fromLeaf: PaneLeafID?
    var keyboard: Bool
    var body: String?
    var truncated = false
    var error: String?
}

extension AppState {
    /// Notes of the open book, for link resolution.
    var linkNotes: [ExplorerNote] { explorer.tree.allNotes.compactMap(\.note) }

    /// Text of the note a pane shows (wiki-link detection, hover bodies).
    func paneText(_ leaf: PaneLeafID?) -> String {
        guard let leaf, leaf != primaryLeaf, let path = noteLayout.notePath(leaf) else { return openNoteText }
        if let doc = localDocs.peek(path) { return doc.currentText }
        if case let .remote(vault) = explorer.source,
           let row = remoteVaultsStore.notes.first(where: { $0.path == path || $0.id == path }),
           let s = remoteVaultsStore.pooledSession(vaultID: vault, noteID: row.id), s.hasSynced {
            return s.text
        }
        return ""
    }

    /// The reader rewrites `[[x]]` to `[x](x.md)`; tell those apart by
    /// the wiki targets written in the note.
    func wikiTarget(for href: String, in text: String) -> String? {
        let targets = LinkRouting.wikiTargets(in: text)
        guard !targets.isEmpty else { return nil }
        var h = (href.removingPercentEncoding ?? href).lowercased()
        if h.hasSuffix(".md") { h.removeLast(3) }
        let base = NoteTree.baseName(h)
        return targets.first { $0 == h || $0 == base || NoteTree.baseName($0) == base && h.hasSuffix($0) }
    }

    func classifyLink(_ href: String, from leaf: PaneLeafID?, wiki: Bool? = nil) -> LinkTarget {
        let fromPath = panePath(leaf) ?? ""
        if wiki == true { return LinkRouting.classify(linkNotes, from: fromPath, href: href, wiki: true) }
        if wiki == nil, let target = wikiTarget(for: href, in: paneText(leaf)) {
            let w = LinkRouting.classify(linkNotes, from: fromPath, href: target, wiki: true)
            if case .note = w { return w }
        }
        return LinkRouting.classify(linkNotes, from: fromPath, href: href)
    }

    /// Follow `href` written in pane `leaf`'s note. External links open in
    /// the browser only here — an explicit action (click, Enter, `gf`).
    @discardableResult
    func openLink(_ href: String, where target: LinkOpenWhere, from leaf: PaneLeafID?, wiki: Bool? = nil) -> Bool {
        switch classifyLink(href, from: leaf, wiki: wiki) {
        case let .note(n):
            openNoteIn(n.path.isEmpty ? n.id : n.path, where: target, from: leaf)
        case let .missing(p):
            showToast("no note at \(p)", tone: .warning)
        case let .external(url):
            openExternal(url)
        case .anchor:
            return false
        case .unsafe:
            showToast("link not followed (unsupported or unsafe)", tone: .warning)
        }
        return true
    }

    func openExternal(_ href: String) {
        guard let safe = LivePreview.safeHref(href), let url = URL(string: safe) else {
            showToast("link not followed (unsupported or unsafe)", tone: .warning)
            return
        }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Where the click that is being handled opens (⌘ vsplit, ⇧⌘ hsplit).
    var clickWhere: LinkOpenWhere {
        #if canImport(AppKit)
        guard let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseUp else { return .current }
        let m = e.modifierFlags
        return LinkOpenWhere.fromClick(command: m.contains(.command), shift: m.contains(.shift)) ?? .current
        #else
        return .current
        #endif
    }

    /// A rendered link as an href relative to the book: file URLs inside
    /// the book become `/path`; anything else keeps its text. nil = not a
    /// note link the app routes (attachments the system opens).
    func readerHref(_ url: URL) -> String? {
        if url.isFileURL {
            guard let root = session?.rootURL.standardizedFileURL.path else { return nil }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(root + "/") else { return nil }
            let rel = String(p.dropFirst(root.count + 1))
            let ext = (rel as NSString).pathExtension.lowercased()
            guard ext == "md" || ext == "canvas" || ext.isEmpty else { return nil }
            return "/" + rel
        }
        return url.absoluteString
    }

    /// A link clicked (or hint-clicked, or followed with Enter) in a
    /// rendered note of pane `leaf`. True = handled (no system fallback).
    func routeReaderURL(_ url: URL, where target: LinkOpenWhere? = nil, from leaf: PaneLeafID?) -> Bool {
        guard let href = readerHref(url) else { return false }
        if url.scheme == nil || url.isFileURL {
            return openLink(href, where: target ?? clickWhere, from: leaf)
        }
        switch classifyLink(href, from: leaf) {
        case .external:
            // The system opens http(s) / mailto from a click.
            if (target ?? clickWhere) == .current { return false }
            openExternal(href)
            return true
        default:
            return openLink(href, where: target ?? clickWhere, from: leaf)
        }
    }

    /// ⌘-click (split) / ⇧⌘-click (stacked) on a Live Preview link.
    func openLiveLink(_ link: LiveLink, from leaf: PaneLeafID?) {
        switch link {
        case let .external(href):
            openExternal(href)
        case let .note(href):
            let w = clickWhere
            openLink(href, where: w == .current ? .vsplit : w, from: leaf)
        case .inert:
            break
        }
    }

    /// `gf`, `Enter` on a link, `⌃w f` / `⌃w Enter` / `⌃w F`, `:follow`.
    func followLinkInFocusedPane(_ target: LinkOpenWhere) {
        let leaf = focusedLeaf
        // A canvas: its selected file node (gf here, ⌃w f in a split).
        if focusedPane != .preview, !paneView(leaf).isEditing, let sink = structuredKeySinks[leaf],
           let path = panePath(leaf), NoteKind.isCanvasPath(path) {
            if target == .current {
                _ = sink(StructuredKey("g"))
                _ = sink(StructuredKey("f"))
            } else {
                _ = sink(StructuredKey("w", ctrl: true))
                _ = sink(StructuredKey("f"))
            }
            return
        }
        if focusedPane != .preview, let editor = paneEditor(leaf) {
            guard let l = editor.linkUnderCursor else {
                showToast("no link under the cursor", tone: .warning)
                return
            }
            openLink(l.href, where: target, from: leaf, wiki: l.wiki)
            return
        }
        guard let (url, _) = MarkdownReading.selectedLink(in: paneScrollView(leaf)) else {
            showToast("no link here — click one or F labels the links", tone: .warning)
            return
        }
        if !routeReaderURL(url, where: target, from: leaf) { openExternal(url.absoluteString) }
    }

    // MARK: - Hover card (SPEC-PARTE2 §4)

    var hoverIntent: HoverIntent<HoverRequest> {
        if let h = hoverIntentStore { return h }
        let h = HoverIntent<HoverRequest>(onShow: { [weak self] req in self?.showHoverCard(req) },
                                          onHide: { [weak self] in self?.dismissHoverCard() })
        hoverIntentStore = h
        return h
    }

    func hoverTarget(href: String, from leaf: PaneLeafID?, wiki: Bool? = nil) -> HoverTarget? {
        switch classifyLink(href, from: leaf, wiki: wiki) {
        case let .note(n): return .note(n)
        case let .missing(p): return .missing(p)
        case let .external(u): return .external(u)
        case .anchor, .unsafe: return nil
        }
    }

    /// The reader's hover hook for pane `leaf`.
    func linkHover(from leaf: PaneLeafID?) -> MarkdownLinkHover {
        MarkdownLinkHover { [weak self] url, rect in
            guard let self else { return false }
            guard let url, self.preferences.hoverPreviews, self.hoverCard?.keyboard != true,
                  let href = self.readerHref(url), let target = self.hoverTarget(href: href, from: leaf) else {
                self.hoverIntentStore?.leave()
                return false
            }
            self.hoverIntent.enter(HoverRequest(target: target, rect: rect, fromLeaf: leaf, keyboard: false), key: target.key)
            return true
        }
    }

    /// Live Preview links (the editor).
    func liveLinkHovered(_ link: LiveLink?, rect: CGRect, from leaf: PaneLeafID?) {
        guard preferences.hoverPreviews, hoverCard?.keyboard != true, let link else {
            hoverIntentStore?.leave()
            return
        }
        let target: HoverTarget?
        switch link {
        case let .note(href): target = hoverTarget(href: href, from: leaf)
        case let .external(href): target = .external(href)
        case .inert: target = nil
        }
        guard let target else { hoverIntentStore?.leave(); return }
        hoverIntent.enter(HoverRequest(target: target, rect: rect, fromLeaf: leaf, keyboard: false), key: target.key)
    }

    /// `K`: the card for the link under the cursor / the selected link.
    func hoverFromKeyboard() {
        let leaf = focusedLeaf
        var target: HoverTarget?
        var rect = CGRect.zero
        if focusedPane != .preview, let editor = paneEditor(leaf) {
            guard let l = editor.linkUnderCursor else {
                showToast("no link under the cursor", tone: .warning)
                return
            }
            target = hoverTarget(href: l.href, from: leaf, wiki: l.wiki)
            let frame = paneGlobalFrames[leaf] ?? CGRect(origin: hintRegistry.globalOrigin, size: hintRegistry.bounds.size)
            rect = CGRect(x: frame.minX + 48, y: frame.minY + 56, width: 1, height: 1)
        } else if let (url, r) = MarkdownReading.selectedLink(in: paneScrollView(leaf)), let href = readerHref(url) {
            target = hoverTarget(href: href, from: leaf)
            rect = r
        } else {
            showToast("no link here — click one or F labels the links", tone: .warning)
            return
        }
        guard let target else { return }
        hoverReturnSlot = currentSlot
        resignTextResponder()
        hoverIntent.showNow(HoverRequest(target: target, rect: rect, fromLeaf: leaf, keyboard: true), key: target.key)
    }

    private func showHoverCard(_ req: HoverRequest) {
        let anchor = req.rect.offsetBy(dx: -hintRegistry.globalOrigin.x, dy: -hintRegistry.globalOrigin.y)
        let card = HoverCardState(target: req.target, anchor: anchor, fromLeaf: req.fromLeaf, keyboard: req.keyboard)
        withMotion(.fast) { hoverCard = card }
        hoverPendingCtrlW = false
        if case let .note(n) = req.target { loadHoverBody(card.id, note: n) }
    }

    private func dismissHoverCard() {
        withMotion(.fast) { hoverCard = nil }
    }

    /// Close the card; a keyboard card hands the keys back.
    func closeHoverCard(restoreFocus: Bool = true) {
        let wasKeyboard = hoverCard?.keyboard == true
        hoverIntentStore?.hide()
        hoverCard = nil
        if wasKeyboard, restoreFocus { focusSlot(hoverReturnSlot) }
    }

    func hoverOpen(_ target: LinkOpenWhere) {
        guard let card = hoverCard else { return }
        closeHoverCard(restoreFocus: true)
        switch card.target {
        case let .note(n): openNoteIn(n.path.isEmpty ? n.id : n.path, where: target, from: card.fromLeaf)
        case let .external(u): openExternal(u)
        case let .missing(p): showToast("no note at \(p)", tone: .warning)
        }
    }

    private func loadHoverBody(_ id: UUID, note: ExplorerNote) {
        let path = note.path.isEmpty ? note.id : note.path
        // Unsaved text of an open note wins.
        if let doc = localDocs.peek(path) {
            applyHoverBody(id, doc.currentText, error: nil)
            return
        }
        if openNotePath == path, !openNoteText.isEmpty {
            applyHoverBody(id, openNoteText, error: nil)
            return
        }
        switch explorer.source {
        case let .local(root):
            guard let url = try? LumiOpenURL.localNoteURL(path, in: root) else {
                applyHoverBody(id, nil, error: "can't read this note")
                return
            }
            Task { @MainActor [weak self] in
                let raw: String? = await Task.detached(priority: .userInitiated) {
                    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
                    defer { try? h.close() }
                    return (try? h.read(upToCount: 256 * 1024)).map { String(decoding: $0, as: UTF8.self) }
                }.value
                self?.applyHoverBody(id, raw, error: raw == nil ? "can't read this note" : nil)
            }
        case let .remote(vault):
            if let s = remoteVaultsStore.pooledSession(vaultID: vault, noteID: note.id), s.hasSynced {
                applyHoverBody(id, s.text, error: nil)
                return
            }
            let store = remoteVaultsStore
            Task { @MainActor [weak self] in
                do {
                    let body = try await store.noteBody(noteID: note.id)
                    self?.applyHoverBody(id, body, error: nil)
                } catch {
                    self?.applyHoverBody(id, nil, error: self?.describe(error) ?? "can't load this note")
                }
            }
        case .none:
            break
        }
    }

    private func applyHoverBody(_ id: UUID, _ raw: String?, error: String?) {
        guard hoverCard?.id == id else { return }
        if let raw {
            let ex = HoverPreview.excerpt(raw)
            hoverCard?.body = ex.text
            hoverCard?.truncated = ex.truncated
        } else {
            hoverCard?.error = error
        }
    }

    /// Keys while a keyboard-opened card shows: j/k d/u scroll, Enter
    /// opens, `⌃w f`/`v` split, `⌃w F`/`s` stacked, Esc/q close.
    func handleHoverKey(_ k: KeyStroke) -> Bool {
        guard let card = hoverCard else { return false }
        if k.command { return false }
        if !card.keyboard {
            // A mouse card: only Esc touches it.
            if k.special == .escape { closeHoverCard(); return true }
            return false
        }
        if hoverPendingCtrlW {
            hoverPendingCtrlW = false
            let c = k.control ? k.chars?.lowercased() : k.chars
            switch (c, k.special) {
            case ("f", _), ("v", _), (_, .enter?): hoverOpen(.vsplit)
            case ("F", _), ("s", _): hoverOpen(.hsplit)
            default: break
            }
            return true
        }
        if k.control, k.chars?.lowercased() == "w" { hoverPendingCtrlW = true; return true }
        let c = hoverCoordinator
        switch (k.chars, k.special) {
        case ("j", _), (_, .down?): c.glide(by: 44)
        case ("k", _), (_, .up?): c.glide(by: -44)
        case ("d", _): c.scrollHalfPage(direction: 1)
        case ("u", _): c.scrollHalfPage(direction: -1)
        case (_, .enter?), ("o", _): hoverOpen(.current)
        case ("q", _), (_, .escape?), ("K", _): closeHoverCard()
        default: break
        }
        return true
    }
}
