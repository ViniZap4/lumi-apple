import Foundation

/// Canonical server identity string (SPEC-LIVROS §2.1).
///
/// `server_url` = scheme and host lowercased, no default port, no trailing
/// slash, no query/fragment. A base path is allowed (`https://x.com/lumi`).
/// `http://` is accepted only for `localhost`, private IPs and `*.local`;
/// the UI shows a persistent (dismissable per server) warning for those.
public enum ServerURL {
    public enum NormalizationError: Error, Equatable, Sendable {
        case invalid
        case unsupportedScheme
        /// Plain `http://` to a public host. Refused outright.
        case insecurePublicHost
    }

    /// Normalise a user-typed URL. Bare hosts (`lumi.example.com`) get
    /// `https://` prepended.
    public static func normalize(_ raw: String) throws(NormalizationError) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalid }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(), !host.isEmpty
        else { throw .invalid }
        guard scheme == "https" || scheme == "http" else { throw .unsupportedScheme }
        if scheme == "http" && !isPrivateHost(host) { throw .insecurePublicHost }
        comps.scheme = scheme
        comps.host = host
        if (scheme == "https" && comps.port == 443) || (scheme == "http" && comps.port == 80) {
            comps.port = nil
        }
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        guard let out = comps.string else { throw .invalid }
        return out
    }

    /// Lenient variant for persisted values (never throws; returns the
    /// input trimmed of a trailing slash when it can't be parsed).
    public static func normalizedOrRaw(_ raw: String) -> String {
        if let n = try? normalize(raw) { return n }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// True when `server_url` is plain http (the UI must warn).
    public static func isInsecure(_ serverURL: String) -> Bool {
        serverURL.lowercased().hasPrefix("http://")
    }

    /// Host label for UI copy ("Sign in to lumi.work.com").
    public static func displayHost(_ serverURL: String) -> String {
        guard let comps = URLComponents(string: serverURL), let host = comps.host else { return serverURL }
        var out = host
        if let port = comps.port { out += ":\(port)" }
        if !comps.path.isEmpty { out += comps.path }
        return out
    }

    /// `localhost`, RFC1918 / loopback / link-local IPv4, IPv6 loopback /
    /// ULA / link-local, and mDNS `*.local`.
    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 && h.split(separator: ".").count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _): return true
            case (192, 168): return true
            case (172, 16...31): return true
            case (169, 254): return true
            case (100, 64...127): return true // CGNAT / Tailscale
            default: return false
            }
        }
        if h.contains(":") {
            if h == "::1" { return true }
            if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80") { return true }
        }
        return false
    }
}
