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

@Test(arguments: [UsageStatus.healthy, .stale, .failure, .unknown])
func tvTopShelfSavedCapacityUsesSharedWarmNeutral(status: UsageStatus) {
    let card = TVTopShelfCard(id: "sample", provider: .google, title: "Sample account", headline: "75% left",
        detail: "", status: status, remainingPercent: 75, actionURLString: TVAppRoute.runway.url.absoluteString)
    #expect(card.capacityToken(isStale: true) == .saved)
    #expect(card.capacityToken(isStale: false) == ([.stale, .failure].contains(status) ? .saved : Provider.google.colorToken))
}
