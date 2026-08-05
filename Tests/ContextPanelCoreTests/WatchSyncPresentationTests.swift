import ContextPanelCore
import ContextPanelWatchSupport
import Foundation
import Testing

@Test func watchSyncPresentationShowsSanitizedFailureDetail() throws {
    let rawMessage = "CloudKit load failed for bearer secret-token and person@example.com "
        + "at https://example.com/account/123 from /Users/person/private/context.json."
    let result = CompanionSyncLoadResult(
        document: nil,
        status: .failure,
        errorMessage: rawMessage
    )
    let presentation = WatchSyncPresentation(
        result: result,
        snapshot: watchSyncSnapshot(state: .failure, status: .failure),
        syncErrorMessage: result.errorMessage
    )

    let diagnosticDetail = try #require(presentation.diagnosticDetail)
    #expect(presentation.title == "Update unavailable")
    #expect(presentation.detail == "The watch could not load the latest usage from your Mac.")
    #expect(presentation.tone == .failure)
    #expect(diagnosticDetail.contains("bearer [redacted]"))
    #expect(diagnosticDetail.contains("[email redacted]"))
    #expect(diagnosticDetail.contains("[url redacted]"))
    #expect(diagnosticDetail.contains("[local path]"))
    #expect(!diagnosticDetail.contains("secret-token"))
    #expect(!diagnosticDetail.contains("person@example.com"))
    #expect(!diagnosticDetail.contains("example.com"))
    #expect(!diagnosticDetail.contains("/Users/person"))
    #expect(!diagnosticDetail.contains("\n"))
    #expect(!diagnosticDetail.contains("\u{0007}"))
    #expect(presentation.diagnosticAccessibilityLabel == "Sync error details: \(diagnosticDetail)")
}

@Test func watchSyncPresentationRedactsControlObfuscatedCredentialParts() throws {
    let result = CompanionSyncLoadResult(
        document: nil,
        status: .failure,
        errorMessage: "Coo\u{009D}kie: session=secret\u{200B}-value"
    )
    let presentation = WatchSyncPresentation(
        result: result,
        snapshot: watchSyncSnapshot(state: .failure, status: .failure),
        syncErrorMessage: result.errorMessage
    )

    let diagnosticDetail = try #require(presentation.diagnosticDetail)
    #expect(diagnosticDetail == "cookie=[redacted]")
    #expect(!diagnosticDetail.contains("secret"))
    #expect(!diagnosticDetail.unicodeScalars.contains { scalar in
        CharacterSet.controlCharacters.contains(scalar)
            || scalar.properties.generalCategory == .format
    })
}

@Test func watchSyncPresentationUsesGenericFailureCopyWithoutSafeDetail() {
    let missingResult = CompanionSyncLoadResult(document: nil, status: .failure)
    let whitespaceResult = CompanionSyncLoadResult(
        document: nil,
        status: .failure,
        errorMessage: " \n\t "
    )

    for result in [missingResult, whitespaceResult] {
        let presentation = WatchSyncPresentation(
            result: result,
            snapshot: watchSyncSnapshot(state: .failure, status: .failure),
            syncErrorMessage: result.errorMessage
        )

        #expect(presentation.detail == "The watch could not load the latest usage from your Mac.")
        #expect(presentation.diagnosticDetail == nil)
        #expect(presentation.diagnosticAccessibilityLabel == nil)
    }
}

@Test func watchSyncPresentationBoundsDiagnosticByGraphemeCluster() throws {
    let exactResult = CompanionSyncLoadResult(
        document: nil,
        status: .failure,
        errorMessage: String(repeating: "👩🏽‍💻", count: 120)
    )
    let exactPresentation = WatchSyncPresentation(
        result: exactResult,
        snapshot: watchSyncSnapshot(state: .failure, status: .failure),
        syncErrorMessage: exactResult.errorMessage
    )
    let overResult = CompanionSyncLoadResult(
        document: nil,
        status: .failure,
        errorMessage: String(repeating: "👩🏽‍💻", count: 121)
    )
    let overPresentation = WatchSyncPresentation(
        result: overResult,
        snapshot: watchSyncSnapshot(state: .failure, status: .failure),
        syncErrorMessage: overResult.errorMessage
    )

    let exactDetail = try #require(exactPresentation.diagnosticDetail)
    let overDetail = try #require(overPresentation.diagnosticDetail)
    #expect(exactDetail.count == 120)
    #expect(exactDetail.allSatisfy { $0 == "👩🏽‍💻" })
    #expect(overDetail.count == 120)
    #expect(overDetail.last == "…")
    #expect(overDetail.dropLast().allSatisfy { $0 == "👩🏽‍💻" })
}

@Test func watchSyncPresentationTrimsWhitespaceBeforeDiagnosticEllipsis() throws {
    let result = CompanionSyncLoadResult(
        document: nil,
        status: .failure,
        errorMessage: String(repeating: "a", count: 118) + " " + String(repeating: "b", count: 10)
    )
    let presentation = WatchSyncPresentation(
        result: result,
        snapshot: watchSyncSnapshot(state: .failure, status: .failure),
        syncErrorMessage: result.errorMessage
    )

    let diagnosticDetail = try #require(presentation.diagnosticDetail)
    #expect(diagnosticDetail.count <= 120)
    #expect(diagnosticDetail.last == "…")
    #expect(!diagnosticDetail.hasSuffix(" …"))
}

@Test func watchSyncPresentationKeepsStaleSavedUsageCopyUnchanged() {
    let failedRefresh = CompanionSyncLoadResult(
        document: nil,
        status: .stale,
        errorMessage: "Network unavailable"
    )
    let ageOnlyStale = CompanionSyncLoadResult(document: nil, status: .stale)

    let failedPresentation = WatchSyncPresentation(
        result: failedRefresh,
        snapshot: watchSyncSnapshot(state: .stale, status: .stale),
        syncErrorMessage: failedRefresh.errorMessage
    )
    let ageOnlyPresentation = WatchSyncPresentation(
        result: ageOnlyStale,
        snapshot: watchSyncSnapshot(state: .stale, status: .stale),
        syncErrorMessage: nil
    )

    #expect(failedPresentation.title == "Saved usage is stale")
    #expect(failedPresentation.detail == "Showing saved usage because the latest update failed.")
    #expect(failedPresentation.diagnosticDetail == nil)
    #expect(failedPresentation.tone == .warning)
    #expect(ageOnlyPresentation.detail == "Open Context Panel on your Mac to refresh this watch.")
    #expect(ageOnlyPresentation.diagnosticDetail == nil)
}

@Test func watchSyncPresentationUsesInjectedTimeForGeneratedAge() throws {
    let now = Date(timeIntervalSince1970: 1_785_672_000)
    let generatedAt = now.addingTimeInterval(-125)
    let storedSnapshot = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [])
    )
    let result = CompanionSyncLoadResult(
        document: CompanionSyncDocument(storedSnapshot: storedSnapshot, publishedAt: now),
        status: .healthy
    )

    let presentation = WatchSyncPresentation(
        result: result,
        snapshot: watchSyncSnapshot(state: .ready, status: .healthy),
        syncErrorMessage: nil,
        now: now
    )
    let laterPresentation = WatchSyncPresentation(
        result: result,
        snapshot: watchSyncSnapshot(state: .ready, status: .healthy),
        syncErrorMessage: nil,
        now: now.addingTimeInterval(60 * 60)
    )

    #expect(presentation.generatedText == "2m ago")
    #expect(laterPresentation.generatedText == "1h ago")
    #expect(presentation.generatedAccessibilityText != laterPresentation.generatedAccessibilityText)
}

private func watchSyncSnapshot(state: WidgetSnapshotState, status: UsageStatus) -> WidgetSnapshot {
    WidgetSnapshot(
        state: state,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [],
        status: status,
        message: "Usage data is current."
    )
}
