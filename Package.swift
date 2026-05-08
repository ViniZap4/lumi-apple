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
    targets: [
        .target(
            name: "LumiKit",
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
