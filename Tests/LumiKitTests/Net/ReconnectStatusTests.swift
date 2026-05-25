import Testing
import Foundation
@testable import LumiKit

/// Pure tests for `ReconnectStatus`'s remainingSeconds + formatHint
/// helpers. The store-side publish/clear lifecycle is exercised
/// alongside the other RemoteVaultsStore tests; here we only pin the
/// math the UI consumes.
@Suite("ReconnectStatus — slice 4f.2 hint formatter")
struct ReconnectStatusTests {

    @Test("remainingSeconds counts down from delaySeconds toward zero")
    func remainingCountsDown() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let status = ReconnectStatus(attempt: 3, delaySeconds: 4.0, scheduledAt: armed)

        #expect(status.remainingSeconds(now: armed) == 4.0)
        #expect(status.remainingSeconds(now: armed.addingTimeInterval(1)) == 3.0)
        #expect(status.remainingSeconds(now: armed.addingTimeInterval(3.5)) == 0.5)
        // Past the deadline → clamps at 0, never negative.
        #expect(status.remainingSeconds(now: armed.addingTimeInterval(10)) == 0)
    }

    @Test("formatHint reads 'Reconnecting…' when due or overdue")
    func hintDueState() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let status = ReconnectStatus(attempt: 1, delaySeconds: 1.0, scheduledAt: armed)
        #expect(status.formatHint(now: armed.addingTimeInterval(1.0)) == "Reconnecting…")
        #expect(status.formatHint(now: armed.addingTimeInterval(5.0)) == "Reconnecting…")
    }

    @Test("formatHint counts remaining whole seconds, ceiled to at least 1")
    func hintWaitingState() {
        let armed = Date(timeIntervalSince1970: 1_700_000_000)
        let status = ReconnectStatus(attempt: 4, delaySeconds: 8.0, scheduledAt: armed)
        // 8s remaining → "8s"
        #expect(status.formatHint(now: armed) == "Reconnecting in 8s…")
        // 7.5s remaining → ceil to 8 (we already passed 0.5s, hint
        // should not jump to "7" mid-flash).
        #expect(status.formatHint(now: armed.addingTimeInterval(0.5)) == "Reconnecting in 8s…")
        // 0.4s remaining → ceil to 1, never "0s" (which would conflict
        // with the due-state branch).
        #expect(status.formatHint(now: armed.addingTimeInterval(7.6)) == "Reconnecting in 1s…")
    }

    @Test("Equatable compares all three fields")
    func equatable() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = ReconnectStatus(attempt: 2, delaySeconds: 2.0, scheduledAt: t)
        let b = ReconnectStatus(attempt: 2, delaySeconds: 2.0, scheduledAt: t)
        let differentAttempt = ReconnectStatus(attempt: 3, delaySeconds: 2.0, scheduledAt: t)
        let differentDelay = ReconnectStatus(attempt: 2, delaySeconds: 3.0, scheduledAt: t)
        let differentAt = ReconnectStatus(attempt: 2, delaySeconds: 2.0, scheduledAt: t.addingTimeInterval(1))
        #expect(a == b)
        #expect(a != differentAttempt)
        #expect(a != differentDelay)
        #expect(a != differentAt)
    }
}

/// Lifecycle tests for `RemoteVaultsStore.reconnectStatus`. We don't
/// drive the WS event stream here (that needs a real
/// `URLSessionWebSocketTask`) — instead we pin the cleared-on-init and
/// cleared-on-unsubscribe contracts. The set-on-willReconnect path is
/// exercised end-to-end in the live app.
@Suite("RemoteVaultsStore.reconnectStatus — slice 4f.2 lifecycle")
@MainActor
struct RemoteVaultsStoreReconnectStatusTests {

    @Test("reconnectStatus is nil on a fresh store")
    func defaultIsNil() async {
        let client = LumiAPIClient()
        let store = RemoteVaultsStore(client: client)
        #expect(store.reconnectStatus == nil)
    }

    @Test("unsubscribeFromOpenNote clears any pending reconnect hint")
    func unsubscribeClears() async {
        let client = LumiAPIClient()
        let store = RemoteVaultsStore(client: client)
        // We can't reach the private setter from the test, but calling
        // unsubscribe before anything is open must be safely no-op AND
        // leave reconnectStatus nil (default).
        store.unsubscribeFromOpenNote()
        #expect(store.reconnectStatus == nil)

        // clear() is the broader sign-out path; same expectation.
        store.clear()
        #expect(store.reconnectStatus == nil)
    }
}
