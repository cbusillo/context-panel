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
        )
    ],
    targets: [
        .target(name: "ContextPanelCore"),
        .executableTarget(
            name: "ContextPanelPreview",
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
        .testTarget(
            name: "ContextPanelCoreTests",
            dependencies: ["ContextPanelCore"]
        )
    ]
)
