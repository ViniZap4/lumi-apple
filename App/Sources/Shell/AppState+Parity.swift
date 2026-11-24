import Foundation
import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Hint mode

/// One clickable thing hint mode can label.
struct HintTarget {
    let id: String
    var frame: CGRect
    let action: @MainActor () -> Void
}

/// Frames of hintable views, kept up to date by `.hintTarget(...)`.
/// Not observed: frames change on every scroll and must not re-render
/// the shell; hint mode snapshots them when it starts.
@MainActor
final class HintRegistry {
    fileprivate(set) var targets: [String: HintTarget] = [:]
    /// Visible shell area (same coordinate space as the frames).
    var bounds: CGRect = .zero
    /// The shell area's origin in window (SwiftUI `.global`)
    /// coordinates: maps rects from AppKit views (links in a rendered
    /// note) into the hint space.
    var globalOrigin: CGPoint = .zero
    /// Sidebar frame in window coordinates (clicks focus it).
    var sidebarGlobalFrame: CGRect = .zero

    func set(_ id: String, frame: CGRect, action: @escaping @MainActor () -> Void) {
        targets[id] = HintTarget(id: id, frame: frame, action: action)
    }

    func remove(_ id: String) { targets.removeValue(forKey: id) }

    /// On-screen targets in reading order (top to bottom, left to right).
    var visible: [HintTarget] { onScreen(Array(targets.values)) }

    func onScreen(_ list: [HintTarget]) -> [HintTarget] {
        let area = bounds.insetBy(dx: -1, dy: -1)
        return list
            .filter { $0.frame.width > 2 && $0.frame.height > 2 && area.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            .sorted { abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
    }

    /// Links / checkboxes / copy buttons of a rendered note as targets.
    func markdownTargets(_ items: [MarkdownHintTarget], prefix: String) -> [HintTarget] {
        items.enumerated().map { i, item in
            HintTarget(id: "\(prefix).\(i)", frame: item.rect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y), action: item.action)
        }
    }
}

struct HintSession {
    var targets: [HintTarget]
    var labels: [String]
    var typed = ""

    var live: [Int] { HintLabels.filter(labels, typed: typed).live }
}

/// Coordinate space every hint frame is measured in.
let shellHintSpace = "lumi.shell"

extension View {
    /// Register this view as a hint-mode target (`f` / `F`).
    func hintTarget(_ id: String, action: @escaping @MainActor () -> Void) -> some View {
        modifier(HintTargetModifier(id: id, action: action))
    }
}

private struct HintTargetModifier: ViewModifier {
    let id: String
    let action: @MainActor () -> Void
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(shellHintSpace)) } action: { frame in
                appState.hintRegistry.set(id, frame: frame, action: action)
            }
            .onDisappear { appState.hintRegistry.remove(id) }
    }
}

extension AppState {
    func startHints() {
        let targets: [HintTarget]
        if focusedPane == .preview {
            // Reading the split preview: its links, checkboxes and copy
            // buttons only.
            let items = MarkdownReading.hintTargets(in: activeSplit?.previewScrollView)
            targets = hintRegistry.onScreen(hintRegistry.markdownTargets(items, prefix: "preview"))
        } else if surface == .reader {
            let items = MarkdownReading.hintTargets(in: readCoordinator.scrollView)
            targets = hintRegistry.onScreen(Array(hintRegistry.targets.values) + hintRegistry.markdownTargets(items, prefix: "reader"))
        } else {
            targets = hintRegistry.visible
        }
        guard !targets.isEmpty else {
            showToast("nothing to click here")
            return
        }
        hintSession = HintSession(targets: targets, labels: HintLabels.make(targets.count))
        keymap.reset()
    }

    /// Keys while hint labels show. Always consumes the key (Esc / an
    /// unknown key cancels), except ⌘ shortcuts.
    func handleHintKey(_ k: KeyStroke) -> Bool {
        guard var session = hintSession else { return false }
        if k.command { hintSession = nil; return false }
        if k.special == .backspace {
            if session.typed.isEmpty { hintSession = nil } else { session.typed.removeLast(); hintSession = session }
            return true
        }
        guard k.special == nil, let c = k.chars?.lowercased(), c.count == 1, c.first?.isLetter == true else {
            hintSession = nil
            return true
        }
        session.typed += c
        let (live, hit) = HintLabels.filter(session.labels, typed: session.typed)
        if let hit {
            hintSession = nil
            session.targets[hit].action()
        } else if live.isEmpty {
            hintSession = nil
        } else {
            hintSession = session
        }
        return true
    }
}

// MARK: - Explorer context menu (mirrors the keys, shows them)

/// One context-menu row: the key that does the same thing is shown (and
/// works as the menu mnemonic), so the mouse path teaches the keyboard.
struct ShellMenuItem: Identifiable {
    let id: String
    let label: String
    /// Key equivalent shown at the right ("" = none, "⏎" = Return).
    let keys: String
    var enabled = true
    var danger = false
    var separatorAbove = false
    let run: @MainActor () -> Void
}

extension AppState {
    /// Point the explorer cursor at `entry` (current or parent column).
    func selectExplorerEntry(_ entry: ExplorerEntry) {
        let nav = explorer.nav
        if let i = nav.entries.firstIndex(where: { $0.key == entry.key }) {
            explorer.nav.setCursor(i)
        } else {
            explorer.nav.goTo(NoteTree.dirOf(entry.path), select: entry.key)
        }
    }

    /// Web `menuFor`: a note, a folder or empty space (entry == nil).
    func explorerMenu(for entry: ExplorerEntry?) -> [ShellMenuItem] {
        let offline = !explorer.isLocal && isRemoteOffline
        let canPaste = explorer.yanked != nil
        guard let entry else {
            return [
                ShellMenuItem(id: "new", label: "New note…", keys: "a", enabled: !offline) { self.beginCreate() },
                ShellMenuItem(id: "new-folder", label: "New folder…", keys: "", enabled: !offline && explorer.isLocal) {
                    self.beginCreate()
                    self.explorer.prompt?.text = "/"
                },
                ShellMenuItem(id: "paste", label: "Paste copy here", keys: "p", enabled: !offline && canPaste) { self.paste() },
                ShellMenuItem(id: "filter", label: "Filter…", keys: "/", separatorAbove: true) {
                    self.explorer.prompt = .init(kind: .filter, text: self.explorer.nav.filter)
                },
                ShellMenuItem(id: "hidden", label: preferences.explorerShowHidden ? "Hide hidden files" : "Show hidden files", keys: ".") {
                    self.preferences.explorerShowHidden.toggle()
                    self.explorer.setShowHidden(self.preferences.explorerShowHidden)
                },
                ShellMenuItem(id: "refresh", label: "Refresh", keys: "R") { self.refreshBook() },
            ]
        }
        if entry.kind == .folder {
            return [
                ShellMenuItem(id: "open", label: "Open folder", keys: "⏎") { self.explorer.nav.goTo(entry.path) },
                ShellMenuItem(id: "new", label: "New note here…", keys: "a", enabled: !offline, separatorAbove: true) {
                    self.explorer.nav.goTo(entry.path)
                    self.beginCreate()
                },
                ShellMenuItem(id: "rename", label: "Rename / move…", keys: "r", enabled: explorer.isLocal) {
                    self.selectExplorerEntry(entry)
                    self.beginRename()
                },
                ShellMenuItem(id: "paste", label: "Paste copy here", keys: "p", enabled: !offline && canPaste) {
                    self.explorer.nav.goTo(entry.path)
                    self.paste()
                },
                ShellMenuItem(id: "delete", label: "Delete…", keys: "d", enabled: explorer.isLocal, danger: true, separatorAbove: true) {
                    self.selectExplorerEntry(entry)
                    self.beginDelete()
                },
            ]
        }
        return [
            ShellMenuItem(id: "open", label: "Open", keys: "⏎") { self.open(entry) },
            ShellMenuItem(id: "edit", label: "Edit", keys: "e", enabled: explorer.isLocal || can("note.write")) { self.open(entry, edit: true) },
            ShellMenuItem(id: "rename", label: "Rename / move…", keys: "r", enabled: !offline, separatorAbove: true) {
                self.selectExplorerEntry(entry)
                self.beginRename()
            },
            ShellMenuItem(id: "yank", label: "Yank (copy note)", keys: "y") {
                self.explorer.yanked = entry
                self.showToast("yanked \(entry.name) · p to paste")
            },
            ShellMenuItem(id: "paste", label: "Paste copy here", keys: "p", enabled: !offline && canPaste) {
                self.explorer.nav.goTo(NoteTree.dirOf(entry.path))
                self.paste()
            },
            ShellMenuItem(id: "link", label: "Copy markdown link", keys: "") { self.copyMarkdownLink(entry) },
            ShellMenuItem(id: "delete", label: "Delete…", keys: "d", enabled: !offline, danger: true, separatorAbove: true) {
                self.selectExplorerEntry(entry)
                self.beginDelete()
            },
        ]
    }

    private func copyMarkdownLink(_ entry: ExplorerEntry) {
        let path = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
        let link = "[\(entry.name)](\(path))"
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        #else
        UIPasteboard.general.string = link
        #endif
        showToast("copied \(link)")
    }
}

// MARK: - Drag a note onto a folder

/// Drag payload for explorer rows: a note path, tagged so a plain text
/// drop from elsewhere is never mistaken for a move.
enum ExplorerDrag {
    static let prefix = "lumi-note:"
    static func payload(_ entry: ExplorerEntry) -> String { prefix + entry.path }
    static func path(from payload: String) -> String? {
        payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil
    }
}

extension AppState {
    /// Move the note at `path` into `folder` (book-relative). Local books
    /// move the file; server books PATCH the note's path (web parity).
    func moveNote(path: String, toFolder folder: String) {
        let path = NoteTree.normalizePath(path)
        let folder = NoteTree.normalizePath(folder)
        guard NoteTree.dirOf(path) != folder else { return }
        guard let entry = explorer.tree.allNotes.first(where: { $0.path == path }) else { return }
        switch explorer.source {
        case .local:
            guard let src = explorer.localURL(for: entry), let dest = explorer.localDirURL(folder) else { return }
            do {
                if selectedEntry?.relativePath == path { closePrimaryNoteForRemoval() }
                let moved = try FileOperations.move(src, into: dest)
                let rel = (folder.isEmpty ? "" : folder + "/") + moved.lastPathComponent
                explorer.rescanLocal(reveal: rel)
                showToast("moved \(entry.name) → \(folder.isEmpty ? "/" : folder + "/")")
            } catch {
                showToast(describe(error), tone: .error)
            }
        case .remote:
            guard requireOnline("moving notes") else { return }
            guard can("note.write"), let note = entry.note else {
                showToast("you can't move notes in this book (note.write)", tone: .warning)
                return
            }
            let file = NoteTree.baseName(path)
            Task {
                do {
                    let updated = try await remoteVaultsStore.updateNoteMeta(noteID: note.id, path: folder.isEmpty ? file : folder + "/" + file)
                    explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
                    explorer.nav.reveal(noteID: updated.id)
                    showToast("moved \(entry.name) → \(folder.isEmpty ? "/" : folder + "/")")
                } catch {
                    showToast(describe(error), tone: .error)
                }
            }
        case .none:
            break
        }
    }
}

// MARK: - Editing page: tasks, host commands, rename

extension AppState {
    /// Toggle task `index` of the open note as one single-character
    /// ranged edit: through the mounted editor when there is one (its
    /// buffer, view and — server notes — CRDT stay one), else straight
    /// into the live replica (server) or the file (local).
    func toggleTask(_ index: Int) {
        if isEditing, let editor = activeEditor, editor.isEditable,
           let edit = MarkdownTasks.toggle(in: editor.buffer.text, index: index) {
            editor.applyProgrammaticEdit(edit)
            return
        }
        if selectedEntry != nil {
            guard let edit = MarkdownTasks.toggle(in: editor.currentText, index: index) else { return }
            let ns = NSMutableString(string: editor.currentText)
            guard edit.apply(to: ns) else { return }
            editor.currentText = ns as String
            if !isEditing { editor.save() }
            return
        }
        if let id = selectedRemoteNoteID {
            guard can("note.write") else {
                showToast("read-only — note.write required", tone: .warning)
                return
            }
            guard let session = remoteVaultsStore.openSession, session.noteID == id, !session.isDestroyed, session.isEditable,
                  let edit = MarkdownTasks.toggle(in: session.text, index: index) else {
                showToast("not connected yet — try again in a moment", tone: .warning)
                return
            }
            // Through the fan-out: every editor pane on the note sees it.
            fanout(for: session).applyExternal([edit])
        }
    }

    /// Ex commands the editor hands to the app (`:preview`, `:preview
    /// split`, `:settings`, `\p`).
    func performHostCommand(_ command: String) {
        if performPaneHostCommand(command.trimmingCharacters(in: .whitespaces)) { return }
        switch command.trimmingCharacters(in: .whitespaces) {
        case "preview split", "preview s":
            toggleSplitPreview()
        case "preview":
            setEditing(!isEditing)
        case "settings":
            showSettings = true
        case "live":
            setNoteViewMode(.live)
        case "source":
            setNoteViewMode(.source)
        default:
            showToast("unknown command: \(command)", tone: .warning)
        }
    }

    /// `\p`, `:preview split`, the note bar button, the palette.
    func toggleSplitPreview() {
        // The split preview sits beside Source.
        if isNoteOpen, noteViewMode != .source {
            setNoteViewMode(.source)
            setSplitPreview(true)
            return
        }
        setSplitPreview(!splitPreviewShown)
    }

    var openFolderPath: String {
        guard let path = openNotePath else { return "" }
        return NoteTree.dirOf(NoteTree.normalizePath(path))
    }

    /// Note bar: rename the open note in place (title + file for local
    /// notes; the title for server notes, like `r` in the explorer).
    func renameOpenNote(to input: String) {
        renamingTitle = false
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != openNoteTitle else { return }
        if let entry = selectedEntry, let session {
            do {
                if editor.isDirty { editor.save() }
                let newURL = try FileOperations.rename(at: entry.url, to: name)
                let dir = NoteTree.dirOf(entry.relativePath)
                let rel = (dir.isEmpty ? "" : dir + "/") + newURL.lastPathComponent
                let ne = NoteEntry(url: newURL, relativePath: rel, updatedAt: Date())
                _ = session
                bookMemory.forget(entry.relativePath, inBook: openBook?.id ?? "")
                bindPrimaryLocal(path: rel, url: newURL)
                selectedNoteID = rel
                selectedEntry = ne
                explorer.rescanLocal(reveal: rel)
            } catch {
                showToast(describe(error), tone: .error)
            }
            return
        }
        if let id = selectedRemoteNoteID {
            guard requireOnline("renaming notes") else { return }
            guard can("note.write") else {
                showToast("you can't rename notes in this book (note.write)", tone: .warning)
                return
            }
            Task {
                do {
                    _ = try await remoteVaultsStore.updateNoteMeta(noteID: id, title: name)
                    explorer.updateRemote(notes: remoteVaultsStore.notes, loading: false)
                } catch {
                    showToast(describe(error), tone: .error)
                }
            }
        }
    }
}
