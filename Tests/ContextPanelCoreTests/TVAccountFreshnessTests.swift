import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import Testing

@Test func tvAccountFreshnessSeparatesSavedAccountFromFreshSibling() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-SnapshotFreshness.companionProviderMaximumAge - 60)
    let metadata = ["saved", "fresh"].map { id in
        AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, id),
            configurationID: AccountDisplayMetadata.safeID(.openAI, id), provider: .openAI, label: id)
    }
    let limits = zip(["saved", "fresh"], [old, now]).map { id, observed in
        UsageLimit(provider: .openAI, accountID: id, accountName: id, label: "Weekly", windowLabel: "Weekly",
            unit: .percent, used: 25, limit: 100, resetsAt: now.addingTimeInterval(86_400),
            lastUpdatedAt: observed, confidence: .observed)
    }
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: limits, status: .healthy,
        message: "", accountDisplayMetadata: metadata)
    let overview = snapshot.accountOverview(now: now, maximumAge: SnapshotFreshness.companionProviderMaximumAge)
    let summary = TVAccountFreshnessSummary(overview: overview, now: now)
    #expect(summary.hasSavedReadings)
    #expect(summary.text.contains(AccountTerms.accountsCount(1)))
    #expect(summary.text.contains(AccountPaceText.when(old, now: now)))
    #expect(overview.accounts.first { $0.metadata.label == "fresh" }?.state == .available)
    #expect(overview.accounts.first { $0.metadata.label == "saved" }?.remainingFraction == 0.75)
}

@Test func tvAccountFreshnessNeverClaimsSavedValuesForAnAccountWithoutReadings() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let metadata = AccountDisplayMetadata(id: "missing", configurationID: "missing", provider: .openAI,
        label: "Needs a reading", readState: .unavailable)
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: [], status: .failure,
        message: "", accountDisplayMetadata: [metadata])
    let summary = TVAccountFreshnessSummary(overview: snapshot.accountOverview(now: now), now: now)
    #expect(!summary.hasSavedReadings)
    #expect(!summary.text.contains("saved readings"))
}

@Test func tvAccountFreshnessWithNoAccountsHasNoInventedObservation() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = WidgetSnapshot(state: .setupNeeded, generatedAt: now, limits: [], status: .unknown,
        message: "", accountDisplayMetadata: [])
    let summary = TVAccountFreshnessSummary(overview: snapshot.accountOverview(now: now), now: now)
    #expect(!summary.hasSavedReadings)
    #expect(summary.text == AccountTerms.noCurrentReading)
}

@Test func tvAccountFreshnessCallsRefreshingCachedReadingsUpdating() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let metadata = AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, "refreshing"),
        configurationID: "refreshing", provider: .openAI, label: "Sample")
    let limit = UsageLimit(provider: .openAI, accountID: "refreshing", accountName: "Sample",
        label: "Weekly", unit: .percent, used: 25, limit: 100,
        lastUpdatedAt: now, confidence: .observed, statusOverride: .loading)
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: [limit], status: .loading,
        message: "", accountDisplayMetadata: [metadata])
    let overview = snapshot.accountOverview(now: now)
    #expect(overview.accounts.first?.state == .refreshing)
    let summary = TVAccountFreshnessSummary(overview: overview, now: now)
    #expect(summary.text.hasPrefix(AccountCapacityState.refreshing.displayText))
    #expect(!summary.text.contains(AccountTerms.updated))
    #expect(summary.text.contains(AccountPaceText.when(now, now: now)))
}

@Test(arguments: [AccountCapacityState.unknown, .notConnected])
func tvAccountFreshnessDoesNotCallNonCurrentObservationsUpdated(state: AccountCapacityState) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let metadata = AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, "sample"),
        configurationID: "sample", provider: .openAI, label: "Sample", readState: state)
    let limit = UsageLimit(provider: .openAI, accountID: "sample", accountName: "Sample",
        label: "Weekly", unit: .percent, used: 25, limit: 100, lastUpdatedAt: now, confidence: .observed)
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: [limit], status: .healthy,
        message: "", accountDisplayMetadata: [metadata])
    let summary = TVAccountFreshnessSummary(overview: snapshot.accountOverview(now: now), now: now)
    #expect(summary.text == AccountTerms.noCurrentReading)
}

@Test(arguments: [UsageStatus.healthy, .stale, .failure, .unknown, .limited, .loading])
func tvTopShelfSavedCapacityUsesSharedSavedToken(status: UsageStatus) {
    let card = TVTopShelfCard(id: "sample", provider: .google, title: "Sample account", headline: "75% left",
        detail: "", status: status, remainingPercent: 75, actionURLString: TVAppRoute.runway.url.absoluteString)
    #expect(card.capacityToken(isStale: true) == .saved)
    #expect(card.capacityToken(isStale: false) == ([.stale, .failure].contains(status) ? .saved : Provider.google.colorToken))
}

@Test func tvTopShelfCompactCardsNamePressureAndSuppressSavedPressureClaims() {
    func card(_ status: UsageStatus) -> TVTopShelfCard {
        TVTopShelfCard(id: "sample", provider: .openAI, title: "Sample", headline: "9% left",
            detail: "", status: status, remainingPercent: 9, actionURLString: TVAppRoute.runway.url.absoluteString)
    }
    #expect(card(.close).gridStatusText(isStale: false) == UsageStatus.close.displayText)
    #expect(card(.limited).gridStatusText(isStale: false) == UsageStatus.limited.displayText)
    #expect(card(.loading).gridStatusText(isStale: false) == UsageStatus.loading.displayText)
    #expect(card(.healthy).gridStatusText(isStale: false) == nil)
    #expect(card(.unknown).gridStatusText(isStale: false) == nil)
    #expect(card(.close).gridStatusText(isStale: true) == nil)
}
