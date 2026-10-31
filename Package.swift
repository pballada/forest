// swift-tools-version: 6.0
import PackageDescription

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
        .executableTarget(
            name: "Forest",
            dependencies: ["ForestCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ForestCoreTests",
            dependencies: ["ForestCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
