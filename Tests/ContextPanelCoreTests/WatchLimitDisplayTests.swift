import ContextPanelCore
import ContextPanelWatchSupport
import Foundation
import Testing

@Test func watchLimitDisplayPrioritizesTightestAccountAndOmitsDuplicatePooledMainLimit() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 25),
            openAIWeeklyPercentLimit(accountID: "secondary", used: 0),
            openAIWeeklyPercentLimit(accountID: "tertiary", used: 0),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.rows(from: snapshot, maximumCount: 5)

    let tightest = try #require(rows.first)
    #expect(tightest.title == "OpenAI")
    #expect(tightest.subtitle == "Weekly")
    #expect(tightest.context == "Primary")
    #expect(tightest.remainingText == "75%")
    #expect(tightest.capacityRatio == 0.75)
    #expect(tightest.pressureRatio == 0.25)

    #expect(rows.contains { $0.id == "summary:openai:weekly" } == false)
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
    #expect(rows.contains { $0.id == "summary:openai:weekly" } == false)
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
    #expect(rows.first?.context == "Primary")
    #expect(rows.first?.remainingText == "5%")
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
    #expect(openAIRows.map(\.subtitle) == ["Weekly", "5-hour"])
    #expect(openAIRows.map(\.remainingText) == ["40%", "55%"])
    #expect(openAIRows.map(\.pressureRatio) == [0.6, 0.45])
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

    let rows = WatchLimitDisplay.mainLaneRows(from: snapshot, maximumCount: 2)

    #expect(rows.map(\.provider) == [.openAI, .openAI])
    #expect(rows.map(\.subtitle) == ["1w", "5h"])
    #expect(rows.map(\.remainingText) == ["40%", "55%"])
    #expect(rows.map(\.pressureRatio) == [0.6, 0.45])
}

@Test func watchLimitDisplayUsesPressureRatioForRawRows() throws {
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

    #expect(rows.first?.pressureRatio == 0.6)
    #expect(rows.first?.capacityRatio == 0.4)
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
    #expect(weekly.remainingText == "?")
    #expect(weekly.status == .unknown)
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
