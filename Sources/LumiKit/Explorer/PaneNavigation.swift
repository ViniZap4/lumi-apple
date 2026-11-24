import Foundation

/// A keyboard-focusable pane of the shell (vim windows /
/// vim-tmux-navigator): the books sidebar, the main area (explorer,
/// reader or editor) and the split preview beside the editor.
public enum PaneID: String, Sendable, Hashable, CaseIterable {
    case sidebar, explorer, reader, editor, preview

    /// Short name for the status line / toasts.
    public var label: String {
        switch self {
        case .sidebar: return "books"
        case .explorer: return "explorer"
        case .reader: return "reader"
        case .editor: return "editor"
        case .preview: return "preview"
        }
    }
}

public enum PaneDirection: Sendable, Hashable { case left, down, up, right }

/// What a pane key asks for: `⌃h/j/k/l`, `⌃w h/j/k/l`, `⌃w w` / `⌃w W`
/// (cycle) and `⌃w p` (previous pane).
public enum PaneCommand: Sendable, Hashable {
    case move(PaneDirection)
    case next
    case previous
    case last
    /// `⌃w q` / `⌃w c`: close the pane (the last one closes the note).
    case close
    /// `⌃w o`: keep only the focused pane.
    case only
    /// `⌃w =`: equal sizes.
    case equalize
    /// `⌃w v` (vertical, side by side) / `⌃w s` (horizontal, stacked):
    /// split the focused pane on the same note.
    case split(SplitAxis)
    /// `⌃w f` / `⌃w Enter` (vertical split), `⌃w F` (horizontal): follow
    /// the link under the cursor / the focused link into a new pane.
    case follow(LinkOpenWhere)
    /// `⌃w >` `<` (`.vertical`: wider / narrower), `⌃w +` `-`
    /// (`.horizontal`: taller / shorter). `steps` is ±1 (× a count).
    case resize(SplitAxis, Int)
    /// `⌃w z` / `:zoom`: zoom the focused pane to the whole note area, or
    /// back (tmux `prefix z`).
    case zoom

    /// Commands that change the layout rather than move focus.
    public var isLayout: Bool {
        switch self {
        case .move, .next, .previous, .last: return false
        default: return true
        }
    }
}

/// What is on screen, as far as pane focus is concerned.
public struct PaneLayout: Sendable, Hashable {
    /// How the split preview shows beside the editor.
    public enum Preview: Sendable, Hashable {
        case none
        /// Side by side (wide window): the preview is right of the editor.
        case beside
        /// Narrow window / iPhone: Source | Preview tabs. The preview
        /// counts as the pane *below* the editor.
        case tabbed
    }

    public var sidebarVisible: Bool
    /// The sidebar can be revealed (⌃h at the left edge opens it).
    public var sidebarAvailable: Bool
    /// The main area's pane: `.explorer`, `.reader` or `.editor`; nil
    /// when nothing is open.
    public var main: PaneID?
    public var preview: Preview

    public init(sidebarVisible: Bool = false, sidebarAvailable: Bool = true, main: PaneID? = nil, preview: Preview = .none) {
        self.sidebarVisible = sidebarVisible
        self.sidebarAvailable = sidebarAvailable
        self.main = main
        self.preview = main == .editor ? preview : .none
    }
}

/// Where a pane command lands.
public struct PaneTarget: Sendable, Hashable {
    public var pane: PaneID
    /// The sidebar was hidden: show it (a drawer — leaving it hides it
    /// again).
    public var revealsSidebar: Bool

    public init(_ pane: PaneID, revealsSidebar: Bool = false) {
        self.pane = pane
        self.revealsSidebar = revealsSidebar
    }
}

/// The focus graph. Pure: given the layout and the focused pane, where
/// does a pane command go? nil = nowhere (the caller lets the key keep
/// its ordinary meaning — `⌃j` scrolls / moves down, in the editor it is
/// vim's own `⌃j`).
///
/// Geometry: sidebar | main | preview (beside), or main above preview
/// (tabbed).
public enum PaneGraph {
    /// Visible panes in cycle order (left → right, top → bottom).
    public static func panes(_ layout: PaneLayout) -> [PaneID] {
        var out: [PaneID] = []
        if layout.sidebarVisible { out.append(.sidebar) }
        if let main = layout.main {
            out.append(main)
            if main == .editor, layout.preview != .none { out.append(.preview) }
        }
        return out
    }

    /// The pane that really has focus: `focused` when it is on screen,
    /// else the main pane (or the sidebar when nothing else shows).
    public static func resolve(_ focused: PaneID?, in layout: PaneLayout) -> PaneID? {
        let visible = panes(layout)
        if let focused, visible.contains(focused) { return focused }
        return layout.main ?? visible.first
    }

    public static func target(from focused: PaneID?, _ command: PaneCommand, layout: PaneLayout, previous: PaneID? = nil) -> PaneTarget? {
        guard let from = resolve(focused, in: layout) else {
            // Nothing open, sidebar hidden: ⌃h still opens the drawer.
            if case .move(.left) = command, layout.sidebarAvailable, !layout.sidebarVisible {
                return PaneTarget(.sidebar, revealsSidebar: true)
            }
            return nil
        }
        let visible = panes(layout)
        switch command {
        case let .move(direction):
            return move(from, direction, layout: layout)
        case .next, .previous:
            guard visible.count > 1, let i = visible.firstIndex(of: from) else { return nil }
            let step = command == .next ? 1 : -1
            return PaneTarget(visible[(i + step + visible.count) % visible.count])
        case .close, .only, .equalize, .split, .follow, .resize, .zoom:
            // Layout commands: the pane tree handles them, not focus.
            return nil
        case .last:
            guard let previous, previous != from else { return nil }
            if visible.contains(previous) { return PaneTarget(previous) }
            if previous == .sidebar, layout.sidebarAvailable { return PaneTarget(.sidebar, revealsSidebar: true) }
            return nil
        }
    }

    private static func move(_ from: PaneID, _ direction: PaneDirection, layout: PaneLayout) -> PaneTarget? {
        let leftEdge: PaneTarget? = {
            if layout.sidebarVisible { return PaneTarget(.sidebar) }
            if layout.sidebarAvailable { return PaneTarget(.sidebar, revealsSidebar: true) }
            return nil
        }()
        switch (from, direction) {
        case (.sidebar, .right):
            return layout.main.map { PaneTarget($0) }
        case (.sidebar, _):
            return nil
        case (.preview, .left):
            return layout.preview == .beside ? PaneTarget(.editor) : leftEdge
        case (.preview, .up):
            return layout.preview == .tabbed ? PaneTarget(.editor) : nil
        case (.preview, _):
            return nil
        case (_, .left):
            return leftEdge
        case (.editor, .right):
            return layout.preview == .beside ? PaneTarget(.preview) : nil
        case (.editor, .down):
            return layout.preview == .tabbed ? PaneTarget(.preview) : nil
        default:
            return nil
        }
    }
}

/// Editor side of pane navigation: decides, per key, whether the vim
/// editor keeps it or it moves focus. Pure.
///
/// - NORMAL / VISUAL (idle — no count, operator or half-typed mapping):
///   `⌃h ⌃j ⌃k ⌃l` move panes when `ctrlHJKL` is on (they are only
///   `h`/`j`/`k`/`l` duplicates in vim). With no pane that way the key
///   is consumed (web parity).
/// - `⌃w` + `h j k l` (or `⌃h …`, arrows), `w`/`⌃w` next, `W` previous,
///   `p` last: vim's window commands, always on.
/// - INSERT / REPLACE / command-line: untouched (`⌃h` backspace, `⌃j`
///   newline, `⌃w` delete word).
/// - A `.vimrc` mapping whose lhs starts with the key wins — except a
///   map onto a window command (`nnoremap <C-h> <C-w>h`), which becomes
///   that pane move. Any `<C-w>…` map hands `⌃w` back to vim.
public struct EditorPaneKeys: Sendable {
    public enum Outcome: Sendable, Hashable {
        /// Not a pane key: send it to the engine.
        case pass
        /// Swallowed (`⌃w` prefix, a cancelled `⌃w` chord).
        case consume
        /// A pane command. `passIfUnhandled`: when no pane lies that way,
        /// send the key to the engine after all.
        case pane(PaneCommand, passIfUnhandled: Bool)
    }

    public var ctrlHJKL: Bool
    public private(set) var awaitingWindowCommand = false

    public init(ctrlHJKL: Bool = true) {
        self.ctrlHJKL = ctrlHJKL
    }

    public mutating func reset() { awaitingWindowCommand = false }

    public mutating func feed(_ input: VimInput, state: VimState) -> Outcome {
        if awaitingWindowCommand {
            awaitingWindowCommand = false
            if let command = Self.windowCommand(input) { return .pane(command, passIfUnhandled: false) }
            return .consume
        }
        guard Self.isIdle(state), let c = input.ctrl else { return .pass }
        let mode: VimMapping.Mode = state.mode.isVisual ? .visual : .normal
        let maps = state.mappings.filter { $0.exAlias == nil && $0.lhs.first == input && $0.applies(in: mode) }
        if !maps.isEmpty {
            // `map <C-h> <C-w>h`: the user spelled out the pane move.
            if maps.count == 1, maps[0].lhs == [input], maps[0].rhs.count == 2, maps[0].rhs[0].ctrl == "w",
               let command = Self.windowCommand(maps[0].rhs[1]) {
                return .pane(command, passIfUnhandled: false)
            }
            return .pass
        }
        if c == "w" {
            awaitingWindowCommand = true
            return .consume
        }
        guard ctrlHJKL, let direction = Self.direction(c) else { return .pass }
        return .pane(.move(direction), passIfUnhandled: false)
    }

    /// Normal or visual mode with nothing half-typed.
    public static func isIdle(_ state: VimState) -> Bool {
        guard state.mode == .normal || state.mode.isVisual else { return false }
        return state.pendingKeys.isEmpty && state.mapPending.isEmpty
            && state.substituteConfirm == nil && state.insertOneShot == 0
    }

    static func direction(_ c: Character) -> PaneDirection? {
        switch c {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        default: return nil
        }
    }

    /// The key after `⌃w`.
    static func windowCommand(_ input: VimInput) -> PaneCommand? {
        switch input {
        case let .arrow(a):
            switch a {
            case .left: return .move(.left)
            case .right: return .move(.right)
            case .up: return .move(.up)
            case .down: return .move(.down)
            }
        case .backspace: return .move(.left)  // ⌃w ⌃h arrives as <BS> on some layouts
        case .return: return .follow(.vsplit)
        case let .character(c):
            if let d = direction(c) { return .move(d) }
            return PaneCommand.windowLetter(c)
        default:
            guard let c = input.ctrl else { return nil }
            if let d = direction(c) { return .move(d) }
            switch c {
            case "w": return .next
            case "p": return .last
            case "q", "c": return .close
            case "o": return .only
            case "v": return .split(.vertical)
            case "s": return .split(.horizontal)
            case "f": return .follow(.vsplit)
            default: return nil
            }
        }
    }
}

extension PaneCommand {
    /// A printed key after `⌃w` (case matters: `f` vs `F`). Shared by the
    /// shell keymap and the editor (web `winCommand`).
    public static func windowLetter(_ c: Character) -> PaneCommand? {
        switch c {
        case "w": return .next
        case "W": return .previous
        case "p": return .last
        case "q", "c": return .close
        case "o": return .only
        case "=": return .equalize
        case "v": return .split(.vertical)
        case "s", "S": return .split(.horizontal)
        case "f": return .follow(.vsplit)
        case "F": return .follow(.hsplit)
        case ">": return .resize(.vertical, 1)
        case "<": return .resize(.vertical, -1)
        case "+": return .resize(.horizontal, 1)
        case "-": return .resize(.horizontal, -1)
        case "z": return .zoom
        default: return nil
        }
    }
}
