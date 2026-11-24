import Foundation

/// A JSON value that keeps object key order and formats exactly like
/// JavaScript's `JSON.parse` / `JSON.stringify`, so a canvas file written
/// by Obsidian or the web client round-trips byte for byte
/// (SPEC-PARTE2 §6). Foundation's `JSONSerialization` loses key order
/// and formats numbers differently, so it cannot be used here.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case let .number(n) = self { return n } else { return nil } }
    public var objectValue: JSONObject? { if case let .object(o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a } else { return nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
    public init(nilLiteral: ()) { self = .null }
}

/// An ordered JSON object with JavaScript's own-property order:
/// array-index keys (`"0"`, `"17"`) first in ascending numeric order,
/// then every other key in insertion order. Setting an existing key keeps
/// its position; a new key appends; setting `nil` deletes.
public struct JSONObject: Sendable, Equatable {
    private var order: [String] = []
    private var values: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    /// Keys in JavaScript property order.
    public var keys: [String] {
        let idx = order.compactMap { k in Self.arrayIndex(k).map { (k, $0) } }
        guard !idx.isEmpty else { return order }
        return idx.sorted { $0.1 < $1.1 }.map(\.0) + order.filter { Self.arrayIndex($0) == nil }
    }

    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }

    public func has(_ key: String) -> Bool { values[key] != nil }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { order.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                order.removeAll { $0 == key }
            }
        }
    }

    public static func == (l: JSONObject, r: JSONObject) -> Bool {
        l.keys == r.keys && l.values == r.values
    }

    /// ECMAScript array index: canonical decimal of an integer in
    /// `0 ..< 2^32 - 1`.
    static func arrayIndex(_ k: String) -> UInt32? {
        guard !k.isEmpty, k.utf8.count <= 10, k.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if k.count > 1, k.hasPrefix("0") { return nil }
        guard let v = UInt64(k), v < 4_294_967_295 else { return nil }
        return UInt32(v)
    }
}

// MARK: - Parse (JSON.parse)

public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at position \(offset)" }
}

public extension JSONValue {
    /// Strict JSON (RFC 8259) like `JSON.parse`: whitespace is space, tab,
    /// LF and CR only; duplicate keys keep the last value at the first
    /// key's position.
    static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        var p = JSONReader(Array(text.utf16))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        guard p.i == p.s.count else { throw p.fail("Unexpected non-whitespace character after JSON") }
        return v
    }
}

private struct JSONReader {
    let s: [UInt16]
    var i = 0
    init(_ s: [UInt16]) { self.s = s }

    func fail(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    mutating func skipWS() {
        while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
    }

    mutating func value(depth: Int) throws(JSONParseError) -> JSONValue {
        guard depth < 512 else { throw fail("JSON nested too deeply") }
        guard i < s.count else { throw fail("Unexpected end of JSON input") }
        switch s[i] {
        case 0x7B: return try object(depth: depth)
        case 0x5B: return try array(depth: depth)
        case 0x22: return .string(try string())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null"); return .null
        case 0x2D, 0x30...0x39: return .number(try number())
        default: throw fail("Unexpected token")
        }
    }

    mutating func literal(_ word: String) throws(JSONParseError) {
        for u in word.utf16 {
            guard i < s.count, s[i] == u else { throw fail("Unexpected token") }
            i += 1
        }
    }

    mutating func object(depth: Int) throws(JSONParseError) -> JSONValue {
        i += 1
        var obj = JSONObject()
        skipWS()
        if i < s.count, s[i] == 0x7D { i += 1; return .object(obj) }
        while true {
            skipWS()
            guard i < s.count, s[i] == 0x22 else { throw fail("Expected property name") }
            let key = try string()
            skipWS()
            guard i < s.count, s[i] == 0x3A else { throw fail("Expected ':' after property name") }
            i += 1
            skipWS()
            obj[key] = try value(depth: depth + 1)
            skipWS()
            guard i < s.count else { throw fail("Unexpected end of JSON input") }
            if s[i] == 0x2C { i += 1; continue }
            if s[i] == 0x7D { i += 1; return .object(obj) }
            throw fail("Expected ',' or '}' after property value")
        }
    }

    mutating func array(depth: Int) throws(JSONParseError) -> JSONValue {
        i += 1
        var out: [JSONValue] = []
        skipWS()
        if i < s.count, s[i] == 0x5D { i += 1; return .array(out) }
        while true {
            skipWS()
            out.append(try value(depth: depth + 1))
            skipWS()
            guard i < s.count else { throw fail("Unexpected end of JSON input") }
            if s[i] == 0x2C { i += 1; continue }
            if s[i] == 0x5D { i += 1; return .array(out) }
            throw fail("Expected ',' or ']' after array element")
        }
    }

    mutating func string() throws(JSONParseError) -> String {
        i += 1
        var out: [UInt16] = []
        while true {
            guard i < s.count else { throw fail("Unterminated string in JSON") }
            let c = s[i]
            if c == 0x22 { i += 1; break }
            if c < 0x20 { throw fail("Bad control character in string literal") }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < s.count else { throw fail("Unterminated string in JSON") }
            let e = s[i]
            i += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard i + 4 <= s.count else { throw fail("Bad Unicode escape") }
                var v: UInt16 = 0
                for k in 0..<4 {
                    let h = s[i + k]
                    let d: UInt16
                    switch h {
                    case 0x30...0x39: d = h - 0x30
                    case 0x41...0x46: d = h - 0x41 + 10
                    case 0x61...0x66: d = h - 0x61 + 10
                    default: throw fail("Bad Unicode escape")
                    }
                    v = v << 4 | d
                }
                i += 4
                out.append(v)
            default: throw fail("Bad escaped character")
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    mutating func number() throws(JSONParseError) -> Double {
        let start = i
        if s[i] == 0x2D { i += 1 }
        guard i < s.count else { throw fail("No number after minus sign") }
        if s[i] == 0x30 {
            i += 1
        } else if (0x31...0x39).contains(s[i]) {
            while i < s.count, (0x30...0x39).contains(s[i]) { i += 1 }
        } else {
            throw fail("No number after minus sign")
        }
        if i < s.count, s[i] == 0x2E {
            i += 1
            guard i < s.count, (0x30...0x39).contains(s[i]) else { throw fail("Unterminated fractional number") }
            while i < s.count, (0x30...0x39).contains(s[i]) { i += 1 }
        }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
            i += 1
            if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }
            guard i < s.count, (0x30...0x39).contains(s[i]) else { throw fail("Exponent part is missing a number") }
            while i < s.count, (0x30...0x39).contains(s[i]) { i += 1 }
        }
        let lexeme = String(decoding: s[start..<i], as: UTF16.self)
        return Double(lexeme) ?? 0
    }
}

// MARK: - Stringify (JSON.stringify)

public extension JSONValue {
    /// `JSON.stringify(value)` (no indent) or `JSON.stringify(value, null,
    /// indent)`.
    func stringify(indent: String = "") -> String {
        var out = ""
        let gap = String(indent.prefix(10))
        JSONValue.write(self, into: &out, gap: gap, current: "")
        return out
    }

    private static func write(_ v: JSONValue, into out: inout String, gap: String, current: String) {
        switch v {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n): out += JSNumber.format(n)
        case let .string(s): quote(s, into: &out)
        case let .array(a):
            if a.isEmpty { out += "[]"; return }
            if gap.isEmpty {
                out += "["
                for (k, x) in a.enumerated() {
                    if k > 0 { out += "," }
                    write(x, into: &out, gap: gap, current: current)
                }
                out += "]"
            } else {
                let inner = current + gap
                out += "[\n" + inner
                for (k, x) in a.enumerated() {
                    if k > 0 { out += ",\n" + inner }
                    write(x, into: &out, gap: gap, current: inner)
                }
                out += "\n" + current + "]"
            }
        case let .object(o):
            let keys = o.keys
            if keys.isEmpty { out += "{}"; return }
            if gap.isEmpty {
                out += "{"
                for (k, key) in keys.enumerated() {
                    if k > 0 { out += "," }
                    quote(key, into: &out)
                    out += ":"
                    write(o[key]!, into: &out, gap: gap, current: current)
                }
                out += "}"
            } else {
                let inner = current + gap
                out += "{\n" + inner
                for (k, key) in keys.enumerated() {
                    if k > 0 { out += ",\n" + inner }
                    quote(key, into: &out)
                    out += ": "
                    write(o[key]!, into: &out, gap: gap, current: inner)
                }
                out += "\n" + current + "}"
            }
        }
    }

    /// `JSON.stringify` string quoting (well-formed variant).
    static func quote(_ s: String, into out: inout String) {
        out += "\""
        var plainStart = s.unicodeScalars.startIndex
        var idx = plainStart
        let scalars = s.unicodeScalars
        func flush(_ upTo: String.UnicodeScalarView.Index) {
            if plainStart < upTo { out.unicodeScalars.append(contentsOf: scalars[plainStart..<upTo]) }
        }
        while idx < scalars.endIndex {
            let c = scalars[idx]
            var esc: String?
            switch c.value {
            case 0x22: esc = "\\\""
            case 0x5C: esc = "\\\\"
            case 0x08: esc = "\\b"
            case 0x0C: esc = "\\f"
            case 0x0A: esc = "\\n"
            case 0x0D: esc = "\\r"
            case 0x09: esc = "\\t"
            case 0..<0x20: esc = String(format: "\\u%04x", c.value)
            default: break
            }
            if let esc {
                flush(idx)
                out += esc
                idx = scalars.index(after: idx)
                plainStart = idx
            } else {
                idx = scalars.index(after: idx)
            }
        }
        flush(idx)
        out += "\""
    }

    static func quote(_ s: String) -> String {
        var out = ""
        quote(s, into: &out)
        return out
    }
}

/// JavaScript `Number.prototype.toString()` (radix 10) for doubles.
public enum JSNumber {
    public static func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "null" } // JSON.stringify semantics
        if v == 0 { return "0" }
        let negative = v < 0
        // Swift's description is the shortest round-trip representation.
        let d = (negative ? -v : v).description
        var mantissa = d
        var exp10 = 0
        if let e = d.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(d[..<e])
            exp10 = Int(d[d.index(after: e)...]) ?? 0
        }
        var intPart = mantissa
        var frac = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            frac = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = Array(intPart + frac)
        // value = 0.digits × 10^n
        var n = intPart.count + exp10
        while let f = digits.first, f == "0", digits.count > 1 {
            digits.removeFirst()
            n -= 1
        }
        while let l = digits.last, l == "0", digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let ds = String(digits)
        var out: String
        if k <= n && n <= 21 {
            out = ds + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let idx = ds.index(ds.startIndex, offsetBy: n)
            out = String(ds[..<idx]) + "." + String(ds[idx...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n) + ds
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            out = String(digits[0]) + (k > 1 ? "." + String(digits[1...]) : "") + "e" + sign + String(abs(e))
        }
        return negative ? "-" + out : out
    }

    /// `Math.round`: halves round toward +∞.
    public static func round(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
}
