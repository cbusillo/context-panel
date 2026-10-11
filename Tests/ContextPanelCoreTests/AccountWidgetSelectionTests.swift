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
    #expect(overview.widgetObservation()?.date == widgetPickNow.addingTimeInterval(-86_400))
    #expect(overview.widgetObservation()?.isCurrent == false)
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
    #expect(overview.widgetObservation(in: [current])?.date == widgetPickNow)
    #expect(overview.widgetObservation()?.date == widgetPickNow)
    #expect(overview.widgetObservation()?.isCurrent == true)
    let paused = widgetPickSnapshot(old: true, disabled: true).accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(paused.widgetObservation() == nil)
}

@Test func savedWidgetHeadlineAndTapIgnorePausedAccounts() throws {
    let saved = widgetPickSnapshot(old: true)
    let paused = try #require(widgetPickSnapshot(old: true, disabled: true).accountDisplayMetadata?.first)
    let pausedMetadata = AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.anthropic, "paused"),
        configurationID: AccountDisplayMetadata.safeID(.anthropic, "paused"), provider: .anthropic,
        label: paused.label, isEnabled: false)
    let snapshot = WidgetSnapshot(state: .stale, generatedAt: widgetPickNow, limits: saved.limits,
        status: .stale, message: "", accountDisplayMetadata: [pausedMetadata] + (saved.accountDisplayMetadata ?? []))
    let overview = snapshot.accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(overview.accounts.first?.state == .off)
    #expect(overview.widgetShowsOnlySavedUsage)
    #expect(overview.widgetTapAccount?.metadata.provider == .openAI)
    #expect(overview.widgetPicks.compactMap(\.account).contains { $0.id == overview.widgetTapAccount?.id })
}

@Test func savedWidgetObservationCannotBeLabeledCurrentByAShortOnlySibling() {
    let saved = widgetPickSnapshot(old: true)
    let short = UsageLimit(provider: .anthropic, accountID: "short", accountName: "Short only",
        label: "5-hour", windowLabel: "5-hour", unit: .percent, used: 20, limit: 100,
        resetsAt: widgetPickNow.addingTimeInterval(3_600), lastUpdatedAt: widgetPickNow, confidence: .observed)
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: widgetPickNow, limits: saved.limits + [short],
        status: .healthy, message: "")
    let overview = snapshot.accountOverview(now: widgetPickNow, widgetsOnly: true)
    #expect(overview.accounts.contains { $0.isReliable && $0.longWindow == nil })
    #expect(overview.widgetObservation()?.isCurrent == false)
    #expect(overview.widgetObservation()?.date == saved.limits.first?.lastUpdatedAt)
    #expect(!overview.widgetShowsOnlySavedUsage)
}

@Test func preResetWidgetReadingRemainsExplicitlySavedWithoutGuessingARefill() throws {
    let observed = widgetPickNow.addingTimeInterval(-86_400)
    let limit = UsageLimit(provider: .openAI, accountID: "saved", accountName: "Saved account",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 95, limit: 100,
        resetsAt: widgetPickNow.addingTimeInterval(-3_600), lastUpdatedAt: observed, confidence: .observed)
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: observed, limits: [limit], status: .healthy, message: "")
    let overview = snapshot.accountOverview(now: widgetPickNow, widgetsOnly: true)
    let pick = try #require(overview.widgetPicks.first)
    let account = try #require(pick.account)
    #expect(account.state == .stale)
    #expect(account.horizon(now: widgetPickNow).remaining == limit.remainingCapacityRatio)
    #expect(account.horizon(now: widgetPickNow).runOutAt == nil)
    #expect(account.horizon(now: widgetPickNow).resetAt == nil)
    #expect(overview.widgetShowsOnlySavedUsage)
    #expect(!pick.isRecommendation)
}

@Test func updatingWidgetRetainsLastKnownCapacityWithoutRecommendingIt() throws {
    let limit = UsageLimit(provider: .openAI, accountID: "updating", accountName: "Updating account",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 25, limit: 100,
        resetsAt: widgetPickNow.addingTimeInterval(86_400), lastUpdatedAt: widgetPickNow,
        confidence: .observed, statusOverride: .loading)
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: widgetPickNow, limits: [limit],
        status: .loading, message: "")
    let overview = snapshot.accountOverview(now: widgetPickNow, widgetsOnly: true)
    let pick = try #require(overview.widgetPicks.first)
    #expect(pick.account?.state == .refreshing)
    #expect(pick.account?.remainingFraction == 0.75)
    #expect(!pick.isRecommendation)
    #expect(!overview.widgetShowsOnlySavedUsage)
}
