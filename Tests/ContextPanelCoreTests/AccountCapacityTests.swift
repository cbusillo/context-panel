import Foundation
import Testing
@testable import ContextPanelCore

private let capacityNow = Date(timeIntervalSince1970: 1_800_000_000)

private func capacityConfiguration(_ id: String, provider: Provider = .openAI, enabled: Bool = true) -> LocalProviderAccountConfiguration {
    LocalProviderAccountConfiguration(id: id, provider: provider,
        connectorKind: provider == .openAI ? .codexRateLimits : .claudeOAuthUsage,
        displayName: "Local \(id)", isEnabled: enabled, authPath: "/unreadable/\(id)")
}

private func capacityLimit(_ id: String, used: Int, at: Date = capacityNow, reset: Date? = nil) -> UsageLimit {
    UsageLimit(provider: .openAI, accountID: id, configuredAccountID: id,
        accountName: "Local \(id)", label: "Weekly", windowLabel: "Weekly", unit: .percent,
        used: used, limit: 100, resetsAt: reset ?? capacityNow.addingTimeInterval(86_400), lastUpdatedAt: at)
}

@Test(arguments: ["GPT-5.3-Codex-Spark", "Another model"])
func accountCapacityUsesMainOpenAILimitsWhileKeepingModelRows(model: String) throws {
    let weekly = capacityLimit("a", used: 20)
    let short = UsageLimit(provider: .openAI, accountID: "a", configuredAccountID: "a", accountName: "Local a",
        label: "Codex 5-hour", windowLabel: "5-hour", modelLabel: "Codex", unit: .percent,
        used: 30, limit: 100, resetsAt: capacityNow.addingTimeInterval(3_600), lastUpdatedAt: capacityNow)
    let modelLimit = UsageLimit(provider: .openAI, accountID: "a", configuredAccountID: "a", accountName: "Local a",
        label: "\(model) 5-hour", windowLabel: "5-hour", modelLabel: model, unit: .percent,
        used: 100, limit: 100, resetsAt: capacityNow.addingTimeInterval(3_600), lastUpdatedAt: capacityNow)
    let limits = [weekly, short, modelLimit]
    let snapshot = UsageSnapshot(generatedAt: capacityNow, limits: limits)
    let report = StoredProviderReport(report: ProviderConnectorReport(provider: .openAI, accountID: "a",
        configuredAccountID: "a", accountName: "Local a", generatedAt: capacityNow, limits: limits))
    let configuration = [capacityConfiguration("a")]
    let row = try #require(AccountCapacity.rows(configuration: configuration, snapshot: snapshot,
        reports: [report], now: capacityNow).first)
    #expect(row.status == .healthy)
    #expect(row.limits == limits)
    for metadata in [nil, AccountDisplayMetadata.local(configuration: configuration,
        stored: StoredUsageSnapshot(savedAt: capacityNow, snapshot: snapshot, reports: [report]), now: capacityNow)] {
        let overview = AccountOverview(snapshot: snapshot, reports: [report], metadata: metadata, now: capacityNow)
        let account = try #require(overview.accounts.first)
        #expect(account.state == .available)
        #expect(account.remainingFraction == short.remainingCapacityRatio)
        #expect(account.windows.count == limits.count)
        #expect(account.windows.last?.status == .limited)
        #expect(account.shortWindow?.id == AccountDisplayMetadata.safeID(.openAI, short.id))
        #expect(account.longWindow?.id == AccountDisplayMetadata.safeID(.openAI, weekly.id))
        #expect(overview.providerTotals(now: capacityNow).first?.shortRemaining == short.remainingCapacityRatio)
    }
}

@Test func accountCapacityKeepsAllFiveAccountsWhenOnlyOneCanBeRead() {
    let configs = [capacityConfiguration("a"), capacityConfiguration("b"), capacityConfiguration("c"),
        capacityConfiguration("d", provider: .anthropic), capacityConfiguration("e", provider: .anthropic)]
    let report = StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
        accountName: "Ignored provider name", generatedAt: capacityNow, status: .healthy, errorMessage: nil)
    let rows = AccountCapacity.rows(configuration: configs,
        snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [capacityLimit("a", used: 30)]), reports: [report], now: capacityNow)
    #expect(rows.count == 5)
    #expect(rows.filter { $0.status == .unknown }.count == 4)
    #expect(rows.first?.name == "Local a")
    #expect(rows.first?.limits.first?.used == 30)
}

@Test(arguments: [true, false])
func capacityCardUsesTheSharedCalmCodexSignInLabel(enabled: Bool) throws {
    let report = StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
        accountName: "Local a", generatedAt: capacityNow, status: .failure,
        accessState: ProviderAccessState(kind: .signInExpired), errorMessage: nil)
    let row = try #require(AccountCapacity.rows(configuration: [capacityConfiguration("a", enabled: enabled)],
        snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [capacityLimit("a", used: 30)]),
        reports: [report], now: capacityNow).first)
    #expect(row.signInExpiryText == (enabled ? AccountTerms.codexSignInExpired : nil))
}

@Test func accountCapacitySeparatesFailureStalenessDisabledAndDeduplicatesLogicalAccounts() {
    var alias = capacityConfiguration("a")
    alias.accountAliases = ["a": "Research"]
    let reports = [StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
        accountName: "Ignored", generatedAt: capacityNow, status: .failure, errorMessage: nil)]
    let rows = AccountCapacity.rows(configuration: [alias, alias, capacityConfiguration("b", enabled: false)],
        snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [capacityLimit("a", used: 90)]), reports: reports, now: capacityNow)
    #expect(rows.count == 2)
    #expect(rows[0].status == .failure)
    #expect(rows[0].name == "Research")
    #expect(rows[1].isEnabled == false)
    let staleReport = StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
        accountName: "Ignored", generatedAt: capacityNow.addingTimeInterval(-SnapshotFreshness.appMaximumAge - 1), status: .healthy, errorMessage: nil)
    let stale = AccountCapacity.rows(configuration: [alias], snapshot: UsageSnapshot(generatedAt: capacityNow,
        limits: [capacityLimit("a", used: 30, at: staleReport.generatedAt)]), reports: [staleReport], now: capacityNow)
    #expect(stale.first?.status == .stale)
    let updated = AccountCapacity.rows(configuration: [alias], snapshot: UsageSnapshot(generatedAt: capacityNow,
        limits: [capacityLimit("a", used: 30)]), reports: [staleReport], now: capacityNow)
    #expect(updated.first?.status == .healthy)
}

@Test func accountBurnRateNeverBorrowsSiblingPace() throws {
    let history = (0...2).map { index in
        let at = capacityNow.addingTimeInterval(Double(index - 2) * 1_800)
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: [
            capacityLimit("a", used: 10 + index * 2, at: at),
            capacityLimit("b", used: 10 + index * 20, at: at)
        ]))
    }
    let current = try #require(history.last).snapshot
    let rates = AccountBurnRateEstimator.observedBurnRates(current: current, history: history, now: capacityNow)
    #expect(rates["a"]?[capacityLimit("a", used: 0).id]?.unitsPerHour == 4)
    #expect(rates["b"]?[capacityLimit("b", used: 0).id]?.unitsPerHour == 40)
    #expect(rates["missing"] == nil)
}

@Test(arguments: [0.75, 1.0, 1.01])
func accountCapacityUsesAppFreshnessBoundary(ageFraction: Double) throws {
    let observedAt = capacityNow.addingTimeInterval(-SnapshotFreshness.appMaximumAge * ageFraction)
    let report = StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
        accountName: "Local a", generatedAt: observedAt, status: .healthy, errorMessage: nil)
    let row = try #require(AccountCapacity.rows(configuration: [capacityConfiguration("a")],
        snapshot: UsageSnapshot(generatedAt: observedAt, limits: [capacityLimit("a", used: 30, at: observedAt)]),
        reports: [report], now: capacityNow).first)
    #expect(row.status == (ageFraction > 1 ? .stale : .healthy))
}

@Test func claudeCapacityKeepsConnectedAndUnconnectedAccountsSeparate() throws {
    let configs = ["primary", "secondary"].map { capacityConfiguration($0, provider: .anthropic) }
    let limit = UsageLimit(provider: .anthropic, accountID: "primary", configuredAccountID: "primary",
        accountName: "Writing", label: "Weekly", unit: .percent, used: 30, limit: 100,
        lastUpdatedAt: capacityNow)
    let connected = StoredProviderReport(provider: .anthropic, accountID: "primary", configuredAccountID: "primary",
        accountName: "Writing", generatedAt: capacityNow, status: .healthy, errorMessage: nil)
    let missing = StoredProviderReport(provider: .anthropic, accountID: "secondary", configuredAccountID: "secondary",
        accountName: "Secondary", generatedAt: capacityNow, status: .failure,
        errorMessage: "Claude is not connected. Sign in to Claude from Settings.")
    for reports in [[connected], [connected, missing]] {
        let rows = AccountCapacity.rows(configuration: configs,
            snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [limit]), reports: reports, now: capacityNow)
        #expect(rows.count == 2)
        let primary = try #require(rows.first { $0.id == "primary" })
        let secondary = try #require(rows.first { $0.id == "secondary" })
        #expect(!primary.isNotConnected)
        #expect(primary.limits == [limit])
        #expect(secondary.isNotConnected)
        #expect(secondary.limits.isEmpty)
    }
}

@Test func accountBurnRateDoesNotCrossResetBoundary() {
    let history = (0...2).map { index in
        let at = capacityNow.addingTimeInterval(Double(index - 2) * 1_800)
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: [
            capacityLimit("a", used: index * 10, at: at, reset: capacityNow.addingTimeInterval(Double(index + 1) * 86_400))
        ]))
    }
    let rates = AccountBurnRateEstimator.observedBurnRates(current: history[2].snapshot, history: history, now: capacityNow)
    #expect(rates["a"]?.isEmpty != false)
}

@Test func secondClaudeAccountCannotDisconnectDefaultCredentials() {
    let second = capacityConfiguration("second", provider: .anthropic)
    #expect(second.oauthCredentialAccountIDs == [second.id])
    let defaultAccount = AccountConfigurationStore.defaultDocument().accounts.first { $0.connectorKind == .claudeOAuthUsage }
    #expect(defaultAccount?.oauthCredentialAccountIDs.contains("claude-local-default") == true)
}

@Test func resetCreditDatesRoundTripAndOldSnapshotsRemainReadable() throws {
    let summary = ProviderResetCreditSummary(availableCount: 3, observedAt: capacityNow, coverage: .partial,
        earliestKnownExpiry: capacityNow.addingTimeInterval(60), knownExpiries: [capacityNow.addingTimeInterval(120), capacityNow.addingTimeInterval(60)])
    let encoded = try JSONEncoder().encode(summary)
    let decoded = try JSONDecoder().decode(ProviderResetCreditSummary.self, from: encoded)
    #expect(decoded.knownExpiries == summary.knownExpiries.sorted())
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "knownExpiries")
    let restored = try JSONDecoder().decode(ProviderResetCreditSummary.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.knownExpiries.isEmpty)
    #expect(restored.earliestKnownExpiry == summary.earliestKnownExpiry)
}

@Test func accountCapacitySourceFailureKeepsMembersWithoutInventingAnotherAccount() {
    let config = capacityConfiguration("source")
    let sourceID = ConnectorRedactor.localAccountID(provider: .openAI, path: config.authPath!)
    let limit = UsageLimit(provider: .openAI, accountID: "member", configuredAccountID: config.id,
        accountName: "Ignored", label: "Weekly", unit: .percent, used: 30, limit: 100)
    let failure = StoredProviderReport(provider: .openAI, accountID: sourceID, configuredAccountID: config.id,
        accountName: "Ignored", generatedAt: capacityNow, status: .failure, errorMessage: nil)
    let rows = AccountCapacity.rows(configuration: [config], snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [limit]),
        reports: [failure], now: capacityNow)
    #expect(rows.count == 1)
    #expect(rows.first?.id == limit.accountID)
    #expect(rows.first?.status == .failure)
}

@Test func accountBurnRateKeepsOverlappingClaudeWindowsSeparate() {
    func windows(_ index: Int, at: Date) -> [UsageLimit] {
        ["Weekly", "Opus Weekly"].enumerated().map { offset, label in
            UsageLimit(provider: .anthropic, accountID: "claude", accountName: "Writing",
                label: label, windowLabel: "Weekly", unit: .percent,
                used: 10 + index * (offset == 0 ? 2 : 20), limit: 100,
                resetsAt: capacityNow.addingTimeInterval(86_400), lastUpdatedAt: at)
        }
    }
    let history = (0...2).map { index in
        let at = capacityNow.addingTimeInterval(Double(index - 2) * 1_800)
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: windows(index, at: at)))
    }
    let current = history[2].snapshot
    let rates = AccountBurnRateEstimator.observedBurnRates(current: current, history: history, now: capacityNow)
    #expect(rates["claude"]?[current.limits[0].id]?.unitsPerHour == 4)
    #expect(rates["claude"]?[current.limits[1].id]?.unitsPerHour == 40)
}

@Test func anObservedAccountsBurnDoesNotChangeAsTheSameSnapshotIsReadLater() {
    let history = [(hours: -7.0, used: 0), (-5.0, 5), (-4.0, 10), (0.0, 20)].map { sample in
        let at = capacityNow.addingTimeInterval(sample.hours * 3600)
        let limit = capacityLimit("a", used: sample.used, at: at)
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: [limit]), reports: [])
    }
    let current = history.last!.snapshot
    let first = AccountBurnRateEstimator.observedBurnRates(current: current, history: history, now: capacityNow)
    #expect(first["a"]?[current.limits[0].id]?.sampleCount ?? 0 > 0)
    #expect(first == AccountBurnRateEstimator.observedBurnRates(current: current, history: history, now: capacityNow.addingTimeInterval(2 * 3600)))
}

@Test func antigravityCapacityStaysCurrentWhileAGYIsIdle() throws {
    // AGY observations arrive while the tool runs; idle time alone is not stale.
    let observedAt = capacityNow.addingTimeInterval(-2 * 3_600)
    let config = LocalProviderAccountConfiguration(id: "google-antigravity-default", provider: .google,
        connectorKind: .googleAntigravityQuota, displayName: "Gemini", isEnabled: true, authPath: nil)
    let report = StoredProviderReport(provider: .google, accountID: "google-x", configuredAccountID: config.id,
        accountName: "Gemini", generatedAt: observedAt, status: .healthy, errorMessage: nil)
    let limit = UsageLimit(id: "google:google-x:agy:gemini-weekly", provider: .google, accountID: "google-x",
        configuredAccountID: config.id, accountName: "Gemini", label: "Gemini Weekly", unit: .percent,
        used: 4, limit: 100, resetsAt: capacityNow.addingTimeInterval(86_400), lastUpdatedAt: observedAt,
        confidence: .observed, freshnessMode: .eventDriven)
    let row = try #require(AccountCapacity.rows(configuration: [config],
        snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [limit]), reports: [report], now: capacityNow).first)
    #expect(row.state == .available)
}

@Test func accountCapacityUsesReportedLoginOnlyWhenTypedNameIsEmpty() {
    var unnamed = capacityConfiguration("c", provider: .anthropic)
    unnamed.displayName = ""
    let report = StoredProviderReport(provider: .anthropic, accountID: "c", configuredAccountID: "c",
        accountName: "pat@example.test", generatedAt: capacityNow, status: .healthy, errorMessage: nil)
    let rows = AccountCapacity.rows(configuration: [unnamed, capacityConfiguration("d", provider: .anthropic)],
        snapshot: UsageSnapshot(generatedAt: capacityNow, limits: []),
        reports: [report, StoredProviderReport(provider: .anthropic, accountID: "d", configuredAccountID: "d",
            accountName: "other@example.test", generatedAt: capacityNow, status: .healthy, errorMessage: nil)],
        now: capacityNow)
    #expect(rows.map(\.name) == ["pat@example.test", "Local d"])
    unnamed.displayName = " "
    let unread = AccountCapacity.rows(configuration: [unnamed], snapshot: UsageSnapshot(generatedAt: capacityNow, limits: []),
        reports: [], now: capacityNow)
    #expect(unread.map(\.name) == [Provider.anthropic.accountDisplayName])
}

@Test func clearedNameUsesTheNewestReportOverLimitsRetainedFromTheTypedName() {
    var cleared = capacityConfiguration("c", provider: .anthropic)
    cleared.displayName = ""
    let retained = UsageLimit(provider: .anthropic, accountID: "c", configuredAccountID: "c", accountName: "Work",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 10, limit: 100,
        resetsAt: capacityNow.addingTimeInterval(86_400), lastUpdatedAt: capacityNow.addingTimeInterval(-600))
    let failedRead = StoredProviderReport(provider: .anthropic, accountID: "c", configuredAccountID: "c",
        accountName: "pat@example.test", generatedAt: capacityNow, status: .failure, errorMessage: nil)
    let rows = AccountCapacity.rows(configuration: [cleared], snapshot: UsageSnapshot(generatedAt: capacityNow, limits: [retained]),
        reports: [failedRead], now: capacityNow)
    #expect(rows.map(\.name) == ["pat@example.test"])
}

@Test func useLastNoticeNamesUnnamedAccountsByTheirLogin() {
    var first = capacityConfiguration("c", provider: .anthropic)
    var second = capacityConfiguration("d", provider: .anthropic)
    first.displayName = ""
    second.displayName = ""
    first.useLast = true
    var accounts = [first, second]
    let reports = ["c", "d"].map { StoredProviderReport(provider: .anthropic, accountID: $0, configuredAccountID: $0,
        accountName: "\($0)@example.test", generatedAt: capacityNow, status: .healthy, errorMessage: nil) }
    let notice = accounts.setUseLast("d", true, reports: reports) ?? ""
    #expect(notice.contains("c@example.test") && notice.contains("d@example.test"))
}
