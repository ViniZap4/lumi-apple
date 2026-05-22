import Foundation

/// Encoders and decoders for the y-protocols v1 wire format used by the
/// lumi-server `/api/vaults/:vault/notes/:id/sync` WebSocket. Server-side
/// reference: `lumi-server/internal/wsync/protocol.go`.
///
/// Wire format:
///
///     Message     ::= varInt(messageType) + payload
///     messageType ::= 0 Sync | 1 Awareness | 3 Auth | 4 QueryAwareness
///
///     Sync payload ::= varInt(syncSubType) + body
///     syncSubType  ::= 0 Step1 (body=stateVector)
///                    | 1 Step2 (body=update)
///                    | 2 Update (body=update)
///
///     Awareness payload ::= varBytes(awarenessUpdate)
///
/// varInt is lib0's unsigned LEB128. varBytes is varInt(len) + bytes.
///
/// Slice 4e of phase E.1.2 uses these primitives just to *subscribe* to
/// live updates (open the WS, parse incoming frames enough to know "a
/// remote update arrived"); it does NOT decode or apply the Y.Doc updates
/// to a local CRDT. That's reserved for a future Phase H slice once a
/// yswift-equivalent Swift Yjs binding lands.
public enum YProtocol {
    public static let messageSync: UInt8 = 0
    public static let messageAwareness: UInt8 = 1
    public static let messageAuth: UInt8 = 3
    public static let messageQueryAwareness: UInt8 = 4

    public static let syncStep1: UInt8 = 0
    public static let syncStep2: UInt8 = 1
    public static let syncUpdate: UInt8 = 2

    /// Decoded form of a single inbound frame.
    public struct ParsedMessage: Sendable, Equatable {
        public let type: UInt8
        /// Sync sub-type. Defined only when `type == messageSync`; left as
        /// 0 for awareness/auth/query messages (callers must check `type`
        /// before reading this field).
        public let syncSub: UInt8
        public let body: Data

        public init(type: UInt8, syncSub: UInt8 = 0, body: Data = Data()) {
            self.type = type
            self.syncSub = syncSub
            self.body = body
        }
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case shortRead
        case varintOverflow
        case unknownMessageType(UInt8)
    }

    // MARK: - varInt (lib0 unsigned LEB128)

    /// Encode `v` as lib0 unsigned LEB128. Bytes are appended to `out`.
    public static func writeVarUint(_ v: UInt64, into out: inout Data) {
        var v = v
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v & 0x7f))
    }

    /// Decode a lib0 unsigned LEB128 varint from `data` starting at `offset`.
    /// Returns the value and the number of bytes consumed.
    public static func readVarUint(_ data: Data, offset: Int) throws -> (value: UInt64, consumed: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        while i < data.count {
            let b = data[data.index(data.startIndex, offsetBy: i)]
            if shift >= 64 {
                throw DecodeError.varintOverflow
            }
            value |= UInt64(b & 0x7f) << shift
            if (b & 0x80) == 0 {
                return (value, i - offset + 1)
            }
            shift += 7
            i += 1
        }
        throw DecodeError.shortRead
    }

    // MARK: - varBytes

    /// Encode `bytes` as varInt(len) + bytes, appended to `out`.
    public static func writeVarBytes(_ bytes: Data, into out: inout Data) {
        writeVarUint(UInt64(bytes.count), into: &out)
        out.append(bytes)
    }

    /// Decode varBytes starting at `offset`. Returns the byte slice + bytes
    /// consumed (varint header + body).
    public static func readVarBytes(_ data: Data, offset: Int) throws -> (bytes: Data, consumed: Int) {
        let (length, headerLen) = try readVarUint(data, offset: offset)
        let bodyStart = offset + headerLen
        let bodyEnd = bodyStart + Int(length)
        if bodyEnd > data.count {
            throw DecodeError.shortRead
        }
        // Subdata view, copied so callers can outlive `data`.
        let body = data.subdata(in: bodyStart..<bodyEnd)
        return (body, headerLen + Int(length))
    }

    // MARK: - Message encoders

    /// `[messageSync, syncStep1, varBytes(stateVector)]`. Clients send on
    /// open so the server knows what it can ship as Step2.
    public static func encodeSyncStep1(stateVector: Data) -> Data {
        var out = Data([messageSync, syncStep1])
        writeVarBytes(stateVector, into: &out)
        return out
    }

    /// `[messageSync, syncStep2, varBytes(update)]`. Response to Step1.
    public static func encodeSyncStep2(update: Data) -> Data {
        var out = Data([messageSync, syncStep2])
        writeVarBytes(update, into: &out)
        return out
    }

    /// `[messageSync, syncUpdate, varBytes(update)]`. Fan-out broadcasts
    /// of an applied update.
    public static func encodeSyncUpdate(update: Data) -> Data {
        var out = Data([messageSync, syncUpdate])
        writeVarBytes(update, into: &out)
        return out
    }

    /// `[messageAwareness, varBytes(awarenessUpdate)]`. Server-opaque relay.
    public static func encodeAwareness(_ awarenessUpdate: Data) -> Data {
        var out = Data([messageAwareness])
        writeVarBytes(awarenessUpdate, into: &out)
        return out
    }

    // MARK: - Decoder

    /// Parse a single inbound WebSocket binary frame. Returns the decoded
    /// message or throws on a truncated frame / unknown type.
    public static func decode(_ data: Data) throws -> ParsedMessage {
        guard data.count >= 1 else { throw DecodeError.shortRead }
        let type = data[data.startIndex]
        var consumed = 1
        switch type {
        case messageSync:
            guard data.count >= 2 else { throw DecodeError.shortRead }
            let syncSub = data[data.index(data.startIndex, offsetBy: 1)]
            consumed = 2
            let (body, _) = try readVarBytes(data, offset: consumed)
            return ParsedMessage(type: type, syncSub: syncSub, body: body)

        case messageAwareness:
            let (body, _) = try readVarBytes(data, offset: consumed)
            return ParsedMessage(type: type, body: body)

        case messageQueryAwareness:
            // Body-less per server-side comment.
            return ParsedMessage(type: type)

        case messageAuth:
            // Body shape varies per Yjs client; treat as opaque.
            return ParsedMessage(type: type)

        default:
            throw DecodeError.unknownMessageType(type)
        }
    }
}
