import Foundation
import SwiftUI
import UniformTypeIdentifiers
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#endif

/// A note dragged over a pane: which pane, which zone.
struct PaneDropTarget: Equatable {
    var leaf: PaneLeafID
    var zone: PaneDropZone
}

// MARK: - Zoom (tmux `prefix z`, SPEC-PARTE2 §3)

extension AppState {
    /// The zoomed pane, while several panes are open.
    var zoomedLeaf: PaneLeafID? { isSplit ? noteLayout.zoomedLeaf : nil }
    var isZoomed: Bool { zoomedLeaf != nil }

    /// Leaves on screen (the zoomed unit while zoomed).
    var visibleLeaves: [PaneLeafID] {
        let shown = Set(noteLayout.visibleLeaves)
        return visibleLayout.leaves.filter { shown.contains($0) }
    }

    /// `⌃w z`, `:zoom`, the header button, a double-click on the header.
    func toggleZoom(_ leaf: PaneLeafID? = nil) {
        guard isSplit else {
            showToast("one pane — nothing to zoom (⌃w v splits)")
            return
        }
        let target = leaf ?? focusedLeaf
        if !isZoomed, target != focusedLeaf { focusLeaf(target) }
        // The spring lives in PaneLayoutView (instant under Reduce Motion).
        noteLayout.toggleZoom(target)
        keymap.reset()
    }

    /// Moving away / splitting unzooms first.
    func unzoom() {
        guard noteLayout.isZoomed else { return }
        noteLayout.unzoom()
    }
}

// MARK: - Click-to-focus

extension AppState {
    #if os(macOS)
    /// The pane under a click (window coordinates), if the click is one a
    /// pane should take. KeyRouter's mouse-down monitor.
    func paneUnderClick(_ point: CGPoint, in window: NSWindow) -> PaneLeafID? {
        guard isSplit, !showFloatingExplorer, !showPalette, !showHelp, hintSession == nil else { return nil }
        return paneProbes.leaf(at: point, in: window, among: visibleLeaves)
            ?? {
                // Fallback: SwiftUI frames (a pane not yet probed).
                var p = point
                if let content = window.contentView {
                    p = content.convert(point, from: nil)
                    if !content.isFlipped { p.y = content.bounds.height - p.y }
                }
                return visibleLeaves.first { paneGlobalFrames[$0]?.contains(p) == true }
            }()
    }

    /// Mouse-down in pane `leaf` (before the view handles it): the pane
    /// becomes the focused one at once — the ring, the status line and
    /// the key router follow it.
    func paneMouseDown(_ leaf: PaneLeafID) {
        if leaf == primaryLeaf {
            if secondaryFocus != nil {
                previousSlot = currentSlot
                secondaryFocus = nil
                noteLayout.focus(leaf)
                keymap.reset()
            }
        } else {
            noteSecondaryFocus(leaf)
        }
    }

    /// After the click was handled: the keyboard must be inside the
    /// clicked pane. When the click landed on something that does not
    /// take first responder (header, margin, link, board, attachment),
    /// the previous pane's text view still holds it — move it now.
    func paneClickSettled(_ leaf: PaneLeafID, in window: NSWindow) {
        guard isSplit, visibleLeaves.contains(leaf), focusedLeaf == leaf,
              let rect = paneProbes.windowRect(leaf, in: window),
              PaneClickFocus.needsKeyboardMove(window, paneRect: rect) else { return }
        if leaf == primaryLeaf {
            focusPane(mainPane ?? .reader)
        } else {
            focusLeaf(leaf)
        }
    }
    #endif
}

// MARK: - Drag a note onto a pane edge

extension AppState {
    /// The explorer started dragging a note row.
    func beginNoteDrag(_ path: String) {
        noteDrag = path
        #if os(macOS)
        // No end callback for SwiftUI drags: watch the mouse button.
        noteDragWatch?.cancel()
        noteDragWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, self.noteDrag != nil else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.endNoteDrag()
                    return
                }
            }
        }
        #endif
    }

    func endNoteDrag() {
        noteDrag = nil
        paneDrop = nil
    }

    /// A note dropped on pane `leaf`: split on that side, or open here.
    func dropNote(_ path: String, on leaf: PaneLeafID, zone: PaneDropZone) {
        endNoteDrag()
        closeFloatingExplorer(restore: false)
        guard isNoteOpen else {
            _ = openNote(atPath: path)
            return
        }
        guard let axis = zone.axis else {
            focusLeaf(leaf)
            openNoteIn(path, where: .current, from: leaf)
            return
        }
        splitPane(axis, note: path, view: .reading, target: leaf, before: zone.before)
    }
}

/// Drop target of a pane: tracks the zone for the highlight and splits on
/// drop. Only explorer note drags (`lumi-note:` payloads) are accepted.
struct PaneDropDelegate: DropDelegate {
    let leaf: PaneLeafID
    let size: CGSize
    let appState: AppState

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ExplorerDrag.type])
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if appState.paneDrop?.leaf == leaf { appState.paneDrop = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let zone = PaneDropZone.zone(at: info.location, in: size) else { return false }
        if let path = appState.noteDrag {
            appState.dropNote(path, on: leaf, zone: zone)
            return true
        }
        let leaf = self.leaf, appState = self.appState
        return ExplorerDrag.loadPath(info.itemProviders(for: [ExplorerDrag.type])) { path in
            Task { @MainActor in appState.dropNote(path, on: leaf, zone: zone) }
        }
    }

    private func update(_ info: DropInfo) {
        guard let zone = PaneDropZone.zone(at: info.location, in: size) else { return }
        let target = PaneDropTarget(leaf: leaf, zone: zone)
        if appState.paneDrop != target { appState.paneDrop = target }
    }
}
