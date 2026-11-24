import Foundation

/// Something the pool can share and tear down.
@MainActor
public protocol PoolableSession: AnyObject {
    /// False once the session stopped for good (destroyed, fatal close,
    /// lineage conflict): it is never handed out again.
    var isPoolUsable: Bool { get }
    func destroy()
}

/// Shared sessions for panes (SPEC-PARTE2 §3: "each pane has its own
/// live session; two panes on the same note share one session/doc").
/// Port of the web's `session-pool.ts`.
///
/// Reference counted per key (book + note). `release(_:defer:)` keeps
/// the last reference alive for a short grace so a pane hand-off (close a
/// split, promote a pane, switch the view) picks the session up again
/// without reconnecting or reloading.
@MainActor
public final class SessionPool<Key: Hashable, Session: PoolableSession> {
    public static var defaultGrace: TimeInterval { 1.5 }

    private struct Entry {
        let session: Session
        var refs: Int
        var timer: AnyObject?
    }

    private var entries: [Key: Entry] = [:]
    private let grace: TimeInterval
    private let timers: HoverTimers

    public init(grace: TimeInterval = SessionPool.defaultGrace, timers: HoverTimers = MainQueueHoverTimers()) {
        self.grace = grace
        self.timers = timers
    }

    /// The live session for `key`, if any (no reference taken).
    public func peek(_ key: Key) -> Session? {
        guard let e = entries[key], e.session.isPoolUsable else { return nil }
        return e.session
    }

    /// Take a reference on the session for `key`, building one when
    /// there is none (or the pooled one stopped).
    @discardableResult
    public func acquire(_ key: Key, make: () -> Session) -> Session {
        if var e = entries[key] {
            if e.session.isPoolUsable {
                if let t = e.timer { timers.cancel(t) }
                e.timer = nil
                e.refs += 1
                entries[key] = e
                return e.session
            }
            // A dead session stays with whoever holds it; the pool forgets it.
            if let t = e.timer { timers.cancel(t) }
            entries[key] = nil
        }
        let s = make()
        entries[key] = Entry(session: s, refs: 1, timer: nil)
        return s
    }

    public func refCount(_ key: Key) -> Int { entries[key]?.refs ?? 0 }

    /// Every key with a pooled session.
    public var keys: [Key] { Array(entries.keys) }

    /// Drop a reference. The last one destroys the session — after the
    /// grace when `defer` (and the session is still usable). A session
    /// the pool does not know (it was replaced) is destroyed directly.
    public func release(_ key: Key, session: Session? = nil, defer deferred: Bool = false) {
        guard var e = entries[key], session == nil || e.session === session else {
            session?.destroy()
            return
        }
        if e.refs > 1 {
            e.refs -= 1
            entries[key] = e
            return
        }
        e.refs = 0
        if deferred, e.session.isPoolUsable {
            if let t = e.timer { timers.cancel(t) }
            let s = e.session
            e.timer = timers.schedule(grace) { [weak self] in
                guard let self, let cur = self.entries[key], cur.session === s, cur.refs == 0 else { return }
                self.entries[key] = nil
                s.destroy()
            }
            entries[key] = e
        } else {
            entries[key] = nil
            e.session.destroy()
        }
    }

    /// Destroy everything (sign out, book switch).
    public func clear() {
        let all = entries.values
        entries = [:]
        for e in all {
            if let t = e.timer { timers.cancel(t) }
            e.session.destroy()
        }
    }

    /// Destroy the sessions whose key matches (an account's books).
    public func clear(where match: (Key) -> Bool) {
        for (k, e) in entries where match(k) {
            if let t = e.timer { timers.cancel(t) }
            entries[k] = nil
            e.session.destroy()
        }
    }
}
