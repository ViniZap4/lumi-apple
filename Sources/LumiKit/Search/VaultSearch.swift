import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One ranked search hit. `lineNumber == 0` means the match was purely
/// against the filename / relative path; `snippet` is non-empty only when
/// the body matched.
public struct SearchHit: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let relativePath: String
    public let title: String
    public let lineNumber: Int
    public let snippet: String
    public let score: Int

    public init(
        id: String,
        url: URL,
        relativePath: String,
        title: String,
        lineNumber: Int,
        snippet: String,
        score: Int
    ) {
        self.id = id
        self.url = url
        self.relativePath = relativePath
        self.title = title
        self.lineNumber = lineNumber
        self.snippet = snippet
        self.score = score
    }
}

/// Tunables for a single search call. Defaults are tuned for typical
/// vaults (≤ tens of thousands of .md files, snippets large enough to
/// give context without overflowing a row).
public struct SearchOptions: Sendable {
    public var caseSensitive: Bool
    public var includeContent: Bool
    public var maxResults: Int
    /// Files whose on-disk size exceeds this are skipped from body
    /// matching. They still participate in filename matching. Default
    /// 1 MiB — keeps an accidental binary or huge log under control.
    public var maxBodyBytes: Int
    /// Maximum snippet length surfaced in results. Centred around the
    /// first body match in the file.
    public var snippetLength: Int

    public init(
        caseSensitive: Bool = false,
        includeContent: Bool = true,
        maxResults: Int = 200,
        maxBodyBytes: Int = 1 << 20,
        snippetLength: Int = 120
    ) {
        self.caseSensitive = caseSensitive
        self.includeContent = includeContent
        self.maxResults = maxResults
        self.maxBodyBytes = maxBodyBytes
        self.snippetLength = snippetLength
    }
}

/// Filesystem-walking full-text search over a vault. Actor isolation so
/// concurrent calls from the UI serialise cleanly; supports cancellation
/// via `Task.cancel()` on the calling task.
///
/// Does NOT touch `FolderNode` — that type is `@MainActor` and lazy,
/// which makes it the wrong tool for a search that's expected to span
/// folders the user hasn't expanded yet. Instead we use
/// `FileManager.enumerator` directly: one walk, no UI thread.
public actor VaultSearch {
    public init() {}

    /// Walks `vaultURL` and returns hits matching `query`. The result
    /// is sorted by descending score (filename match > body match,
    /// prefix > contains, earlier body lines > later ones). One hit
    /// per file — the highest-scoring match for that file.
    public func search(
        query: String,
        vaultURL: URL,
        options: SearchOptions = .init()
    ) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        }
        let needle = options.caseSensitive ? trimmed : trimmed.lowercased()
        // On macOS, /var, /tmp, /private/var/folders, and other
        // firmlinks make `FileManager.enumerator(at: vaultURL)` hand
        // back URLs with a different prefix than the vault root we
        // received (e.g. /var/... vs /private/var/...).
        // `URL.resolvingSymlinksInPath()` doesn't normalise firmlinks;
        // `realpath()` does. Both sides of the relative-path strip
        // go through the same canonical form so the prefix match
        // never disagrees.
        let canonicalRoot = Self.canonicalPath(vaultURL)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var hits: [SearchHit] = []

        // Manual nextObject loop — `for ... in enumerator` uses
        // `makeIterator`, which isn't callable from async contexts. The
        // explicit while loop sidesteps that limitation while still
        // letting Task.checkCancellation() interrupt long walks.
        while let raw = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let fileURL = raw as? URL else { continue }
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            // FileManager.enumerator descends through every directory by
            // default; .skipsHiddenFiles already excludes ".lumi" et al.

            let canonicalFile = Self.canonicalPath(fileURL)
            let relPath = Self.relativePath(absolute: canonicalFile, root: canonicalRoot)
            let titleFromFilename = fileURL.deletingPathExtension().lastPathComponent
            let nameHaystack = options.caseSensitive ? titleFromFilename : titleFromFilename.lowercased()
            let pathHaystack = options.caseSensitive ? relPath : relPath.lowercased()

            var bestScore = 0
            var bestLine = 0
            var bestSnippet = ""

            // Filename / path matching first — score reflects how
            // strongly the match anchors at the start.
            if nameHaystack.hasPrefix(needle) {
                bestScore = 100
            } else if nameHaystack.contains(needle) {
                bestScore = 80
            } else if pathHaystack.contains(needle) {
                bestScore = 50
            }

            // Body matching — only if we don't already have a perfect
            // prefix match (we keep one hit per file; filename
            // matches don't benefit from a body line number anyway).
            if options.includeContent && bestScore < 100 {
                if let bodyHit = try await bodyMatch(
                    fileURL: fileURL,
                    needle: needle,
                    options: options
                ) {
                    let bodyScore = max(10, 60 - bodyHit.lineNumber)
                    if bodyScore > bestScore {
                        bestScore = bodyScore
                        bestLine = bodyHit.lineNumber
                        bestSnippet = bodyHit.snippet
                    } else if bestScore > 0 {
                        // Filename match wins, but keep the snippet so
                        // the UI can show context.
                        bestSnippet = bodyHit.snippet
                        bestLine = bodyHit.lineNumber
                    }
                }
            }

            if bestScore == 0 { continue }

            hits.append(SearchHit(
                id: "\(relPath):\(bestLine)",
                url: fileURL,
                relativePath: relPath,
                title: titleFromFilename,
                lineNumber: bestLine,
                snippet: bestSnippet,
                score: bestScore
            ))

            if hits.count >= options.maxResults * 2 {
                // We need slack on the cap so the sort below can pick
                // the best maxResults of what we've collected. Don't
                // run forever though.
                break
            }
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.relativePath < rhs.relativePath
        }
        if hits.count > options.maxResults {
            hits = Array(hits.prefix(options.maxResults))
        }
        return hits
    }

    // MARK: - Body matching

    private struct BodyMatch {
        let lineNumber: Int
        let snippet: String
    }

    /// Returns the first body line matching `needle`, plus a centered
    /// snippet. Returns nil if the file is over the size cap, unreadable,
    /// or doesn't contain the needle.
    private func bodyMatch(
        fileURL: URL,
        needle: String,
        options: SearchOptions
    ) async throws -> BodyMatch? {
        try Task.checkCancellation()

        // Cheap size gate — avoid pulling huge files into memory just
        // to scan them. `attributesOfItem` is faster than reading.
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attrs?[.size] as? Int, size > options.maxBodyBytes {
            return nil
        }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let haystack = options.caseSensitive ? content : content.lowercased()
        if haystack.range(of: needle) == nil {
            return nil
        }

        // Walk lines; first match wins (lower lines are more salient
        // anyway, and a single snippet keeps the UI scannable).
        var lineNumber = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineH = options.caseSensitive ? String(line) : String(line).lowercased()
            if lineH.contains(needle) {
                let snippet = centeredSnippet(
                    line: String(line),
                    needle: needle,
                    caseSensitive: options.caseSensitive,
                    maxLength: options.snippetLength
                )
                return BodyMatch(lineNumber: lineNumber, snippet: snippet)
            }
            lineNumber += 1
        }
        return nil
    }

    /// Trims `line` to ~`maxLength` characters centered on the first
    /// match of `needle`. Adds ellipses when truncating.
    private func centeredSnippet(
        line: String,
        needle: String,
        caseSensitive: Bool,
        maxLength: Int
    ) -> String {
        let trimmedLine = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        if trimmedLine.count <= maxLength {
            return trimmedLine
        }
        let haystack = caseSensitive ? trimmedLine : trimmedLine.lowercased()
        guard let range = haystack.range(of: needle) else {
            return String(trimmedLine.prefix(maxLength)) + "…"
        }
        let matchOffset = trimmedLine.distance(from: trimmedLine.startIndex, to: range.lowerBound)
        let half = maxLength / 2
        var start = max(0, matchOffset - half)
        let end = min(trimmedLine.count, start + maxLength)
        // Re-balance if we hit the right edge first.
        if end - start < maxLength {
            start = max(0, end - maxLength)
        }
        let startIdx = trimmedLine.index(trimmedLine.startIndex, offsetBy: start)
        let endIdx = trimmedLine.index(trimmedLine.startIndex, offsetBy: end)
        var snippet = String(trimmedLine[startIdx..<endIdx])
        if start > 0 { snippet = "…" + snippet }
        if end < trimmedLine.count { snippet += "…" }
        return snippet
    }

    /// Canonical (firmlink + symlink resolved) on-disk path for `url`.
    /// Falls back to `url.path` when the file doesn't exist; this
    /// matters because we feed candidate paths through here BEFORE
    /// confirming they exist (e.g. for the vault root we might be
    /// given a URL the user just chose). `realpath()` is the only
    /// API that resolves macOS firmlinks (`/var` → `/private/var`).
    private static func canonicalPath(_ url: URL) -> String {
        #if canImport(Darwin)
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        #endif
        return url.path
    }

    /// Drop the vault root prefix so callers see vault-relative paths.
    /// Both inputs must already be canonical (see canonicalPath).
    private static func relativePath(absolute: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if absolute.hasPrefix(prefix) {
            return String(absolute.dropFirst(prefix.count))
        }
        return absolute
    }
}
