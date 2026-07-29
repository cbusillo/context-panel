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

@Test func resetCreditPresentationStaysReadOnlyAndSurfaceScoped() throws {
    let root = try userFacingCopyRepositoryRoot()
    let guidanceSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelCore/ResetCreditGuidance.swift"),
        encoding: .utf8
    )
    let appSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelApp/ContextPanelApp.swift"),
        encoding: .utf8
    )
    let widgetSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelWidgetUI/ContextPanelWidgetViews.swift"),
        encoding: .utf8
    )
    let macWidgetSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelWidget/ContextPanelWidget.swift"),
        encoding: .utf8
    )
    let companionWidgetSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelCompanionWidget/ContextPanelCompanionWidget.swift"),
        encoding: .utf8
    )
    let appResetRow = try userFacingCopySection(
        in: appSource,
        startingAt: "private struct OpenAIResetCreditRow",
        endingAt: "private struct OpenAIAccountWindowPill"
    )
    let smallWidget = try userFacingCopySection(
        in: widgetSource,
        startingAt: "struct ContextPanelSmallWidget",
        endingAt: "private struct CPWSmallPrimaryLimitView"
    )
    let mediumWidget = try userFacingCopySection(
        in: widgetSource,
        startingAt: "struct ContextPanelMediumWidget",
        endingAt: "struct ContextPanelLargeWidget"
    )
    let largeWidget = try userFacingCopySection(
        in: widgetSource,
        startingAt: "struct ContextPanelLargeWidget",
        endingAt: "private enum CPWMainLimitHeaderLayout"
    )

    for phrase in ["redeem", "consume", "guarantee", "payment", "purchase"] {
        #expect(!guidanceSource.lowercased().contains(phrase), "Guidance source contains mutation or guarantee language: \(phrase)")
    }
    for phrase in ["Button(", "Link(", "openURL", "redeem", "consume"] {
        #expect(!appResetRow.contains(phrase), "The app reset-credit row must remain read-only: \(phrase)")
    }

    #expect(!smallWidget.contains("ResetCredit"))
    #expect(mediumWidget.contains("CPWMainLimitHeaderAccessory"))
    #expect(largeWidget.contains("CPWMainLimitHeaderAccessory"))
    #expect(mediumWidget.contains("maximumCount: 3"))
    #expect(largeWidget.contains("maximumCount: 5"))
    #expect(!mediumWidget.contains("maximumCount: resetCredit"))
    #expect(!largeWidget.contains("maximumCount: resetCredit"))
    #expect(widgetSource.contains("private struct CPWResetCreditHeaderToken"))
    #expect(widgetSource.contains("Text(\"Credits · \\(summary.accountCountText)\")"))
    #expect(widgetSource.contains("guidance.glanceActionText"))
    #expect(widgetSource.contains("showsResetCreditSurfaces: Bool = false"))
    #expect(macWidgetSource.contains("showsResetCreditSurfaces: true"))
    #expect(!companionWidgetSource.contains("showsResetCreditSurfaces: true"))
    #expect(appSource.contains("ResetCreditAvailabilityTag"))
    #expect(appSource.contains("Reset credits last seen"))
    #expect(appSource.contains("arrow.counterclockwise.circle"))
    #expect(widgetSource.contains("components.scheme = \"contextpanel\""))
    #expect(widgetSource.contains("components.host = \"provider\""))
    #expect(widgetSource.contains("\"Opens account detail in Context Panel\""))
    #expect(widgetSource.contains("\"Opens OpenAI detail in Context Panel\""))
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

private func userFacingCopySection(
    in source: String,
    startingAt start: String,
    endingAt end: String
) throws -> Substring {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return source[startRange.lowerBound..<endRange.lowerBound]
}
