// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ContextPanel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ContextPanelCore",
            targets: ["ContextPanelCore"]
        ),
        .executable(
            name: "ContextPanelPreview",
            targets: ["ContextPanelPreview"]
        ),
        .executable(
            name: "ContextPanelRefreshAgent",
            targets: ["ContextPanelRefreshAgent"]
        ),
        .executable(
            name: "OpenAILimitProbe",
            targets: ["OpenAILimitProbe"]
        ),
        .executable(
            name: "CodexRateLimitProbe",
            targets: ["CodexRateLimitProbe"]
        ),
        .executable(
            name: "GeminiQuotaProbe",
            targets: ["GeminiQuotaProbe"]
        ),
        .executable(
            name: "ClaudeLimitProbe",
            targets: ["ClaudeLimitProbe"]
        ),
        .executable(
            name: "ClaudeStatuslineSetup",
            targets: ["ClaudeStatuslineSetup"]
        ),
        .executable(
            name: "SnapshotStoreProbe",
            targets: ["SnapshotStoreProbe"]
        ),
        .executable(
            name: "ContextPanelWidget",
            targets: ["ContextPanelWidget"]
        )
    ],
    targets: [
        .target(name: "ContextPanelCore"),
        .executableTarget(
            name: "ContextPanelPreview",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "ContextPanelRefreshAgent",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "OpenAILimitProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "CodexRateLimitProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "GeminiQuotaProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "ClaudeLimitProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "ClaudeStatuslineSetup",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "SnapshotStoreProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "ContextPanelWidget",
            dependencies: ["ContextPanelCore"]
        ),
        .testTarget(
            name: "ContextPanelCoreTests",
            dependencies: ["ContextPanelCore"]
        )
    ]
)
