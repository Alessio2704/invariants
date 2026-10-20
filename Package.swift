// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .unsafeFlags(["-warnings-as-errors"]),
]

let package = Package(
    name: "invariants",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "invariants", targets: ["invariants"]),
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Extensions", targets: ["Extensions"]),
        .library(name: "InvariantKit", targets: ["InvariantKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "64aa0b26913249c4e7c21d351a215fba02702003"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "600.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "Extensions",
            dependencies: [],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "VersionGenTool",
            dependencies: [
                "Extensions",
            ],
            path: "Sources/VersionGenTool",
            swiftSettings: swiftSettings
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            dependencies: ["VersionGenTool"]
        ),
        .target(
            name: "Core",
            dependencies: [
                "Extensions",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings,
            plugins: ["VersionPlugin"]
        ),
        .target(
            name: "InvariantKit",
            dependencies: [
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "kits/kit-swift/Sources/InvariantKit",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Terminal",
            dependencies: [
                "Extensions",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Managers",
            dependencies: [
                "Core",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Workflows",
            dependencies: [
                "Core",
                "Managers",
                "Terminal",
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "invariants",
            dependencies: [
                "Core",
                "InvariantKit",
                "Terminal",
                "Workflows",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "Extensions", "Terminal"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "InvariantKitTests",
            dependencies: ["InvariantKit"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ScenarioTests",
            dependencies: ["Core", "Extensions", "InvariantKit", "Managers", "Terminal", "Workflows"],
            swiftSettings: swiftSettings
        ),
    ]
)
