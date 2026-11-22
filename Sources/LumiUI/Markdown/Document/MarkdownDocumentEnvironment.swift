import SwiftUI

#if canImport(AppKit)
import AppKit
/// Scroll view hosting the read-mode document.
public typealias MarkdownPlatformScrollView = NSScrollView
#else
import UIKit
public typealias MarkdownPlatformScrollView = UIScrollView
#endif

/// Hands the reader's scroll view to the host (the app's read-mode
/// keyboard scroll controller) once it exists. The reader owns its
/// scroll view now — it is a TextKit document view, not SwiftUI content
/// wrapped in somebody else's `NSScrollView`.
public struct MarkdownScrollViewSink {
    public let attach: @MainActor (MarkdownPlatformScrollView) -> Void

    public init(attach: @escaping @MainActor (MarkdownPlatformScrollView) -> Void) {
        self.attach = attach
    }
}

public extension EnvironmentValues {
    /// See `MarkdownScrollViewSink`.
    @Entry var markdownScrollViewSink: MarkdownScrollViewSink? = nil
    /// iOS / visionOS: hardware-keyboard j/k/d/u/g/G/space scrolling in
    /// the read pane (macOS routes these through the app's key monitor).
    @Entry var markdownKeyboardScrolling: Bool = true
}
