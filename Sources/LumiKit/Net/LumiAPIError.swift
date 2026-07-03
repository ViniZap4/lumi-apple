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

extension LumiAPIError {
    /// True when this error represents a strict-conflict rejection of an
    /// `applyDiff` call — the server received a stale `base_clock` and
    /// refused to merge. Callers handle this by refetching the snapshot
    /// (to restore baseline) and preserving the user's in-memory edits.
    /// Slice 4c.
    public var isApplyDiffConflict: Bool {
        if case let .server(status, code, _) = self,
           status == 409,
           code == "conflict" {
            return true
        }
        return false
    }

    /// True when the server rejected a `copyVault` call because the
    /// requested recipient username doesn't exist on this server
    /// (`400 {"error":"recipient_not_found"}`). Callers surface this as
    /// "check the username" rather than a generic failure. SPEC-V3
    /// share-a-copy.
    public var isRecipientNotFound: Bool {
        if case let .server(status, code, _) = self,
           status == 400,
           code == "recipient_not_found" {
            return true
        }
        return false
    }

    /// True when a member mutation (remove, role change) bounced off the
    /// vault owner's non-removable Admin-equivalent grant
    /// (`409 {"error":"owner_protected","message":...}`). The server's
    /// human-readable `message` rides in the error's `detail` slot. SPEC-V3
    /// vault ownership.
    public var isOwnerProtected: Bool {
        if case let .server(status, code, _) = self,
           status == 409,
           code == "owner_protected" {
            return true
        }
        return false
    }
}
