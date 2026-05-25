import Foundation

/// Pending WS reconnect cycle, as published by `RemoteVaultsStore.reconnectStatus`.
///
/// The store sets this when a `.willReconnect` event arrives from
/// `NoteSyncClient` and the host-side decision (see
/// `RemoteVaultsStore.decideReconnect`) settles on an effective attempt
/// number and delay. It's a SwiftUI-side hint, not a control surface —
/// hosts cannot reschedule from this value.
///
/// `scheduledAt` is the wall-clock instant at which the store decided
/// the reconnect; combined with `delaySeconds` it gives a stable target
/// time the UI can poll against (`remainingSeconds(now:)`,
/// `formatHint(now:)`).
///
/// Slice 4f.2.
public struct ReconnectStatus: Sendable, Equatable {
    /// 1-based attempt number for the *upcoming* reconnect (`1` after a
    /// stability reset; otherwise the previous attempt + 1).
    public let attempt: Int
    /// Backoff delay (seconds) chosen by `decideReconnect`. Already
    /// includes ±20% jitter.
    public let delaySeconds: Double
    /// Wall-clock instant at which the store armed this reconnect.
    /// Together with `delaySeconds`, this is the only state the hint
    /// formatter needs.
    public let scheduledAt: Date

    public init(attempt: Int, delaySeconds: Double, scheduledAt: Date) {
        self.attempt = attempt
        self.delaySeconds = delaySeconds
        self.scheduledAt = scheduledAt
    }

    /// Seconds remaining before the scheduled reconnect fires, given
    /// `now`. Clamps at 0 — if the wake-up is overdue the UI should
    /// just say "reconnecting…".
    public func remainingSeconds(now: Date) -> Double {
        let elapsed = now.timeIntervalSince(scheduledAt)
        let remaining = delaySeconds - elapsed
        return max(0, remaining)
    }

    /// Short human-readable hint string. The format is intentionally
    /// terse so the UI can drop it inline next to a spinner:
    ///
    /// - 0 seconds remaining → "Reconnecting…"
    /// - 1 second remaining → "Reconnecting in 1s…"
    /// - rounded up otherwise → "Reconnecting in 3s…"
    ///
    /// Localisation hook: the strings are bare ASCII for now; when
    /// localisation lands, swap the string-builder out for a
    /// `LocalizedStringKey`-backed table without changing the call
    /// sites. Slice 4f.2 keeps it simple.
    public func formatHint(now: Date) -> String {
        let remaining = remainingSeconds(now: now)
        if remaining <= 0 {
            return "Reconnecting…"
        }
        // Ceil so "0.4s left" reads as "1s" rather than "0s" (which
        // would re-trigger "Reconnecting…" before the wake-up actually
        // happens).
        let secs = Int((remaining + 0.999).rounded(.down))
        let display = max(1, secs)
        return "Reconnecting in \(display)s…"
    }
}
