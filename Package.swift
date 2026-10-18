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
        .library(name: "InvariantKit", targets: ["InvariantKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "64aa0b26913249c4e7c21d351a215fba02702003"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "600.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "VersionGenTool",
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
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Terminal",
            dependencies: [],
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
                "Workflows",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "InvariantKitTests",
            dependencies: ["InvariantKit"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ScenarioTests",
            dependencies: ["Core", "InvariantKit", "Managers", "Workflows"],
            swiftSettings: swiftSettings
        ),
    ]
)
