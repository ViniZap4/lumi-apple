import Foundation

/// One discrete input event into the vim engine. Higher-level inputs (key
/// chords, modifier-only events) are decomposed into a stream of these by the
/// UI bridge.
public enum VimInput: Sendable, Hashable {
    /// A printable character. The engine routes it through the active mode.
    case character(Character)

    /// Escape key — exits insert/visual mode, cancels pending operator/count.
    case escape

    /// Return / Enter key — newline in insert mode, line down in normal.
    case `return`

    /// Backspace — character delete in insert, `h` (wrapping) in normal.
    case backspace

    /// Forward delete (`<Del>`) — `x` in normal, delete under cursor in insert.
    case delete

    /// Tab — inserts a tab (or spaces with `expandtab`) in insert mode.
    case tab

    /// Ctrl-R — redo in normal mode, insert register in insert mode.
    case controlR

    /// Ctrl-D — half-page down in normal, de-indent in insert.
    case controlD

    /// Ctrl-U — half-page up in normal, delete to line start in insert.
    case controlU

    /// Any other Ctrl chord, by its lower-case base key (`w` for Ctrl-W).
    /// Ctrl-R / Ctrl-D / Ctrl-U keep their dedicated cases above.
    case control(Character)

    /// Up arrow while in command-line mode — recall older history entry.
    case historyPrev

    /// Down arrow while in command-line mode — step toward newer entries.
    case historyNext

    /// An arrow key. Normal/visual: the `h`/`j`/`k`/`l` motion. Insert:
    /// moves the cursor without typing. Command-line: up/down walk history.
    case arrow(ArrowDirection)
}

public enum ArrowDirection: Sendable, Hashable {
    case left, right, up, down

    /// The equivalent normal-mode motion key.
    public var motionCharacter: Character {
        switch self {
        case .left: return "h"
        case .right: return "l"
        case .up: return "k"
        case .down: return "j"
        }
    }
}

public extension VimInput {
    /// The printable character, if any.
    var char: Character? {
        if case let .character(c) = self { return c }
        return nil
    }

    /// The base key of a Ctrl chord (`r` for Ctrl-R), if any.
    var ctrl: Character? {
        switch self {
        case .controlR: return "r"
        case .controlD: return "d"
        case .controlU: return "u"
        case let .control(c): return c
        default: return nil
        }
    }

    /// Build the input for Ctrl+`base` (legacy cases for r/d/u, `[` and
    /// `c` are Escape).
    static func ctrl(_ base: Character) -> VimInput {
        switch Character(base.lowercased()) {
        case "r": return .controlR
        case "d": return .controlD
        case "u": return .controlU
        case "[", "c": return .escape
        case let c: return .control(c)
        }
    }

    /// Vim key notation (`a`, `<CR>`, `<C-w>`, `<Space>`), used by the
    /// legend, `:map` listings and `:registers`.
    var notation: String {
        switch self {
        case let .character(c):
            switch c {
            case " ": return "<Space>"
            case "<": return "<lt>"
            default: return String(c)
            }
        case .escape: return "<Esc>"
        case .return: return "<CR>"
        case .backspace: return "<BS>"
        case .delete: return "<Del>"
        case .tab: return "<Tab>"
        case .historyPrev: return "<Up>"
        case .historyNext: return "<Down>"
        case let .arrow(d):
            switch d {
            case .left: return "<Left>"
            case .right: return "<Right>"
            case .up: return "<Up>"
            case .down: return "<Down>"
            }
        default:
            if let c = ctrl { return "<C-\(c)>" }
            return ""
        }
    }

    /// Compact display for pending keys (`"a2d`, `^W`, `␣`).
    var display: String {
        switch self {
        case let .character(c): return c == " " ? "␣" : String(c)
        case .escape: return "⎋"
        case .return: return "⏎"
        case .backspace: return "⌫"
        case .tab: return "⇥"
        default:
            if let c = ctrl { return "^" + c.uppercased() }
            return notation
        }
    }

    /// Parse normalised key notation (the output of
    /// `Vimrc.normalizeKeys`) into inputs. Keys the engine cannot receive
    /// (function keys, Home/End, Alt chords) return nil — a mapping using
    /// them could never fire.
    static func parse(notation: String) -> [VimInput]? {
        var out: [VimInput] = []
        let chars = Array(notation)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">"), close > i + 1 {
                let body = String(chars[(i + 1)..<close])
                if let key = namedKey(body) {
                    out.append(key)
                    i = close + 1
                    continue
                }
                if body.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil, body.count > 1 {
                    // A key name we can't receive.
                    return nil
                }
            }
            out.append(.character(c))
            i += 1
        }
        return out
    }

    private static func namedKey(_ body: String) -> VimInput? {
        switch body {
        case "CR": return .return
        case "Esc": return .escape
        case "Space": return .character(" ")
        case "Tab": return .tab
        case "BS": return .backspace
        case "Del": return .delete
        case "lt": return .character("<")
        case "Up": return .arrow(.up)
        case "Down": return .arrow(.down)
        case "Left": return .arrow(.left)
        case "Right": return .arrow(.right)
        default: break
        }
        if body.hasPrefix("C-"), body.count == 3, let k = body.last {
            return .ctrl(k)
        }
        return nil
    }
}

public extension Array where Element == VimInput {
    /// Keys as vim notation (`dw`, `ci"`, `<C-w>`).
    var notation: String { map(\.notation).joined() }
    /// Keys as compact display text.
    var display: String { map(\.display).joined() }
}
