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
            targets: ["ContextPanelAppMain"]
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
            name: "ContextPanelAccountSnapshot",
            targets: ["ContextPanelAccountSnapshot"]
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
        .target(name: "ContextPanelValidationFixtures"),
        .target(
            name: "ContextPanelValidationGalleryUI",
            dependencies: [
                "ContextPanelCore",
                "ContextPanelValidationFixtures",
                "ContextPanelWidgetUI",
            ]
        ),
        .target(
            name: "ContextPanelSettingsUI",
            dependencies: ["ContextPanelCore", "ContextPanelWidgetUI"]
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
        .target(
            name: "ContextPanelTVSupport",
            dependencies: ["ContextPanelCore"]
        ),
        // The Mac app's views are a library so the shared-view renderer can draw
        // them on the host; the Xcode app target compiles both directories as one.
        .target(
            name: "ContextPanelApp",
            dependencies: [
                "ContextPanelCore",
                "ContextPanelCloudKitSync",
                "ContextPanelSettingsUI",
                "ContextPanelWidgetUI",
                "ContextPanelValidationGalleryUI",
            ],
            exclude: ["Main"]
        ),
        .executableTarget(
            name: "ContextPanelAppStoreCapture",
            dependencies: ["ContextPanelApp", "ContextPanelCore", "ContextPanelWidgetUI"],
            path: "Tools/ContextPanelAppStoreCapture"
        ),
        .executableTarget(
            name: "ContextPanelAppMain",
            dependencies: ["ContextPanelApp"],
            path: "Sources/ContextPanelApp/Main"
        ),
        .executableTarget(
            name: "ContextPanelRefreshAgent",
            dependencies: ["ContextPanelCore", "ContextPanelCloudKitSync"]
        ),
        .executableTarget(
            name: "ContextPanelSharedViewRenderer",
            dependencies: [
                "ContextPanelApp",
                "ContextPanelCore",
                "ContextPanelWidgetUI",
                "ContextPanelSettingsUI",
                "ContextPanelTVSupport",
                "ContextPanelValidationFixtures",
                "ContextPanelValidationGalleryUI",
                "ContextPanelWatchSupport",
            ],
            path: "Tools/ContextPanelSharedViewRenderer"
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
            name: "ContextPanelAccountSnapshot",
            dependencies: ["ContextPanelCore"],
            path: "Tools/ContextPanelAccountSnapshot"
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
                "ContextPanelApp",
                "ContextPanelCore",
                "ContextPanelSharedViewRenderer",
                "ContextPanelCloudKitSync",
                "ContextPanelCompanionSupport",
                "ContextPanelSettingsUI",
                "ContextPanelTVSupport",
                "ContextPanelValidationFixtures",
                "ContextPanelValidationGalleryUI",
                "ContextPanelWatchSupport",
                "ContextPanelWidget",
                "ContextPanelWidgetUI",
            ]
        )
    ]
)
