import Foundation

/// A folder in a vault — recursive tree node. Mirrors `domain.Folder` in the Go
/// codebase. Sub-folders and notes are kept separate so the UI can render them
/// distinctly without re-walking the tree.
public struct Folder: Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var path: String
    public var subfolders: [Folder]
    public var notes: [Note]

    public init(
        id: String,
        name: String,
        path: String,
        subfolders: [Folder] = [],
        notes: [Note] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.subfolders = subfolders
        self.notes = notes
    }
}
