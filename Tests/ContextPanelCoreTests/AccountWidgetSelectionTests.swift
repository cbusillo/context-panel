import Foundation
import Testing
@testable import ContextPanelCore

private let widgetPickNow = Date(timeIntervalSince1970: 1_800_000_000)

private func widgetPickSnapshot(old: Bool = false, hidden: Bool = false, disabled: Bool = false,
                                unknown: Bool = false, withCurrent: Bool = false) -> WidgetSnapshot {
    let observed = old ? widgetPickNow.addingTimeInterval(-86_400) : widgetPickNow
    var limits = [UsageLimit(provider: .openAI, accountID: "saved", accountName: "Saved account",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: unknown ? nil : 25, limit: 100,
        resetsAt: widgetPickNow.addingTimeInterval(86_400), lastUpdatedAt: observed, confidence: .observed)]
    var metadata = [AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, "saved"),
        configurationID: AccountDisplayMetadata.safeID(.openAI, "saved"), provider: .openAI, label: "Saved account",
        isEnabled: !disabled, showInWidgets: !hidden)]
    if withCurrent {
        limits.append(UsageLimit(provider: .openAI, accountID: "current", accountName: "Current account",
            label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 40, limit: 100,
            resetsAt: widgetPickNow.addingTimeInterval(86_400), lastUpdatedAt: widgetPickNow, confidence: .observed))
        metadata.append(AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, "current"),
            configurationID: AccountDisplayMetadata.safeID(.openAI, "current"), provider: .openAI, label: "Current account"))
    }
    return WidgetSnapshot(state: .ready, generatedAt: widgetPickNow, limits: limits,
        status: .healthy, message: "", accountDisplayMetadata: metadata)
}

@Test func savedWidgetPickKeepsItsValueWithoutRecommendingIt() throws {
    let overview = widgetPickSnapshot(old: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    let pick = try #require(overview.widgetPicks.first)
    let account = try #require(pick.account)
    #expect(account.remainingFraction == 0.75)
    #expect(account.state == .stale)
    #expect(!pick.isRecommendation)
    #expect(overview.useNext(provider: .openAI) == nil)
    #expect(!account.glanceAccessibilityText(now: widgetPickNow, isNext: pick.isRecommendation).contains(AccountTerms.useNext))
    #expect(overview.widgetShowsOnlySavedUsage)
    #expect(overview.widgetObservationDate() == widgetPickNow.addingTimeInterval(-86_400))
}

@Test func currentWidgetRecommendationWinsOverSavedFallback() throws {
    let overview = widgetPickSnapshot(old: true, withCurrent: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    let pick = try #require(overview.widgetPicks.first)
    #expect(pick.account?.metadata.label == "Current account")
    #expect(pick.isRecommendation)
    #expect(!overview.widgetShowsOnlySavedUsage)
}

@Test func savedWidgetFallbackPreservesVisibilityAndUnknownStates() {
    let hidden = widgetPickSnapshot(old: true, hidden: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(hidden.widgetPicks.isEmpty)
    let disabled = widgetPickSnapshot(old: true, disabled: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(disabled.widgetPicks.first?.account == nil)
    let unknown = widgetPickSnapshot(old: true, unknown: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(unknown.widgetPicks.first?.account == nil)
    #expect(!unknown.widgetShowsOnlySavedUsage)
}

@Test func savedWidgetFallbackDoesNotMaskCurrentExhaustion() throws {
    let snapshot = widgetPickSnapshot(old: true, withCurrent: true)
    var limits = snapshot.limits
    limits[1] = UsageLimit(provider: .openAI, accountID: "current", accountName: "Current account",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 100, limit: 100,
        resetsAt: widgetPickNow.addingTimeInterval(86_400), lastUpdatedAt: widgetPickNow, confidence: .observed)
    let exhausted = WidgetSnapshot(state: .ready, generatedAt: widgetPickNow, limits: limits,
        status: .healthy, message: "", accountDisplayMetadata: snapshot.accountDisplayMetadata)
    let overview = exhausted.accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(overview.accounts.last?.state == .limited)
    let pick = try #require(overview.widgetPicks.first)
    #expect(pick.account == nil)
    #expect(!pick.isRecommendation)
}

@Test func widgetObservationUsesDisplayedActiveOrSavedReadings() throws {
    let snapshot = widgetPickSnapshot(old: true, withCurrent: true)
    let overview = snapshot.accountOverview(now: widgetPickNow, widgetsOnly: true)
    let current = try #require(overview.accounts.last)
    #expect(overview.widgetObservationDate(in: [current]) == widgetPickNow)
    let paused = widgetPickSnapshot(old: true, disabled: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(paused.widgetObservationDate() == nil)
}
