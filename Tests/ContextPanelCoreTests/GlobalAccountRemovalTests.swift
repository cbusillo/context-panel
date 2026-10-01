import Foundation
import Testing
@testable import ContextPanelCore

private let removalNow = Date(timeIntervalSince1970: 1_800_000_000)
private func removalFixture(_ id: String, observed: Bool) -> (LocalProviderAccountConfiguration, StoredUsageSnapshot, CompanionSyncDocument) {
    let account = LocalProviderAccountConfiguration(id: id, provider: .anthropic,
        connectorKind: .claudeOAuthUsage, displayName: "Typed \(id)@example.invalid")
    let limits: [UsageLimit] = observed ? [UsageLimit(provider: .anthropic, accountID: id, configuredAccountID: id,
        accountName: "Provider identity", label: "Weekly", unit: .percent, used: 25, limit: 100,
        resetsAt: removalNow.addingTimeInterval(3600), lastUpdatedAt: removalNow)] : []
    let stored = StoredUsageSnapshot(savedAt: removalNow, snapshot: UsageSnapshot(generatedAt: removalNow, limits: limits), reports: [])
    return (account, stored, CompanionSyncDocument(storedSnapshot: stored,
        publishedAt: removalNow, accountDisplayMetadata: AccountDisplayMetadata.companion(configuration: [account], stored: stored, now: removalNow)))
}

@Test func explicitGlobalRemovalCannotBeRevivedByOfflinePublisherAndAllowsNewMembership() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let (account, stored, offline) = removalFixture("old", observed: true)
    try store.save(AccountConfigurationDocument(updatedAt: removalNow, accounts: [account]))
    let removed = try #require(try await store.removeAccount(id: account.id,
        lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")), now: removalNow, storedSnapshot: stored))
    let deletion = CompanionSyncDocument(snapshot: CompanionSnapshot(generatedAt: removalNow, publishedAt: removalNow,
        limits: [], providerStatuses: [], promptCacheSummaries: []), accountDisplayMetadata: [], removedDisplayIDs: removed.globalRemovedDisplayIDs)
    let merged = deletion.mergingForRemotePublish(existing: offline, now: removalNow)
    #expect(merged.snapshot.limits.isEmpty)
    #expect(merged.accountDisplayMetadata?.isEmpty == true)
    #expect(offline.mergingForRemotePublish(existing: merged, now: removalNow).snapshot.limits.isEmpty)
    let (_, _, fresh) = removalFixture("new-membership", observed: true)
    let readded = fresh.mergingForRemotePublish(existing: merged, now: removalNow)
    #expect(readded.snapshot.limits.count == 1)
    #expect(readded.accountDisplayMetadata?.count == 1)
    #expect(readded.removedDisplayIDs == merged.removedDisplayIDs)
    let roundtrip = try CompanionSyncPayloadCodec.decode(CompanionSyncPayloadCodec.encode(readded))
    #expect(roundtrip.removedDisplayIDs == readded.removedDisplayIDs)
}

@Test func globalRemovalReachesMacSetupWithoutTouchingCredentialsAndPreservesOtherNoDataRows() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let (removedAccount, stored, first) = removalFixture("Mac-A", observed: false)
    let (keptAccount, _, second) = removalFixture("Mac-B", observed: false)
    let merged = second.mergingForRemotePublish(existing: first, now: removalNow)
    #expect(merged.accountDisplayMetadata?.count == 2)
    try store.save(AccountConfigurationDocument(updatedAt: removalNow, accounts: [removedAccount, keptAccount]))
    let credential = root.appending(path: "credential-sentinel")
    let sentinel = Data("private sentinel".utf8)
    try sentinel.write(to: credential)
    let ids = [AccountDisplayMetadata.safeID(.anthropic, removedAccount.id)]
    try store.applyGlobalRemovals(ids, storedSnapshot: stored, now: removalNow)
    let changed = store.load(now: removalNow).document
    #expect(changed.accounts == [keptAccount])
    #expect(try Data(contentsOf: credential) == sentinel)
    let deletion = CompanionSyncDocument(snapshot: merged.snapshot,
        accountDisplayMetadata: merged.accountDisplayMetadata, removedDisplayIDs: ids).applyingGlobalRemovals()
    #expect(deletion.accountDisplayMetadata?.map(\.label) == [keptAccount.displayName])
    #expect(changed.removedAccountIDs == [removedAccount.id])
}

@Test func globalRemovalsRequireSuccessfulSameUserRemoteDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let (account, stored, fixture) = removalFixture("active", observed: true)
    let original = AccountConfigurationDocument(updatedAt: removalNow, accounts: [account])
    let scope = try #require(CompanionCloudKitUserScope(rawValue: String(repeating: "a", count: 64)))
    let other = try #require(CompanionCloudKitUserScope(rawValue: String(repeating: "b", count: 64)))
    for (deliveredScope, succeeded, shouldRemove) in [(other, true, false), (scope, false, false), (scope, true, true)] {
        try store.save(original)
        let document = CompanionSyncDocument(snapshot: fixture.snapshot, cloudKitUserScope: deliveredScope,
            removedDisplayIDs: [AccountDisplayMetadata.safeID(.anthropic, account.id)])
        let remote = CompanionRemoteSyncStore(saveDocument: { _ in CompanionRemoteSyncOutcome(succeeded: true) },
            loadDocument: { _ in CompanionRemoteSyncLoadResult(result: CompanionSyncLoadResult(document: document, status: .healthy),
                outcome: CompanionRemoteSyncOutcome(succeeded: succeeded)) }, resolveUserScope: { scope })
        let publisher = CompanionSyncPublisher(stores: CompanionSyncStoreSet(stores: [CompanionSyncStore(documentURL: root.appending(path: "sync.json"))]), remoteStore: remote,
            widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "widget.json")),
            fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json")))
        try await publisher.receiveGlobalRemovals(accountStore: store, storedSnapshot: stored, now: removalNow)
        #expect(store.load(now: removalNow).document.accounts.isEmpty == shouldRemove)
    }
}
