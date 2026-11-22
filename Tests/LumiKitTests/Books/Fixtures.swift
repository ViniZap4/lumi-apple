import Foundation

/// Shared cross-client fixtures live in `Tests/Fixtures/` (copied verbatim
/// into the TUI and web repos; SPEC-LIVROS §6). Located via `#filePath` so
/// no SwiftPM resource bundle is needed.
enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Books
            .deletingLastPathComponent() // LumiKitTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relative))
    }

    static func text(_ relative: String) throws -> String {
        String(decoding: try data(relative), as: UTF8.self)
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func freshDefaults() -> UserDefaults {
    let name = "lumi-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

func ts(_ s: String) -> Date {
    try! Date(s, strategy: .iso8601)
}
