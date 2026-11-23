import Foundation

/// Validation rules for insert-mode escape sequences, shared with the web
/// client's `editor-settings.ts` (`validateEscapeSequence`,
/// `MAX_ESCAPE_SEQUENCES`, `ESCAPE_TIMEOUT_MIN/MAX`) so a sequence that is
/// valid on one client is valid on the other.
public enum EscapeSequences {
    public static let maxCount = 8
    public static let timeoutMinMs = 100
    public static let timeoutMaxMs = 1000
    public static let defaultTimeoutMs = 200

    public enum ValidationError: Error, Equatable, Sendable {
        case tooShort, tooLong, whitespace, keyNotation, control

        public var message: String {
            switch self {
            case .tooShort: return "Use at least 2 characters (e.g. jk)."
            case .tooLong: return "Use at most 4 characters."
            case .whitespace: return "Spaces are not allowed."
            case .keyNotation: return "Key notation (<…>) is not allowed here."
            case .control: return "Only printable characters."
            }
        }
    }

    /// 2–4 printable characters, no whitespace, no `<…>` key notation.
    public static func validate(_ raw: String) -> Result<String, ValidationError> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count < 2 { return .failure(.tooShort) }
        if value.count > 4 { return .failure(.tooLong) }
        if value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .failure(.whitespace)
        }
        if value.contains("<") { return .failure(.keyNotation) }
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(.control)
        }
        return .success(value)
    }

    /// Valid, de-duplicated, capped list (order kept).
    public static func sanitize(_ list: [String]) -> [String] {
        var out: [String] = []
        for raw in list {
            guard case let .success(v) = validate(raw), !out.contains(v) else { continue }
            out.append(v)
            if out.count >= maxCount { break }
        }
        return out
    }

    /// Storage form: sequences separated by single spaces (they cannot
    /// contain whitespace themselves).
    public static func encode(_ list: [String]) -> String {
        sanitize(list).joined(separator: " ")
    }

    public static func decode(_ raw: String?) -> [String] {
        sanitize((raw ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    public static func clampTimeout(_ ms: Int) -> Int {
        max(timeoutMinMs, min(timeoutMaxMs, ms))
    }
}
