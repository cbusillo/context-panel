import Foundation
import Testing
@testable import ContextPanelCore

private let overviewNow = Date(timeIntervalSince1970: 1_800_000_000)
private func overviewLimit(_ account: String, _ window: String, used: Int?, at: Date = overviewNow,
                           reset: Date? = nil, provider: Provider = .openAI) -> UsageLimit {
    UsageLimit(provider: provider, accountID: account, configuredAccountID: account, accountName: "Provider identity",
               label: window, windowLabel: window, unit: .percent, used: used, limit: 100,
               resetsAt: reset ?? overviewNow.addingTimeInterval(3_600), lastUpdatedAt: at)
}
private func overviewMetadata(_ account: String, provider: Provider = .openAI, hidden: Bool = false,
                              useLast: Bool = false) -> AccountDisplayMetadata {
    AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(provider, account),
                           configurationID: AccountDisplayMetadata.safeID(provider, account),
                           provider: provider, label: account, showInWidgets: !hidden, useLast: useLast)
}

@Test func overviewRanksTheTightestWindowAndRequiresRoomInEveryWindow() throws {
    let snapshot = UsageSnapshot(generatedAt: overviewNow, limits: [
        overviewLimit("weekly-room", "Weekly", used: 10), overviewLimit("weekly-room", "5-hour", used: 100),
        overviewLimit("balanced", "Weekly", used: 30), overviewLimit("balanced", "5-hour", used: 40),
        overviewLimit("use-last", "Weekly", used: 0), overviewLimit("unknown", "Weekly", used: nil)
    ])
    let overview = AccountOverview(snapshot: snapshot, reports: [], metadata: [
        overviewMetadata("weekly-room"), overviewMetadata("balanced"), overviewMetadata("use-last", useLast: true),
        overviewMetadata("unknown")
    ], now: overviewNow)
    let blocked = try #require(overview.accounts.first)
    #expect(blocked.remainingFraction == 0)
    #expect(blocked.state == .limited)
    #expect(overview.closest?.id == blocked.id)
    #expect(overview.useNext(provider: .openAI)?.metadata.label == "balanced")
    #expect(overview.accounts.last?.remainingFraction == nil)
    #expect(overview.accounts.last?.isReliable == false)
}

@Test func overviewKeepsSavedOrderAndUsesItToBreakRecommendationTies() {
    let snapshot = UsageSnapshot(generatedAt: overviewNow, limits: [
        overviewLimit("second", "Weekly", used: 40), overviewLimit("first", "Weekly", used: 40),
        overviewLimit("claude", "Weekly", used: 20, provider: .anthropic)
    ])
    let overview = AccountOverview(snapshot: snapshot, reports: [], metadata: [
        overviewMetadata("first"), overviewMetadata("second"), overviewMetadata("claude", provider: .anthropic)
    ], now: overviewNow)
    #expect(overview.accounts.map(\.metadata.label) == ["first", "second", "claude"])
    #expect(overview.closest?.metadata.label == "first")
    #expect(overview.useNext(provider: .openAI)?.metadata.label == "first")
    #expect(overview.useNext(provider: .anthropic)?.metadata.label == "claude")
}

@Test func overviewHiddenAccountsStayInAppAnswersButAreExcludedFromWidgets() {
    let snapshot = UsageSnapshot(generatedAt: overviewNow, limits: [
        overviewLimit("hidden", "Weekly", used: 90), overviewLimit("visible", "Weekly", used: 20)
    ])
    let metadata = [overviewMetadata("hidden", hidden: true), overviewMetadata("visible")]
    let app = AccountOverview(snapshot: snapshot, reports: [], metadata: metadata, now: overviewNow)
    let widget = AccountOverview(snapshot: snapshot, reports: [], metadata: metadata, now: overviewNow, widgetsOnly: true)
    #expect(app.accounts.count == 2)
    #expect(app.closest?.metadata.label == "hidden")
    #expect(widget.accounts.map(\.metadata.label) == ["visible"])
}

@Test func overviewSavedAndFailedWindowsNeverBecomeLiveRecommendations() throws {
    let old = overviewNow.addingTimeInterval(-SnapshotFreshness.appMaximumAge - 1)
    let snapshot = UsageSnapshot(generatedAt: overviewNow, limits: [
        overviewLimit("old", "Weekly", used: 5, at: old), overviewLimit("failed", "Weekly", used: 10)
    ])
    let reports = [StoredProviderReport(provider: .openAI, accountID: "failed", configuredAccountID: "failed",
        accountName: "Ignored", generatedAt: overviewNow, status: .failure, errorMessage: "private diagnostic")]
    let overview = AccountOverview(snapshot: snapshot, reports: reports, now: overviewNow)
    #expect(overview.accounts.first?.state == .stale)
    #expect(overview.accounts.first?.remainingFraction == 0.95)
    #expect(overview.accounts.last?.state == .unavailable)
    #expect(overview.closest == nil)
    #expect(overview.useNext(provider: .openAI) == nil)
}

@Test func overviewDeadlinesExpireAtTheDeadlineAndRetainLastObservedCoverage() throws {
    let expiry = overviewNow.addingTimeInterval(60)
    let summary = ProviderResetCreditSummary(availableCount: 3, observedAt: overviewNow,
        coverage: .partial, knownExpiries: [expiry, overviewNow.addingTimeInterval(120)])
    let report = StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
        accountName: "Ignored", generatedAt: overviewNow, resetCredits: summary, status: .healthy, errorMessage: nil)
    let snapshot = UsageSnapshot(generatedAt: overviewNow, limits: [overviewLimit("a", "Weekly", used: 30)])
    let before = AccountOverview(snapshot: snapshot, reports: [report], now: overviewNow)
    let after = AccountOverview(snapshot: snapshot, reports: [report], now: expiry)
    #expect(before.deadlines.map(\.expiresAt) == summary.knownExpiries)
    #expect(after.deadlines.map(\.expiresAt) == [overviewNow.addingTimeInterval(120)])
    #expect(after.accounts.first?.bankedResets?.availableCount == 2)
    #expect(after.accounts.first?.unknownExpiryCount == 1)
    #expect(after.accounts.first?.remainingFraction == before.accounts.first?.remainingFraction)
    let stale = AccountOverview(snapshot: snapshot, reports: [report], now: overviewNow.addingTimeInterval(30), maximumAge: 10)
    #expect(stale.deadlines.first?.state == .stale)
    #expect(stale.nextDeadline == nil)
}

@Test func overviewMetadataCarriesTypedLabelsAndPreferencesWithoutSourceOrCredentialIdentity() throws {
    var setup = LocalProviderAccountConfiguration(id: "person@example.invalid", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Typed@example.invalid", authPath: "/private/source/auth.json",
        showInWidgets: false, useLast: true)
    setup.accountAliases = [setup.id: "Alias@example.invalid"]
    let snapshot = StoredUsageSnapshot(savedAt: overviewNow,
        snapshot: UsageSnapshot(generatedAt: overviewNow, limits: [overviewLimit(setup.id, "Weekly", used: 20)]),
        reports: [StoredProviderReport(provider: .openAI, accountID: setup.id, configuredAccountID: setup.id,
            accountName: "Provider identity", generatedAt: overviewNow, status: .healthy, errorMessage: nil)])
    let metadata = AccountDisplayMetadata.local(configuration: [setup], stored: snapshot, now: overviewNow)
    let encoded = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
    #expect(encoded.contains("Alias@example.invalid"))
    #expect(!encoded.contains("person@example.invalid"))
    #expect(!encoded.contains("Provider identity"))
    #expect(!encoded.contains("/private/"))
    #expect(metadata.first?.showInWidgets == false)
    #expect(metadata.first?.useLast == true)
    let export = AgentAccountSnapshot(configuration: AccountConfigurationDocument(updatedAt: overviewNow, accounts: [setup]),
        stored: snapshot, history: [], now: overviewNow)
    #expect(export.accounts.first?.id == metadata.first?.id)
    #expect(export.accounts.first?.remainingFraction == 0.8)
    #expect(export.answers.useNext.isEmpty)
}

@Test func companionAccountMetadataMatchesCompanionLimitsAndSurvivesBindingAndRemoteMerge() throws {
    let setup = LocalProviderAccountConfiguration(id: "a", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Typed@example.invalid", authPath: "/not/read/auth.json", showInWidgets: false, useLast: true)
    let stored = StoredUsageSnapshot(savedAt: overviewNow,
        snapshot: UsageSnapshot(generatedAt: overviewNow, limits: [overviewLimit("a", "Weekly", used: 20)]),
        reports: [StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
            accountName: "Provider identity", generatedAt: overviewNow, status: .healthy, errorMessage: nil)])
    let metadata = AccountDisplayMetadata.companion(configuration: [setup], stored: stored, now: overviewNow)
    let document = CompanionSyncDocument(storedSnapshot: stored, publishedAt: overviewNow, accountDisplayMetadata: metadata)
    let widget = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: document, status: .healthy), now: overviewNow)
    let row = try #require(widget.accountOverview(now: overviewNow).accounts.first)
    #expect(row.metadata.label == setup.displayName)
    #expect(row.remainingFraction == 0.8)
    #expect(widget.accountOverview(now: overviewNow, widgetsOnly: true).accounts.isEmpty)
    let merged = document.mergingForRemotePublish(existing: document, now: overviewNow)
    #expect(merged.accountDisplayMetadata == metadata)
    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(CompanionSyncDocument.self, from: encoded)
    #expect(decoded.accountDisplayMetadata == metadata)
}

@Test func savedTransportSnapshotCannotRecommendFreshLookingRows() {
    let snapshot = WidgetSnapshot(state: .stale, generatedAt: overviewNow,
        limits: [overviewLimit("saved", "Weekly", used: 10)], status: .stale, message: "Saved")
    let overview = snapshot.accountOverview(now: overviewNow)
    #expect(overview.accounts.first?.remainingFraction == 0.9)
    #expect(overview.accounts.first?.state == .stale)
    #expect(overview.closest == nil)
    #expect(overview.useNext(provider: .openAI) == nil)
}

@Test func codexHomeDiscoveryFindsOnlyAuthorizedDirectChildrenWithoutReadingCredentials() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "a@example.invalid")
    let second = root.appending(path: "b@example.invalid")
    let nested = root.appending(path: "not-a-home/nested")
    for url in [first, second, nested] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Invalid synthetic bytes cannot be decoded as credentials; discovery needs only metadata.
        try Data([0xff]).write(to: url.appending(path: "auth.json"))
    }
    try FileManager.default.createSymbolicLink(at: root.appending(path: "linked-home"), withDestinationURL: first)
    let linkedAuth = root.appending(path: "linked-auth")
    try FileManager.default.createDirectory(at: linkedAuth, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkedAuth.appending(path: "auth.json"), withDestinationURL: first.appending(path: "auth.json"))
    #expect(try CodexHomeDiscovery.find(in: linkedAuth).isEmpty)
    #expect(try CodexHomeDiscovery.find(in: root).map(\.lastPathComponent) == ["a@example.invalid", "b@example.invalid"])
    #expect(try CodexHomeDiscovery.find(in: first) == [first])
}

@Test func accountResetTextIncludesViewerWeekdayAndExactMinuteAcrossTimeZones() throws {
    let date = try #require(ContextPanelDateFormatting.date(from: "2026-10-02T00:07:00Z"))
    let local = ContextPanelDateFormatting.accountReset(date, locale: Locale(identifier: "en_US_POSIX"),
        timeZone: try #require(TimeZone(identifier: "America/New_York")))
    #expect(local.contains("Thu"))
    #expect(local.contains("8:07"))
    let utc = ContextPanelDateFormatting.accountReset(date, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
    #expect(utc.contains("Fri"))
    #expect(utc.contains("12:07"))
}

@Test func oneFailedCatalogMemberDoesNotPoisonItsHealthySibling() throws {
    let config = LocalProviderAccountConfiguration(id: "catalog", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Typed", authPath: "/synthetic/auth.json")
    let limits = [overviewLimit("healthy-member", "Weekly", used: 20), overviewLimit("failed-member", "Weekly", used: 70)].map { limit in
        UsageLimit(provider: limit.provider, accountID: limit.accountID, configuredAccountID: config.id,
            accountName: limit.accountName, label: limit.label, windowLabel: limit.windowLabel,
            unit: limit.unit, used: limit.used, limit: limit.limit, resetsAt: limit.resetsAt, lastUpdatedAt: limit.lastUpdatedAt)
    }
    let reports = [StoredProviderReport(provider: .openAI, accountID: "healthy-member", configuredAccountID: config.id,
        accountName: "Ignored", generatedAt: overviewNow, status: .healthy, errorMessage: nil),
        StoredProviderReport(provider: .openAI, accountID: "failed-member", configuredAccountID: config.id,
        accountName: "Ignored", generatedAt: overviewNow.addingTimeInterval(1), status: .failure, errorMessage: "Failed member")]
    let stored = StoredUsageSnapshot(savedAt: overviewNow, snapshot: UsageSnapshot(generatedAt: overviewNow, limits: limits), reports: reports)
    let metadata = AccountDisplayMetadata.local(configuration: [config], stored: stored, now: overviewNow)
    let overview = AccountOverview(snapshot: stored.snapshot, reports: reports, metadata: metadata, now: overviewNow)
    let healthy = try #require(overview.accounts.first { $0.id == AccountDisplayMetadata.safeID(.openAI, "healthy-member") })
    #expect(healthy.state == .available)
    #expect(overview.useNext(provider: .openAI)?.id == healthy.id)
    #expect(overview.accounts.first { $0.id == AccountDisplayMetadata.safeID(.openAI, "failed-member") }?.state == .unavailable)
}

@Test func fallbackProviderEmailsAreRedactedWhileTypedMetadataEmailsRemain() throws {
    let snapshot = UsageSnapshot(generatedAt: overviewNow, limits: [UsageLimit(provider: .openAI, accountID: "a",
        accountName: "provider@example.invalid", label: "Weekly", unit: .percent, used: 10, limit: 100, lastUpdatedAt: overviewNow)])
    let fallback = AccountOverview(snapshot: snapshot, reports: [], now: overviewNow)
    #expect(fallback.accounts.first?.metadata.label.contains("provider@example.invalid") == false)
    let typed = AccountOverview(snapshot: snapshot, reports: [], metadata: [AccountDisplayMetadata(
        id: AccountDisplayMetadata.safeID(.openAI, "a"), configurationID: "safe-config", provider: .openAI,
        label: "typed@example.invalid")], now: overviewNow)
    #expect(typed.accounts.first?.metadata.label == "typed@example.invalid")
}

@Test func remoteMergeKeepsDifferentMacAccountListsAndLatestSameSourceDisplayEdits() throws {
    func document(_ id: String, provider: Provider, now: Date, hidden: Bool = false, useLast: Bool = false) -> CompanionSyncDocument {
        let setup = LocalProviderAccountConfiguration(id: id, provider: provider,
            connectorKind: provider == .openAI ? .codexRateLimits : .claudeOAuthUsage,
            displayName: "Typed \(id)", authPath: provider == .openAI ? "/synthetic/auth.json" : nil,
            showInWidgets: !hidden, useLast: useLast)
        let stored = StoredUsageSnapshot(savedAt: now,
            snapshot: UsageSnapshot(generatedAt: now, limits: [overviewLimit(id, "Weekly", used: 20, at: now, provider: provider)]),
            reports: [StoredProviderReport(provider: provider, accountID: id, configuredAccountID: id,
                accountName: "Provider identity", generatedAt: now, status: .healthy, errorMessage: nil)])
        return CompanionSyncDocument(storedSnapshot: stored, publishedAt: now,
            accountDisplayMetadata: AccountDisplayMetadata.companion(configuration: [setup], stored: stored, now: now))
    }
    let first = document("Mac-A", provider: .openAI, now: overviewNow)
    let second = document("Mac-B", provider: .anthropic, now: overviewNow.addingTimeInterval(5), hidden: true, useLast: true)
    let merged = second.mergingForRemotePublish(existing: first, now: overviewNow.addingTimeInterval(6))
    let rows = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: merged, status: .healthy), now: overviewNow.addingTimeInterval(6))
        .accountOverview(now: overviewNow.addingTimeInterval(6)).accounts
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.metadata.label)) == ["Typed Mac-A", "Typed Mac-B"])
    #expect(rows.first { $0.metadata.provider == .anthropic }?.metadata.showInWidgets == false)
    #expect(rows.first { $0.metadata.provider == .anthropic }?.metadata.useLast == true)
    let edit = document("Mac-A", provider: .openAI, now: overviewNow.addingTimeInterval(10), useLast: true)
    let afterEdit = edit.mergingForRemotePublish(existing: merged, now: overviewNow.addingTimeInterval(11))
    #expect(afterEdit.accountDisplayMetadata?.count == 2)
    #expect(afterEdit.accountDisplayMetadata?.first { $0.provider == .openAI }?.useLast == true)
    let reverse = first.mergingForRemotePublish(existing: second, now: overviewNow.addingTimeInterval(6))
    #expect(reverse.accountDisplayMetadata == merged.accountDisplayMetadata)
}
