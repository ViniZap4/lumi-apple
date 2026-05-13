import Foundation

/// Failure shapes from `LumiAPIClient`. Categorised so callers can branch on
/// the kind of failure without inspecting underlying error strings.
public enum LumiAPIError: Error, Sendable, Equatable {
    /// Underlying URLSession or connection failure (offline, TLS, DNS, etc.).
    /// Stores the localized message so the type can stay Equatable / Sendable
    /// without leaking arbitrary NSError graphs.
    case network(message: String)

    /// Server responded but with a non-2xx status. `code` is the server's
    /// `"error"` field (e.g. `"validation_failed"`, `"unauthorized"`);
    /// `detail` is the optional human-readable hint.
    case server(status: Int, code: String, detail: String?)

    /// 401 specifically. Surfaced as a distinct case so callers can clear the
    /// stored session without parsing `.server` codes.
    case unauthorized

    /// Response body couldn't be decoded into the expected DTO. Usually means
    /// the client is talking to a server it doesn't understand.
    case decoding(message: String)

    /// Anything else: unexpected status with no parseable error envelope.
    case invalidResponse(status: Int)
}
