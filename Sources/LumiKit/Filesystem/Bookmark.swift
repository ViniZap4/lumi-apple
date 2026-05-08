import Foundation

/// Security-scoped bookmark utilities. On macOS we must request the security
/// scope explicitly; on iOS/visionOS, app-scoped bookmarks are the default.
public enum Bookmark {
    public static func encode(url: URL) throws -> Data {
        let options: URL.BookmarkCreationOptions
        #if os(macOS)
        options = [.withSecurityScope]
        #else
        options = []
        #endif
        return try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public struct Resolved: Sendable {
        public let url: URL
        public let isStale: Bool
    }

    public static func decode(_ data: Data) throws -> Resolved {
        let options: URL.BookmarkResolutionOptions
        #if os(macOS)
        options = [.withSecurityScope]
        #else
        options = []
        #endif
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return Resolved(url: url, isStale: stale)
    }
}

/// Run `body` while a security-scoped resource is accessible. Required around
/// any file I/O on a bookmarked URL on iOS/macOS sandbox.
public func withScopedAccess<T>(to url: URL, body: () throws -> T) rethrows -> T {
    let started = url.startAccessingSecurityScopedResource()
    defer { if started { url.stopAccessingSecurityScopedResource() } }
    return try body()
}
