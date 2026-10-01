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
        limits: [capacityLimit("a", used: 30)]), reports: [staleReport], now: capacityNow)
    #expect(stale.first?.status == .stale)
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
