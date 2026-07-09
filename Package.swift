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
            name: "ContextPanelApp",
            targets: ["ContextPanelApp"]
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
            name: "SnapshotStoreProbe",
            targets: ["SnapshotStoreProbe"]
        ),
        .executable(
            name: "PromptCacheTelemetryMirror",
            targets: ["PromptCacheTelemetryMirror"]
        ),
        .executable(
            name: "PromptCacheTelemetryProbe",
            targets: ["PromptCacheTelemetryProbe"]
        ),
        .library(
            name: "ContextPanelWidgetUI",
            targets: ["ContextPanelWidgetUI"]
        ),
        .library(
            name: "ContextPanelSettingsUI",
            targets: ["ContextPanelSettingsUI"]
        ),
        .executable(
            name: "ContextPanelWidget",
            targets: ["ContextPanelWidget"]
        )
    ],
    targets: [
        .target(name: "ContextPanelCore"),
        .target(
            name: "ContextPanelWidgetUI",
            dependencies: ["ContextPanelCore"]
        ),
        .target(
            name: "ContextPanelSettingsUI",
            dependencies: ["ContextPanelCore"]
        ),
        .target(
            name: "ContextPanelCompanionSupport",
            dependencies: ["ContextPanelCore", "ContextPanelWidgetUI"]
        ),
        .target(
            name: "ContextPanelCloudKitSync",
            dependencies: ["ContextPanelCore"]
        ),
        .target(
            name: "ContextPanelWatchSupport",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "ContextPanelApp",
            dependencies: ["ContextPanelCore", "ContextPanelCloudKitSync", "ContextPanelSettingsUI"]
        ),
        .executableTarget(
            name: "ContextPanelRefreshAgent",
            dependencies: ["ContextPanelCore", "ContextPanelCloudKitSync"]
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
            name: "SnapshotStoreProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "PromptCacheTelemetryMirror",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "PromptCacheTelemetryProbe",
            dependencies: ["ContextPanelCore"]
        ),
        .executableTarget(
            name: "ContextPanelWidget",
            dependencies: ["ContextPanelCore", "ContextPanelWidgetUI"]
        ),
        .testTarget(
            name: "ContextPanelCoreTests",
            dependencies: [
                "ContextPanelCore",
                "ContextPanelCompanionSupport",
                "ContextPanelSettingsUI",
                "ContextPanelWatchSupport",
                "ContextPanelWidget",
                "ContextPanelWidgetUI",
            ]
        )
    ]
)
