import Testing
import Foundation
@testable import LumiKit

/// Slice 4f covers the *pure* parts of the WS reconnect surface:
/// exponential-with-jitter backoff math, plus the public URL builder.
/// The receive loop's transient-close → willReconnect path is exercised
/// end-to-end via RemoteVaultsStore in the integration tier (the loop
/// itself depends on a real `URLSessionWebSocketTask`, which we don't
/// stub here). The unit tests below pin the math so a future tweak to
/// the curve can't silently slow reconnects (or starve users with
/// runaway delays).
@Suite("NoteSyncClient — slice 4f reconnect math + URL building")
struct NoteSyncClientTests {

    // MARK: - backoffSeconds

    @Test("backoff base curve doubles each attempt up to the 32s cap")
    func backoffBaseCurve() {
        // Sample enough attempts to span the curve from 1s → 32s cap.
        // Each sample is checked against its expected base ± 20% jitter
        // window. The math: base(n) = min(32, 2^(n-1)).
        let cases: [(attempt: Int, base: Double)] = [
            (1, 1),
            (2, 2),
            (3, 4),
            (4, 8),
            (5, 16),
            (6, 32),
            (7, 32),  // capped
            (10, 32), // capped
            (50, 32), // still capped, no overflow
        ]
        for tc in cases {
            // Draw a few samples per attempt to catch a single bad random.
            for _ in 0..<25 {
                let got = NoteSyncClient.backoffSeconds(attempt: tc.attempt)
                let low = tc.base * 0.8
                let high = tc.base * 1.2
                #expect(got >= low, "attempt=\(tc.attempt) got=\(got) below low=\(low)")
                #expect(got <= high, "attempt=\(tc.attempt) got=\(got) above high=\(high)")
            }
        }
    }

    @Test("backoff clamps non-positive attempts to attempt=1")
    func backoffClampsLowAttempts() {
        // attempt 0 and negative attempts should be treated as attempt=1
        // (the receive loop computes nextAttempt = attempt + 1 so this
        // path is only reached if a host explicitly passes a weird
        // value; still — must not crash, must produce a usable delay).
        for attempt in [Int.min / 2, -100, -1, 0] {
            for _ in 0..<10 {
                let got = NoteSyncClient.backoffSeconds(attempt: attempt)
                #expect(got >= 0.8 && got <= 1.2, "attempt=\(attempt) got=\(got) outside attempt-1 window")
            }
        }
    }

    @Test("backoff never returns negative seconds even with worst-case jitter")
    func backoffNeverNegative() {
        // Run a lot of samples across small attempts since ±20% of a
        // small base is closest to crossing zero.
        for _ in 0..<5_000 {
            let got = NoteSyncClient.backoffSeconds(attempt: 1)
            #expect(got >= 0)
        }
    }

    // MARK: - URL construction (regression — slice 4f keeps the contract)

    @Test("wsURL swaps http→ws and preserves path-encoded note slug")
    func wsURLBuildsCorrectly() {
        let base = URL(string: "http://localhost:8080")!
        let vid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let client = NoteSyncClient(
            baseURL: base,
            token: "abc",
            vaultID: vid,
            noteID: "my note",
            attempt: 3
        )
        let url = client.wsURL()
        #expect(url != nil)
        let s = url?.absoluteString ?? ""
        #expect(s.hasPrefix("ws://localhost:8080/api/vaults/"))
        #expect(s.contains("/notes/my%20note/sync"))
        #expect(s.contains("token=abc"))
    }

    @Test("wsURL upgrades https→wss")
    func wsURLUpgradesHTTPS() {
        let base = URL(string: "https://lumi.example/")!
        let vid = UUID()
        let client = NoteSyncClient(baseURL: base, token: "t", vaultID: vid, noteID: "x")
        let url = client.wsURL()
        #expect(url?.scheme == "wss")
    }

    @Test("attempt is clamped to >= 1 in the initializer")
    func attemptInitClamping() {
        // Just exercise the constructor with a bogus value; no public
        // accessor for `attempt`, but at minimum the construction must
        // not crash and `wsURL` must still produce a valid URL.
        let base = URL(string: "https://x.example")!
        let c = NoteSyncClient(baseURL: base, token: "t", vaultID: UUID(), noteID: "n", attempt: -5)
        #expect(c.wsURL() != nil)
    }

    // MARK: - Event Equatable round-trip (sanity)

    @Test("willReconnect events compare by attempt + delay")
    func willReconnectEquatable() {
        let a = NoteSyncClient.Event.willReconnect(attempt: 2, delaySeconds: 1.5)
        let b = NoteSyncClient.Event.willReconnect(attempt: 2, delaySeconds: 1.5)
        let c = NoteSyncClient.Event.willReconnect(attempt: 3, delaySeconds: 1.5)
        let d = NoteSyncClient.Event.willReconnect(attempt: 2, delaySeconds: 2.5)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}
