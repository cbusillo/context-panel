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

@Test func aggregateStatusUsesPooledMainWindowCapacity() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
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
    )

    #expect(snapshot.mostConstrainedLimits.first?.status == .limited)
    #expect(snapshot.mainLimitSummaries.first?.status == .healthy)
    #expect(snapshot.aggregateStatus == .healthy)
}

@Test func aggregateStatusRemainsLimitedWhenPooledMainWindowIsExhausted() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "first",
                accountName: "First OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 100,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "second",
                accountName: "Second OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 100,
                limit: 100
            ),
        ]
    )

    #expect(snapshot.mainLimitSummaries.first?.status == .limited)
    #expect(snapshot.aggregateStatus == .limited)
}

@Test func aggregateStatusStillIncludesNonMainLimitPressure() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
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
    )

    #expect(snapshot.mainLimitSummaries.first?.status == .healthy)
    #expect(snapshot.aggregateStatus == .limited)
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
            UsageLimit(
                provider: .google,
                accountID: "gemini",
                accountName: "Gemini",
                label: "Gemini compute weekly",
                windowLabel: "Weekly",
                modelLabel: "Gemini Apps",
                unit: .percent,
                used: 42,
                limit: 100
            ),
            UsageLimit(
                provider: .google,
                accountID: "gemini",
                accountName: "Gemini",
                label: "Gemini compute 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Gemini Apps",
                unit: .percent,
                used: 9,
                limit: 100
            ),
        ]
    )

    let summaries = snapshot.mainLimitSummaries

    #expect(summaries.map(\.id) == [
        "openai:fiveHour",
        "anthropic:weekly",
        "google:fiveHour",
        "google:weekly",
        "google:daily",
    ])
    #expect(summaries[0].accountCount == 2)
    #expect(summaries[0].primaryLimit?.accountName == "Work")
    #expect(summaries[0].used == 105)
    #expect(summaries[0].limit == 200)
    #expect(summaries[0].remaining == 95)
    #expect(summaries[0].usageRatio == 0.525)
}

@Test func googleAntigravityModelAvailabilityDoesNotInferQuotaWindowsFromResetHorizon() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google-antigravity",
                accountName: "Antigravity",
                label: "Gemini Pro capacity",
                windowLabel: "Model capacity",
                modelLabel: "Gemini Pro",
                unit: .percent,
                used: 92,
                limit: 100,
                resetsAt: now.addingTimeInterval(4 * 3_600),
                lastUpdatedAt: now,
                note: "source: Google Antigravity model availability"
            ),
            UsageLimit(
                provider: .google,
                accountID: "google-antigravity",
                accountName: "Antigravity",
                label: "Gemini Flash capacity",
                windowLabel: "Model capacity",
                modelLabel: "Gemini Flash",
                unit: .percent,
                used: 40,
                limit: 100,
                resetsAt: now.addingTimeInterval(4 * 24 * 3_600),
                lastUpdatedAt: now,
                note: "source: Google Antigravity model availability"
            ),
            UsageLimit(
                provider: .google,
                accountID: "google-antigravity",
                accountName: "Antigravity",
                label: "Claude capacity",
                windowLabel: "Model capacity",
                modelLabel: "Claude",
                unit: .percent,
                used: 10,
                limit: 100,
                resetsAt: now.addingTimeInterval(4 * 3_600),
                lastUpdatedAt: now,
                note: "source: Google Antigravity model availability"
            ),
        ]
    )

    #expect(snapshot.mainLimitSummaries.map(\.id) == ["google:availability"])
    let summary = try #require(snapshot.mainLimitSummaries.first)
    #expect(summary.displayWindowName(now: now) == "Model capacity")
    #expect(summary.compactDisplayWindowName(now: now) == "Cap")
    #expect(summary.limits.map(\.modelLabel) == ["Gemini Pro", "Gemini Flash"])
    #expect(snapshot.mainLimitSummaries.contains { $0.id == "google:fiveHour" } == false)
    #expect(snapshot.mainLimitSummaries.contains { $0.id == "google:weekly" } == false)
    #expect(snapshot.limits.filter { !$0.isMainLimit }.map(\.modelLabel) == ["Claude"])
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
    let pooledCapacity = try #require(summary.pooledPercentCapacity)
    #expect(pooledCapacity.usedPoints == 91)
    #expect(pooledCapacity.poolPoints == 200)
    #expect(pooledCapacity.remainingPoints == 109)
    #expect(pooledCapacity.usedPercent == 45)
    #expect(pooledCapacity.remainingPercent == 55)
    #expect(pooledCapacity.usedPercent + pooledCapacity.remainingPercent == 100)
    #expect(pooledCapacity.contributingAccountCount == 2)
    #expect(pooledCapacity.pointsPerAccount == 100)
    #expect(MetricProgress.remainingCapacity(remainingRatio: summary.remainingCapacityRatio).percentText == "55%")
}

@Test func pooledPercentCapacityRejectsNonPercentPools() {
    let summary = MainLimitSummary(
        provider: .openAI,
        window: .weekly,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "tokens",
                accountName: "Token account",
                label: "Token weekly",
                windowLabel: "Weekly",
                unit: .tokens,
                used: 400,
                limit: 1_000
            ),
        ]
    )

    #expect(summary.pooledPercentCapacity == nil)
}

@Test func mainLimitSummariesExcludeAccountsExhaustedByLongerOpenAIWindow() throws {
    let generatedAt = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let snapshot = UsageSnapshot(
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "full",
                accountName: "Full weekly",
                label: "Codex 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Codex",
                unit: .percent,
                used: 60,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(3 * 3_600),
                confidence: .observed
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "full",
                accountName: "Full weekly",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(4 * 24 * 3_600),
                confidence: .observed
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "available",
                accountName: "Available weekly",
                label: "Codex 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Codex",
                unit: .percent,
                used: 5,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(2 * 3_600),
                confidence: .observed
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "available",
                accountName: "Available weekly",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 22,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(7 * 24 * 3_600),
                confidence: .observed
            ),
        ]
    )

    let summaries = Dictionary(uniqueKeysWithValues: snapshot.mainLimitSummaries.map { ($0.id, $0) })
    let fiveHour = try #require(summaries["openai:fiveHour"])
    let weekly = try #require(summaries["openai:weekly"])

    #expect(fiveHour.accountCount == 2)
    #expect(fiveHour.liveLimits.map(\.accountName) == ["Available weekly"])
    #expect(fiveHour.lastKnownCapacityLimits.map(\.accountName) == ["Available weekly"])
    #expect(fiveHour.used == 5)
    #expect(fiveHour.limit == 100)
    #expect(fiveHour.remaining == 95)
    #expect(fiveHour.usageRatio == 0.05)
    let fiveHourPool = try #require(fiveHour.pooledPercentCapacity)
    #expect(fiveHourPool.contributingAccountCount == 1)
    #expect(fiveHourPool.pointsPerAccount == 100)
    #expect(weekly.liveLimits.map(\.accountName) == ["Full weekly", "Available weekly"])
    #expect(weekly.used == 122)
    #expect(weekly.limit == 200)
}

@Test func mainLimitSummariesExcludeExpiredBucketsFromLiveCapacity() throws {
    let generatedAt = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let snapshot = UsageSnapshot(
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 90,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(-2 * 3_600),
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude 5-hour fresh",
                windowLabel: "5-hour",
                unit: .percent,
                used: 2,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(2 * 3_600),
                confidence: .observed
            ),
        ]
    )

    let summary = try #require(snapshot.mainLimitSummaries.first)

    #expect(summary.liveLimits.map(\.label) == ["Claude 5-hour fresh"])
    #expect(summary.lastKnownCapacityLimits.map(\.label) == ["Claude 5-hour fresh"])
    #expect(summary.used == 2)
    #expect(summary.limit == 100)
    #expect(summary.remaining == 98)
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

@Test func accountResetRecommendationIDsKeepSharedConfiguredAccountsDistinct() {
    let resetAt = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let sharedConfiguredAccountID = "configured-openai-shared"
    let firstLimit = UsageLimit(
        provider: .openAI,
        accountID: "raw-openai-a",
        configuredAccountID: sharedConfiguredAccountID,
        accountName: "Work A",
        label: "OpenAI Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 10,
        limit: 100,
        resetsAt: resetAt
    )
    let secondLimit = UsageLimit(
        provider: .openAI,
        accountID: "raw-openai-b",
        configuredAccountID: sharedConfiguredAccountID,
        accountName: "Work B",
        label: "OpenAI Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 20,
        limit: 100,
        resetsAt: resetAt
    )
    let firstRecommendation = AccountResetRecommendation(
        provider: .openAI,
        accountID: firstLimit.accountID,
        configuredAccountID: firstLimit.configuredAccountID,
        accountName: firstLimit.accountName,
        window: .weekly,
        resetsAt: resetAt,
        limit: firstLimit
    )
    let secondRecommendation = AccountResetRecommendation(
        provider: .openAI,
        accountID: secondLimit.accountID,
        configuredAccountID: secondLimit.configuredAccountID,
        accountName: secondLimit.accountName,
        window: .weekly,
        resetsAt: resetAt,
        limit: secondLimit
    )

    #expect(firstRecommendation.id != secondRecommendation.id)
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
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: 7), toOffset: 0)

    #expect(preferences.visibleMainLimitSummaries(from: snapshot.mainLimitSummaries, maximumCount: 3).map(\.id) == [
        "google:daily",
        "openai:weekly",
        "openai:fiveHour",
    ])
    #expect(preferences.visibleMainLimitSummaries(from: snapshot.mainLimitSummaries, maximumCount: 5).map(\.id) == [
        "google:daily",
        "openai:weekly",
        "openai:fiveHour",
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

    let lanes = WidgetDisplayPreferences.defaultPreferences.visibleMainLimitLanes(from: snapshot.mainLimitSummaries, maximumCount: 8)

    #expect(lanes.map(\.id) == [
        "openai:weekly",
        "openai:fiveHour",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:availability",
        "google:weekly",
        "google:fiveHour",
        "google:daily",
    ])
    #expect(lanes[0].summary?.id == "openai:weekly")
    #expect(lanes[1].summary?.id == "openai:fiveHour")
    #expect(lanes[2].summary == nil)
    #expect(lanes[3].summary?.id == "anthropic:fiveHour")
    #expect(lanes[4].summary == nil)
    #expect(lanes[5].summary == nil)
    #expect(lanes[6].summary == nil)
    #expect(lanes[7].summary?.id == "google:daily")
}

@Test func widgetDisplayPreferencesPreserveSettingsOrderForGooglePlaceholders() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google",
                accountName: "Google",
                label: "Gemini compute 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 15,
                limit: 100
            ),
        ]
    )

    let preferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .google, window: .weekly, isVisible: true, sortOrder: 0),
        WidgetMainLimitPreference(provider: .google, window: .fiveHour, isVisible: true, sortOrder: 1),
    ])
    let lanes = preferences.visibleMainLimitLanes(from: snapshot.mainLimitSummaries, maximumCount: 2)

    #expect(lanes.map(\.id) == ["google:weekly", "google:fiveHour"])
    #expect(lanes[0].summary == nil)
    #expect(lanes[1].summary?.id == "google:fiveHour")
}

@Test func widgetDisplayPreferencesShowsGeminiWeeklyAndFiveHourLanesByDefault() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google",
                accountName: "Google",
                label: "Gemini compute weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 65,
                limit: 100
            ),
            UsageLimit(
                provider: .google,
                accountID: "google",
                accountName: "Google",
                label: "Gemini compute 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 15,
                limit: 100
            ),
        ]
    )

    let lanes = WidgetDisplayPreferences.defaultPreferences.visibleMainLimitLanes(
        from: snapshot.mainLimitSummaries,
        maximumCount: 6
    )

    #expect(snapshot.mainLimitSummaries.map(\.id) == ["google:fiveHour", "google:weekly"])
    #expect(lanes.map(\.id) == [
        "openai:weekly",
        "openai:fiveHour",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:weekly",
        "google:fiveHour",
    ])
    #expect(lanes[0].summary == nil)
    #expect(lanes[1].summary == nil)
    #expect(lanes[2].summary == nil)
    #expect(lanes[3].summary == nil)
    #expect(lanes[4].summary?.id == "google:weekly")
    #expect(lanes[5].summary?.id == "google:fiveHour")

    let largeWidgetLanes = WidgetDisplayPreferences.defaultPreferences.visibleMainLimitLanes(
        from: snapshot.mainLimitSummaries,
        maximumCount: 5
    )
    #expect(largeWidgetLanes.map(\.id) == [
        "openai:weekly",
        "openai:fiveHour",
        "anthropic:weekly",
        "google:weekly",
        "google:fiveHour",
    ])

    let mediumWidgetLanes = WidgetDisplayPreferences.defaultPreferences.visibleMainLimitLanes(
        from: snapshot.mainLimitSummaries,
        maximumCount: 3
    )
    #expect(mediumWidgetLanes.map(\.id) == [
        "openai:weekly",
        "google:weekly",
        "google:fiveHour",
    ])
}

@Test func googleAntigravityExpiredModelAvailabilityDoesNotCarryForwardAfterReset() {
    let lastUpdatedAt = Date(timeIntervalSince1970: 1_000)
    let observedReset = lastUpdatedAt.addingTimeInterval(5 * 3_600)
    let generatedAt = observedReset.addingTimeInterval(3_600)
    let snapshot = UsageSnapshot(
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google-antigravity-default",
                accountName: "Antigravity",
                label: "Gemini Pro capacity",
                windowLabel: "Model capacity",
                modelLabel: "Gemini Pro",
                unit: .percent,
                used: 40,
                limit: 100,
                resetsAt: observedReset,
                lastUpdatedAt: lastUpdatedAt,
                confidence: .observed,
                note: "source: Google Antigravity model availability"
            ),
        ]
    )

    let summary = snapshot.mainLimitSummaries.first

    #expect(summary?.id == "google:availability")
    #expect(summary?.liveLimits.isEmpty == true)
    #expect(summary?.used == nil)
    #expect(summary?.limit == nil)
    #expect(summary?.confidence == .observed)
    #expect(summary?.resetsAt == observedReset)
}

@Test func nonGoogleExpiredCapacityDoesNotCarryForwardAfterReset() {
    let generatedAt = Date(timeIntervalSince1970: 20_000)
    let snapshot = UsageSnapshot(
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "Codex 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 40,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(-3_600),
                lastUpdatedAt: generatedAt.addingTimeInterval(-6 * 3_600),
                confidence: .official
            ),
        ]
    )

    let summary = snapshot.mainLimitSummaries.first

    #expect(summary?.id == "openai:fiveHour")
    #expect(summary?.used == nil)
    #expect(summary?.limit == nil)
    #expect(summary?.usageRatio == nil)
    #expect(summary?.confidence == .official)
}

@Test func widgetDisplayPreferencesMigratesSavedDefaultsToIncludeGeminiWindows() {
    let preferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
        WidgetMainLimitPreference(provider: .openAI, window: .fiveHour, isVisible: true, sortOrder: 1),
        WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 2),
        WidgetMainLimitPreference(provider: .anthropic, window: .fiveHour, isVisible: true, sortOrder: 3),
        WidgetMainLimitPreference(provider: .google, window: .daily, isVisible: true, sortOrder: 4),
    ])

    #expect(preferences.mainLimits.map(\.id) == [
        "openai:weekly",
        "openai:fiveHour",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:daily",
        "google:availability",
        "google:weekly",
        "google:fiveHour",
    ])
    #expect(preferences.preference(for: MainLimitSummary(provider: .google, window: .weekly, limits: []))?.isVisible == true)
    #expect(preferences.preference(for: MainLimitSummary(provider: .google, window: .fiveHour, limits: []))?.isVisible == true)
}

@Test func widgetDisplayPreferencesMigratesLegacyDefaultOpenAIFiveHourVisibility() {
    let preferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
        WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 1),
        WidgetMainLimitPreference(provider: .anthropic, window: .fiveHour, isVisible: true, sortOrder: 2),
        WidgetMainLimitPreference(provider: .google, window: .availability, isVisible: true, sortOrder: 3),
        WidgetMainLimitPreference(provider: .google, window: .weekly, isVisible: true, sortOrder: 4),
        WidgetMainLimitPreference(provider: .google, window: .fiveHour, isVisible: true, sortOrder: 5),
        WidgetMainLimitPreference(provider: .google, window: .daily, isVisible: true, sortOrder: 6),
        WidgetMainLimitPreference(provider: .openAI, window: .fiveHour, isVisible: false, sortOrder: 7),
    ])

    #expect(preferences.mainLimits.map(\.id) == [
        "openai:weekly",
        "openai:fiveHour",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:availability",
        "google:weekly",
        "google:fiveHour",
        "google:daily",
    ])
    #expect(preferences.preference(for: MainLimitSummary(provider: .openAI, window: .fiveHour, limits: []))?.isVisible == true)
}

@Test func widgetDisplayPreferencesPreservesCustomHiddenOpenAIFiveHourPreference() {
    let preferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
        WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 1),
        WidgetMainLimitPreference(provider: .anthropic, window: .fiveHour, isVisible: true, sortOrder: 2),
        WidgetMainLimitPreference(provider: .google, window: .availability, isVisible: true, sortOrder: 3),
        WidgetMainLimitPreference(provider: .google, window: .weekly, isVisible: true, sortOrder: 4),
        WidgetMainLimitPreference(provider: .google, window: .fiveHour, isVisible: true, sortOrder: 5),
        WidgetMainLimitPreference(provider: .openAI, window: .fiveHour, isVisible: false, sortOrder: 6),
        WidgetMainLimitPreference(provider: .google, window: .daily, isVisible: true, sortOrder: 7),
    ])

    #expect(preferences.mainLimits.map(\.id) == [
        "openai:weekly",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:availability",
        "google:weekly",
        "google:fiveHour",
        "openai:fiveHour",
        "google:daily",
    ])
    #expect(preferences.preference(for: MainLimitSummary(provider: .openAI, window: .fiveHour, limits: []))?.isVisible == false)
}

@Test func widgetDisplayPreferencesStoreMigratesSavedDefaultsToIncludeGeminiWindows() throws {
    let json = #"""
    {
      "schemaVersion" : 1,
      "mainLimits" : [
        { "provider" : "openai", "window" : "weekly", "isVisible" : true, "sortOrder" : 0 },
        { "provider" : "openai", "window" : "fiveHour", "isVisible" : true, "sortOrder" : 1 },
        { "provider" : "anthropic", "window" : "weekly", "isVisible" : true, "sortOrder" : 2 },
        { "provider" : "anthropic", "window" : "fiveHour", "isVisible" : true, "sortOrder" : 3 },
        { "provider" : "google", "window" : "daily", "isVisible" : true, "sortOrder" : 4 }
      ]
    }
    """#.data(using: .utf8)!

    let preferences = try JSONDecoder().decode(WidgetDisplayPreferences.self, from: json)

    #expect(preferences.mainLimits.map(\.id) == [
        "openai:weekly",
        "openai:fiveHour",
        "anthropic:weekly",
        "anthropic:fiveHour",
        "google:daily",
        "google:availability",
        "google:weekly",
        "google:fiveHour",
    ])
}

@Test func widgetDisplayPreferencesStoreRoundTripsReorderedLimits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = WidgetDisplayPreferencesStore(
        preferencesURL: directory.appending(path: "widget-display-preferences.json")
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: 7), toOffset: 0)
    preferences.setMainLimit(provider: .anthropic, window: .weekly, isVisible: false)

    try store.save(preferences)

    let loaded = store.load()
    #expect(store.exists)
    #expect(Array(loaded.mainLimits.map(\.id).prefix(3)) == [
        "google:daily",
        "openai:weekly",
        "openai:fiveHour",
    ])
    #expect(loaded.preference(for: MainLimitSummary(provider: .anthropic, window: .weekly, limits: []))?.isVisible == false)
}

@Test func widgetDisplayPreferencesStoreSetSavesToReachableMirrorsWhenOneFails() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let blockedFile = directory.appending(path: "blocked")
    try Data().write(to: blockedFile)
    let failingStore = WidgetDisplayPreferencesStore(
        preferencesURL: blockedFile.appending(path: "widget-display-preferences.json")
    )
    let reachableStore = WidgetDisplayPreferencesStore(
        preferencesURL: directory.appending(path: "reachable/widget-display-preferences.json")
    )
    let storeSet = WidgetDisplayPreferencesStoreSet(stores: [failingStore, reachableStore])
    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.setMainLimit(provider: .openAI, window: .fiveHour, isVisible: true)

    try storeSet.save(preferences)

    #expect(reachableStore.loadIfAvailable() == preferences)
    #expect(storeSet.load() == preferences)
}
