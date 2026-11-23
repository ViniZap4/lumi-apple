import Foundation

/// A decoded lib0-v1 Yjs state vector: `clientID → clock` (number of
/// items that client has integrated). Wire form:
/// `varUint(n) · n × (varUint(client) · varUint(clock))`.
///
/// Used by the offline replica's lineage guard (`ReplicaLineage`): inside
/// one CRDT lineage a server's state vector only ever grows, so a server
/// whose vector does not *dominate* what it already acknowledged to us is
/// a different lineage (note recreated, CRDT reset, backup restore).
public struct StateVector: Sendable, Equatable {
    public private(set) var clocks: [UInt64: UInt64]

    public init(_ clocks: [UInt64: UInt64] = [:]) {
        self.clocks = clocks.filter { $0.value > 0 }
    }

    public var isEmpty: Bool { clocks.isEmpty }

    /// Decode a lib0-v1 state vector. Empty input decodes as empty
    /// (an empty doc's vector is the single byte `0`).
    public init(decoding data: Data) throws {
        var clocks: [UInt64: UInt64] = [:]
        guard !data.isEmpty else {
            self.clocks = [:]
            return
        }
        var offset = 0
        let (n, c0) = try YProtocol.readVarUint(data, offset: offset)
        offset += c0
        guard n <= UInt64(data.count) else { throw YProtocol.DecodeError.shortRead }
        for _ in 0..<n {
            let (client, c1) = try YProtocol.readVarUint(data, offset: offset)
            offset += c1
            let (clock, c2) = try YProtocol.readVarUint(data, offset: offset)
            offset += c2
            clocks[client] = max(clocks[client] ?? 0, clock)
        }
        self.clocks = clocks.filter { $0.value > 0 }
    }

    /// lib0-v1 encoding (clients sorted for determinism).
    public func encoded() -> Data {
        var out = Data()
        YProtocol.writeVarUint(UInt64(clocks.count), into: &out)
        for client in clocks.keys.sorted() {
            YProtocol.writeVarUint(client, into: &out)
            YProtocol.writeVarUint(clocks[client] ?? 0, into: &out)
        }
        return out
    }

    /// True when every clock in `other` is ≤ the matching clock here.
    public func dominates(_ other: StateVector) -> Bool {
        other.clocks.allSatisfy { client, clock in (clocks[client] ?? 0) >= clock }
    }

    /// Component-wise maximum.
    public func merged(with other: StateVector) -> StateVector {
        StateVector(clocks.merging(other.clocks) { max($0, $1) })
    }
}
