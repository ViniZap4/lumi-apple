// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lumi-apple",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "LumiKit", targets: ["LumiKit"]),
        .library(name: "LumiUI", targets: ["LumiUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        // Yjs CRDT binding for the Apple client. Wire-compatible with the
        // server's yrs (Rust) — same lib0-v1 encoding for state vectors
        // and updates. Frozen-since-2024 (0.2.1) wrapper around yrs via
        // UniFFI; we contain it behind the LumiCRDT actor so the Swift 6
        // strict-concurrency surface stays small. Phase H slice 1.
        .package(url: "https://github.com/y-crdt/yswift.git", from: "0.2.1")
    ],
    targets: [
        .target(
            name: "LumiKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "YSwift", package: "yswift")
            ],
            path: "Sources/LumiKit"
        ),
        .target(
            name: "LumiUI",
            dependencies: ["LumiKit"],
            path: "Sources/LumiUI"
        ),
        .testTarget(
            name: "LumiKitTests",
            dependencies: ["LumiKit"],
            path: "Tests/LumiKitTests"
        ),
        .testTarget(
            name: "LumiUITests",
            dependencies: ["LumiUI"],
            path: "Tests/LumiUITests"
        )
    ],
    swiftLanguageModes: [.v6]
)
