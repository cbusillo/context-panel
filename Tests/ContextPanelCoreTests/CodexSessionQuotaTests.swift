import Foundation
import Testing
@testable import ContextPanelCore

private struct QuotaFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func account(_ id: String = "personal") -> LocalProviderAccountConfiguration {
        LocalProviderAccountConfiguration(id: id, provider: .openAI, connectorKind: .codexRateLimits,
            displayName: id.capitalized, authPath: "/must-not-read/auth.json", codexQuotaPath: root.path)
    }
    func event(used: Double = 70, age: TimeInterval = 0, resetOffset: TimeInterval = 3600) -> String {
        let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        return """
        {"timestamp":"\(date)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":20,"window_minutes":300,"resets_at":\(now.addingTimeInterval(resetOffset).timeIntervalSince1970)},"secondary":{"used_percent":\(used),"window_minutes":10080,"resets_at":\(now.addingTimeInterval(resetOffset).timeIntervalSince1970)},"credits":{"has_credits":true,"unlimited":false,"balance":62500}}}}
        """
    }
    func write(_ text: String, name: String = "quota.jsonl") throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func connector(_ accounts: [LocalProviderAccountConfiguration]? = nil, sandbox: Bool = false) throws -> any ProviderConnector {
        try #require(AccountConnectorFactory.connectors(
            from: AccountConfigurationDocument(updatedAt: now, accounts: accounts ?? [account()]),
            requiresBookmarkedAuthFiles: sandbox).first)
    }
}

@Test func sessionQuotaReadsLatestCommittedValidObservationAndNumericCredits() async throws {
    let fixture = try QuotaFixture()
    defer { fixture.remove() }
    try fixture.write(fixture.event(used: 10, age: 60) + "\n" + fixture.event(used: 70) + "\n"
        + fixture.event(used: 110) + "\n" + fixture.event(used: 99, age: -1) + "\n"
        + fixture.event(used: 80)) // uncommitted row
    try fixture.write(fixture.event(used: 5, age: 120) + "\n", name: "newer-modification.jsonl")
    let report = try #require(await fixture.connector().refresh(now: fixture.now).reports.first)
    #expect(report.limits.map(\.used) == [20, 70])
    #expect(report.limits.allSatisfy { $0.lastUpdatedAt == fixture.now })
    #expect(report.usageCredits?.balance == 62500)
    #expect(report.resetCredits == nil)
    #expect(report.configuredAccountID == fixture.account().id)
    #expect(report.accountName == fixture.account().displayName)
    #expect(report.status == .healthy)
}

@Test func sessionQuotaStaleAndExpiredObservationsNeverBecomeFreshByPolling() async throws {
    let fixture = try QuotaFixture()
    defer { fixture.remove() }
    let age = SnapshotFreshness.appMaximumAge + 1
    try fixture.write(fixture.event(age: age) + "\n")
    let connector = try fixture.connector()
    let report = try #require(await connector.refresh(now: fixture.now).reports.first)
    #expect(report.status == .stale)
    #expect(report.limits.first?.lastUpdatedAt == fixture.now.addingTimeInterval(-age))
    let rows = AccountCapacity.rows(configuration: [fixture.account()],
        snapshot: UsageSnapshot(generatedAt: fixture.now, limits: report.limits),
        reports: [StoredProviderReport(report: report)], now: fixture.now)
    #expect(rows.first?.status == .stale)
    try fixture.write(fixture.event(resetOffset: -1) + "\n")
    #expect(await connector.refresh(now: fixture.now).reports.first?.status == .stale)
}

@Test func sessionQuotaRequiresBookmarkInSandboxAndRejectsMissingAndSharedRoots() async throws {
    let fixture = try QuotaFixture()
    defer { fixture.remove() }
    try fixture.write(fixture.event() + "\n")
    #expect(await (try fixture.connector(sandbox: true)).refresh(now: fixture.now).reports.first?.status == .failure)
    let shared = [fixture.account(), fixture.account("projects")]
    for connector in AccountConnectorFactory.connectors(from: AccountConfigurationDocument(updatedAt: fixture.now,
        accounts: shared), requiresBookmarkedAuthFiles: false) {
        let report = try #require(await connector.refresh(now: fixture.now).reports.first)
        #expect(report.status == .failure)
        #expect(report.limits.isEmpty)
        #expect(report.errorMessage?.contains("multiple accounts") == true)
    }
    var missing = fixture.account()
    missing.codexQuotaPath = fixture.root.appendingPathComponent("missing").path
    #expect(await (try fixture.connector([missing])).refresh(now: fixture.now).reports.first?.status == .failure)
}

@Test func sessionQuotaEmptyFolderAndSymlinkDoNotSupplyAnotherAccountsData() async throws {
    let fixture = try QuotaFixture()
    defer { fixture.remove() }
    let connector = try fixture.connector()
    #expect(await connector.refresh(now: fixture.now).reports.first?.status == .unknown)
    let sibling = try QuotaFixture()
    defer { sibling.remove() }
    try sibling.write(sibling.event() + "\n")
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("other.jsonl"),
        withDestinationURL: sibling.root.appendingPathComponent("quota.jsonl"))
    #expect(await connector.refresh(now: fixture.now).reports.first?.limits.isEmpty == true)
}

@Test func sessionQuotaConfigurationRoundTripsWithoutChangingAuthMapping() throws {
    let fixture = try QuotaFixture()
    defer { fixture.remove() }
    let store = AccountConfigurationStore(configurationURL: fixture.root.appendingPathComponent("config.json"))
    let account = fixture.account()
    try store.save(AccountConfigurationDocument(updatedAt: fixture.now, accounts: [account]))
    #expect(store.load().document.accounts == [account])
    #expect(account.effectiveAuthPath == nil)
    #expect(account.promptCacheDirectory?.path == account.codexQuotaPath)
    var apiAccount = account
    apiAccount.codexQuotaPath = nil
    #expect(apiAccount.effectiveAuthPath == account.authPath)
}

@Test func sessionSourceSwitchReplacesOldLogicalLaneDuringPartialRefresh() async throws {
    let fixture = try QuotaFixture()
    defer { fixture.remove() }
    try fixture.write(fixture.event() + "\n")
    let store = JSONSnapshotStore(rootDirectory: fixture.root.appendingPathComponent("snapshots"))
    let account = fixture.account()
    let old = ProviderConnectorReport(provider: .openAI, accountID: "old-api-member", configuredAccountID: account.id,
        accountName: account.displayName, generatedAt: fixture.now,
        limits: [UsageLimit(provider: .openAI, accountID: "old-api-member", configuredAccountID: account.id,
            accountName: account.displayName, label: "Weekly", windowLabel: "Weekly", unit: .percent,
            used: 50, limit: 100, resetsAt: fixture.now.addingTimeInterval(3600), lastUpdatedAt: fixture.now)])
    try store.save(StoredUsageSnapshot(savedAt: fixture.now, refreshResult: ConnectorRefreshResult(generatedAt: fixture.now, reports: [old])))
    let fresh = await (try fixture.connector()).refresh(now: fixture.now)
    try store.saveMerged(refreshResult: fresh, savedAt: fixture.now)
    let saved = try #require(store.loadCurrent().snapshot)
    #expect(Set(saved.snapshot.limits.map(\.accountID)) == Set(fresh.reports.map(\.accountID)))
    #expect(saved.reports.count == 1)
    #expect(AccountCapacity.rows(configuration: [account], snapshot: saved.snapshot, reports: saved.reports, now: fixture.now).count == 1)
}

@Test func allAccountsIncludesAntigravityWithoutHidingUnconnectedClaude() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configs = [LocalProviderAccountConfiguration(id: "google", provider: .google,
        connectorKind: .googleAntigravityQuota, displayName: "Antigravity"),
        LocalProviderAccountConfiguration(id: "claude", provider: .anthropic,
        connectorKind: .claudeOAuthUsage, displayName: "Writing")]
    let rows = AccountCapacity.rows(configuration: configs, snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: [], now: now)
    #expect(rows.map(\.provider) == [.google, .anthropic])
    #expect(rows.last?.isNotConnected == true)
}
