import Foundation
import Testing

@testable import ContextPanelCore

@Test func jsonSnapshotStoreRoundTripsCurrentSnapshotAndReports() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    let refresh = ConnectorRefreshResult(generatedAt: savedAt, reports: [ProviderConnectorReport(
        provider: .openAI,
        accountID: "local-openai",
        accountName: "OpenAI",
        generatedAt: savedAt,
        limits: [usageLimit(provider: .openAI, accountID: "local-openai", used: 30, savedAt: savedAt)]
    )])

    try store.save(StoredUsageSnapshot(savedAt: savedAt, refreshResult: refresh))

    let result = store.loadCurrent()

    #expect(result.status == .healthy)
    #expect(result.snapshot?.schemaVersion == 1)
    #expect(result.snapshot?.savedAt == savedAt)
    #expect(result.snapshot?.snapshot.limits.count == 1)
    #expect(result.snapshot?.reports.count == 1)
    #expect(result.snapshot?.reports[0].provider == .openAI)
    #expect(FileManager.default.fileExists(atPath: store.currentSnapshotURL.path))
    #expect(store.loadHistory().count == 1)
}

@Test func jsonSnapshotStoreFiltersHistoryByProviderAccountAndLimit() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(savedAt: first, snapshot: UsageSnapshot(
        generatedAt: first,
        limits: [usageLimit(provider: .openAI, accountID: "a", used: 10, savedAt: first)]
    )))
    try store.save(StoredUsageSnapshot(savedAt: second, snapshot: UsageSnapshot(
        generatedAt: second,
        limits: [usageLimit(provider: .google, accountID: "b", used: 20, savedAt: second)]
    )))

    #expect(store.loadHistory().map(\.savedAt) == [second, first])
    #expect(store.loadHistory(query: SnapshotStoreQuery(provider: .openAI)).map(\.savedAt) == [first])
    #expect(store.loadHistory(query: SnapshotStoreQuery(accountID: "b")).map(\.savedAt) == [second])
    #expect(store.loadHistory(query: SnapshotStoreQuery(limit: 1)).count == 1)
}

@Test func jsonSnapshotStoreMergesRefreshResultByProviderAccount() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    let initial = ConnectorRefreshResult(generatedAt: first, reports: [
        ProviderConnectorReport(
            provider: .openAI,
            accountID: "openai-a",
            accountName: "OpenAI A",
            generatedAt: first,
            limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 40, savedAt: first)]
        ),
        ProviderConnectorReport(
            provider: .google,
            accountID: "gemini-a",
            accountName: "Gemini A",
            generatedAt: first,
            limits: [usageLimit(provider: .google, accountID: "gemini-a", used: 10, savedAt: first)]
        ),
    ])
    try store.save(StoredUsageSnapshot(savedAt: first, refreshResult: initial))

    let claudeRefresh = ConnectorRefreshResult(generatedAt: second, reports: [
        ProviderConnectorReport(
            provider: .anthropic,
            accountID: "claude-web",
            accountName: "Claude Web",
            generatedAt: second,
            limits: [usageLimit(provider: .anthropic, accountID: "claude-web", used: 3, savedAt: second)]
        )
    ])

    try store.saveMerged(refreshResult: claudeRefresh, savedAt: second)

    let limits = try #require(store.loadCurrent().snapshot?.snapshot.limits)
    #expect(limits.map(\.provider).contains(.openAI))
    #expect(limits.map(\.provider).contains(.google))
    #expect(limits.map(\.provider).contains(.anthropic))
    #expect(store.loadCurrent().snapshot?.reports.count == 3)
    #expect(store.loadHistory().count == 2)

    let replacement = ConnectorRefreshResult(generatedAt: second, reports: [
        ProviderConnectorReport(
            provider: .openAI,
            accountID: "openai-a",
            accountName: "OpenAI A",
            generatedAt: second,
            limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 80, savedAt: second)]
        )
    ])
    try store.saveMerged(refreshResult: replacement, savedAt: second.addingTimeInterval(1))

    let replaced = try #require(store.loadCurrent().snapshot?.snapshot.limits)
    let openAILimit = try #require(replaced.first { $0.provider == .openAI && $0.accountID == "openai-a" })
    #expect(openAILimit.used == 80)
    #expect(replaced.filter { $0.provider == .openAI && $0.accountID == "openai-a" }.count == 1)
    #expect(replaced.map(\.provider).contains(.google))
    #expect(replaced.map(\.provider).contains(.anthropic))
}

@Test func jsonSnapshotStoreReportsMissingCurrentAsUnknown() throws {
    let store = JSONSnapshotStore(rootDirectory: try temporaryDirectory())

    let result = store.loadCurrent()

    #expect(result.snapshot == nil)
    #expect(result.status == .unknown)
}

@Test func jsonSnapshotStoreReportsCorruptCurrentAsFailureWithoutThrowing() throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: root.appending(path: "current-snapshot.json"))

    let result = JSONSnapshotStore(rootDirectory: root).loadCurrent()

    #expect(result.snapshot == nil)
    #expect(result.status == .failure)
    #expect(result.errorMessage?.isEmpty == false)
}

@Test func jsonSnapshotStoreAppliesStalenessPolicy() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    try store.save(StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .google, accountID: "g", used: 20, savedAt: savedAt)]
    )))

    let fresh = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: Date(timeIntervalSince1970: 120))
    let stale = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: Date(timeIntervalSince1970: 200))

    #expect(fresh.status == .healthy)
    #expect(stale.status == .stale)
}

@Test func jsonSnapshotStoreRejectsUnsupportedSchema() throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let current = root.appending(path: "current-snapshot.json")
    let json = #"""
    {
      "schemaVersion": 99,
      "savedAt": "1970-01-01T00:00:00Z",
      "snapshot": { "generatedAt": "1970-01-01T00:00:00Z", "limits": [] },
      "reports": []
    }
    """#
    try Data(json.utf8).write(to: current)

    let result = JSONSnapshotStore(rootDirectory: root).loadCurrent()

    #expect(result.status == .failure)
    #expect(result.errorMessage?.contains("Unsupported snapshot schema") == true)
}

@Test func storedProviderReportRedactsErrorMessages() {
    let report = ProviderConnectorReport(
        provider: .openAI,
        accountID: "local",
        accountName: "OpenAI",
        generatedAt: Date(timeIntervalSince1970: 0),
        limits: [],
        status: .failure,
        errorMessage: "failed for user@example.com with bearer sk-secret"
    )

    let stored = StoredProviderReport(report: report)

    #expect(stored.errorMessage?.contains("user@example.com") == false)
    #expect(stored.errorMessage?.contains("sk-secret") == false)
}

private func usageLimit(provider: Provider, accountID: String, used: Int, savedAt: Date) -> UsageLimit {
    UsageLimit(
        provider: provider,
        accountID: accountID,
        accountName: accountID,
        label: "usage",
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: savedAt.addingTimeInterval(3_600),
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
