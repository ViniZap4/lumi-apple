import Testing
import Foundation
@testable import LumiKit

@Suite("NoteFile load + write")
struct NoteFileTests {
    @Test("write then load roundtrips body and frontmatter")
    func roundtrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("hello.md")
        let fm = Frontmatter(id: "hello", title: "Hello", tags: ["greeting"])
        try NoteFile.write(body: "# Hello world\n", frontmatter: fm, to: url)

        let loaded = try NoteFile.load(at: url, vaultRoot: dir)
        #expect(loaded.note.title == "Hello")
        #expect(loaded.note.id == "hello")
        #expect(loaded.note.tags == ["greeting"])
        #expect(loaded.note.content == "# Hello world\n")
        #expect(loaded.frontmatter.updatedAt != nil)
    }

    @Test("write preserves unknown frontmatter keys across roundtrip")
    func unknownKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("note.md")
        let raw = """
        ---
        title: T
        custom: stays
        ---
        body
        """
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try NoteFile.load(at: url, vaultRoot: dir)
        try NoteFile.write(body: loaded.note.content, frontmatter: loaded.frontmatter, to: url)

        let reloaded = try NoteFile.load(at: url, vaultRoot: dir)
        #expect(reloaded.frontmatter.unknownLines.contains("custom: stays"))
    }

    @Test("hasChangedExternally returns true after writing later")
    func conflictDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("conflict.md")
        try "first".write(to: url, atomically: true, encoding: .utf8)
        let firstMTime = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? Date()

        // Force a different mtime via Thread.sleep — short, but enough to
        // exceed the half-second tolerance.
        Thread.sleep(forTimeInterval: 1.1)
        try "second".write(to: url, atomically: true, encoding: .utf8)

        #expect(NoteFile.hasChangedExternally(at: url, sinceLoadedAt: firstMTime))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
