import Foundation

/// Writable mirror of the bundled `Web/` resource directory (KaTeX +
/// Mermaid + fonts) used as the ACL anchor for `WKWebView.loadFileURL`.
///
/// **Why a mirror, not the bundle directly?** `WKWebView` has two ways
/// to load HTML:
///
///   - `loadHTMLString(_:baseURL:)` — fast, in-memory. On macOS the
///     web view is sandboxed and **cannot read file-system
///     subresources**, even when `baseURL` is a `file://` URL inside
///     the app bundle. KaTeX's `<link href="katex.min.css">` and the
///     CSS's `url(fonts/KaTeX_*.woff2)` requests silently 404 and the
///     `katex` global never appears — math renders blank.
///   - `loadFileURL(_:allowingReadAccessTo:)` — slower (round-trip
///     through disk) but grants explicit file-system ACL to the
///     directory passed as `allowingReadAccessTo`. Subresources inside
///     that dir load correctly.
///
/// We use `loadFileURL`. The host directory must contain both the
/// bundled assets and each render's HTML file, which means the bundle's
/// read-only `Web/` won't do — we need a writable subtree. So at first
/// use we mirror the bundle into `NSTemporaryDirectory()/com.vinizap.lumi/web/`.
///
/// The mirror is created once per launch (idempotent), and stale
/// `render-*.html` files left over from previous launches are pruned at
/// the same time so the temp dir doesn't accumulate cruft.
enum BundledWebAssets {
    /// Filesystem URL to the writable Web/ mirror. Pass this as the
    /// `allowingReadAccessTo:` argument when loading dynamic HTML via
    /// `loadFileURL`. `nil` only if the bundle layout drifts (i.e. the
    /// folder reference is missing from `App/Resources/Web/`) or the
    /// temp dir is unwritable — callers should fall back to a CDN
    /// build of the HTML in that case.
    static let writableWebDir: URL? = makeWritableMirror()

    /// Render a one-shot HTML payload into the mirror dir and return
    /// the file URL. The HTML is expected to reference bundled assets
    /// via relative paths (`<link href="katex.min.css">`); those
    /// resolve against the file's location which is the mirror dir.
    ///
    /// The file is left on disk after this call — `loadFileURL` reads
    /// it asynchronously, so removing it immediately would race the
    /// load. `cleanRenderFiles()` (called at launch) prunes any
    /// `render-*.html` that survive across runs.
    static func writeRenderHTML(_ html: String) -> URL? {
        guard let dir = writableWebDir else { return nil }
        let file = dir.appendingPathComponent("render-\(UUID().uuidString).html")
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    // MARK: - Setup

    private static func makeWritableMirror() -> URL? {
        guard let bundleWebDir = Bundle.main.resourceURL?
            .appendingPathComponent("Web", isDirectory: true)
        else { return nil }

        let fm = FileManager.default
        let mirror = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.vinizap.lumi", isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)

        do {
            try fm.createDirectory(
                at: mirror.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let bundleHash = self.bundleHash(at: bundleWebDir)
            let stampFile = mirror.appendingPathComponent(".lumi-web-version")
            let storedHash = (try? String(contentsOf: stampFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if storedHash == bundleHash, fm.fileExists(atPath: mirror.path) {
                // Mirror is current — just sweep transient render files.
                cleanRenderFiles(in: mirror)
                return mirror
            }

            // Stale or missing — wipe and rebuild.
            if fm.fileExists(atPath: mirror.path) {
                try? fm.removeItem(at: mirror)
            }
            try fm.copyItem(at: bundleWebDir, to: mirror)
            try? bundleHash.write(to: stampFile, atomically: true, encoding: .utf8)
            return mirror
        } catch {
            return nil
        }
    }

    /// Cheap "did the bundle change?" stamp: aggregated mtimes of the
    /// known asset files. Tied to the latest build's contents, not just
    /// the app version, so a Debug-build re-link refreshes the mirror.
    private static func bundleHash(at dir: URL) -> String {
        let names = ["katex.min.css", "katex.min.js", "auto-render.min.js", "mermaid.min.js"]
        var sig = ""
        for name in names {
            let u = dir.appendingPathComponent(name)
            if let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                sig += "\(name):\(date.timeIntervalSince1970)|"
            }
        }
        return sig
    }

    /// Delete any leftover render-*.html files from previous launches.
    /// Bundled assets (katex.*, mermaid.*, fonts/) stay put.
    private static func cleanRenderFiles(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries
        where url.lastPathComponent.hasPrefix("render-")
            && url.pathExtension.lowercased() == "html" {
            try? fm.removeItem(at: url)
        }
    }
}
