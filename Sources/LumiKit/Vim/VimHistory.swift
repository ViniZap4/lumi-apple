import Foundation

/// Stack of buffer snapshots for `u` (undo) and `<C-r>` (redo). Snapshots are
/// taken at the start of each operator / insert session so a single `u` reverts
/// the whole change at once, matching vim's coarse-grained undo.
public struct VimHistory: Sendable, Hashable {
    public struct Snapshot: Sendable, Hashable {
        public let text: String
        public let cursor: Int

        public init(text: String, cursor: Int) {
            self.text = text
            self.cursor = cursor
        }

        public init(buffer: TextBuffer) {
            self.text = buffer.text
            self.cursor = buffer.cursor
        }

        public var asBuffer: TextBuffer {
            TextBuffer(text: text, cursor: cursor)
        }
    }

    public var undo: [Snapshot]
    public var redo: [Snapshot]

    public init(undo: [Snapshot] = [], redo: [Snapshot] = []) {
        self.undo = undo
        self.redo = redo
    }

    /// Push a pre-change snapshot. Discards any redo stack — once you make a
    /// new change, the redo branch becomes unreachable, matching vim's
    /// non-tree undo behavior.
    public mutating func push(_ snapshot: Snapshot) {
        // Avoid pushing duplicate snapshots back-to-back.
        if undo.last != snapshot {
            undo.append(snapshot)
        }
        redo.removeAll(keepingCapacity: true)
    }

    public mutating func popUndo(current: Snapshot) -> Snapshot? {
        guard let last = undo.popLast() else { return nil }
        redo.append(current)
        return last
    }

    public mutating func popRedo(current: Snapshot) -> Snapshot? {
        guard let last = redo.popLast() else { return nil }
        undo.append(current)
        return last
    }
}
