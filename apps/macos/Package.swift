// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HighliteMenuBar",
    platforms: [
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
