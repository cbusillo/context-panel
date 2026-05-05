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
        .testTarget(
            name: "ContextPanelCoreTests",
            dependencies: ["ContextPanelCore"]
        )
    ]
)
