// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ledge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LedgeCore",  targets: ["LedgeCore"]),
        .library(name: "LedgeIndex", targets: ["LedgeIndex"]),
        .library(name: "LedgeStore", targets: ["LedgeStore"]),
        .executable(name: "ledge-tests", targets: ["LedgeTests"]),
        .executable(name: "LedgeApp", targets: ["LedgeApp"]),
    ],
    targets: [
        .target(name: "LedgeCore"),
        .target(name: "LedgeIndex", dependencies: ["LedgeCore"]),
        .target(name: "LedgeStore", dependencies: ["LedgeCore", "LedgeIndex"]),
        // Not a .testTarget: the Command Line Tools ship Testing.framework
        // without its _Testing_Foundation module, and XCTest needs full Xcode.
        // This is the same suite as a plain executable — `swift run ledge-tests`.
        .executableTarget(name: "LedgeTests", dependencies: ["LedgeCore", "LedgeIndex", "LedgeStore"]),
        .executableTarget(name: "LedgeApp", dependencies: ["LedgeCore", "LedgeIndex", "LedgeStore"]),
    ],
    swiftLanguageModes: [.v6]
)
