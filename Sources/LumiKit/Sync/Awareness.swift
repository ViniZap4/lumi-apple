import Foundation

/// One y-protocols awareness entry: `clientID → (clock, JSON state)`.
/// `state == nil` is the wire `"null"` (client left).
public struct AwarenessEntry: Sendable, Equatable {
    public var clientID: UInt64
    public var clock: UInt64
    /// JSON text of the state object, or nil for `null`.
    public var stateJSON: String?

    public init(clientID: UInt64, clock: UInt64, stateJSON: String?) {
        self.clientID = clientID
        self.clock = clock
        self.stateJSON = stateJSON
    }
}

/// Standard y-protocols awareness update codec
/// (`y-protocols/awareness.js` `encodeAwarenessUpdate` /
/// `applyAwarenessUpdate`; server `wsync.EncodeAwarenessUpdate`):
///
///     update ::= varUint(n) { varUint(clientID) varUint(clock) varString(JSON) }^n
///
/// `varString` is lib0's varUint(byteLength) + UTF-8. A removed client
/// is the JSON text `null`.
public enum AwarenessCodec {
    public enum DecodeError: Error, Equatable {
        case malformed
    }

    public static func encode(_ entries: [AwarenessEntry]) -> Data {
        var out = Data()
        YProtocol.writeVarUint(UInt64(entries.count), into: &out)
        for e in entries {
            YProtocol.writeVarUint(e.clientID, into: &out)
            YProtocol.writeVarUint(e.clock, into: &out)
            YProtocol.writeVarBytes(Data((e.stateJSON ?? "null").utf8), into: &out)
        }
        return out
    }

    public static func decode(_ data: Data) throws(DecodeError) -> [AwarenessEntry] {
        do {
            let bytes = Data(data) // re-base indices at 0
            var off = 0
            let (n, k) = try YProtocol.readVarUint(bytes, offset: off)
            off += k
            guard n <= UInt64(bytes.count) else { throw DecodeError.malformed }
            var out: [AwarenessEntry] = []
            out.reserveCapacity(Int(n))
            for _ in 0..<n {
                let (client, k1) = try YProtocol.readVarUint(bytes, offset: off)
                off += k1
                let (clock, k2) = try YProtocol.readVarUint(bytes, offset: off)
                off += k2
                let (state, k3) = try YProtocol.readVarBytes(bytes, offset: off)
                off += k3
                guard let json = String(data: state, encoding: .utf8) else { throw DecodeError.malformed }
                out.append(AwarenessEntry(clientID: client, clock: clock, stateJSON: json == "null" ? nil : json))
            }
            guard off == bytes.count else { throw DecodeError.malformed }
            return out
        } catch let e as DecodeError {
            throw e
        } catch {
            throw .malformed
        }
    }
}

/// A peer visible on the open note, decoded from its awareness state
/// `{"user": {"name", "color", "colorLight", "username"?}}` — the shape
/// the web client publishes for y-codemirror.
public struct PeerPresence: Sendable, Equatable, Identifiable {
    public let clientID: UInt64
    public let name: String
    public let color: String
    public let username: String?
    public var id: UInt64 { clientID }

    public init(clientID: UInt64, name: String, color: String, username: String? = nil) {
        self.clientID = clientID
        self.name = name
        self.color = color
        self.username = username
    }
}

/// The local user as published over awareness.
public struct AwarenessUser: Sendable, Equatable {
    public var username: String
    public var displayName: String

    public init(username: String, displayName: String) {
        self.username = username
        self.displayName = displayName
    }

    /// Same palette + hash as the web client's `pickColor(username)` so
    /// a user has one colour on every client.
    public static let palette = [
        "#7aa2f7", "#bb9af7", "#7dcfff", "#9ece6a", "#e0af68",
        "#f7768e", "#f5c2e7", "#a9b1d6", "#f9e2af", "#cba6f7",
    ]

    public static func color(for username: String) -> String {
        var h: Int32 = 0
        for unit in username.utf16 {
            h = h &* 31 &+ Int32(unit)
        }
        // JS Math.abs on int32 (|0) — Int32.min stays positive in JS
        // doubles; widen before abs.
        let idx = Int(abs(Int64(h))) % palette.count
        return palette[idx]
    }

    /// JSON state (keys sorted for stable bytes).
    func stateJSON() -> String {
        let color = Self.color(for: username)
        let user: [String: String] = [
            "name": displayName.isEmpty ? username : displayName,
            "color": color,
            "colorLight": color + "33",
            "username": username,
            "client": "apple",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["user": user], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// y-protocols `Awareness` semantics for one note session: a local
/// state with a monotonic clock, remote states keyed by clientID,
/// renewal every 15 s and expiry of remote states silent for 30 s.
/// A pure value type; the session drives it and ships the returned
/// update bytes.
public struct AwarenessState: Sendable {
    /// y-protocols `outdatedTimeout`.
    public static let outdatedTimeout: TimeInterval = 30
    /// Local state is re-broadcast when older than half the timeout.
    public static let renewInterval: TimeInterval = 15

    public let clientID: UInt64
    public private(set) var clock: UInt64 = 0
    public private(set) var localJSON: String?
    private var lastLocalUpdate: Date = .distantPast

    private struct Remote: Sendable {
        var clock: UInt64
        var json: String?
        var lastUpdated: Date
    }
    private var remotes: [UInt64: Remote] = [:]

    public init(clientID: UInt64 = AwarenessState.randomClientID()) {
        self.clientID = clientID
    }

    /// Yjs clientIDs are random uint32s.
    public static func randomClientID() -> UInt64 {
        UInt64(UInt32.random(in: 1...UInt32.max))
    }

    /// Set (or clear with nil) the local state; returns the update.
    public mutating func setLocal(_ json: String?, now: Date = Date()) -> Data {
        clock += 1
        localJSON = json
        lastLocalUpdate = now
        return localUpdate()
    }

    /// Encode the current local entry (for (re)announcing after open).
    public func localUpdate() -> Data {
        AwarenessCodec.encode([AwarenessEntry(clientID: clientID, clock: clock, stateJSON: localJSON)])
    }

    /// Encode every known state (local + remote), as a reply to
    /// QueryAwareness.
    public func fullUpdate() -> Data {
        var entries = [AwarenessEntry(clientID: clientID, clock: clock, stateJSON: localJSON)]
        for (id, r) in remotes.sorted(by: { $0.key < $1.key }) where r.json != nil {
            entries.append(AwarenessEntry(clientID: id, clock: r.clock, stateJSON: r.json))
        }
        return AwarenessCodec.encode(entries)
    }

    /// `applyAwarenessUpdate`. Returns `(changed, reply)` where `reply`
    /// is a local re-announcement when a peer claimed we left.
    public mutating func apply(_ update: Data, now: Date = Date()) -> (changed: Bool, reply: Data?) {
        guard let entries = try? AwarenessCodec.decode(update) else { return (false, nil) }
        var changed = false
        var reply: Data?
        for e in entries {
            if e.clientID == clientID {
                // Someone (the server's leave frame for an old socket of
                // ours) says we are gone while we are present: bump and
                // re-announce, like y-protocols does.
                if e.stateJSON == nil, localJSON != nil, e.clock >= clock {
                    clock = e.clock + 1
                    lastLocalUpdate = now
                    reply = localUpdate()
                }
                continue
            }
            let current = remotes[e.clientID]
            let currClock = current?.clock ?? 0
            let isNewer = currClock < e.clock
            let isRemovalOfKnown = currClock == e.clock && e.stateJSON == nil && current?.json != nil
            guard isNewer || isRemovalOfKnown else { continue }
            if e.stateJSON == nil {
                if current?.json != nil { changed = true }
                remotes[e.clientID] = Remote(clock: e.clock, json: nil, lastUpdated: now)
            } else {
                if current?.json != e.stateJSON { changed = true }
                remotes[e.clientID] = Remote(clock: e.clock, json: e.stateJSON, lastUpdated: now)
            }
        }
        return (changed, reply)
    }

    /// Periodic tick: returns a renewal update when the local state is
    /// due, and whether expiring silent peers changed the peer list.
    public mutating func tick(now: Date = Date()) -> (renewal: Data?, changed: Bool) {
        var renewal: Data?
        if localJSON != nil, now.timeIntervalSince(lastLocalUpdate) >= Self.renewInterval {
            renewal = setLocal(localJSON, now: now)
        }
        var changed = false
        for (id, r) in remotes where r.json != nil && now.timeIntervalSince(r.lastUpdated) >= Self.outdatedTimeout {
            remotes[id] = Remote(clock: r.clock, json: nil, lastUpdated: r.lastUpdated)
            changed = true
        }
        return (renewal, changed)
    }

    /// Forget every remote (socket dropped: the server retires our view).
    public mutating func clearRemotes() {
        remotes.removeAll()
    }

    /// Visible peers, sorted by name then clientID. States without a
    /// `user` object are ignored.
    public var peers: [PeerPresence] {
        remotes.compactMap { id, r -> PeerPresence? in
            guard let json = r.json,
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let user = obj["user"] as? [String: Any]
            else { return nil }
            let username = user["username"] as? String
            let name = (user["name"] as? String) ?? username ?? "anonymous"
            let color = (user["color"] as? String) ?? AwarenessUser.color(for: username ?? name)
            return PeerPresence(clientID: id, name: name, color: color, username: username)
        }
        .sorted { ($0.name, $0.clientID) < ($1.name, $1.clientID) }
    }
}
