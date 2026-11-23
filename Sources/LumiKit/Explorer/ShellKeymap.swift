import Foundation

/// One key press, platform-neutral. The macOS key router builds it from
/// an `NSEvent`, the iOS views from a SwiftUI `KeyPress`.
public struct KeyStroke: Sendable, Equatable {
    public enum Special: Sendable, Equatable {
        case up, down, left, right, enter, escape, backspace, tab
        case pageUp, pageDown, home, end
        /// Shift+F10 / the context-menu key.
        case menu
    }

    /// Printed character(s) with shift applied (`G`, `?`, `~`). nil for
    /// special keys.
    public var chars: String?
    public var special: Special?
    public var control: Bool
    public var command: Bool
    public var option: Bool

    public init(_ chars: String? = nil, special: Special? = nil, control: Bool = false, command: Bool = false, option: Bool = false) {
        self.chars = chars
        self.special = special
        self.control = control
        self.command = command
        self.option = option
    }

    public static func char(_ c: String, control: Bool = false) -> KeyStroke { KeyStroke(c, control: control) }
    public static func key(_ s: Special) -> KeyStroke { KeyStroke(nil, special: s) }
}

/// What a key does in the app shell (explorer + reader). The note editor
/// is not routed through here: it owns its keys (vim engine).
public enum ShellAction: Sendable, Equatable {
    // Cursor / scrolling
    case move(Int)
    case halfPage(Int)
    case page(Int)
    case top
    case bottom
    // Columns
    case parent          // h ← - ⌫ : up one folder (reader: back to explorer)
    case open            // l → ⏎   : descend / open note
    case historyBack     // H
    case historyForward  // L
    case home            // ~ gh zh
    // Filter
    case filter          // /
    case nextMatch       // n
    case prevMatch       // N
    case clearOrBack     // Esc
    // Files
    case create          // a
    case rename          // r
    case delete          // d
    case yank            // y
    case paste           // p
    case toggleHidden    // .
    case togglePreview   // zp
    case refresh         // R
    case edit            // i e
    // Shell
    case palette         // space
    case command         // :
    case help            // ?
    case book(Int)       // g1–g9, ⌃1–⌃9
    case prevBook        // [
    case nextBook        // ]
    case close           // q (reader)
    case settings        // , (explorer)
    case hints           // f (explorer) / F (explorer, reader)
    case contextMenu     // Shift+F10
    // Panes (vim windows / vim-tmux-navigator)
    /// `⌃h ⌃j ⌃k ⌃l`: move focus that way; when no pane lies there the
    /// key keeps its ordinary meaning (`⌃j`/`⌃k` move / scroll).
    case paneKey(PaneDirection)
    /// `⌃w h/j/k/l`, `⌃w w`, `⌃w W`, `⌃w p`.
    case pane(PaneCommand)
    // Reading (reader / split preview)
    case nextHeading     // } ]]
    case prevHeading     // { [[
    case find            // / (reader, preview)
    /// First key of a chord (`g`, `z`) or a count digit: consumed, no-op.
    case pending
}

/// Stateful key → action reader for the explorer and the reader. Mirrors
/// the web client's `GChord` (`g1`–`g9`, `gg`, `gh`, `zh`, `zp`) plus the
/// yazi keymap (`a` create, `r` rename, `d` delete, `y`/`p`, `.`, `~`).
/// A count prefix (`5j`) multiplies movement.
public struct ShellKeymap: Sendable {
    public enum Context: Sendable, Equatable {
        case explorer, reader
        /// The split preview beside the editor, focused for reading.
        case preview
        /// The books sidebar, focused.
        case sidebar
    }

    /// `⌃h ⌃j ⌃k ⌃l` move between panes (setting, default on). `⌃w`
    /// chords always do.
    public var ctrlHJKLPanes = true

    /// Prefix sentinel for `⌃w`.
    static let ctrlW: Character = "\u{17}"

    /// Seconds a `g`/`z` prefix stays armed (web: 500 ms).
    public static let chordTimeout: TimeInterval = 0.8

    private var prefix: Character?
    private var prefixAt: TimeInterval = 0
    private var count: Int?

    public init() {}

    public mutating func reset() {
        prefix = nil
        count = nil
    }

    /// Keys typed but not yet resolved (`5`, `g`, `5g`) — the legend shows
    /// their continuations.
    public var pendingDisplay: String {
        (count.map(String.init) ?? "") + (prefix.map { $0 == Self.ctrlW ? "^W" : String($0) } ?? "")
    }

    /// Returns nil when the key is not bound in `context` (the caller lets
    /// it through to the system).
    public mutating func feed(_ k: KeyStroke, context: Context, now: TimeInterval) -> ShellAction? {
        // Command-modified keys belong to the menu bar.
        if k.command || k.option { reset(); return nil }

        // Second key of `⌃w` (vim waits for it; no timeout).
        if prefix == Self.ctrlW {
            reset()
            return Self.windowCommand(k).map { .pane($0) } ?? .pending
        }

        if k.control {
            reset()
            guard let c = k.chars?.lowercased() else { return nil }
            if let n = Int(c), (1...9).contains(n) { return .book(n) }
            if c == "w" {
                prefix = Self.ctrlW
                prefixAt = now
                return .pending
            }
            if ctrlHJKLPanes, let d = Self.direction(c) { return .paneKey(d) }
            switch c {
            case "d": return .halfPage(1)
            case "u": return .halfPage(-1)
            case "f": return .page(1)
            case "b": return .page(-1)
            case "n": return .move(1)
            case "p": return .move(-1)
            default: return nil
            }
        }

        if let special = k.special {
            let n = takeCount()
            prefix = nil
            switch special {
            case .down: return .move(n)
            case .up: return .move(-n)
            case .left, .backspace: return .parent
            case .right, .enter: return .open
            case .escape: return .clearOrBack
            case .pageDown: return .page(1)
            case .pageUp: return .page(-1)
            case .home: return .top
            case .end: return .bottom
            case .tab: return nil
            case .menu: return context == .explorer ? .contextMenu : nil
            }
        }

        guard let s = k.chars, s.count == 1, let ch = s.first else { reset(); return nil }

        // Second key of a chord.
        if let p = prefix {
            prefix = nil
            let armed = now - prefixAt < Self.chordTimeout
            if armed {
                if p == "g" {
                    if let n = Int(String(ch)), (1...9).contains(n) { count = nil; return .book(n) }
                    switch ch {
                    case "g": count = nil; return .top
                    case "h": count = nil; return .home
                    case "e": count = nil; return .bottom
                    default: break
                    }
                } else if p == "[" || p == "]" {
                    if ch == p { count = nil; return p == "[" ? .prevHeading : .nextHeading }
                } else if p == "z" {
                    switch ch {
                    case "h": count = nil; return .home
                    case "p": count = nil; return .togglePreview
                    default: break
                    }
                }
            }
            // Unknown second key: fall through and treat it on its own.
        }

        // Count prefix (no digit is bound on its own; `0` only extends).
        if let d = Int(String(ch)), ch.isASCII, d > 0 || count != nil {
            count = min(9999, (count ?? 0) * 10 + d)
            return .pending
        }

        if context == .preview, ch == " " { count = nil; return .page(1) }
        if context == .preview, ch == "[" || ch == "]" {
            prefix = ch
            prefixAt = now
            return .pending
        }

        switch ch {
        case "g", "z":
            prefix = ch
            prefixAt = now
            return .pending
        case "j": return .move(takeCount())
        case "k": return .move(-takeCount())
        case "G": count = nil; return .bottom
        case "h", "-": count = nil; return .parent
        case "l": count = nil; return .open
        case "H": count = nil; return .historyBack
        case "L": count = nil; return .historyForward
        case "~": count = nil; return .home
        case ":": count = nil; return .command
        case " ": count = nil; return .palette
        case "?": count = nil; return .help
        case "[": count = nil; return .prevBook
        case "]": count = nil; return .nextBook
        case "i", "e": count = nil; return .edit
        case "R": count = nil; return .refresh
        case "F": count = nil; return .hints
        default: break
        }

        switch context {
        case .explorer:
            count = nil
            switch ch {
            case "/": return .filter
            case "n": return .nextMatch
            case "N": return .prevMatch
            case "a": return .create
            case "r": return .rename
            case "d": return .delete
            case "y": return .yank
            case "p": return .paste
            case ".": return .toggleHidden
            case ",": return .settings
            case "f": return .hints
            case "q": return nil
            default: return nil
            }
        case .reader:
            count = nil
            switch ch {
            case "q": return .close
            case "d": return .halfPage(1)
            case "u": return .halfPage(-1)
            case "f": return .page(1)
            case "b": return .page(-1)
            case "y": return .yank
            case "/": return .find
            case "n": return .nextMatch
            case "N": return .prevMatch
            case "{": return .prevHeading
            case "}": return .nextHeading
            default: return nil
            }
        case .preview:
            count = nil
            switch ch {
            case "q": return .close
            case "d": return .halfPage(1)
            case "u": return .halfPage(-1)
            case "b": return .page(-1)
            case "y": return .yank
            case "f": return .hints
            case "/": return .find
            case "n": return .nextMatch
            case "N": return .prevMatch
            case "{": return .prevHeading
            case "}": return .nextHeading
            default: return nil
            }
        case .sidebar:
            count = nil
            return nil
        }
    }

    static func direction(_ c: String) -> PaneDirection? {
        switch c {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        default: return nil
        }
    }

    /// The key after `⌃w` (vim `CTRL-W h` …, also with ⌃ held).
    static func windowCommand(_ k: KeyStroke) -> PaneCommand? {
        if let special = k.special {
            switch special {
            case .left, .backspace: return .move(.left)
            case .right: return .move(.right)
            case .up: return .move(.up)
            case .down: return .move(.down)
            default: return nil
            }
        }
        guard let s = k.chars, s.count == 1 else { return nil }
        let c = k.control ? s.lowercased() : s
        if let d = direction(c) { return .move(d) }
        switch c {
        case "w": return .next
        case "W": return .previous
        case "p": return .last
        default: return nil
        }
    }

    private mutating func takeCount() -> Int {
        defer { count = nil }
        return max(1, count ?? 1)
    }
}
