import Foundation

// Canvas keyboard model (SPEC-PARTE2 §6), pure — port of web-client
// `lib/canvas/canvas-keys.ts`.
//
//   Tab / S-Tab     next / previous node (reading order)
//   Enter           edit text node / group label, open file or link node
//   gf              open file node        C-w f   open it in a split
//   h j k l, arrows pan                   H J K L  move the selected node (S-arrows too)
//   + / =  -  0     zoom in / out / fit   a        new text node
//   f               new file node (note picker)
//   d, x, Backspace, Delete  delete selection
//   c 1..6 / c 0    color / clear color   (Enter on a selected edge edits its label)
//   u / C-r         undo / redo           Esc      clear selection

public enum CanvasKeyAction: Sendable, Equatable {
    case cycle(dir: Int)
    case activate
    case openFile(split: Bool)
    case pan(dx: Double, dy: Double)
    case nudge(dx: Double, dy: Double)
    case zoom(factor: Double)
    case fit
    case addText
    case addFile
    case delete
    case color(String?)
    case undo
    case redo
    case escape
}

public struct CanvasKeys: Sendable {
    public static let panStep = 80.0
    public static let nudgeStep = 20.0

    public var pending: String?

    public init() {}

    public mutating func reset() { pending = nil }

    /// `hasSelection`: a node or edge is selected.
    public mutating func feed(_ e: StructuredKey, hasSelection: Bool) -> CanvasKeyAction? {
        if e.meta || e.alt { return nil }
        let k = e.key
        let p = pending
        pending = nil

        if p == "C-w" { return k == "f" || k == "Enter" ? .openFile(split: true) : nil }
        if p == "g" { return k == "f" ? .openFile(split: false) : nil }
        if p == "c" {
            if k.count == 1, let n = Int(k), (1...6).contains(n) { return .color(k) }
            if k == "0" { return .color(nil) }
            return nil
        }

        if e.ctrl {
            if k == "w" {
                pending = "C-w"
                return nil
            }
            if k == "r" { return .redo }
            return nil
        }

        // Panning moves the view: content shifts opposite to the key.
        func pan(_ dx: Double, _ dy: Double) -> CanvasKeyAction {
            .pan(dx: dx == 0 ? 0 : -dx * Self.panStep, dy: dy == 0 ? 0 : -dy * Self.panStep)
        }
        func nudge(_ dx: Double, _ dy: Double) -> CanvasKeyAction {
            hasSelection ? .nudge(dx: dx * Self.nudgeStep, dy: dy * Self.nudgeStep) : pan(dx, dy)
        }

        switch k {
        case "Tab": return .cycle(dir: e.shift ? -1 : 1)
        case "Enter": return hasSelection ? .activate : nil
        case "g":
            pending = "g"
            return nil
        case "c":
            if !hasSelection { return nil }
            pending = "c"
            return nil
        case "h": return pan(-1, 0)
        case "l": return pan(1, 0)
        case "j": return pan(0, 1)
        case "k": return pan(0, -1)
        case "ArrowLeft": return e.shift ? nudge(-1, 0) : pan(-1, 0)
        case "ArrowRight": return e.shift ? nudge(1, 0) : pan(1, 0)
        case "ArrowDown": return e.shift ? nudge(0, 1) : pan(0, 1)
        case "ArrowUp": return e.shift ? nudge(0, -1) : pan(0, -1)
        case "H": return hasSelection ? nudge(-1, 0) : nil
        case "L": return hasSelection ? nudge(1, 0) : nil
        case "J": return hasSelection ? nudge(0, 1) : nil
        case "K": return hasSelection ? nudge(0, -1) : nil
        case "+", "=": return .zoom(factor: 1.2)
        case "-", "_": return .zoom(factor: 1 / 1.2)
        case "0": return .fit
        case "a": return .addText
        case "f": return .addFile
        case "d", "x", "Backspace", "Delete": return hasSelection ? .delete : nil
        case "u": return .undo
        case "Escape": return .escape
        default: return nil
        }
    }
}
