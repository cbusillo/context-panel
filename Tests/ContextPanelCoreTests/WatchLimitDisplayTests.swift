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
    #expect(tightest.usedTextLabeled == "33% used")
    #expect(tightest.remainingText == "67%")
    #expect(tightest.remainingTextLabeled == "67% left")
    #expect(abs(remainingRatio - 0.6666) < 0.001)
    #expect(abs(usedRatio - 0.3333) < 0.001)
    #expect(
        tightest.accessibilitySentence(direction: .remaining, now: snapshot.generatedAt)
            == "OpenAI, Weekly, 3 accounts. 67 percent remaining, available. Resets in 7 days. Synced just now."
    )

    #expect(tightest.id == "summary:openai:weekly")
    #expect(rows.filter { $0.provider == .openAI && $0.subtitle == "1w" }.count == 1)
}

@Test func watchComplicationKeepsLastKnownPoolWhenCachedAccountsAgeToStale() throws {
    let snapshot = WidgetSnapshot(
        state: .stale,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 100, statusOverride: .stale),
            openAIWeeklyPercentLimit(accountID: "secondary", used: 2, statusOverride: .stale),
            openAIWeeklyPercentLimit(accountID: "tertiary", used: 77, statusOverride: .stale),
        ],
        status: .stale,
        message: "Saved usage is stale."
    )

    let row = try #require(WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: .defaultPreferences,
        maximumCount: 1
    ).first)

    #expect(row.id == "summary:openai:weekly")
    #expect(row.context == "3 accounts")
    #expect(row.usedText == "60%")
    #expect(row.remainingText == "40%")
    #expect(row.remainingComplicationText == "40% left · stale")
    #expect(row.usedPressure.ratio == 0.5966666666666667)
    #expect(row.remainingCapacity.ratio == 0.4033333333333333)
    #expect(row.status == .stale)
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
    #expect(row.usedTextLabeled == "15% used")
    #expect(row.remainingText == "85%")
    #expect(row.remainingTextLabeled == "85% left")
    #expect(row.remainingComplicationText == "85% left")
    #expect(row.remainingInlineText == "85% left")
    #expect(row.usedPressure.ratio == 0.15)
    #expect(row.remainingCapacity.ratio == 0.85)
    #expect(row.resetText(now: snapshot.generatedAt) == "7d")
    #expect(
        row.accessibilitySentence(direction: .used, now: snapshot.generatedAt)
            == "OpenAI, Weekly, 1 account. 15 percent used, available. Resets in 7 days. Synced just now."
    )
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

@Test func watchInlineRowsUseClosestLimitWhenItNeedsAttention() {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 7),
            openAIFiveHourPercentLimit(accountID: "primary", used: 12),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                accountName: "Anthropic",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 85,
                limit: 100
            ),
        ],
        status: .close,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.inlineRows(
        from: snapshot,
        preferences: .defaultPreferences
    )

    #expect(rows.map(\.provider) == [.openAI, .anthropic])
    #expect(rows.map(\.subtitle) == ["1w", "1w"])
    #expect(rows.map(\.compactInlineQuantity) == ["93%", "15%"])
}

@Test func watchInlineRowsUseNextSavedLimitWhenClosestWouldAddNoise() {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            openAIWeeklyPercentLimit(accountID: "primary", used: 30),
            openAIFiveHourPercentLimit(accountID: "primary", used: 40),
            googleWeeklyPercentLimit(accountID: "antigravity", used: 45),
        ],
        status: .healthy,
        message: "Synced"
    )

    let rows = WatchLimitDisplay.inlineRows(
        from: snapshot,
        preferences: .defaultPreferences
    )

    #expect(rows.map(\.provider) == [.openAI, .openAI])
    #expect(rows.map(\.subtitle) == ["1w", "5h"])
}

@Test func watchRowsKeepMissingSavedPrimaryAsUnknown() {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                accountName: "Anthropic",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 85,
                limit: 100
            ),
        ],
        status: .close,
        message: "Partial sync"
    )

    let singleRow = WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: .defaultPreferences,
        maximumCount: 1
    )
    let inlineRows = WatchLimitDisplay.inlineRows(
        from: snapshot,
        preferences: .defaultPreferences
    )

    #expect(singleRow.first?.provider == .openAI)
    #expect(singleRow.first?.context == "No current data")
    #expect(singleRow.first?.remainingCapacity.isIndeterminate == true)
    #expect(inlineRows.map(\.provider) == [.openAI, .anthropic])
    #expect(inlineRows.first?.compactInlineQuantity == "?")
}

@Test func watchLimitDisplayMainLaneRowsPreserveSelectedUnknownLane() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                accountName: "Anthropic",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: nil,
                limit: nil,
                confidence: .estimated,
                statusOverride: .unknown
            ),
            openAIWeeklyPercentLimit(accountID: "openai", used: 15),
        ],
        status: .unknown,
        message: "Partial sync"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    for index in preferences.mainLimits.indices {
        preferences.mainLimits[index].isVisible = (
            preferences.mainLimits[index].provider == .anthropic
                && preferences.mainLimits[index].window == .weekly
        ) || (
            preferences.mainLimits[index].provider == .openAI
                && preferences.mainLimits[index].window == .weekly
        )
    }
    let anthropicIndex = try #require(preferences.mainLimits.firstIndex {
        $0.provider == .anthropic && $0.window == .weekly
    })
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: anthropicIndex), toOffset: 0)

    let rows = WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: preferences,
        maximumCount: 2
    )

    #expect(rows.map(\.provider) == [.anthropic, .openAI])
    #expect(rows.first?.remainingCapacity.isIndeterminate == true)
    #expect(rows.first?.remainingComplicationText == "unknown")
}

@Test func watchLimitDisplayMainLaneRowsKeepSavedPrimaryWhenOnlyNonMainLimitsExist() {
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

    #expect(rows.map(\.provider) == [.openAI, .openAI])
    #expect(rows.map(\.subtitle) == ["1w", "5h"])
    #expect(rows.allSatisfy { $0.remainingCapacity.isIndeterminate })
    #expect(rows.first?.context == "No current data")
}

@Test func watchLimitDisplayDoesNotRestoreHiddenMainLanes() {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        limits: [openAIWeeklyPercentLimit(accountID: "openai", used: 20)],
        status: .healthy,
        message: "Synced"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    for index in preferences.mainLimits.indices {
        preferences.mainLimits[index].isVisible = false
    }

    #expect(
        WatchLimitDisplay.mainLaneRows(
            from: snapshot,
            preferences: preferences,
            maximumCount: 2
        ).isEmpty
    )
    #expect(
        WatchLimitDisplay.inlineRows(
            from: snapshot,
            preferences: preferences
        ).isEmpty
    )
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
    #expect(weekly.usedTextLabeled == "usage unknown")
    #expect(weekly.remainingText == "—")
    #expect(weekly.remainingTextLabeled == "remaining unknown")
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
    #expect(row.usedTextLabeled == "usage unknown")
    #expect(row.remainingText == "—")
    #expect(row.remainingTextLabeled == "remaining unknown")
    #expect(row.usedPressure.isIndeterminate)
    #expect(row.remainingCapacity.isIndeterminate)
    #expect(row.status == .unknown)
}

@Test func watchLimitDisplayRoundsUsedAsRemainingComplement() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "half-point",
                accountName: "Half Point",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 29,
                limit: 200,
                resetsAt: generatedAt.addingTimeInterval(3 * 3_600),
                confidence: .observed
            ),
        ],
        status: .healthy,
        message: "Synced"
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.remainingText == "86%")
    #expect(row.usedText == "14%")
    #expect(row.remainingTextLabeled == "86% left")
    #expect(row.usedTextLabeled == "14% used")
}

@Test func watchLimitDisplayKeepsNumericUnknownIndeterminate() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "unknown",
                accountName: "Antigravity",
                label: "Model requests",
                unit: .requests,
                used: 35,
                limit: 100,
                statusOverride: .unknown
            ),
        ],
        status: .unknown,
        message: "Partial sync"
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.usedTextLabeled == "usage unknown")
    #expect(row.remainingTextLabeled == "remaining unknown")
    #expect(row.remainingComplicationText == "unknown")
    #expect(row.remainingInlineText == "capacity unknown")
    #expect(row.usedPressure.isIndeterminate)
    #expect(row.remainingCapacity.isIndeterminate)
    #expect(
        row.accessibilitySentence(direction: .remaining, now: generatedAt)
            == "Google, Model requests, account Antigravity. remaining capacity unknown. Reset time unknown. Synced just now."
    )
}

@Test func watchLimitDisplayAccessibilityPreservesStaleValuesAndFreshness() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = WidgetSnapshot(
        state: .stale,
        generatedAt: now.addingTimeInterval(-2 * 3_600),
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "stale",
                accountName: "Antigravity",
                label: "Model requests",
                unit: .requests,
                used: 35,
                limit: 100,
                resetsAt: now.addingTimeInterval(2 * 3_600)
            ),
        ],
        status: .stale,
        message: "Showing saved data"
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.usedTextLabeled == "35 used")
    #expect(row.remainingText == "65")
    #expect(row.remainingComplicationText == "65 left · stale")
    #expect(row.status == .stale)
    #expect(row.resetText(now: now) == "2h")
    #expect(
        row.accessibilitySentence(direction: .remaining, now: now)
            == "Google, Model requests, account Antigravity. 65 of 100 requests remaining, stale. Resets in 2 hours. Showing saved data, last synced 2 hours ago."
    )
}

@Test func watchLimitDisplayPreservesRemainingCapacityWhenRefreshFails() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = WidgetSnapshot(
        state: .failure,
        generatedAt: now.addingTimeInterval(-2 * 3_600),
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "failed",
                accountName: "Antigravity",
                label: "Model requests",
                unit: .requests,
                used: 35,
                limit: 100,
                resetsAt: now.addingTimeInterval(2 * 3_600)
            ),
        ],
        status: .failure,
        message: "Sync failed"
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.remainingCapacity.ratio == 0.65)
    #expect(row.remainingComplicationText == "65 left · failed")
    #expect(row.status == .failure)
    #expect(
        row.accessibilitySentence(direction: .remaining, now: now)
            == "Google, Model requests, account Antigravity. 65 of 100 requests remaining, refresh failed. Resets in 2 hours. Not synced."
    )
}

@Test func watchLimitDisplayMarksAssumedScheduledResetCapacity() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now.addingTimeInterval(-3_600),
        limits: [
            UsageLimit(
                id: "google:local:agy:gemini-weekly",
                provider: .google,
                accountID: "local",
                accountName: "Antigravity",
                label: "Gemini Weekly",
                windowLabel: "Weekly",
                modelLabel: "Gemini",
                unit: .percent,
                used: 0,
                limit: 100,
                lastUpdatedAt: now.addingTimeInterval(-3_600),
                confidence: .estimated,
                presentationAssumption: .scheduledReset
            ),
        ],
        status: .healthy,
        message: "Usage data is current."
    )

    let row = try #require(WatchLimitDisplay.rows(from: snapshot, maximumCount: 1).first)

    #expect(row.usedText == "≈0%")
    #expect(row.remainingText == "≈100%")
    #expect(row.resetText(now: now) == "assumed reset")
    let accessibilitySentence = row.accessibilitySentence(direction: .remaining, now: now)
    #expect(accessibilitySentence.contains("approximately 100 percent remaining"))
    #expect(accessibilitySentence.contains("Assumed after scheduled reset"))
}

private func openAIWeeklyPercentLimit(
    accountID: String,
    used: Int,
    statusOverride: UsageStatus? = nil
) -> UsageLimit {
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
        confidence: .observed,
        statusOverride: statusOverride
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
