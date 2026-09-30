import Foundation
import Testing
@testable import ContextPanelCore

@Test func accountQuotaIncludesFiveAccountsAndMissingSources() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configurations = (0..<5).map { index in
        LocalProviderAccountConfiguration(id: "local-\(index)", provider: index < 3 ? .openAI : .anthropic,
            connectorKind: index < 3 ? .codexRateLimits : .claudeOAuthUsage,
            displayName: "Account \(index)", sessionQuotaPath: index < 3 ? "/selected/\(index)" : nil)
    }
    let report = ProviderConnectorReport(provider: .anthropic,
        accountID: ConnectorRedactor.localAccountID(provider: .anthropic, stableID: "local-3"),
        configuredAccountID: "local-3", accountName: "Account 3", generatedAt: now,
        limits: [], status: .failure, errorMessage: "Unavailable")
    let rows = ProviderAccountQuota.accounts(configurations: configurations,
        snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: [StoredProviderReport(report: report)])
    #expect(rows.count == 5)
    #expect(Set(rows.map(\.displayName)) == Set(configurations.map(\.displayName)))
    #expect(rows.first { $0.displayName == "Account 3" }?.status == .failure)
    #expect(rows.filter { $0.status == .unknown }.count == 4)
}

@Test func accountQuotaDeduplicatesMirroredLogicalAccounts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configurations = ["a", "b"].map {
        LocalProviderAccountConfiguration(id: $0, provider: .openAI, connectorKind: .codexRateLimits,
                                         displayName: $0, authPath: "/selected/\($0)/auth.json")
    }
    let reports = configurations.map {
        StoredProviderReport(report: ProviderConnectorReport(provider: .openAI, accountID: "same-account",
            configuredAccountID: $0.id, accountName: $0.displayName, generatedAt: now, limits: []))
    }
    let rows = ProviderAccountQuota.accounts(configurations: configurations,
        snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: reports)
    #expect(rows.count == 1)
}

@Test func accountBurnRatesDoNotRepeatPooledRateAcrossAccounts() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(_ age: Double) -> UsageSnapshot {
        UsageSnapshot(generatedAt: now.addingTimeInterval(-age), limits: ["a", "b"].enumerated().map { index, id in
            UsageLimit(provider: .openAI, accountID: id, accountName: id, label: "Weekly",
                windowLabel: "Weekly", unit: .percent, used: 30 - Int(age / 3600) * (index + 1) * 2,
                limit: 100, resetsAt: now.addingTimeInterval(3 * 24 * 3600), lastUpdatedAt: now.addingTimeInterval(-age))
        })
    }
    let current = snapshot(0)
    let history = [7200.0, 3600, 0].map {
        StoredUsageSnapshot(savedAt: now.addingTimeInterval(-$0), snapshot: snapshot($0))
    }
    let rates = AccountQuotaBurnRateEstimator.rates(current: current, history: history, now: now)
    #expect(rates[current.limits[0].id]?.unitsPerHour == 2)
    #expect(rates[current.limits[1].id]?.unitsPerHour == 4)
}

@Test func sessionQuotaUsesLatestCommittedQuotaAndOriginalTimestamp() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let timestamp = ContextPanelDateFormatting.string(from: now.addingTimeInterval(-3600))
    let line = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":20,\"window_minutes\":300,\"resets_at\":1800003600},\"secondary\":{\"used_percent\":70,\"window_minutes\":10080,\"resets_at\":1800259200}}}}"
    try (line + "\n" + line).write(to: root.appending(path: "quota.jsonl"), atomically: true, encoding: .utf8)
    let observation = try #require(CodexSessionQuotaReader.latest(rootDirectory: root, now: now))
    #expect(observation.observedAt == now.addingTimeInterval(-3600))
    #expect(observation.snapshot.secondary?.usedPercent == 70)
    let account = LocalProviderAccountConfiguration(id: "local-a", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Local A", sessionQuotaPath: root.path)
    let connector = CodexSessionQuotaConnector(account: account) { _ in observation }
    let result = await connector.refresh(now: now)
    #expect(result.reports.first?.status == .stale)
    #expect(result.snapshot.limits.allSatisfy { $0.lastUpdatedAt == observation.observedAt })
    #expect(result.reports.first?.resetCredits == nil)
}

@Test func sessionQuotaMissingDirectoryIsVisibleAndDoesNotReadAuth() async {
    let account = LocalProviderAccountConfiguration(id: "local-a", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Local A", sessionQuotaPath: "/unavailable")
    let result = await CodexSessionQuotaConnector(account: account) { _ in nil }.refresh(now: Date())
    #expect(result.reports.count == 1)
    #expect(result.reports.first?.status == .unknown)
    #expect(result.snapshot.limits.isEmpty)
}

@Test func sessionQuotaRejectsMalformedFutureAndTranscriptRows() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func line(type: String = "event_msg", age: Double = 10, used: String = "45") -> String {
        let timestamp = ContextPanelDateFormatting.string(from: now.addingTimeInterval(-age))
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"\(type)\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":\(used),\"window_minutes\":300}}}}"
    }
    try ([line(type: "response_item"), line(age: -10), line(used: "101"), line(used: "-1")]
        .joined(separator: "\n") + "\n").write(to: root.appending(path: "quota.jsonl"), atomically: true, encoding: .utf8)
    #expect(CodexSessionQuotaReader.latest(rootDirectory: root, now: now) == nil)
    try (line() + "\n" + line(age: 0, used: "99")).write(to: root.appending(path: "quota.jsonl"), atomically: true, encoding: .utf8)
    let result = try #require(CodexSessionQuotaReader.latest(rootDirectory: root, now: now))
    #expect(result.snapshot.primary?.usedPercent == 45)
    #expect(result.snapshot.primary?.resetsAt == nil)
}

@Test func accountQuotaOldCreditSummaryStillLoadsAndNewDatesRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let original = ProviderResetCreditSummary(availableCount: 2, observedAt: date, coverage: .complete,
        earliestKnownExpiry: date.addingTimeInterval(3600),
        knownExpiryDates: [date.addingTimeInterval(7200), date.addingTimeInterval(3600)])
    let roundTrip = try decoder.decode(ProviderResetCreditSummary.self, from: encoder.encode(original))
    #expect(roundTrip.knownExpiryDates == original.knownExpiryDates.sorted())
    var oldObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
    oldObject.removeValue(forKey: "knownExpiryDates")
    let legacy = try decoder.decode(ProviderResetCreditSummary.self, from: JSONSerialization.data(withJSONObject: oldObject))
    #expect(legacy.knownExpiryDates.isEmpty)
    #expect(legacy.earliestKnownExpiry == original.earliestKnownExpiry)
}
