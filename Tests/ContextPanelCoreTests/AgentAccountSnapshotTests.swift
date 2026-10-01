import Foundation
import Testing
@testable import ContextPanelCore

private let agentNow = Date(timeIntervalSince1970: 1_800_000_000)

private func agentConfiguration(_ id: String, provider: Provider = .openAI, enabled: Bool = true) -> LocalProviderAccountConfiguration {
    LocalProviderAccountConfiguration(id: id, provider: provider,
        connectorKind: provider == .openAI ? .codexRateLimits
            : provider == .anthropic ? .claudeOAuthUsage : .googleAntigravityQuota,
        displayName: "Local \(id)", isEnabled: enabled, authPath: "/private/never-read/\(id)")
}

private func agentLimit(_ id: String, used: Int, at: Date, provider: Provider = .openAI) -> UsageLimit {
    UsageLimit(provider: provider, accountID: id, configuredAccountID: id,
        accountName: "Ignored", label: "Weekly", windowLabel: "Weekly", unit: .percent,
        used: used, limit: 100, resetsAt: agentNow.addingTimeInterval(86_400), lastUpdatedAt: at)
}

@Test func agentSnapshotIncludesAllAccountsAndUsesIndependentBurnAndResetData() throws {
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [
        agentConfiguration("a"), agentConfiguration("b"), agentConfiguration("c"),
        agentConfiguration("d", provider: .anthropic), agentConfiguration("e", provider: .anthropic),
        agentConfiguration("f", provider: .google)
    ])
    let history = (0...2).map { index in
        let at = agentNow.addingTimeInterval(Double(index - 2) * 1_800)
        let limits = [
            agentLimit("a", used: 10 + index * 2, at: at),
            agentLimit("b", used: 10 + index * 20, at: at),
            agentLimit("d", used: 21, at: at, provider: .anthropic)
        ]
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: limits),
            reports: limits.map { limit in
                StoredProviderReport(provider: limit.provider, accountID: limit.accountID,
                    configuredAccountID: limit.configuredAccountID, accountName: "Ignored",
                    generatedAt: at, status: .healthy, errorMessage: nil)
            })
    }
    let stored = try #require(history.last)
    let export = AgentAccountSnapshot(configuration: config, stored: stored, history: history, now: agentNow)
    #expect(export.accounts.count == config.accounts.count)
    let a = try #require(export.accounts.first { $0.label == "Local a" })
    let b = try #require(export.accounts.first { $0.label == "Local b" })
    #expect(a.windows.first?.burn?.unitsPerHour == 4)
    #expect(b.windows.first?.burn?.unitsPerHour == 40)
    #expect(a.windows.first?.naturalResetAt == stored.snapshot.limits.first?.resetsAt)
    #expect(export.accounts.first { $0.label == "Local d" }?.state == .available)
    #expect(export.accounts.first { $0.label == "Local e" }?.state == .notConnected)
    #expect(export.accounts.first { $0.label == "Local f" }?.state == .unknown)
    #expect(export.accounts.allSatisfy { $0.bankedResets.summary == nil && $0.bankedResets.state != .available })
}

@Test(arguments: [-SnapshotFreshness.appMaximumAge - 1, 120])
func agentSnapshotDoesNotOfferBurnForOldOrFutureObservations(offset: TimeInterval) throws {
    let at = agentNow.addingTimeInterval(offset)
    let stored = StoredUsageSnapshot(savedAt: agentNow,
        snapshot: UsageSnapshot(generatedAt: agentNow, limits: [agentLimit("a", used: 30, at: at)]))
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [agentConfiguration("a")])
    let export = AgentAccountSnapshot(configuration: config, stored: stored, history: [stored], now: agentNow)
    let row = try #require(export.accounts.first)
    #expect(row.state == .stale)
    #expect(row.windows.first?.burn == nil)
    #expect(row.windows.first?.observedAt == at)
}

@Test func agentSnapshotKeepsBankedResetDatesSeparateFromNaturalResetsAndUnknownCoverage() throws {
    let reset = ProviderResetCreditSummary(availableCount: 2, observedAt: agentNow, coverage: .partial,
        knownExpiries: [agentNow.addingTimeInterval(3_600)])
    let report = StoredProviderReport(provider: .anthropic, accountID: "d", configuredAccountID: "d",
        accountName: "Ignored", generatedAt: agentNow, resetCredits: reset, status: .healthy, errorMessage: nil)
    let stored = StoredUsageSnapshot(savedAt: agentNow,
        snapshot: UsageSnapshot(generatedAt: agentNow, limits: [agentLimit("d", used: 21, at: agentNow, provider: .anthropic)]),
        reports: [report])
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [agentConfiguration("d", provider: .anthropic)])
    let row = try #require(AgentAccountSnapshot(configuration: config, stored: stored, history: [], now: agentNow).accounts.first)
    #expect(row.bankedResets.state == .available)
    #expect(row.bankedResets.summary == reset)
    #expect(row.bankedResets.unknownExpiryCount == 1)
    #expect(row.windows.first?.naturalResetAt != reset.earliestKnownExpiry)
    let later = AgentAccountSnapshot(configuration: config, stored: stored, history: [], now: agentNow.addingTimeInterval(3_601))
    #expect(later.accounts.first?.bankedResets.state == .stale)
    #expect(later.accounts.first?.bankedResets.summary?.availableCount == reset.availableCount - reset.knownExpiries.count)
    #expect(later.accounts.first?.bankedResets.summary?.knownExpiries.isEmpty == true)
    #expect(later.accounts.first?.windows.first?.used == row.windows.first?.used)
}

@Test func agentSnapshotJSONExcludesRawDiagnosticsPathsAndIdentityAndMakesUnknownsExplicit() throws {
    var account = agentConfiguration("person@example.invalid")
    account.displayName = "Local person@example.invalid /private/source auth"
    let stored = StoredUsageSnapshot(savedAt: agentNow, snapshot: UsageSnapshot(generatedAt: agentNow, limits: []),
        reports: [StoredProviderReport(provider: .openAI, accountID: account.id, configuredAccountID: account.id,
            accountName: "Ignored", generatedAt: agentNow, status: .failure,
            errorMessage: "Bearer private-secret; raw response")])
    let export = AgentAccountSnapshot(configuration: AccountConfigurationDocument(updatedAt: agentNow, accounts: [account]),
        stored: stored, history: [], now: agentNow)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(export)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("person@example.invalid"))
    #expect(!json.contains("/private/"))
    #expect(!json.contains("private-secret"))
    #expect(!json.contains("raw response"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try #require(object["accounts"] as? [[String: Any]])
    #expect(rows.first?["usageCredits"] is NSNull)
    let resets = try #require(rows.first?["bankedResets"] as? [String: Any])
    #expect(resets["summary"] is NSNull)
    #expect(resets["unknownExpiryCount"] is NSNull)
    #expect(export.accounts.first?.state == .unavailable)
}

@Test func agentSnapshotDoesNotTreatLegacyEarliestExpiryAsAllResetDates() {
    let legacy = ProviderResetCreditSummary(availableCount: 4, observedAt: agentNow,
        coverage: .complete, earliestKnownExpiry: agentNow.addingTimeInterval(86_400))
    let observation = AgentAccountSnapshot.BankedResets(state: .available, summary: legacy)
    #expect(observation.summary == legacy)
    #expect(observation.unknownExpiryCount == 3)
    let zero = ProviderResetCreditSummary(availableCount: 0, observedAt: agentNow, coverage: .countOnly)
    #expect(AgentAccountSnapshot.BankedResets(state: .available, summary: zero).unknownExpiryCount == 0)
}

@Test func agentSnapshotAccountObservationDoesNotAdvanceWhenSessionQuotaIsPolled() throws {
    let eventAt = agentNow.addingTimeInterval(-SnapshotFreshness.appMaximumAge * 0.8)
    var account = agentConfiguration("a")
    account.codexQuotaPath = "/not-read/account/sessions"
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [account])
    let stored = StoredUsageSnapshot(savedAt: agentNow, snapshot: UsageSnapshot(generatedAt: agentNow,
        limits: [agentLimit("a", used: 30, at: eventAt)]),
        reports: [StoredProviderReport(provider: .openAI, accountID: "a", configuredAccountID: "a",
            accountName: "Ignored", generatedAt: agentNow, status: .healthy, errorMessage: nil)])
    let row = try #require(AgentAccountSnapshot(configuration: config, stored: stored, history: [], now: agentNow).accounts.first)
    #expect(row.state == .available)
    #expect(row.observedAt == eventAt)
    #expect(row.observedAt != stored.reports.first?.generatedAt)
}

@Test func agentSnapshotRetainsConfigurationKeyWhenClaudeConnects() throws {
    let account = agentConfiguration("d", provider: .anthropic)
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [account])
    let empty = StoredUsageSnapshot(savedAt: agentNow, snapshot: UsageSnapshot(generatedAt: agentNow, limits: []))
    let before = try #require(AgentAccountSnapshot(configuration: config, stored: empty, history: [], now: agentNow).accounts.first)
    let logical = ConnectorRedactor.localAccountID(provider: .anthropic, stableID: account.id)
    let limit = UsageLimit(provider: .anthropic, accountID: logical, accountName: "Ignored", label: "Weekly",
        windowLabel: "Weekly", unit: .percent, used: 21, limit: 100, lastUpdatedAt: agentNow)
    let connected = StoredUsageSnapshot(savedAt: agentNow, snapshot: UsageSnapshot(generatedAt: agentNow, limits: [limit]),
        reports: [StoredProviderReport(provider: .anthropic, accountID: logical,
            accountName: "Ignored", generatedAt: agentNow, status: .healthy, errorMessage: nil)])
    let after = try #require(AgentAccountSnapshot(configuration: config, stored: connected, history: [], now: agentNow).accounts.first)
    #expect(before.state == .notConnected)
    #expect(after.state == .available)
    #expect(before.configurationID == after.configurationID)
}

@Test func agentSnapshotMatchesPanelScheduledResetPresentationWithExplicitAssumption() throws {
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [agentConfiguration("f", provider: .google)])
    let raw = UsageLimit(provider: .google, accountID: "f", configuredAccountID: "f", accountName: "Ignored",
        label: "Quota", windowLabel: "Weekly", unit: .percent, used: 100, limit: 100,
        resetsAt: agentNow.addingTimeInterval(-30), lastUpdatedAt: agentNow.addingTimeInterval(-60),
        freshnessMode: .eventDriven)
    let stored = StoredUsageSnapshot(savedAt: agentNow, snapshot: UsageSnapshot(generatedAt: agentNow, limits: [raw]),
        reports: [StoredProviderReport(provider: .google, accountID: "f", configuredAccountID: "f",
            accountName: "Ignored", generatedAt: agentNow, status: .healthy, errorMessage: nil)])
    let presented = stored.snapshot.presented(at: agentNow)
    let panel = try #require(AccountCapacity.rows(configuration: config.accounts, snapshot: presented,
        reports: stored.reports, now: agentNow).first)
    let exported = try #require(AgentAccountSnapshot(configuration: config, stored: stored, history: [], now: agentNow).accounts.first)
    #expect(exported.state == panel.state)
    #expect(exported.windows.first?.used == panel.limits.first?.used)
    #expect(exported.windows.first?.confidence == panel.limits.first?.confidence)
    #expect(exported.windows.first?.presentationAssumption == .scheduledReset)
    #expect(exported.windows.first?.naturalResetAt == panel.limits.first?.resetsAt)
}

@Test func agentSnapshotReaderFailsClosedAndDoesNotWriteOrReadAuthSources() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: AgentAccountSnapshotReadError.self) { try AgentAccountSnapshot.read(rootDirectory: root, now: agentNow) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let config = AccountConfigurationDocument(updatedAt: agentNow, accounts: [agentConfiguration("a")])
    try AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")).save(config)
    let stored = StoredUsageSnapshot(savedAt: agentNow, snapshot: UsageSnapshot(generatedAt: agentNow,
        limits: [agentLimit("a", used: 20, at: agentNow)]))
    try JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots")).save(stored)
    let original = try Data(contentsOf: root.appending(path: "accounts.json"))
    let export = try AgentAccountSnapshot.read(rootDirectory: root, now: agentNow)
    #expect(export.accounts.first?.windows.first?.used == 20)
    #expect(try Data(contentsOf: root.appending(path: "accounts.json")) == original)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "file-bookmarks.json").path))
    try Data("malformed".utf8).write(to: root.appending(path: "Snapshots/current-snapshot.json"))
    #expect(throws: AgentAccountSnapshotReadError.self) { try AgentAccountSnapshot.read(rootDirectory: root, now: agentNow) }
}
