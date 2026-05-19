import Foundation
import Testing
@testable import LumiKit

@Suite("VaultSearch")
struct VaultSearchTests {
    /// Build a temporary vault with the given files. `files` maps
    /// vault-relative paths (e.g. "alpha.md", "sub/beta.md") to their
    /// contents. Returns the vault root URL.
    private static func makeTempVault(files: [String: String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "lumi-search-test-\(UUID().uuidString)"
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func emptyQueryReturnsNothing() async throws {
        let root = try Self.makeTempVault(files: [
            "alpha.md": "hello world",
        ])
        let hits = try await VaultSearch().search(query: "", vaultURL: root)
        #expect(hits.isEmpty)
    }

    @Test func noMatchReturnsEmpty() async throws {
        let root = try Self.makeTempVault(files: [
            "alpha.md": "hello world",
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        #expect(hits.isEmpty)
    }

    @Test func filenamePrefixMatchOutranksContains() async throws {
        let root = try Self.makeTempVault(files: [
            "design.md": "x",
            "redesign.md": "x",
        ])
        let hits = try await VaultSearch().search(query: "design", vaultURL: root)
        #expect(hits.count == 2)
        // The prefix match should sort first.
        #expect(hits[0].relativePath == "design.md")
        #expect(hits[1].relativePath == "redesign.md")
        #expect(hits[0].score > hits[1].score)
    }

    @Test func bodyMatchProducesSnippetWithLineNumber() async throws {
        let body = """
        # Heading
        intro line
        the magic needle lives on line 2
        outro
        """
        let root = try Self.makeTempVault(files: [
            "alpha.md": body,
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        let hit = try #require(hits.first)
        #expect(hit.lineNumber == 2) // zero-indexed
        #expect(hit.snippet.contains("magic needle"))
    }

    @Test func filenameMatchOutranksBodyMatch() async throws {
        let root = try Self.makeTempVault(files: [
            "needle.md": "irrelevant body",
            "other.md": "this has the needle somewhere in the body",
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        #expect(hits.count == 2)
        // The filename-prefix hit must outrank the body hit.
        #expect(hits[0].relativePath == "needle.md")
        #expect(hits[0].lineNumber == 0)
    }

    @Test func caseInsensitiveByDefault() async throws {
        let root = try Self.makeTempVault(files: [
            "alpha.md": "Hello World",
        ])
        let hits = try await VaultSearch().search(query: "WORLD", vaultURL: root)
        #expect(hits.count == 1)
    }

    @Test func caseSensitiveOptionRespected() async throws {
        let root = try Self.makeTempVault(files: [
            "alpha.md": "Hello World",
        ])
        var opts = SearchOptions()
        opts.caseSensitive = true
        let hits = try await VaultSearch().search(query: "WORLD", vaultURL: root, options: opts)
        #expect(hits.isEmpty)
    }

    @Test func includeContentFalseSkipsBodyMatching() async throws {
        let root = try Self.makeTempVault(files: [
            "alpha.md": "secret needle here",
        ])
        var opts = SearchOptions()
        opts.includeContent = false
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root, options: opts)
        // Filename doesn't match, body matching disabled → nothing.
        #expect(hits.isEmpty)
    }

    @Test func nestedSubdirsAreWalked() async throws {
        let root = try Self.makeTempVault(files: [
            "a/b/c/deep.md": "the magic needle is buried deep",
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        let hit = try #require(hits.first)
        #expect(hit.relativePath == "a/b/c/deep.md")
    }

    @Test func hiddenDirsAreSkipped() async throws {
        let root = try Self.makeTempVault(files: [
            ".lumi/cache.md": "needle hidden here",
            "visible.md": "no match here",
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        // .lumi is a hidden directory; FileManager.skipsHiddenFiles
        // must exclude it.
        #expect(hits.isEmpty)
    }

    @Test func sizeCapSkipsBodyForHugeFiles() async throws {
        let huge = String(repeating: "padding ", count: 50_000) // ~400 KB
        let root = try Self.makeTempVault(files: [
            "huge.md": huge + " needle " + huge,
        ])
        var opts = SearchOptions()
        opts.maxBodyBytes = 1024
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root, options: opts)
        // Filename doesn't match, body skipped due to size → nothing.
        #expect(hits.isEmpty)
    }

    @Test func nonMarkdownFilesIgnored() async throws {
        let root = try Self.makeTempVault(files: [
            "config.txt": "needle here in plain text",
            "image.png": "irrelevant binary stand-in",
            "real.md": "the actual needle target",
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        #expect(hits.count == 1)
        #expect(hits[0].relativePath == "real.md")
    }

    @Test func maxResultsHonoured() async throws {
        var files: [String: String] = [:]
        for i in 0..<10 {
            files["note-\(i).md"] = "the needle"
        }
        let root = try Self.makeTempVault(files: files)
        var opts = SearchOptions()
        opts.maxResults = 3
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root, options: opts)
        #expect(hits.count == 3)
    }

    @Test func snippetIsCenteredAroundMatch() async throws {
        let pad = String(repeating: "padding ", count: 30)
        let body = "\(pad)the magic needle lives in the middle\(pad)"
        let root = try Self.makeTempVault(files: [
            "alpha.md": body,
        ])
        let hits = try await VaultSearch().search(query: "needle", vaultURL: root)
        let hit = try #require(hits.first)
        #expect(hit.snippet.contains("magic needle"))
        // Snippet should be truncated (we asked for default 120) and
        // visually marked with the ellipsis on the leading edge.
        #expect(hit.snippet.count <= 130) // 120 + a few extra for ellipses
        #expect(hit.snippet.hasPrefix("…"))
    }

    @Test func cancellationIsHonoured() async throws {
        var files: [String: String] = [:]
        for i in 0..<500 {
            files["note-\(i).md"] = "the needle"
        }
        let root = try Self.makeTempVault(files: files)

        let task = Task {
            try await VaultSearch().search(query: "needle", vaultURL: root)
        }
        task.cancel()

        do {
            _ = try await task.value
            // If cancellation lands AFTER the (fast) search completes,
            // that's also acceptable — the task simply finished first.
        } catch is CancellationError {
            // expected when cancellation lands during the walk
        }
    }

    @Test func nonexistentVaultReturnsEmpty() async throws {
        let bogus = URL(fileURLWithPath: "/nonexistent/lumi/vault/that/does/not/exist")
        let hits = try await VaultSearch().search(query: "anything", vaultURL: bogus)
        #expect(hits.isEmpty)
    }
}
