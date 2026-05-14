import Foundation

#if canImport(AppKit)
import AppKit
import ObjectiveC.runtime

/// Silences the system "you pressed a key with no binding" beep
/// (NSBeep) by replacing `NSResponder.noResponderFor(_:)` with a
/// no-op. AppKit calls that method at the end of the keyDown
/// responder-chain walk when no responder claims the event, and the
/// stock implementation invokes NSBeep().
///
/// Going lower-level than `NSEvent.addLocalMonitorForEvents` here is
/// deliberate: SwiftUI's internal event monitors (sidebar typeahead,
/// command-palette navigation) consume keys *and beep on no-match*
/// before yielding to our monitor, so returning `nil` from our
/// monitor was racing a beep that had already played.
///
/// Method swizzling is permanent for the process — install once at
/// app start. Anything that *would* have beeped is silently dropped
/// (the responder chain still walks normally; we just don't ring the
/// bell at the end).
enum BeepSilencer {
    @MainActor
    private static var installed = false

    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true

        let cls = NSResponder.self
        let originalSelector = NSSelectorFromString("noResponderFor:")
        let swizzledSelector = #selector(NSResponder.lumi_silentNoResponderFor(_:))
        guard let original = class_getInstanceMethod(cls, originalSelector),
              let swizzled = class_getInstanceMethod(cls, swizzledSelector)
        else { return }
        // Try to add our replacement first; if NSResponder doesn't
        // implement the original (unlikely), `class_addMethod` succeeds
        // and the original ends up as the swap target. Otherwise we
        // just exchange in place.
        let added = class_addMethod(
            cls,
            originalSelector,
            method_getImplementation(swizzled),
            method_getTypeEncoding(swizzled)
        )
        if added {
            class_replaceMethod(
                cls,
                swizzledSelector,
                method_getImplementation(original),
                method_getTypeEncoding(original)
            )
        } else {
            method_exchangeImplementations(original, swizzled)
        }
    }
}

extension NSResponder {
    /// Replacement for `NSResponder.noResponderFor(_:)` installed by
    /// `BeepSilencer`. Intentionally empty — that's the whole point.
    @objc dynamic func lumi_silentNoResponderFor(_ eventSelector: Selector) {
        // No-op: silence the system beep.
    }
}
#endif
