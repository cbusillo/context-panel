import Foundation
import Testing

@testable import ContextPanelCore

@Test func googleAntigravityUsagePublishesImmediatelyWithoutRefreshingOtherProviders() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = JSONSnapshotStore(rootDirectory: root.appending(path: "snapshots"))
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let configuration = AccountConfigurationDocument(updatedAt: observedAt, accounts: [
        LocalProviderAccountConfiguration(id: "google", provider: .google, connectorKind: .googleAntigravityQuota, displayName: "Google"),
        LocalProviderAccountConfiguration(id: "paused", provider: .google, connectorKind: .googleAntigravityQuota, displayName: "Paused", isEnabled: false),
        LocalProviderAccountConfiguration(id: "openai", provider: .openAI, connectorKind: .codexRateLimits, displayName: "OpenAI"),
    ])
    try accountStore.save(configuration)
    let siblingLimit = UsageLimit(id: "openai-limit", provider: .openAI, accountID: "openai", configuredAccountID: "openai",
        accountName: "OpenAI", label: "Weekly", unit: .percent, used: 25, limit: 100, lastUpdatedAt: observedAt.addingTimeInterval(-60))
    let sibling = ProviderConnectorReport(provider: .openAI, accountID: "openai", configuredAccountID: "openai",
        accountName: "OpenAI", generatedAt: observedAt.addingTimeInterval(-60), limits: [siblingLimit])
    try primary.save(StoredUsageSnapshot(savedAt: observedAt.addingTimeInterval(-60),
        refreshResult: ConnectorRefreshResult(generatedAt: observedAt.addingTimeInterval(-60), reports: [sibling])))
    let service = SnapshotRefreshService(accountStore: accountStore, stores: SnapshotRefreshStores(primary: primary),
        connectorFactory: { _ in
            Issue.record("Hook ingestion must not refresh other providers")
            return []
        }, promptCacheTelemetryReader: { _ in [] })
    let runner = SnapshotRefreshRunner(service: service, resetExpiryRefreshStore: nil,
        lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")))
    let bridge = GoogleAntigravityUsageSnapshotStore(snapshotURL: root.appending(path: "bridge/quota.json"))
    let payload = Data(#"""
    {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[
      {"id":"gemini-weekly","remaining_fraction":0.8,"reset_time":"2027-01-16T09:00:00Z"}
    ]}]}}}
    """#.utf8)
    let result = try GoogleAntigravityUsageBridge.ingest(data: payload, observedAt: observedAt, store: bridge)
    guard case .saved(let snapshot) = result else {
        Issue.record("Expected a saved Google observation")
        return
    }

    try await GoogleAntigravityUsageBridge.publish(snapshot: snapshot, configuration: configuration, runner: runner)

    let saved = try #require(primary.loadCurrent().snapshot)
    let google = try #require(saved.snapshot.limits.first { $0.provider == .google })
    #expect(google.lastUpdatedAt == observedAt)
    #expect(google.used == 20)
    #expect(google.configuredAccountID == "google")
    #expect(saved.snapshot.limits.filter { $0.provider == .google }.count == 1)
    #expect(saved.snapshot.limits.first { $0.provider == .openAI } == siblingLimit)
}
