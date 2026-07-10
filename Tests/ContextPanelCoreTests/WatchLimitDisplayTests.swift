import ContextPanelCore
import ContextPanelWatchSupport
import Foundation
import Testing

@Test func watchLimitDisplayUsesPooledMainLimitWhenMultipleAccountsShareAWindow() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 100),
            openAIWeeklyPercentLimit(accountID: "secondary", used: 0),
            openAIWeeklyPercentLimit(accountID: "tertiary", used: 0),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 5)

    let tightest = try #require(rows.first)
    let remainingRatio = try #require(tightest.remainingCapacity.ratio)
    let usedRatio = try #require(tightest.usedPressure.ratio)
    #expect(tightest.title == "OpenAI")
    #expect(tightest.subtitle == "1w")
    #expect(tightest.context == "3 accounts")
    #expect(tightest.usedText == "33%")
    #expect(abs(remainingRatio - 0.6666) < 0.001)
    #expect(abs(usedRatio - 0.3333) < 0.001)

    #expect(tightest.id == "summary:openai:weekly")
    #expect(rows.filter { $0.provider == .openAI && $0.subtitle == "1w" }.count == 1)
}

@Test func watchLimitDisplayShowsPercentUsedFromThePressureRatio() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [openAIWeeklyPercentLimit(accountID: "primary", used: 15)],
        status: .healthy,
        message: "Synced"
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.usedText == "15%")
    #expect(row.usedPressure.ratio == 0.15)
    #expect(row.remainingCapacity.ratio == 0.85)
}

@Test func watchLimitDisplayDeduplicatesPooledRowsBeforeApplyingLimit() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 25),
            openAIWeeklyPercentLimit(accountID: "secondary", used: 0),
            googleWeeklyPercentLimit(accountID: "antigravity", used: 30),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 2)

    #expect(rows.map(\.title) == ["Google", "OpenAI"])
    #expect(rows.contains { $0.id == "summary:openai:weekly" })
}

@Test func watchLimitDisplayKeepsDistinctMainWindowsWhenRawRowsExceedLimit() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 95),
            openAIWeeklyPercentLimit(accountID: "secondary", used: 90),
            openAIWeeklyPercentLimit(accountID: "tertiary", used: 85),
            googleWeeklyPercentLimit(accountID: "antigravity", used: 80),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 2)

    #expect(rows.map(\.title) == ["OpenAI", "Google"])
    #expect(rows.first?.id == "summary:openai:weekly")
    #expect(rows.first?.context == "3 accounts")
    #expect(rows.first?.usedText == "90%")
}

@Test func watchLimitDisplayKeepsOpenAIWeeklyAndFiveHourLanes() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 60),
            openAIFiveHourPercentLimit(accountID: "primary", used: 45),
            googleWeeklyPercentLimit(accountID: "antigravity", used: 55),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 5)

    let openAIRows = rows.filter { $0.provider == .openAI }
    #expect(openAIRows.map(\.subtitle) == ["1w", "5h"])
    #expect(openAIRows.map(\.usedText) == ["60%", "45%"])
    #expect(openAIRows.compactMap { $0.usedPressure.ratio } == [0.6, 0.45])
}

@Test func watchLimitDisplayMainLaneRowsKeepOpenAIWeeklyAndFiveHourFirst() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 60),
            openAIFiveHourPercentLimit(accountID: "primary", used: 45),
            googleWeeklyPercentLimit(accountID: "antigravity", used: 55),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: .defaultPreferences,
        maximumCount: 2
    )

    #expect(rows.map(\.provider) == [.openAI, .openAI])
    #expect(rows.map(\.subtitle) == ["1w", "5h"])
    #expect(rows.map(\.usedText) == ["60%", "45%"])
    #expect(rows.compactMap { $0.usedPressure.ratio } == [0.6, 0.45])
}

@Test func watchLimitDisplayMainLaneRowsFollowCompanionOrdering() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 60),
            openAIFiveHourPercentLimit(accountID: "primary", used: 45),
            googleWeeklyPercentLimit(accountID: "antigravity", used: 55),
        ],
        status: .healthy,
        message: "Synced"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    let googleIndex = try #require(preferences.mainLimits.firstIndex {
        $0.provider == .google && $0.window == .weekly
    })
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: googleIndex), toOffset: 0)

    let rows = WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: preferences,
        maximumCount: 3
    )

    #expect(rows.map(\.provider) == [.google, .openAI, .openAI])
    #expect(rows.map(\.subtitle) == ["1w", "1w", "5h"])
}

@Test func watchLimitDisplayMainLaneRowsFallBackToNonMainLimits() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [UsageLimit(
            provider: .google,
            accountID: "antigravity",
            accountName: "Antigravity",
            label: "Model requests",
            unit: .requests,
            used: 35,
            limit: 100
        )],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: .defaultPreferences,
        maximumCount: 2
    )

    let row = try #require(rows.first)
    #expect(row.title == "Google")
    #expect(row.subtitle == "Model requests")
    #expect(row.usedText == "35")
}

@Test func watchLimitDisplayUsesPressureRatioForPooledRows() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 60),
            openAIWeeklyPercentLimit(accountID: "secondary", used: 20),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 2)

    #expect(rows.first?.id == "summary:openai:weekly")
    #expect(rows.first?.usedPressure.ratio == 0.4)
    #expect(rows.first?.remainingCapacity.ratio == 0.6)
}

@Test func watchLimitDisplayFallsBackToRawMainLimitWhenPoolCannotBeBuilt() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "primary",
                accountName: "Primary",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: nil,
                limit: nil,
                resetsAt: Date(timeIntervalSince1970: 1_800_604_800),
                confidence: .estimated,
                statusOverride: .unknown
            ),
        ],
        status: .unknown,
        message: "Partial sync"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 5)

    let weekly = try #require(rows.first)
    #expect(weekly.title == "Anthropic")
    #expect(weekly.subtitle == "Weekly")
    #expect(weekly.context == "Primary")
    #expect(weekly.usedText == "—")
    #expect(weekly.usedPressure.isIndeterminate)
    #expect(weekly.remainingCapacity.isIndeterminate)
    #expect(weekly.status == .unknown)
}

@Test func watchLimitDisplayKeepsPercentUnknownWhenLimitIsMissing() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "primary",
                accountName: "Primary",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 15,
                limit: nil,
                confidence: .estimated
            ),
        ],
        status: .unknown,
        message: "Partial sync"
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.usedText == "—")
    #expect(row.usedPressure.isIndeterminate)
    #expect(row.remainingCapacity.isIndeterminate)
    #expect(row.status == .unknown)
}

private func openAIWeeklyPercentLimit(accountID: String, used: Int) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: accountID,
        accountName: accountID.capitalized,
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: Date(timeIntervalSince1970: 1_800_604_800),
        confidence: .observed
    )
}

private func openAIFiveHourPercentLimit(accountID: String, used: Int) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: accountID,
        accountName: accountID.capitalized,
        label: "5-hour",
        windowLabel: "5-hour",
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: Date(timeIntervalSince1970: 1_800_018_000),
        confidence: .observed
    )
}

private func googleWeeklyPercentLimit(accountID: String, used: Int) -> UsageLimit {
    UsageLimit(
        provider: .google,
        accountID: accountID,
        accountName: accountID.capitalized,
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: Date(timeIntervalSince1970: 1_800_604_800),
        confidence: .observed
    )
}
