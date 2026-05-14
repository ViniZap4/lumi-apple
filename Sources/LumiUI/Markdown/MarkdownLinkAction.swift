import SwiftUI

/// Closure the markdown renderer hands link clicks to. Returns `true` if
/// the caller fully handled the URL (no system fallback); `false` to let
/// AppKit/UIKit open the URL via the normal channel (https → browser,
/// mailto → mail, etc.).
///
/// Defaults to "I don't handle this; system, take it." so any view that
/// doesn't explicitly install a handler still works for external links.
public struct MarkdownLinkAction: Sendable {
    public let handle: @MainActor @Sendable (URL) -> Bool

    public init(handle: @escaping @MainActor @Sendable (URL) -> Bool) {
        self.handle = handle
    }

    public static let systemDefault = MarkdownLinkAction { _ in false }
}

public struct MarkdownLinkActionKey: EnvironmentKey {
    public static let defaultValue: MarkdownLinkAction = .systemDefault
}

public extension EnvironmentValues {
    /// Per-render link-click handler. The reader (`NoteDetailView`)
    /// installs an action that intercepts `file://*.md` URLs and
    /// re-routes them to the in-app note loader; everything else
    /// returns false so the system takes over.
    var markdownLinkAction: MarkdownLinkAction {
        get { self[MarkdownLinkActionKey.self] }
        set { self[MarkdownLinkActionKey.self] = newValue }
    }
}
