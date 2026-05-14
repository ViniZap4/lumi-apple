import Foundation

/// File-backed key/value store for the Apple client's preferences, written to
/// `~/.config/lumi/apple.yaml`. The shape is intentionally flat (one key per
/// line, `key: value`) so the file is editable by hand and the parser stays
/// trivial — mirrors the TUI client's `config.yaml` convention which is also
/// hand-rolled YAML (`tui-client/config/config.go`).
///
/// Threading: a single shared store backs the live `LumiPreferences`
/// instance, and `LumiPreferences` is `@MainActor`-bound. We protect the
/// in-memory cache with a serial dispatch queue anyway so a future detached
/// caller can't corrupt the file by interleaving reads with writes.
///
/// Value rules:
///
///   - Strings unquoted; quotes only added on write when the value contains
///     a YAML metacharacter or leading/trailing whitespace.
///   - Booleans serialised as `true` / `false`.
///   - Integers serialised plain.
///   - Doubles serialised with up to 6 fractional digits, no trailing zero
///     bloat.
///   - Comments (`# …`) and blank lines are preserved on a re-read but lost
///     on rewrite. The file is small enough that this is acceptable.
public final class PreferencesStore: @unchecked Sendable {
    public static let shared = PreferencesStore(fileURL: ConfigPaths.apple)

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.vinizap.lumi.preferences-store")
    private var cache: [String: String]
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.cache = [:]
    }

    // MARK: - Typed reads

    public func string(_ key: String) -> String? {
        load()
        return queue.sync { cache[key] }
    }

    public func bool(_ key: String) -> Bool? {
        guard let raw = string(key)?.lowercased() else { return nil }
        switch raw {
        case "true", "yes", "on", "1":  return true
        case "false", "no", "off", "0": return false
        default:                         return nil
        }
    }

    public func int(_ key: String) -> Int? {
        guard let raw = string(key) else { return nil }
        return Int(raw)
    }

    public func double(_ key: String) -> Double? {
        guard let raw = string(key) else { return nil }
        return Double(raw)
    }

    // MARK: - Typed writes

    public func set(_ key: String, _ value: String) { write(key, value) }
    public func set(_ key: String, _ value: Bool) { write(key, value ? "true" : "false") }
    public func set(_ key: String, _ value: Int) { write(key, String(value)) }
    public func set(_ key: String, _ value: Double) {
        // Trim trailing zeros so `1.0` writes as `1` and `1.5` as `1.5`.
        let s = String(format: "%g", value)
        write(key, s)
    }

    // MARK: - Internals

    private func write(_ key: String, _ value: String) {
        load()
        queue.sync {
            cache[key] = value
            persistLocked()
        }
    }

    private func load() {
        queue.sync {
            guard !loaded else { return }
            loaded = true
            cache = readFromDisk(fileURL) ?? [:]
        }
    }

    private func persistLocked() {
        ConfigPaths.ensureDirectory()
        let body = serialize(cache)
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort. A failed write leaves the in-memory cache intact;
            // the next mutation will retry. Non-fatal by design.
        }
    }

    /// Inject a fresh in-memory map. Used by one-shot migrations (e.g. from
    /// UserDefaults) before the first user-driven mutation. Safe to call
    /// before `load()` — sets `loaded=true` so subsequent reads see the
    /// injected values.
    public func bootstrap(_ values: [String: String]) {
        queue.sync {
            for (k, v) in values where cache[k] == nil {
                cache[k] = v
            }
            loaded = true
            persistLocked()
        }
    }
}

// MARK: - Hand-rolled YAML I/O (flat key:value only)

/// Reads a flat `key: value` YAML file. Returns nil if the file doesn't
/// exist (a missing config file is the default-state path, not an error).
private func readFromDisk(_ url: URL) -> [String: String]? {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    var out: [String: String] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.drop(while: { $0 == " " || $0 == "\t" })
        if line.isEmpty || line.first == "#" { continue }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { continue }
        let valueRaw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        out[key] = unquoteIfNeeded(valueRaw)
    }
    return out
}

private func unquoteIfNeeded(_ s: String) -> String {
    guard s.count >= 2 else { return s }
    if (s.first == "\"" && s.last == "\"") || (s.first == "'" && s.last == "'") {
        return String(s.dropFirst().dropLast())
    }
    return s
}

private func serialize(_ map: [String: String]) -> String {
    // Stable key order so the file's diff is reviewable and version-friendly.
    let keys = map.keys.sorted()
    var lines: [String] = []
    lines.append("# lumi-apple preferences. Managed by the Apple client; safe to edit.")
    lines.append("# Shared directory: ~/.config/lumi/. Per-client file: apple.yaml.")
    for k in keys {
        let v = map[k] ?? ""
        lines.append("\(k): \(quoteIfNeeded(v))")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func quoteIfNeeded(_ s: String) -> String {
    if s.isEmpty { return "\"\"" }
    if let first = s.first, first.isWhitespace { return "\"\(s)\"" }
    if let last = s.last, last.isWhitespace { return "\"\(s)\"" }
    if s.contains(":") || s.contains("#") || s.contains("\"") {
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    return s
}
