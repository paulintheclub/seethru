// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Seethru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Seethru", targets: ["Seethru"]),
    ],
    targets: [
        // All private-API usage lives here, behind protocols.
        .target(name: "PrivateAPI"),
        // Engine: window listing, rules, backends, hotkeys. No SwiftUI.
        .target(name: "SeethruCore", dependencies: ["PrivateAPI"]),
        // Menu bar UI.
        .executableTarget(name: "Seethru", dependencies: ["SeethruCore"]),
        .testTarget(name: "SeethruCoreTests", dependencies: ["SeethruCore"]),
    ],
    swiftLanguageModes: [.v6]
)
