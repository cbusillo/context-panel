import Foundation
import Testing
@testable import ContextPanelCore

private let freshnessNow = Date(timeIntervalSince1970: 1_800_000_000)

private func freshnessLimit(_ provider: Provider, account: String = "primary", window: String = "Weekly",
                            used: Int = 25, observedAt: Date = freshnessNow, reset: Date) -> UsageLimit {
    UsageLimit(provider: provider, accountID: account, accountName: "Test account", label: window,
        windowLabel: window, unit: .percent, used: used, limit: 100, resetsAt: reset,
        lastUpdatedAt: observedAt, confidence: .observed, freshnessMode: .polling)
}

@Test(arguments: [Provider.openAI, .anthropic, .google])
func resetOnlySavesTheExpiredWindowWhileWeeklyForecastStaysUsable(provider: Provider) throws {
    let weekly = freshnessLimit(provider, reset: freshnessNow.addingTimeInterval(86_400))
    let short = freshnessLimit(provider, window: "5-hour", used: 40,
        observedAt: freshnessNow.addingTimeInterval(-60), reset: freshnessNow)
    let snapshot = UsageSnapshot(generatedAt: freshnessNow.addingTimeInterval(-60), limits: [weekly, short])
    let widget = WidgetSnapshot(state: .stale, generatedAt: snapshot.generatedAt, limits: snapshot.limits,
        status: .stale, message: "Saved")
    let overview = widget.accountOverview(now: freshnessNow)
    let account = try #require(overview.accounts.first)
    #expect(account.state == .available)
    #expect(account.shortWindow?.status == .stale)
    #expect(account.shortWindow?.remainingFraction == 0.6)
    #expect(account.shortWindow?.assumption == nil)
    #expect(AccountTerms.refill(try #require(account.shortWindow), now: freshnessNow) == AccountCapacityState.stale.displayText)
    #expect(account.horizon(now: freshnessNow).isCurrent)
    #expect(account.horizon(now: freshnessNow).remaining == 0.75)
    #expect(!account.isReliable)

    let replacement = freshnessLimit(provider, window: "5-hour", used: 0,
        reset: freshnessNow.addingTimeInterval(5 * 3_600))
    let replaced = AccountOverview(snapshot: UsageSnapshot(generatedAt: freshnessNow, limits: [weekly, replacement]),
        reports: [], now: freshnessNow)
    let current = try #require(replaced.accounts.first)
    #expect(current.isReliable)
    #expect(current.shortWindow?.remainingFraction == 1)
    #expect(current.shortWindow?.assumption == nil)
    #expect(current.longWindow == account.longWindow)
}

@Test(arguments: [Provider.openAI, .anthropic, .google])
func oneOldWindowDoesNotAgeItsFreshSiblingOrAnotherAccount(provider: Provider) throws {
    let reset = freshnessNow.addingTimeInterval(86_400)
    let old = freshnessNow.addingTimeInterval(-SnapshotFreshness.appMaximumAge - 1)
    let limits = [freshnessLimit(provider, reset: reset),
        freshnessLimit(provider, window: "5-hour", used: 10, observedAt: old, reset: reset),
        freshnessLimit(provider, account: "sibling", used: 50, reset: reset)]
    let widget = WidgetSnapshot(state: .stale, generatedAt: freshnessNow, limits: limits,
        status: .stale, message: "Saved")
    let accounts = widget.accountOverview(now: freshnessNow).accounts
    let primary = try #require(accounts.first { $0.shortWindow != nil })
    #expect(primary.state == .available)
    #expect(primary.horizon(now: freshnessNow).isCurrent)
    #expect(primary.shortWindow?.status == .stale)
    #expect(accounts.allSatisfy { $0.horizon(now: freshnessNow).isCurrent })
}

@Test func oldAccountObservationCannotHideBehindANewerSnapshotEnvelope() {
    let observed = freshnessNow.addingTimeInterval(-SnapshotFreshness.refreshNeededAge - 1)
    let limit = freshnessLimit(.openAI, observedAt: observed, reset: freshnessNow.addingTimeInterval(86_400))
    let stored = StoredUsageSnapshot(savedAt: freshnessNow,
        snapshot: UsageSnapshot(generatedAt: freshnessNow, limits: [limit]))
    let policy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.refreshNeededAge)
    #expect(policy.status(for: stored, now: freshnessNow) == .stale)
}

@Test func backgroundWakeChecksAccountAgeBeforeDisplayExpiryAndResetAtTheBoundary() throws {
    let reset = freshnessNow.addingTimeInterval(60)
    let limit = freshnessLimit(.anthropic, reset: reset)
    let snapshot = UsageSnapshot(generatedAt: freshnessNow, limits: [limit])
    #expect(SnapshotRefreshRunner.nextRefreshCheckDate(snapshot: snapshot, now: freshnessNow) == reset)
    #expect(limit.isResetRefreshDue(now: reset))
    let long = UsageSnapshot(generatedAt: freshnessNow,
        limits: [freshnessLimit(.openAI, reset: freshnessNow.addingTimeInterval(86_400))])
    let wake = try #require(SnapshotRefreshRunner.nextRefreshCheckDate(snapshot: long, now: freshnessNow))
    #expect(wake > freshnessNow)
    #expect(wake < freshnessNow.addingTimeInterval(SnapshotFreshness.appMaximumAge))
}
