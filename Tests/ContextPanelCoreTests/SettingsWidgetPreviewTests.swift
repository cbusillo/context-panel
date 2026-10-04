import Foundation
import Testing
@testable import ContextPanelCore

@Test func settingsWidgetPreviewUsesSavedWidgetContractWithoutCollectingOrWriting() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = JSONSnapshotStore(rootDirectory: root.appending(path: "snapshots"))
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let configurations = [
        LocalProviderAccountConfiguration(id: "last", provider: .anthropic, connectorKind: .claudeOAuthUsage,
            displayName: "Use last", useLast: true),
        LocalProviderAccountConfiguration(id: "next", provider: .anthropic, connectorKind: .claudeOAuthUsage,
            displayName: "Use next"),
        LocalProviderAccountConfiguration(id: "hidden", provider: .anthropic, connectorKind: .claudeOAuthUsage,
            displayName: "Hidden", showInWidgets: false),
    ]
    let document = AccountConfigurationDocument(updatedAt: now, accounts: configurations)
    try accountStore.save(document)
    let limits = configurations.enumerated().map { index, account in
        UsageLimit(provider: account.provider, accountID: account.id, configuredAccountID: account.id,
            accountName: account.displayName, label: "Weekly", windowLabel: "Weekly", unit: .percent,
            used: index * 20, limit: 100, resetsAt: now.addingTimeInterval(86_400),
            lastUpdatedAt: now, confidence: .observed)
    }
    let reports = configurations.map { account in
        StoredProviderReport(provider: account.provider, accountID: account.id, configuredAccountID: account.id,
            accountName: account.displayName, generatedAt: now, status: .healthy, errorMessage: nil)
    }
    try store.save(StoredUsageSnapshot(savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: limits), reports: reports))
    let savedConfiguration = try Data(contentsOf: accountStore.configurationURL)
    let savedSnapshot = try Data(contentsOf: store.currentSnapshotURL)
    let service = SnapshotRefreshService(accountStore: accountStore, stores: SnapshotRefreshStores(primary: store),
        connectorFactory: { _ in Issue.record("Preview must never build provider connectors"); return [] },
        promptCacheTelemetryReader: { _ in Issue.record("Preview must not collect telemetry"); return [] })
    let policy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge)
    for date in [now, now.addingTimeInterval(SnapshotFreshness.widgetMaximumAge + 1)] {
        let preview = service.savedWidgetPreviewSnapshot(now: date, stalenessPolicy: policy)
        let widget = WidgetSnapshot.fromStore(store.loadCurrent(policy: policy, now: date), now: date,
            history: store.loadHistory(), stalenessPolicy: policy, configuration: configurations,
            publisherID: document.publisherID, accountIntentDocument: document)
        #expect(preview == widget)
        let overview = preview.accountOverview(now: date, widgetsOnly: true)
        #expect(overview.accounts.count == 2)
        #expect(overview.accounts.allSatisfy { $0.metadata.label != "Hidden" })
        if date == now {
            #expect(overview.useNext(provider: .anthropic)?.metadata.label == "Use next")
        } else {
            #expect(preview.state == .stale)
            #expect(overview.useNext(provider: .anthropic) == nil)
        }
    }
    #expect(try Data(contentsOf: accountStore.configurationURL) == savedConfiguration)
    #expect(try Data(contentsOf: store.currentSnapshotURL) == savedSnapshot)
}

@Test func settingsWidgetPreviewKeepsFirstRunAndSavedMirrorHonest() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = JSONSnapshotStore(rootDirectory: root.appending(path: "primary"))
    let mirror = JSONSnapshotStore(rootDirectory: root.appending(path: "mirror"))
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let service = SnapshotRefreshService(accountStore: accountStore,
        stores: SnapshotRefreshStores(primary: store, mirrors: [mirror]))
    let policy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge)
    #expect(service.savedWidgetPreviewSnapshot(now: now, stalenessPolicy: policy).state == .setupNeeded)
    #expect(!FileManager.default.fileExists(atPath: accountStore.configurationURL.path))
    let old = now.addingTimeInterval(-SnapshotFreshness.widgetMaximumAge - 1)
    let limit = UsageLimit(provider: .openAI, accountID: "saved", accountName: "Saved account",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 40, limit: 100,
        resetsAt: now.addingTimeInterval(86_400), lastUpdatedAt: old, confidence: .observed)
    try mirror.save(StoredUsageSnapshot(savedAt: old, snapshot: UsageSnapshot(generatedAt: old, limits: [limit])))
    let preview = service.savedWidgetPreviewSnapshot(now: now, stalenessPolicy: policy)
    #expect(preview.generatedAt == old)
    #expect(preview.state == .stale)
    #expect(preview.accountOverview(now: now).accounts.first?.isReliable == false)
    #expect(preview.limits.first?.used == limit.used)
}
