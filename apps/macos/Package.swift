// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HighliteMenuBar",
    platforms: [
        // The app keeps its macOS 14 floor. The native recorder is macOS 15+
        // and is gated at runtime with @available checks.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "HighliteMenuBar", targets: ["HighliteMenuBar"]),
    ],
    targets: [
        .target(
            name: "HighliteMenuBarCore"
        ),
        .executableTarget(
            name: "HighliteMenuBar",
            dependencies: ["HighliteMenuBarCore"]
        ),
        .testTarget(
            name: "HighliteMenuBarCoreTests",
            dependencies: ["HighliteMenuBarCore"],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "HighliteMenuBarTests",
            dependencies: ["HighliteMenuBar", "HighliteMenuBarCore"]
        ),
    ]
)
