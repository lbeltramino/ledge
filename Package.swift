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
        .executable(name: "ledge", targets: ["LedgeCLI"]),
    ],
    dependencies: [
        // Mermaid diagrams drawn with CoreGraphics — no JavaScript, no WebView,
        // no network. Measured before it was picked: +1.0 MB of binary and
        // +2.6 MB of footprint with a diagram on screen, against 35-45 MB for
        // the same diagram in a WKWebView. Thanks to Australware for writing it.
        .package(url: "https://github.com/Australware/swift-mermaid", from: "0.3.0"),
    ],
    targets: [
        .target(name: "LedgeCore"),
        .target(name: "LedgeIndex", dependencies: ["LedgeCore"]),
        .target(name: "LedgeStore", dependencies: ["LedgeCore", "LedgeIndex"]),
        // Not a .testTarget: the Command Line Tools ship Testing.framework
        // without its _Testing_Foundation module, and XCTest needs full Xcode.
        // This is the same suite as a plain executable — `swift run ledge-tests`.
        .executableTarget(name: "LedgeTests", dependencies: ["LedgeCore", "LedgeIndex", "LedgeStore"]),
        .executableTarget(name: "LedgeApp",
                          dependencies: ["LedgeCore", "LedgeIndex", "LedgeStore",
                                         .product(name: "Mermaid", package: "swift-mermaid")]),
        // The headless half: no AppKit, so an agent calling it does not start a
        // connection to the window server to tick a checkbox.
        .executableTarget(name: "LedgeCLI", dependencies: ["LedgeCore", "LedgeStore"]),
    ],
    swiftLanguageModes: [.v6]
)
