import Foundation

/// Single SPEC-shaped `vaults.yaml` row, kept on disk in `~/.config/lumi/`
/// and shared with the TUI client (Phase 5 will read this file too).
///
/// The shape mirrors `SPEC.md > Client architecture > Multi-vault, multi-server clients`:
///
///     vaults:
///       - id: 8c5a1d9f-...
///         name: Work team
///         path: ~/notes/work
///         server: https://lumi.work.com
///         account: alice
///         added_at: 2026-05-14T12:00:00Z
///         last_opened_at: 2026-05-14T12:05:00Z
///
/// `path` is stored with a leading `~/` when inside the user's home so the
/// file is portable across machines that share the same `$HOME`-relative
/// layout (common for Syncthing / iCloud Drive setups).
public struct VaultRegistryEntry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var server: String?
    public var account: String?
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public init(
        id: UUID,
        name: String,
        path: String,
        server: String? = nil,
        account: String? = nil,
        addedAt: Date,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.server = server
        self.account = account
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// File-backed registry of vault locations shared between lumi clients via
/// `~/.config/lumi/vaults.yaml`. The Apple client owns the writer for v1;
/// the TUI's Phase 5 work will add a reader on the Go side.
///
/// Mirror semantics: Apple keeps a SwiftData `VaultRecord` (with bookmark
/// blobs that can't live in YAML) as its primary store, and mirrors metadata
/// changes here. The yaml file is downstream — the SwiftData store is
/// authoritative on the Apple side. When the TUI starts writing this file
/// the Apple client will need a reconciliation pass on launch.
public final class VaultRegistry: @unchecked Sendable {
    public static let shared = VaultRegistry(fileURL: ConfigPaths.vaults)

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.vinizap.lumi.vault-registry")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// All known vault entries, sorted by `lastOpenedAt` descending so the
    /// most-recent vault is first — matches the Apple sidebar's order.
    public func entries() -> [VaultRegistryEntry] {
        queue.sync { readFromDisk(fileURL) }
    }

    /// Insert or update an entry by `id`. The on-disk file is rewritten with
    /// the merged set so the operation is idempotent.
    public func upsert(_ entry: VaultRegistryEntry) {
        queue.sync {
            var current = readFromDisk(fileURL)
            if let idx = current.firstIndex(where: { $0.id == entry.id }) {
                current[idx] = entry
            } else {
                current.append(entry)
            }
            writeToDisk(current, to: fileURL)
        }
    }

    /// Remove an entry by `id`. No-op if missing.
    public func remove(id: UUID) {
        queue.sync {
            var current = readFromDisk(fileURL)
            current.removeAll(where: { $0.id == id })
            writeToDisk(current, to: fileURL)
        }
    }
}

// MARK: - Path encoding (~/ -prefix when inside home)

/// Encode an absolute filesystem path with a leading `~/` when it sits inside
/// the user's home directory. Used on write so the yaml stays portable
/// across machines that share `$HOME`-relative layouts.
public func encodeHomeRelative(_ absolute: String) -> String {
    let home = NSHomeDirectory()
    if absolute == home { return "~" }
    let prefix = home.hasSuffix("/") ? home : home + "/"
    if absolute.hasPrefix(prefix) {
        return "~/" + String(absolute.dropFirst(prefix.count))
    }
    return absolute
}

/// Reverse of `encodeHomeRelative` — expands a leading `~` to the current
/// user's home directory. Paths without `~` pass through unchanged.
public func expandHomeRelative(_ encoded: String) -> String {
    if encoded == "~" { return NSHomeDirectory() }
    if encoded.hasPrefix("~/") {
        return NSHomeDirectory() + "/" + String(encoded.dropFirst(2))
    }
    return encoded
}

// MARK: - Hand-rolled YAML I/O

private func readFromDisk(_ url: URL) -> [VaultRegistryEntry] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else { return [] }

    var entries: [VaultRegistryEntry] = []
    var currentFields: [String: String] = [:]
    var inList = false

    func flushCurrent() {
        guard !currentFields.isEmpty else { return }
        if let entry = entryFromFields(currentFields) {
            entries.append(entry)
        }
        currentFields = [:]
    }

    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmedLeading.isEmpty || trimmedLeading.first == "#" { continue }

        // Top-level key (no leading whitespace).
        if line == trimmedLeading {
            flushCurrent()
            // Recognised top-level key: `vaults:`. Anything else is ignored
            // to be tolerant of hand-edits.
            if trimmedLeading.hasPrefix("vaults:") {
                inList = true
            } else {
                inList = false
            }
            continue
        }
        guard inList else { continue }

        // List item start: `  - key: value`.
        if trimmedLeading.first == "-" {
            flushCurrent()
            var rest = trimmedLeading.dropFirst() // drop '-'
            rest = rest.drop(while: { $0 == " " })
            if let (k, v) = splitKeyValue(String(rest)) {
                currentFields[k] = v
            }
            continue
        }

        // Continuation of current entry: `    key: value`.
        if let (k, v) = splitKeyValue(String(trimmedLeading)) {
            currentFields[k] = v
        }
    }
    flushCurrent()

    // Newest first.
    return entries.sorted { (a, b) in
        let la = a.lastOpenedAt ?? a.addedAt
        let lb = b.lastOpenedAt ?? b.addedAt
        return la > lb
    }
}

private func splitKeyValue(_ s: String) -> (String, String)? {
    guard let colon = s.firstIndex(of: ":") else { return nil }
    let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
    if key.isEmpty { return nil }
    let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    return (key, unquote(value))
}

private func unquote(_ s: String) -> String {
    guard s.count >= 2 else { return s }
    if (s.first == "\"" && s.last == "\"") || (s.first == "'" && s.last == "'") {
        return String(s.dropFirst().dropLast())
    }
    return s
}

private func entryFromFields(_ f: [String: String]) -> VaultRegistryEntry? {
    guard let idStr = f["id"], let id = UUID(uuidString: idStr) else { return nil }
    guard let name = f["name"], !name.isEmpty else { return nil }
    guard let path = f["path"], !path.isEmpty else { return nil }
    let server = nonNullOrNil(f["server"])
    let account = nonNullOrNil(f["account"])
    let addedAt = parseDate(f["added_at"]) ?? Date()
    let lastOpened = parseDate(f["last_opened_at"])
    return VaultRegistryEntry(
        id: id,
        name: name,
        path: path,
        server: server,
        account: account,
        addedAt: addedAt,
        lastOpenedAt: lastOpened
    )
}

private func nonNullOrNil(_ s: String?) -> String? {
    guard let s, !s.isEmpty, s.lowercased() != "null" else { return nil }
    return s
}

private func parseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty, s.lowercased() != "null" else { return nil }
    return try? Date(s, strategy: .iso8601)
}

private func formatDate(_ d: Date) -> String {
    d.ISO8601Format()
}

private func writeToDisk(_ entries: [VaultRegistryEntry], to url: URL) {
    ConfigPaths.ensureDirectory()
    var lines: [String] = []
    lines.append("# lumi shared vault registry. Format defined in SPEC.md.")
    lines.append("# Written by lumi-apple; read by both the Apple client and the TUI (Phase 5+).")
    lines.append("vaults:")
    // Most recent first — matches the sidebar's sort.
    let sorted = entries.sorted { (a, b) in
        let la = a.lastOpenedAt ?? a.addedAt
        let lb = b.lastOpenedAt ?? b.addedAt
        return la > lb
    }
    for e in sorted {
        lines.append("  - id: \(e.id.uuidString.lowercased())")
        lines.append("    name: \(yamlString(e.name))")
        lines.append("    path: \(yamlString(e.path))")
        lines.append("    server: \(e.server.map(yamlString) ?? "null")")
        lines.append("    account: \(e.account.map(yamlString) ?? "null")")
        lines.append("    added_at: \(formatDate(e.addedAt))")
        if let last = e.lastOpenedAt {
            lines.append("    last_opened_at: \(formatDate(last))")
        } else {
            lines.append("    last_opened_at: null")
        }
    }
    let body = lines.joined(separator: "\n") + "\n"
    try? body.write(to: url, atomically: true, encoding: .utf8)
}

private func yamlString(_ s: String) -> String {
    if s.isEmpty { return "\"\"" }
    if s.contains(":") || s.contains("#") || s.contains("\"") || s.first == " " || s.last == " " {
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    return s
}
