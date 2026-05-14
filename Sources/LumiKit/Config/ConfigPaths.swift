import Foundation

/// Filesystem locations for lumi's per-user configuration. The directory is
/// `~/.config/lumi/` on every platform we ship to, matching the TUI client's
/// convention (`tui-client/config/config.go`). On iOS / iPadOS / visionOS
/// `NSHomeDirectory()` returns the app sandbox home so the directory is
/// per-app; on macOS (sandbox disabled in v0.1) it's the user's real home, so
/// `apple.yaml` and `vaults.yaml` are shared with the TUI on the same machine.
///
/// File ownership:
///
///   ~/.config/lumi/config.yaml   — TUI prefs only (editor, themes, …)
///   ~/.config/lumi/apple.yaml    — Apple client prefs only (this client)
///   ~/.config/lumi/vaults.yaml   — shared vault registry (Apple writes; TUI
///                                  Phase 5 will read)
///   ~/.config/lumi/servers.yaml  — shared server accounts (future; see SPEC)
///   ~/.config/lumi/themes/       — TUI custom themes (future Apple use)
///
/// Callers should never hard-code these paths; they go through this type so a
/// future migration (e.g. `XDG_CONFIG_HOME` honoring) lands in one place.
public enum ConfigPaths {
    public static var directory: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent(".config/lumi", isDirectory: true)
    }

    public static var apple: URL {
        directory.appendingPathComponent("apple.yaml", isDirectory: false)
    }

    public static var vaults: URL {
        directory.appendingPathComponent("vaults.yaml", isDirectory: false)
    }

    /// Best-effort `mkdir -p`. Returns true if the directory exists at the
    /// end, regardless of whether we created it. Logged failures only — a
    /// missing config dir is non-fatal; the caller falls back to in-memory
    /// defaults.
    @discardableResult
    public static func ensureDirectory() -> Bool {
        let fm = FileManager.default
        let path = directory.path
        if fm.fileExists(atPath: path) { return true }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return fm.fileExists(atPath: path)
        }
    }
}
