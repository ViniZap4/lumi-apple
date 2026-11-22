import Foundation
import SwiftData

/// Security-scoped folder bookmark for a local (or mirrored) book. Bookmarks
/// are opaque per-device blobs that cannot live in the shared `books.yaml`,
/// so they sit in this SwiftData side store keyed by `book_id`
/// (SPEC-LIVROS §2.3).
@Model
public final class BookBookmark {
    @Attribute(.unique) public var bookID: String
    public var bookmark: Data

    public init(bookID: String, bookmark: Data) {
        self.bookID = bookID
        self.bookmark = bookmark
    }
}

/// Abstract bookmark side store so `BooksRegistry` is testable without
/// SwiftData.
@MainActor
public protocol BookBookmarkStore: AnyObject {
    func bookmark(for bookID: String) -> Data?
    func setBookmark(_ data: Data, for bookID: String)
    func removeBookmark(for bookID: String)
}

@MainActor
public final class InMemoryBookmarkStore: BookBookmarkStore {
    public private(set) var storage: [String: Data]
    public init(_ initial: [String: Data] = [:]) { storage = initial }
    public func bookmark(for bookID: String) -> Data? { storage[bookID] }
    public func setBookmark(_ data: Data, for bookID: String) { storage[bookID] = data }
    public func removeBookmark(for bookID: String) { storage[bookID] = nil }
}

@MainActor
public final class SwiftDataBookmarkStore: BookBookmarkStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    private func row(_ bookID: String) -> BookBookmark? {
        var descriptor = FetchDescriptor<BookBookmark>(predicate: #Predicate { $0.bookID == bookID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func bookmark(for bookID: String) -> Data? { row(bookID)?.bookmark }

    public func setBookmark(_ data: Data, for bookID: String) {
        if let existing = row(bookID) {
            existing.bookmark = data
        } else {
            context.insert(BookBookmark(bookID: bookID, bookmark: data))
        }
        try? context.save()
    }

    public func removeBookmark(for bookID: String) {
        if let existing = row(bookID) {
            context.delete(existing)
            try? context.save()
        }
    }
}
