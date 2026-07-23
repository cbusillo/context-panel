import Foundation
import Testing

@Test func primaryStatusCopyHidesImplementationDetails() throws {
    let root = try userFacingCopyRepositoryRoot()
    let forbiddenPhrasesByPath = [
        "Sources/ContextPanelCompanion/ContextPanelCompanionApp.swift": [
            "Apple Watch sync failed",
        ],
        "Sources/ContextPanelCompanionSupport/CompanionSyncPresentation.swift": [
            "Checking CloudKit",
            "Latest Mac snapshot",
            "Mac sync is stale",
            "Waiting for Mac sync",
            "Loading Mac sync",
            "local mirror",
            "CloudKit healthy",
            "CloudKit record not found",
            "CloudKit connected",
            "CloudKit unavailable",
            "CloudKit retrying",
            "publish usage lanes",
        ],
        "Sources/ContextPanelWatch/ContextPanelWatchApp.swift": [
            "Checking CloudKit",
            "Mac sync",
            "sync snapshot",
            "synced snapshot",
            "fresh snapshot",
            "publish usage limits",
        ],
        "Sources/ContextPanelWatchSupport/WatchSyncPresentation.swift": [
            "Checking CloudKit",
            "Mac sync",
            "sync snapshot",
            "synced snapshot",
            "fresh snapshot",
            "publish usage limits",
        ],
        "Sources/ContextPanelTV/ContextPanelTVApp.swift": [
            "Cloud sync is unavailable",
            "Contacting CloudKit",
            "Checking for Mac sync",
            "Offline validation mode",
            "Publish from your Mac",
            "Check your Mac connection",
        ],
        "Sources/ContextPanelTVSupport/TVRunwayPresentation.swift": [
            "Waiting for Mac sync",
            "Contacting CloudKit",
            "Mac-published snapshot",
            "companion snapshot",
            "last Mac snapshot",
            "published by your Mac",
        ],
        "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift": [
            "Mac sync failed",
        ],
        "Sources/ContextPanelWatchWidget/ContextPanelWatchWidget.swift": [
            "Waiting for Mac sync",
        ],
        "Sources/ContextPanelApp/ContextPanelApp.swift": [
            "Snapshot cache",
            "update the snapshot",
            "fresh snapshot",
            "quota snapshot",
            "usage snapshots",
        ],
        "Sources/ContextPanelCore/SnapshotStore.swift": [
            "The latest snapshot is old",
        ],
    ]

    for (relativePath, phrases) in forbiddenPhrasesByPath {
        let source = try String(
            contentsOf: root.appending(path: relativePath),
            encoding: .utf8
        )
        for phrase in phrases {
            #expect(!source.contains(phrase), "\(relativePath) still contains primary UI copy: \(phrase)")
        }
    }
}

@Test func providerAccessStateIsPresentedAcrossProductSurfaces() throws {
    let root = try userFacingCopyRepositoryRoot()
    let requiredPhrasesByPath = [
        "Sources/ContextPanelApp/ContextPanelApp.swift": [
            "ProviderAccessAlertsSection",
            "Provider Access",
        ],
        "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift": [
            "primaryProviderAccessAlert",
            "providerAccessProblemText",
        ],
        "Sources/ContextPanelWatch/ContextPanelWatchApp.swift": [
            "WatchProviderAccessSection",
        ],
        "Sources/ContextPanelCompanion/ContextPanelCompanionApp.swift": [
            "CompanionProviderAccessAlertsView",
        ],
        "Sources/ContextPanelWatchWidget/ContextPanelWatchWidget.swift": [
            "WatchCircularProviderAccessComplication",
            "WatchRectangularProviderAccessComplication",
            "WatchInlineProviderAccessComplication",
            "WatchCornerProviderAccessComplication",
        ],
        "Sources/ContextPanelTVSupport/TVRunwayPresentation.swift": [
            "report.accessState.requiresProminentPresentation",
            "report.providerAccessAlert",
        ],
    ]

    for (relativePath, phrases) in requiredPhrasesByPath {
        let source = try String(
            contentsOf: root.appending(path: relativePath),
            encoding: .utf8
        )
        for phrase in phrases {
            #expect(source.contains(phrase), "\(relativePath) is missing provider access presentation: \(phrase)")
        }
    }
}

private func userFacingCopyRepositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appending(path: "Package.swift").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
