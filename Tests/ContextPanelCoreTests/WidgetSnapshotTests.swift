import Foundation
import Testing

@testable import ContextPanelCore
@testable import ContextPanelWidget

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
    #expect(widget.status == .stale)
    #expect(widget.limits.count == 1)
    #expect(widget.message == "Refresh Context Panel to update data.")
    #expect(widget.hasProviderReconnectIssue == false)
}

@Test func widgetSnapshotKeepsStaleStatusWhenCachedLimitIsLimited() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 100, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.limits.first?.status == .limited)
    #expect(widget.message == "Refresh Context Panel to update data.")
}

@Test func widgetSnapshotKeepsFailureStatusWhenCachedLimitIsLimited() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 100, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .failure),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .failure)
    #expect(widget.status == .failure)
    #expect(widget.limits.first?.status == .limited)
    #expect(widget.message == "Reconnect account to update data.")
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
    #expect(widget.status == .stale)
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
    #expect(widget.status == .stale)
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

@Test func providerSummariesUsePooledMainWindowStatus() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "limited",
                accountName: "Limited OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 100,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "usable",
                accountName: "Usable OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 20,
                limit: 100
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(widget.status == .healthy)
    #expect(openAI?.status == .healthy)
    #expect(openAI?.tightestLimit?.status == .limited)
}

@Test func providerSummariesStillIncludeNonMainLimitPressure() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "usable",
                accountName: "Usable OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 20,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "usable",
                accountName: "Usable OpenAI",
                label: "Image generation",
                unit: .requests,
                used: 10,
                limit: 10,
                statusOverride: .limited
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(widget.status == .limited)
    #expect(openAI?.status == .limited)
    #expect(widget.message == "1 limit needs attention.")
}

@Test func anthropicProviderSummaryUsesMainSummaryWhenNonMainLimitIsUnknown() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude weekly",
                windowLabel: "Weekly",
                modelLabel: "Claude",
                unit: .percent,
                used: 12,
                limit: 100,
                resetsAt: savedAt.addingTimeInterval(6 * 3_600),
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "claude-unknown",
                accountName: "Claude Unknown",
                label: "Claude auxiliary signal",
                modelLabel: "Claude",
                unit: .unknown,
                used: nil,
                limit: nil,
                resetsAt: nil,
                lastUpdatedAt: savedAt,
                confidence: .observed,
                statusOverride: .unknown
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let anthropic = widget.providerSummaries.first { $0.provider == .anthropic }

    #expect(widget.status == .unknown)
    #expect(anthropic?.status == .healthy)
    #expect(widget.usageSnapshot.mainLimitSummaries.first { $0.provider == .anthropic }?.status == .healthy)
    #expect(widget.limits.first { $0.label == "Claude auxiliary signal" }?.status == .unknown)
}

@Test func anthropicEstimatedSummaryKeepsResetTextWithoutUsageRatio() {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(3_600)
    let summary = MainLimitSummary(
        provider: .anthropic,
        window: .fiveHour,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude 5-hour estimate",
                windowLabel: "5-hour estimated",
                modelLabel: "Claude",
                unit: .unknown,
                used: nil,
                limit: nil,
                resetsAt: reset,
                lastUpdatedAt: now,
                confidence: .estimated,
                statusOverride: .healthy
            ),
        ],
        generatedAt: now
    )

    #expect(summary.usageRatio == nil)
    #expect(summary.widgetResetText != nil)
    #expect(summary.widgetResetConfidenceText?.contains("estimated") == true)
}

@Test func anthropicWidgetSnapshotSurfacesConnectedUnknownOAuthStatusWithoutMainLimit() {
    let now = Date(timeIntervalSince1970: 1000)
    let limits = [
        UsageLimit(
            provider: .anthropic,
            accountID: "claude-acct",
            accountName: "Claude",
            label: "Claude OAuth usage",
            modelLabel: "Claude",
            unit: .unknown,
            used: nil,
            limit: nil,
            resetsAt: nil,
            lastUpdatedAt: now,
            confidence: .observed,
            statusOverride: .unknown
        )
    ]
    let stored = StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: limits))
    let snapshot = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy), now: now)
    #expect(snapshot.status == .unknown)
    #expect(snapshot.limits.contains { $0.provider == .anthropic })
    #expect(snapshot.usageSnapshot.mainLimitSummaries.filter { $0.provider == .anthropic }.isEmpty)

    let healthyLimit = UsageLimit(
        provider: .anthropic,
        accountID: "claude-acct",
        accountName: "Claude",
        label: "Claude weekly",
        windowLabel: "Weekly",
        modelLabel: "Claude",
        unit: .percent,
        used: 25,
        limit: 100,
        resetsAt: nil,
        lastUpdatedAt: now,
        confidence: .observed
    )
    #expect(healthyLimit.status == .healthy)

    let summary = MainLimitSummary(provider: .anthropic, window: .weekly, limits: [healthyLimit])
    #expect(summary.resetsAt == nil)
    #expect(summary.status == .healthy)
}
