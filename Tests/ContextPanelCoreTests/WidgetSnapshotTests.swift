import Foundation
import Testing

@testable import ContextPanelCore

@Test func widgetSnapshotUsesSetupNeededForMissingStore() {
    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: nil, status: .unknown),
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(widget.state == .setupNeeded)
    #expect(widget.status == .unknown)
    #expect(widget.limits.isEmpty)
    #expect(widget.message.contains("Set up"))
}

@Test func widgetSnapshotPreservesStaleCachedLimits() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.limits.count == 1)
    #expect(widget.message == "Refresh Context Panel to update data.")
    #expect(widget.hasProviderReconnectIssue == false)
}

@Test func widgetSnapshotUsesReconnectMessageForStaleProviderFailures() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
        ),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-account",
                configuredAccountID: "openai-code-default",
                accountName: "OpenAI",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Auth expired"
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.message == "Reconnect account to update data.")
    #expect(widget.hasProviderReconnectIssue == true)
}

@Test func widgetSnapshotDoesNotUseReconnectMessageWhenFailureHasWorkingConfiguredSibling() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-code-default",
                accountName: "Working OpenAI",
                label: "Codex",
                used: 20,
                limit: 100
            )]
        ),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-expired-account",
                configuredAccountID: "openai-code-default",
                accountName: "Expired OpenAI",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Auth expired"
            ),
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-code-default",
                accountName: "Working OpenAI",
                generatedAt: savedAt,
                status: .healthy,
                errorMessage: nil
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.message == "Refresh Context Panel to update data.")
    #expect(widget.hasProviderReconnectIssue == false)
}

@Test func widgetSnapshotUsesReconnectMessageWhenFailureHasOnlyDifferentConfiguredSibling() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-other-default",
                accountName: "Working OpenAI",
                label: "Codex",
                used: 20,
                limit: 100
            )]
        ),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-expired-account",
                configuredAccountID: "openai-code-default",
                accountName: "Expired OpenAI",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Auth expired"
            ),
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-other-default",
                accountName: "Working OpenAI",
                generatedAt: savedAt,
                status: .healthy,
                errorMessage: nil
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.message == "Reconnect account to update data.")
    #expect(widget.hasProviderReconnectIssue == true)
}

@Test func widgetSnapshotBuildsProviderSummaries() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 85, limit: 100),
            UsageLimit(provider: .google, label: "Gemini", used: 10, limit: 100),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .healthy),
        now: savedAt.addingTimeInterval(60)
    )
    let summaries = Dictionary(uniqueKeysWithValues: widget.providerSummaries.map { ($0.provider, $0) })

    #expect(widget.state == .ready)
    #expect(summaries[.openAI]?.status == .close)
    #expect(summaries[.openAI]?.limitCount == 1)
    #expect(summaries[.openAI]?.tightestLimit?.label == "Codex")
    #expect(summaries[.google]?.status == .healthy)
    #expect(summaries[.anthropic]?.limitCount == 0)
}

@Test func widgetSnapshotCarriesPromptCacheTelemetry() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100),
        ]),
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "every-code",
                accountName: "Every Code",
                observedAt: savedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .healthy),
        now: savedAt.addingTimeInterval(60)
    )

    #expect(widget.promptCacheObservations.count == 1)
    #expect(widget.promptCacheSummary.tokenWeightedHitRate == 0.9)
}

@Test func providerSummariesUseTheTightestWindowInsteadOfAverageCapacity() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(provider: .openAI, label: "Weekly", used: 95, limit: 100),
            UsageLimit(provider: .openAI, label: "5-hour", used: 5, limit: 100),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy))
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(abs((openAI?.capacityRatio ?? 0) - 0.05) < 0.0001)
    #expect(openAI?.tightestLimit?.label == "Weekly")
}
