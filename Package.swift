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
        )
    ],
    targets: [
        .target(name: "ContextPanelCore"),
        .testTarget(
            name: "ContextPanelCoreTests",
            dependencies: ["ContextPanelCore"]
        )
    ]
)
