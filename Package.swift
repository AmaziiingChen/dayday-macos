// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Dayday",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DaydayCore", targets: ["DaydayCore"]),
        .library(name: "DaydayStorage", targets: ["DaydayStorage"]),
        .library(name: "DaydayCapture", targets: ["DaydayCapture"]),
        .library(name: "DaydayUnderstanding", targets: ["DaydayUnderstanding"]),
        .library(name: "DaydayAI", targets: ["DaydayAI"]),
        .library(name: "DaydayIntegrations", targets: ["DaydayIntegrations"]),
        .library(name: "MarkEditCore", targets: ["MarkEditCore"]),
        .library(name: "MarkEditKit", targets: ["MarkEditKit"]),
        .executable(name: "DaydayApp", targets: ["DaydayApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [
                .brew(["sqlite3"])
            ]
        ),
        .target(name: "DaydayCore"),
        .target(
            name: "DaydayStorage",
            dependencies: ["DaydayCore", "CSQLite"]
        ),
        .target(
            name: "DaydayCapture",
            dependencies: ["DaydayCore"]
        ),
        .target(
            name: "DaydayUnderstanding",
            dependencies: ["DaydayCore"]
        ),
        .target(
            name: "DaydayAI",
            dependencies: ["DaydayCore"]
        ),
        .target(
            name: "DaydayIntegrations",
            dependencies: ["DaydayCore"]
        ),
        .target(
            name: "MarkEditCore",
            path: "ThirdParty/MarkEdit/MarkEditCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MarkEditKit",
            dependencies: ["MarkEditCore"],
            path: "ThirdParty/MarkEdit/MarkEditKit/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DaydayApp",
            dependencies: [
                "DaydayCore",
                "DaydayStorage",
                "DaydayCapture",
                "DaydayUnderstanding",
                "DaydayAI",
                "DaydayIntegrations",
                "MarkEditCore",
                "MarkEditKit"
            ],
            resources: [.copy("Resources/MarkEdit")]
        ),
        .testTarget(
            name: "DaydayCoreTests",
            dependencies: ["DaydayCore"]
        ),
        .testTarget(
            name: "DaydayCaptureTests",
            dependencies: ["DaydayCapture"]
        ),
        .testTarget(
            name: "DaydayStorageTests",
            dependencies: ["DaydayStorage", "DaydayCore", "CSQLite"]
        ),
        .testTarget(
            name: "DaydayAppTests",
            dependencies: ["DaydayApp"]
        ),
        .testTarget(
            name: "DaydayIntegrationsTests",
            dependencies: ["DaydayIntegrations"]
        ),
        .testTarget(
            name: "DaydayUnderstandingTests",
            dependencies: ["DaydayUnderstanding", "DaydayCore"]
        ),
        .testTarget(
            name: "DaydayAITests",
            dependencies: ["DaydayAI", "DaydayCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
