import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ContextPanelApp
@testable import ContextPanelCore
@testable import ContextPanelValidationFixtures
@testable import ContextPanelValidationGalleryUI

@Test func appProviderStatusIncludesBlockedAccessBeyondHealthyCapacity() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let summary = try #require(UsageSnapshot(
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "blocked-claude",
                accountName: "Blocked Claude",
                label: "Claude weekly",
                windowLabel: "Weekly",
                modelLabel: "Claude",
                unit: .percent,
                used: 45,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(86_400),
                lastUpdatedAt: generatedAt,
                confidence: .observed
            ),
        ]
    ).mainLimitSummaries.first)
    let alert = providerAccessAlert(
        kind: .blockedUntilReset,
        resetsAt: generatedAt.addingTimeInterval(3_600)
    )

    #expect(summary.status == .healthy)
    let status = providerStatusIncludingAccessAlerts(
        provider: .anthropic,
        baseStatuses: [summary.status],
        alerts: [alert]
    )
    #expect(status == .limited)
    #expect(summary.detailRemainingAccessibilityValue(status: status).contains("limited"))
    #expect(summary.usedPressureAccessibilityValue(status: status).contains("limited"))
    #expect(summary.pooledCapacityAccessibilityValue(updatedText: "just now", status: status).contains("limited"))
}

@MainActor
@Test func macValidationGalleryProductionPresentationsRender() throws {
    let validationDirectory = FileManager.default.temporaryDirectory.appending(
        path: "ContextPanelValidationGallery",
        directoryHint: .isDirectory
    )
    try? FileManager.default.removeItem(at: validationDirectory)
    let presentationDate = ValidationFixtureCatalog.referencePresentationDate
    let adapter = ValidationGalleryFixtureAdapter()
    let scenarios: [(
        fixtureID: ValidationFixtureID,
        presentation: ValidationGalleryPresentation,
        appearance: ValidationGalleryAppearance,
        dynamicTypeSize: DynamicTypeSize
    )] = [
        (.healthy, .overview, .light, .large),
        (.denseAccounts, .detail, .dark, .accessibility1),
        (.failed, .reconnect, .light, .large),
        (.failed, .diagnostics, .dark, .large),
    ]

    for scenario in scenarios {
        let fixture = ValidationFixtureCatalog.fixture(id: scenario.fixtureID)
        let snapshot = adapter.snapshot(fixture: fixture, presentationDate: presentationDate)
        let context = ValidationGalleryContext(
            fixture: fixture,
            snapshot: snapshot,
            presentationDate: presentationDate,
            presentation: scenario.presentation,
            family: .systemLarge,
            appearance: scenario.appearance,
            displayPreferences: adapter.displayPreferences
        )
        let content = MacValidationGalleryPreview(context: context)
            .frame(width: 1_024, height: 900)
            .environment(\.dynamicTypeSize, scenario.dynamicTypeSize)
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(
            named: scenario.appearance == .dark ? .darkAqua : .aqua
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_024, height: 900)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))

        #expect(pngData.count > 20_000)
        if let outputDirectory = ProcessInfo.processInfo.environment[
            "CONTEXT_PANEL_MAC_GALLERY_PREVIEW_DIRECTORY"
        ] {
            let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                .appending(path: "\(scenario.presentation.rawValue)-\(scenario.fixtureID.rawValue).png")
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: outputURL, options: .atomic)
        }
    }

    #expect(!FileManager.default.fileExists(atPath: validationDirectory.path))
}

@MainActor
@Test func macValidationGalleryModelUsesInjectedPresentationDate() {
    let presentationDate = ValidationFixtureCatalog.referencePresentationDate
    let adapter = ValidationGalleryFixtureAdapter()
    let fixture = ValidationFixtureCatalog.fixture(id: .healthy)
    let snapshot = adapter.snapshot(fixture: fixture, presentationDate: presentationDate)
    let context = ValidationGalleryContext(
        fixture: fixture,
        snapshot: snapshot,
        presentationDate: presentationDate,
        presentation: .overview,
        family: .systemLarge,
        appearance: .light,
        displayPreferences: adapter.displayPreferences
    )
    let model = ContextPanelAppModel.validationFixture(context: context)

    #expect(model.lastRefreshText == "1m ago")
    #expect(model.providerAccessAlerts == snapshot.providerAccessAlerts)
    #expect(model.currentSnapshot == snapshot.usageSnapshot.presented(at: presentationDate))
}

@MainActor
@Test func macValidationGalleryShellRendersAtProductionWidth() throws {
    let route = ValidationGalleryRoute(
        fixtureID: .denseAccounts,
        family: .systemLarge,
        appearance: .dark,
        presentation: .overview
    )
    let content = ValidationGalleryView(
        route: route,
        supportedPresentations: [.overview, .detail, .reconnect, .diagnostics, .widget],
        applicationPreview: { context in
            AnyView(MacValidationGalleryPreview(context: context))
        }
    )
    .frame(width: 1_120, height: 900)
    .environment(\.colorScheme, .dark)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: .darkAqua)
    hostingView.frame = NSRect(x: 0, y: 0, width: 1_120, height: 900)
    hostingView.layoutSubtreeIfNeeded()
    let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    let pngData = try #require(bitmap.representation(using: .png, properties: [:]))

    #expect(bitmap.size.width == 1_120)
    #expect(bitmap.size.height == 900)
    #expect(pngData.count > 30_000)
    if let outputPath = ProcessInfo.processInfo.environment[
        "CONTEXT_PANEL_MAC_GALLERY_SHELL_PREVIEW_PATH"
    ] {
        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

@Test func appProviderStatusKeepsFallbackAndDegradedAsWarnings() {
    let paidFallback = providerAccessAlert(kind: .paidFallbackActive)
    let degraded = providerAccessAlert(kind: .degraded)

    #expect(providerStatusIncludingAccessAlerts(
        provider: .anthropic,
        baseStatuses: [.healthy],
        alerts: [paidFallback]
    ) == .close)
    #expect(providerStatusIncludingAccessAlerts(
        provider: .anthropic,
        baseStatuses: [.healthy],
        alerts: [degraded]
    ) == .close)
    #expect(providerStatusIncludingAccessAlerts(
        provider: .google,
        baseStatuses: [.healthy],
        alerts: [paidFallback, degraded]
    ) == .healthy)
}

@Test func openAIAccountPresentationKeepsResolvedAccountsUnderSharedConfigurationDistinct() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accountIDs = ["resolved-a", "resolved-b", "resolved-c"]
    let limits = accountIDs.enumerated().map { index, accountID in
        UsageLimit(
            provider: .openAI,
            accountID: accountID,
            configuredAccountID: "configured-openai",
            accountName: "OpenAI Account \(index + 1)",
            label: "Codex Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 20 + index,
            limit: 100,
            resetsAt: now.addingTimeInterval(3 * 60 * 60),
            lastUpdatedAt: now,
            confidence: .observed
        )
    }
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: "resolved-b",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Account 2",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: now,
            coverage: .complete,
            earliestKnownExpiry: now.addingTimeInterval(86_400)
        ),
        status: .healthy,
        errorMessage: nil
    )
    let summaries = UsageSnapshot(generatedAt: now, limits: limits).mainLimitSummaries

    let accounts = OpenAIAccountLimitSummary.accounts(from: summaries, reports: [report])

    #expect(accounts.count == 3)
    #expect(Set(accounts.map(\.accountID)) == Set(accountIDs))
    #expect(accounts.allSatisfy { account in
        account.limits.map(\.accountID) == [account.accountID]
    })
}

@Test func openAIAccountPresentationKeepsResetCreditFailureVisibleAndFailed() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let failureReport = StoredProviderReport(
        provider: .openAI,
        accountID: "resolved-failure",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Failure",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: now,
            coverage: .countOnly
        ),
        status: .failure,
        errorMessage: "Refresh failed"
    )

    let accounts = OpenAIAccountLimitSummary.accounts(from: [], reports: [failureReport])
    let account = try #require(accounts.first)

    #expect(accounts.count == 1)
    #expect(account.accountID == "resolved-failure")
    #expect(account.limits.isEmpty)
    #expect(account.status == .failure)
    #expect(shouldShowProviderNavigation(provider: .openAI, summaries: [], reports: [failureReport]))
}

@Test func failureOnlyResetCreditSnapshotJSONLoadsAndShowsOpenAIProviderNavigation() throws {
    let root = try presentationTestTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let fixture = #"""
    {
      "schemaVersion": 1,
      "savedAt": "2026-07-28T12:00:00Z",
      "snapshot": {
        "generatedAt": "2026-07-28T12:00:00Z",
        "limits": []
      },
      "reports": [
        {
          "provider": "openai",
          "accountID": "fixture-openai-reset-credit",
          "configuredAccountID": "fixture-configured-openai",
          "accountName": "Fixture OpenAI",
          "generatedAt": "2026-07-28T12:00:00Z",
          "resetCredits": {
            "availableCount": 1,
            "observedAt": "2026-07-28T11:00:00Z",
            "coverage": "countOnly"
          },
          "status": "failure",
          "accessState": {
            "kind": "unknown"
          },
          "errorMessage": "Fixture-only sanitized refresh failure"
        }
      ],
      "promptCacheObservations": []
    }
    """#
    try Data(fixture.utf8).write(to: root.appending(path: "current-snapshot.json"))

    let result = JSONSnapshotStore(rootDirectory: root).loadCurrent()
    let storedSnapshot = try #require(result.snapshot)
    let report = try #require(storedSnapshot.reports.first)
    let account = try #require(OpenAIAccountLimitSummary.accounts(
        from: storedSnapshot.snapshot.mainLimitSummaries,
        reports: storedSnapshot.reports
    ).first)

    #expect(result.errorMessage == nil)
    #expect(result.status == .unknown)
    #expect(storedSnapshot.snapshot.limits.isEmpty)
    #expect(report.resetCredits?.availableCount == 1)
    #expect(report.status == .failure)
    #expect(report.errorMessage == "Fixture-only sanitized refresh failure")
    #expect(account.status == .failure)
    #expect(shouldShowProviderNavigation(
        provider: .openAI,
        summaries: storedSnapshot.snapshot.mainLimitSummaries,
        reports: storedSnapshot.reports
    ))
}

@Test func failedRefreshPreservesResetOnlyCreditsForProviderNavigation() throws {
    let root = try presentationTestTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = JSONSnapshotStore(rootDirectory: root)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let failedAt = observedAt.addingTimeInterval(3_600)
    let initialReport = ProviderConnectorReport(
        provider: .openAI,
        accountID: "resolved-openai",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Reset Only",
        generatedAt: observedAt,
        limits: [],
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: observedAt,
            coverage: .complete,
            earliestKnownExpiry: observedAt.addingTimeInterval(86_400)
        ),
        status: .healthy,
        errorMessage: nil
    )
    let failureReport = ProviderConnectorReport(
        provider: .openAI,
        accountID: "resolved-openai",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Reset Only",
        generatedAt: failedAt,
        limits: [],
        status: .failure,
        errorMessage: "Refresh failed"
    )

    try store.save(StoredUsageSnapshot(
        savedAt: observedAt,
        refreshResult: ConnectorRefreshResult(generatedAt: observedAt, reports: [initialReport])
    ))
    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: failedAt, reports: [failureReport]),
        savedAt: failedAt,
        preservesUnreportedAccounts: false
    )

    let storedSnapshot = try #require(store.loadCurrent().snapshot)
    let report = try #require(storedSnapshot.reports.first)
    let resetCredits = try #require(report.resetCredits)
    let account = try #require(OpenAIAccountLimitSummary.accounts(
        from: storedSnapshot.snapshot.mainLimitSummaries,
        reports: storedSnapshot.reports
    ).first)

    #expect(storedSnapshot.snapshot.limits.isEmpty)
    #expect(report.status == .failure)
    #expect(resetCredits.availableCount == 1)
    #expect(resetCredits.observedAt == observedAt)
    #expect(resetCredits.coverage == .countOnly)
    #expect(resetCredits.earliestKnownExpiry == nil)
    #expect(account.status == .failure)
    #expect(shouldShowProviderNavigation(
        provider: .openAI,
        summaries: storedSnapshot.snapshot.mainLimitSummaries,
        reports: storedSnapshot.reports
    ))
}

@Test func openAIAccountPresentationUsesStoredStaleStatusWithoutLimits() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let staleReport = StoredProviderReport(
        provider: .openAI,
        accountID: "resolved-stale",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Stale",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: now.addingTimeInterval(-3_600),
            coverage: .countOnly
        ),
        status: .stale,
        errorMessage: nil
    )

    let account = try #require(OpenAIAccountLimitSummary.accounts(from: [], reports: [staleReport]).first)

    #expect(account.status == .stale)
    #expect(shouldShowProviderNavigation(provider: .openAI, summaries: [], reports: [staleReport]))
}

@Test func providerNavigationIgnoresZeroCreditAndNonOpenAIReportsWithoutLimits() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let zeroOpenAIReport = StoredProviderReport(
        provider: .openAI,
        accountID: "resolved-zero",
        accountName: "OpenAI Zero",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 0,
            observedAt: now,
            coverage: .countOnly
        ),
        status: .failure,
        errorMessage: "Refresh failed"
    )
    let nonOpenAIReport = StoredProviderReport(
        provider: .anthropic,
        accountID: "claude",
        accountName: "Claude",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: now,
            coverage: .countOnly
        ),
        status: .failure,
        errorMessage: "Refresh failed"
    )

    #expect(!shouldShowProviderNavigation(provider: .openAI, summaries: [], reports: [zeroOpenAIReport]))
    #expect(!shouldShowProviderNavigation(provider: .anthropic, summaries: [], reports: [nonOpenAIReport]))
}

@Test func openAIAccountPresentationKeepsSharedConfigurationFailureDistinctFromHealthySibling() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let healthyLimit = UsageLimit(
        provider: .openAI,
        accountID: "resolved-healthy",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Healthy",
        label: "Codex Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 20,
        limit: 100,
        resetsAt: now.addingTimeInterval(3 * 60 * 60),
        lastUpdatedAt: now,
        confidence: .observed
    )
    let failureReport = StoredProviderReport(
        provider: .openAI,
        accountID: "resolved-failure",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Failure",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: now,
            coverage: .countOnly
        ),
        status: .failure,
        errorMessage: "Refresh failed"
    )
    let summaries = UsageSnapshot(generatedAt: now, limits: [healthyLimit]).mainLimitSummaries

    let accounts = OpenAIAccountLimitSummary.accounts(from: summaries, reports: [failureReport])
    let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountID, $0) })

    #expect(accounts.count == 2)
    #expect(accountsByID["resolved-healthy"]?.status == .healthy)
    #expect(accountsByID["resolved-failure"]?.status == .failure)
    #expect(accountsByID["resolved-failure"]?.limits.isEmpty == true)
}

private func providerAccessAlert(
    kind: ProviderAccessState.Kind,
    resetsAt: Date? = nil
) -> ProviderAccessAlert {
    ProviderAccessAlert(
        provider: .anthropic,
        accountID: "claude",
        configuredAccountID: "claude",
        accountName: "Claude",
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        accessState: ProviderAccessState(kind: kind, resetsAt: resetsAt)
    )
}

private func presentationTestTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-presentation-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
