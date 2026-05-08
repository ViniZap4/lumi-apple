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
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "LumiKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
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
