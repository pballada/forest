// swift-tools-version: 6.0
import PackageDescription

// GhosttyKit (libghostty) is built from Ghostty's official source by scripts/build-ghosttykit.sh into Vendor/.
let package = Package(
    name: "Forest",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Forest", targets: ["Forest"]),
        .library(name: "ForestCore", targets: ["ForestCore"]),
    ],
    targets: [
        .target(
            name: "ForestCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "ForestTerminal",
            dependencies: ["GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "Forest",
            dependencies: ["ForestCore", "ForestTerminal"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ForestCoreTests",
            dependencies: ["ForestCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
