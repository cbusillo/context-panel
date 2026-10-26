import Foundation
import Testing
@testable import ContextPanelCore

private let freshnessNow = Date(timeIntervalSince1970: 1_800_000_000)

private func freshnessLimit(_ provider: Provider, account: String = "primary", window: String = "Weekly",
                            used: Int = 25, observedAt: Date = freshnessNow, reset: Date) -> UsageLimit {
    UsageLimit(provider: provider, accountID: account, configuredAccountID: account, accountName: "Test account", label: window,
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
    #expect(account.glanceAccessibilityText(now: freshnessNow, isNext: false).contains(
        AccountTerms.windowReading(try #require(account.shortWindow), includingLeft: true)))
    #expect(AccountTerms.refill(try #require(account.shortWindow), now: freshnessNow) == AccountCapacityState.stale.displayText)
    #expect(account.horizon(now: freshnessNow).isCurrent)
    #expect(account.horizon(now: freshnessNow).remaining == 0.75)
    #expect(!account.isReliable)
    #expect(overview.providerTotals(now: freshnessNow).first?.longRemaining == 0.75)
    #expect(overview.providerTotals(now: freshnessNow).first?.shortRemaining == nil)

    let stored = StoredUsageSnapshot(savedAt: snapshot.generatedAt, snapshot: snapshot)
    let companion = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(
        document: CompanionSyncDocument(storedSnapshot: stored, publishedAt: freshnessNow), status: .healthy),
        now: freshnessNow)
    let shared = try #require(companion.accountOverview(now: freshnessNow).accounts.first)
    #expect(shared.horizon(now: freshnessNow).isCurrent)
    #expect(shared.shortWindow?.status == .stale)

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

    let past = freshnessNow.addingTimeInterval(SnapshotFreshness.appMaximumAge + 60)
    let retry = try #require(SnapshotRefreshRunner.nextRefreshCheckDate(snapshot: long, now: past))
    #expect(SnapshotRefreshRunner.nextRefreshCheckInterval(normalInterval: 3_600, nextCheckDate: retry,
        startedAt: past, finishedAt: past) > 0)
    #expect(SnapshotRefreshRunner.nextRefreshCheckInterval(normalInterval: 3_600, nextCheckDate: past,
        startedAt: past, finishedAt: past.addingTimeInterval(1)) > 0)

    let near = freshnessLimit(.openAI, account: "near", observedAt: past.addingTimeInterval(-60),
        reset: past.addingTimeInterval(86_400))
    let mixed = UsageSnapshot(generatedAt: past, limits: long.limits + [near])
    let nearDate = try #require(SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.refreshNeededAge)
        .nextAgeStaleTransitionDate(for: UsageSnapshot(generatedAt: past, limits: [near]), now: past))
    #expect(SnapshotRefreshRunner.nextRefreshCheckDate(snapshot: mixed, now: past) == nearDate)

    let delayed = freshnessLimit(.anthropic, observedAt: reset.addingTimeInterval(1), reset: reset)
    var retries = ResetExpiryRefreshState()
    retries.recordAttempt(previousSnapshot: snapshot,
        refreshedSnapshot: UsageSnapshot(generatedAt: reset.addingTimeInterval(1), limits: [delayed]),
        attemptedAt: reset.addingTimeInterval(1))
    #expect(retries.records.first?.retryCount == 1)
    #expect(retries.nextRefreshCheckDate(for: UsageSnapshot(generatedAt: reset, limits: [delayed]), now: reset)
        == reset.addingTimeInterval(1 + SnapshotFreshness.resetExpiryRetryDelay))
}

@Test(arguments: [false, true])
func agentExportsEachWindowsFreshnessWithoutLiveBurnForSavedValues(shared: Bool) throws {
    let configuration = LocalProviderAccountConfiguration(id: "primary", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Test account", authPath: "/never-read/fixture")
    let document = AccountConfigurationDocument(updatedAt: freshnessNow, accounts: [configuration])
    let weekly = freshnessLimit(.openAI, reset: freshnessNow.addingTimeInterval(86_400))
    let short = freshnessLimit(.openAI, window: "5-hour", used: 40, reset: freshnessNow)
    let report = StoredProviderReport(provider: .openAI, accountID: "primary", configuredAccountID: "primary",
        accountName: "Test account", generatedAt: freshnessNow, status: .healthy, errorMessage: nil)
    let stored = StoredUsageSnapshot(savedAt: freshnessNow,
        snapshot: UsageSnapshot(generatedAt: freshnessNow, limits: [weekly, short]), reports: [report])
    let remote = shared ? CompanionSyncDocument(snapshot: CompanionSnapshot(storedSnapshot: stored,
        configuration: [configuration], publisherID: "fixture")) : nil
    let export = AgentAccountSnapshot(configuration: document, stored: stored, history: [], now: freshnessNow,
        sharedDocument: remote)
    let account = try #require(export.accounts.first)
    #expect(account.state == .available)
    let payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
    let windows = try #require(payload["windows"] as? [[String: Any]])
    let saved = try #require(windows.first { $0["period"] as? String == MainLimitWindow.fiveHour.rawValue })
    let current = try #require(windows.first { $0["period"] as? String == MainLimitWindow.weekly.rawValue })
    #expect(saved["isCurrent"] as? Bool == false)
    #expect(current["isCurrent"] as? Bool == true)
    #expect(saved["burn"] is NSNull)
    #expect(saved["remainingFraction"] as? Double == 0.6)
}

@Test func transportFailureAndMissingObservationTimesNeverBecomeCurrent() throws {
    let old = freshnessNow.addingTimeInterval(-SnapshotFreshness.appMaximumAge - 1)
    let limit = UsageLimit(provider: .openAI, accountID: "legacy", accountName: "Test account", label: "Weekly",
        windowLabel: "Weekly", unit: .percent, used: 25, limit: 100, resetsAt: freshnessNow.addingTimeInterval(86_400))
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: old, limits: [limit]), reports: [], now: freshnessNow)
    #expect(overview.accounts.first?.state == .stale)
    let expired = freshnessLimit(.anthropic, window: "5-hour", reset: freshnessNow)
    let current = freshnessLimit(.openAI, reset: freshnessNow.addingTimeInterval(86_400))
    for limits in [[current], [current, expired]] {
        let snapshot = WidgetSnapshot(state: .stale, generatedAt: freshnessNow, limits: limits,
            status: .stale, message: "Saved", syncErrorMessage: "Update unavailable")
        #expect(snapshot.accountOverview(now: freshnessNow).accounts.allSatisfy { !$0.horizon(now: freshnessNow).isCurrent })
    }
}
