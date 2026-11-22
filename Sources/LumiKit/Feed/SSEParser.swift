import Foundation

/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String
    public var data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

public enum SSEItem: Sendable, Equatable {
    case event(SSEEvent)
    /// `: ping` and other comment lines (text after the colon, trimmed).
    case comment(String)
}

/// Incremental, byte-oriented SSE parser (WHATWG event-stream rules).
///
/// Handles LF / CRLF / CR line endings (including a CR at the end of one
/// chunk and its LF at the start of the next), a leading UTF-8 BOM,
/// comment lines, fields without a space after the colon, multi-line
/// `data`, and chunks cut anywhere — including inside a multi-byte UTF-8
/// sequence, since lines are decoded only once complete. `id:` and
/// `retry:` are ignored: the lumi feed has no replay (SPEC-LIVROS §3.2).
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var pendingCR = false
    private var atStreamStart = true
    private var eventName = ""
    private var dataLines: [String] = []
    private var hasData = false

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEItem] where S.Element == UInt8 {
        var out: [SSEItem] = []
        for b in bytes {
            if pendingCR {
                pendingCR = false
                if b == 0x0A { continue }
            }
            switch b {
            case 0x0D:
                pendingCR = true
                processLine(into: &out)
            case 0x0A:
                processLine(into: &out)
            default:
                line.append(b)
            }
        }
        return out
    }

    /// Discard partial state (call when a connection is torn down).
    public mutating func reset() {
        self = SSEParser()
    }

    private mutating func processLine(into out: inout [SSEItem]) {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStreamStart {
            atStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        if bytes.isEmpty {
            if hasData {
                out.append(.event(SSEEvent(event: eventName.isEmpty ? "message" : eventName,
                                           data: dataLines.joined(separator: "\n"))))
            }
            eventName = ""
            dataLines = []
            hasData = false
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.first == ":" {
            out.append(.comment(String(text.dropFirst()).trimmingCharacters(in: .whitespaces)))
            return
        }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data":
            dataLines.append(String(value))
            hasData = true
        default: break
        }
    }
}
