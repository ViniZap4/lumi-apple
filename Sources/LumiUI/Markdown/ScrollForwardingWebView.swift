import Foundation
import WebKit

#if canImport(AppKit)
import AppKit

/// WKWebView subclass that bubbles scroll-wheel events up to its next
/// responder instead of consuming them for internal scrolling. Required
/// because the standard WKWebView's internal NSScrollView swallows every
/// `scrollWheel(with:)` event the moment the cursor is over the WebView
/// — even when the embedded content fits without scrolling. That broke
/// the read-pane's outer NSScrollView (`NativeScrollHost`): the user's
/// trackpad / mouse-wheel input never reached the host because the
/// hosted KaTeX / Mermaid / iframe WebViews ate it first.
///
/// Trade-off: this gives up the ability to scroll *inside* the WebView's
/// content. For everything we host (KaTeX glyphs, Mermaid diagrams sized
/// to their measured height, YouTube iframes that have their own player
/// chrome) that's the right call — the wrapping SwiftUI host already
/// sizes them to fit, and surrendering inner-scroll keeps the page-level
/// scroll continuous.
///
/// Used by `KaTeXBlockView`, `KaTeXParagraphView`, `MermaidView`, and
/// `EmbedMediaView` — every place we put a WKWebView inside the read
/// pane.
final class ScrollForwardingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// iOS / iPadOS / visionOS sibling. UITouch-based scrolling doesn't
/// suffer the AppKit pass-through issue (the outer ScrollView and the
/// inner WKWebView negotiate via the gesture-recognizer system), but we
/// still want a single place that knobs "scroll lives in the host, not
/// the embed" for parity. Subclasses can disable the internal scroll
/// after construction (`webView.scrollView.isScrollEnabled = false`)
/// since UIView equivalent of NSResponder forwarding isn't necessary.
typealias ScrollForwardingWKWebView = WKWebView
#endif
