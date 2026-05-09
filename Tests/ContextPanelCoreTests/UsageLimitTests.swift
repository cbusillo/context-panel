import Foundation
import Testing

@testable import ContextPanelCore

@Test func remainingCapacityDoesNotGoBelowZero() {
    let limit = UsageLimit(provider: .openAI, label: "GPT-5", used: 12, limit: 10)

    #expect(limit.remaining == 0)
}

@Test func usageRatioIsCappedAtOne() {
    let limit = UsageLimit(provider: .anthropic, label: "Claude", used: 15, limit: 10)

    #expect(limit.usageRatio == 1)
}

@Test func unknownLimitsHaveUnknownStatus() {
    let limit = UsageLimit(
        provider: .google,
        accountID: "google-personal",
        accountName: "Personal",
        label: "Gemini Pro",
        used: nil,
        limit: nil,
        confidence: .unknown
    )

    #expect(limit.remaining == nil)
    #expect(limit.usageRatio == nil)
    #expect(limit.status == .unknown)
}

@Test func snapshotSortsMostConstrainedFirst() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google-work",
                accountName: "Work",
                label: "Gemini Deep Research",
                used: nil,
                limit: nil,
                confidence: .unknown,
                statusOverride: .failure
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai-team",
                accountName: "Team",
                label: "Image generation",
                used: 49,
                limit: 50,
                confidence: .observed
            )
        ]
    )
    let first = snapshot.mostConstrainedLimits.first

    #expect(first?.label == "Image generation")
    #expect(abs(snapshot.aggregateCapacityRatio - 0.02) < 0.0001)
}

@Test func aggregateCapacityUsesTightestTrackedWindow() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(provider: .openAI, label: "Weekly", used: 95, limit: 100),
            UsageLimit(provider: .openAI, label: "5-hour", used: 5, limit: 100),
        ]
    )

    #expect(abs(snapshot.aggregateCapacityRatio - 0.05) < 0.0001)
}

@Test func usageLimitSeparatesWindowAndModelLabels() {
    let limit = UsageLimit(
        provider: .openAI,
        accountID: "openai-personal",
        accountName: "Personal",
        label: "Codex 5-hour",
        windowLabel: "5-hour",
        modelLabel: "Codex",
        used: 42,
        limit: 100
    )

    #expect(limit.displayLabel == "5-hour")
    #expect(limit.contextLabel == "Codex · Personal")
}

@Test func providersCoverInitialScope() {
    #expect(Provider.allCases == [.openAI, .anthropic, .google])
}

@Test func usageLimitCanRepresentPercentPressure() {
    let limit = UsageLimit(
        provider: .openAI,
        accountID: "openai-personal",
        accountName: "Personal",
        label: "Codex weekly",
        unit: .percent,
        used: 38,
        limit: 100,
        confidence: .official
    )

    #expect(limit.unit == .percent)
    #expect(limit.remaining == 62)
    #expect(limit.usageRatio == 0.38)
}

@Test func mainLimitSummariesCollapseAccountsAndHideSparkRows() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "personal",
                accountName: "Personal",
                label: "OpenAI Codex 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Codex",
                unit: .percent,
                used: 25,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "work",
                accountName: "Work",
                label: "OpenAI Codex 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Codex",
                unit: .percent,
                used: 80,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "personal",
                accountName: "Personal",
                label: "GPT-5.3-Codex-Spark 5-hour",
                windowLabel: "5-hour",
                modelLabel: "GPT-5.3-Codex-Spark",
                unit: .percent,
                used: 90,
                limit: 100
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude 7-day",
                windowLabel: "7-day",
                modelLabel: "Claude Pro",
                unit: .percent,
                used: 55,
                limit: 100
            ),
            UsageLimit(
                provider: .google,
                accountID: "gemini",
                accountName: "Gemini",
                label: "Gemini daily",
                windowLabel: "Daily",
                modelLabel: "Gemini Code Assist",
                unit: .percent,
                used: 12,
                limit: 100
            ),
        ]
    )

    let summaries = snapshot.mainLimitSummaries

    #expect(summaries.map(\.id) == ["openai:fiveHour", "anthropic:weekly", "google:daily"])
    #expect(summaries[0].accountCount == 2)
    #expect(summaries[0].primaryLimit?.accountName == "Work")
    #expect(summaries[0].used == 105)
    #expect(summaries[0].limit == 200)
    #expect(summaries[0].remaining == 95)
    #expect(summaries[0].usageRatio == 0.525)
}

@Test func mainLimitSummariesPoolInterchangeableProviderAccounts() throws {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "codex",
                accountName: "OpenAI Codex",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 90,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "code",
                accountName: "OpenAI Code",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 1,
                limit: 100
            ),
        ]
    )

    let summary = try #require(snapshot.mainLimitSummaries.first)

    #expect(summary.accountCount == 2)
    #expect(summary.used == 91)
    #expect(summary.limit == 200)
    #expect(summary.remaining == 109)
    #expect(abs((summary.usageRatio ?? 0) - 0.455) < 0.0001)
    #expect(abs(summary.capacityRatio - 0.545) < 0.0001)
    #expect(summary.status == .healthy)
}

@Test func mainLimitSummaryExposesDeterministicPoolResetHelpers() throws {
    let reference = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let soonerReset = reference.addingTimeInterval(2 * 3_600)
    let laterReset = reference.addingTimeInterval(24 * 3_600)
    let snapshot = UsageSnapshot(
        generatedAt: reference,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "personal",
                accountName: "Personal",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: soonerReset
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "work",
                accountName: "Work",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100,
                resetsAt: laterReset
            ),
        ]
    )

    let summary = try #require(snapshot.mainLimitSummaries.first)

    #expect(summary.capacityPool.totalRemainingUnits == 90)
    #expect(summary.capacityPool.totalUnits == 200)
    #expect(summary.firstKnownReset == soonerReset)
    #expect(summary.nextReset(after: reference) == soonerReset)
    #expect(summary.nextReset(after: soonerReset) == laterReset)
}

@Test func widgetDisplayPreferencesUseOrderedVisiblePrefixes() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 52,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 4,
                limit: 100
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                accountName: "Anthropic",
                label: "Claude Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 42,
                limit: 100
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                accountName: "Anthropic",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 71,
                limit: 100
            ),
            UsageLimit(
                provider: .google,
                accountID: "google",
                accountName: "Google",
                label: "Gemini Daily",
                windowLabel: "Daily",
                unit: .percent,
                used: 0,
                limit: 100
            ),
        ]
    )

    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: 3), toOffset: 0)

    #expect(preferences.visibleMainLimitSummaries(from: snapshot.mainLimitSummaries, maximumCount: 3).map(\.id) == [
        "google:daily",
        "openai:weekly",
        "anthropic:weekly",
    ])
    #expect(preferences.visibleMainLimitSummaries(from: snapshot.mainLimitSummaries, maximumCount: 5).map(\.id) == [
        "google:daily",
        "openai:weekly",
        "anthropic:weekly",
        "anthropic:fiveHour",
    ])
}

@Test func widgetDisplayPreferencesKeepSelectedLaneWhenCurrentSnapshotHasNoData() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 52,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 9,
                limit: 100
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                accountName: "Anthropic",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 71,
                limit: 100
            ),
            UsageLimit(
                provider: .google,
                accountID: "google",
                accountName: "Google",
                label: "Gemini Daily",
                windowLabel: "Daily",
                unit: .percent,
                used: 0,
                limit: 100
            ),
        ]
    )

    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.setMainLimit(provider: .openAI, window: .fiveHour, isVisible: true)

    let lanes = preferences.visibleMainLimitLanes(from: snapshot.mainLimitSummaries, maximumCount: 5)

    #expect(lanes.map(\.id) == [
        "openai:weekly",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:daily",
        "openai:fiveHour",
    ])
    #expect(lanes[1].summary == nil)
    #expect(lanes[2].summary?.id == "anthropic:fiveHour")
}

@Test func widgetDisplayPreferencesStoreRoundTripsReorderedLimits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = WidgetDisplayPreferencesStore(
        preferencesURL: directory.appending(path: "widget-display-preferences.json")
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: 3), toOffset: 0)
    preferences.setMainLimit(provider: .anthropic, window: .weekly, isVisible: false)

    try store.save(preferences)

    let loaded = store.load()
    #expect(store.exists)
    #expect(Array(loaded.mainLimits.map(\.id).prefix(3)) == [
        "google:daily",
        "openai:weekly",
        "anthropic:weekly",
    ])
    #expect(loaded.preference(for: MainLimitSummary(provider: .anthropic, window: .weekly, limits: []))?.isVisible == false)
}
