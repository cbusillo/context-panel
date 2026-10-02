import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelWidget

private let integrationNow = Date(timeIntervalSince1970: 1_900_000_000)
private let integrationKey = ProviderAccountIdentityKey.generate()
private let integrationScope = CompanionCloudKitUserScope.derive(containerIdentifier: "test-container", userRecordName: "test-user")

private func integrationFixture(setupID: String, providerID: String, used: Int, at: Date = integrationNow,
    keyAvailable: Bool = true) -> (StoredUsageSnapshot, LocalProviderAccountConfiguration, SharedProviderAccountIdentity) {
    let material = ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID,
        identifier: providerID, scope: "seat:seat-one")!
    let raw = material.localHistoryID(configurationID: setupID)
    let identity = integrationKey.identity(for: material).bound(toUserScope: integrationScope).bound(toLocalAccountID: raw)
    let limit = UsageLimit(provider: .openAI, accountID: raw, configuredAccountID: setupID, accountName: "Typed @ name",
        label: "Weekly", unit: .percent, used: used, limit: 100, resetsAt: at.addingTimeInterval(3600), lastUpdatedAt: at)
    let report = StoredProviderReport(provider: .openAI, accountID: raw, configuredAccountID: setupID,
        accountName: "Typed @ name", generatedAt: at, status: .healthy, errorMessage: nil,
        legacyAccountID: "old-local-" + setupID, sharedAccountIdentity: keyAvailable ? identity : nil)
    return (StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: [limit]), reports: [report]),
        LocalProviderAccountConfiguration(id: setupID, provider: .openAI, connectorKind: .codexRateLimits, displayName: "Typed @ name", authPath: "/fake/auth.json"), identity)
}

private func integrationDocument(_ fixture: (StoredUsageSnapshot, LocalProviderAccountConfiguration, SharedProviderAccountIdentity), publisher: String) -> CompanionSyncDocument {
    CompanionSyncDocument(storedSnapshot: fixture.0, publishedAt: fixture.0.savedAt, cloudKitUserScope: integrationScope,
        accountDisplayMetadata: AccountDisplayMetadata.companion(configuration: [fixture.1], stored: fixture.0,
            now: fixture.0.savedAt, publisherID: publisher),
        accountIdentityAliases: CompanionAccountIdentityAlias.verifiedAliases(stored: fixture.0,
            configuration: [fixture.1], publisherID: publisher))
}

@Test func nativeHistoryMembershipAndSharedProviderPrimaryKeyHaveSeparateLifetimes() {
    let a = integrationFixture(setupID: "mac-a", providerID: "account-one", used: 10)
    let b = integrationFixture(setupID: "mac-b", providerID: "account-one", used: 20)
    #expect(a.0.reports.first?.accountID != b.0.reports.first?.accountID)
    #expect(a.2.accountID == b.2.accountID)
    let unavailable = integrationFixture(setupID: "mac-a", providerID: "account-one", used: 30, keyAvailable: false)
    #expect(a.0.reports.first?.accountID == unavailable.0.reports.first?.accountID)
    let changedLogin = integrationFixture(setupID: "mac-a", providerID: "account-two", used: 30)
    #expect(a.0.reports.first?.accountID != changedLogin.0.reports.first?.accountID)
}

@Test func twoMacsSelectOneWholeAccountObservationAndCopiedSetupKeepsDifferentLogin() throws {
    let a = integrationFixture(setupID: "mac-a", providerID: "account-one", used: 10, at: integrationNow.addingTimeInterval(-30))
    let b = integrationFixture(setupID: "mac-b", providerID: "account-one", used: 20)
    let merged = integrationDocument(b, publisher: "host-b").mergingForRemotePublish(existing: integrationDocument(a, publisher: "host-a"), now: integrationNow)
    #expect(merged.snapshot.limits.count == 1)
    #expect(merged.snapshot.limits.first?.used == 20)
    #expect(merged.snapshot.limits.first?.companionAccountID == a.2.accountID)
    let other = integrationFixture(setupID: "mac-b", providerID: "different-login", used: 40)
    #expect(integrationDocument(other, publisher: "host-c").mergingForRemotePublish(existing: merged, now: integrationNow).snapshot.limits.count == 2)
    let payload = String(decoding: try CompanionSyncPayloadCodec.encode(merged), as: UTF8.self)
    #expect(!payload.contains("account-one"))
    #expect(!payload.contains("-history-"))
}

@Test func scopedStrongAliasMaintainsOneLaneOnTemporaryKeyFailureWithoutReattributingLegacyQuota() {
    let known = integrationFixture(setupID: "mac-a", providerID: "account-one", used: 10, at: integrationNow.addingTimeInterval(-30))
    let missing = integrationFixture(setupID: "mac-a", providerID: "account-one", used: 25, keyAvailable: false)
    let merged = integrationDocument(missing, publisher: "host-a").mergingForRemotePublish(existing: integrationDocument(known, publisher: "host-a"), now: integrationNow)
    #expect(merged.snapshot.limits.count == 1)
    #expect(merged.snapshot.limits.first?.used == 25)
    #expect(merged.snapshot.limits.first?.companionAccountID == known.2.accountID)
    #expect(merged.snapshot.providerStatuses.first?.accountIdentityStatus == .verified)
}

@Test func explicitRestoreWinsOlderRemovalButNotANewerRemoval() {
    let fixture = integrationFixture(setupID: "setup", providerID: "account-one", used: 10)
    let key = AccountDisplayMetadata.safeID(.openAI, fixture.2.accountID)
    let document = integrationDocument(fixture, publisher: "host")
    func intent(removed: Date, restored: Date?) -> CompanionSyncDocument {
        CompanionSyncDocument(snapshot: document.snapshot, cloudKitUserScope: integrationScope,
            removedDisplayIDs: [key], accountRemovalDates: [key: removed],
            accountRestorationDates: restored.map { [key: $0] })
    }
    #expect(intent(removed: integrationNow, restored: nil).applyingGlobalRemovals().snapshot.limits.isEmpty)
    #expect(intent(removed: integrationNow, restored: integrationNow.addingTimeInterval(1)).applyingGlobalRemovals().snapshot.limits.count == 1)
    #expect(intent(removed: integrationNow.addingTimeInterval(2), restored: integrationNow.addingTimeInterval(1)).applyingGlobalRemovals().snapshot.limits.isEmpty)
}

@Test func macSharedCacheAndAgentReadRemoteOnlyAccountWithoutCredentialsOrLocalSnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = integrationFixture(setupID: "remote-setup", providerID: "account-one", used: 30)
    let cache = MacSharedAccountCache(cacheURL: root.appending(path: MacSharedAccountCache.filename))
    let document = integrationDocument(fixture, publisher: "remote-host")
    try cache.save(document, verifiedScope: integrationScope, checkedAt: integrationNow)
    #expect(cache.load(now: integrationNow) != nil)
    #expect(cache.load(now: integrationNow.addingTimeInterval(cache.verifiedScopeLeaseSeconds + 1)) == nil)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [])).write(to: root.appending(path: "accounts.json"))
    let agent = try AgentAccountSnapshot.read(rootDirectory: root, now: integrationNow)
    #expect(agent.accounts.count == 1)
    #expect(agent.accounts.first?.sharedAccountIdentity?.accountID == fixture.2.accountID)
    #expect(agent.accounts.first?.windows.first?.used == 30)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Snapshots/current-snapshot.json").path))
}

@Test func privateProfileBindingRejectsChangedCredentialAndPreservesSameCredentialMaterial() throws {
    let keychain = InMemoryProviderCredentialStore(storage: [:])
    let store = ProviderAccountIdentityMaterialStore(store: keychain)
    let account = UUID(); let organization = UUID()
    let payload = try JSONSerialization.data(withJSONObject: ["account": ["uuid": account.uuidString], "organization": ["uuid": organization.uuidString]])
    let material = try #require(ClaudeOAuthAccountIdentityParser.material(from: payload))
    store.save(material, configurationID: "setup", credential: "fake-access-one")
    let cached = try #require(store.load(provider: .anthropic, configurationID: "setup", credential: "fake-access-one"))
    #expect(integrationKey.identity(for: cached) == integrationKey.identity(for: material))
    #expect(store.load(provider: .anthropic, configurationID: "setup", credential: "fake-access-two") == nil)
    #expect(store.load(provider: .anthropic, configurationID: "copied-setup", credential: "fake-access-one") == nil)
    #expect(ClaudeOAuthAccountIdentityParser.material(from: Data("{\"account\":{\"uuid\":\"\(account.uuidString)\"}}".utf8)) == nil)
}

@Test func foreignScopeDoesNotSupplyIdentityContinuityOrRemoteAccountPresentation() {
    let fixture = integrationFixture(setupID: "setup", providerID: "account-one", used: 10)
    let different = CompanionCloudKitUserScope.derive(containerIdentifier: "test-container", userRecordName: "other-user")
    let document = integrationDocument(fixture, publisher: "host").bound(to: different)
    #expect(document.verifiedAccountsOnly().snapshot.limits.isEmpty)
    let view = MacSharedAccountPresentation.make(stored: fixture.0, configuration: [fixture.1], remote: document, now: integrationNow)
    #expect(view.limits.isEmpty)
}

@Test func removingVerifiedCopiedSetupTargetsProviderAccountNotSetupConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = integrationFixture(setupID: "copied", providerID: "account-one", used: 10)
    let b = integrationFixture(setupID: "copied", providerID: "account-two", used: 20)
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try store.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [a.1], publisherID: "host"))
    let removed = try #require(try await store.removeAccount(id: a.1.id,
        lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")), now: integrationNow,
        storedSnapshot: a.0, userScope: integrationScope))
    #expect(!(removed.removedDisplayIDs ?? []).contains(AccountDisplayMetadata.companionConfigurationID(a.1, publisherID: "host")))
    let all = integrationDocument(b, publisher: "other-host").mergingForRemotePublish(existing: integrationDocument(a, publisher: "host"), now: integrationNow)
    let filtered = CompanionSyncDocument(snapshot: all.snapshot, cloudKitUserScope: integrationScope,
        accountDisplayMetadata: all.accountDisplayMetadata, removedDisplayIDs: removed.removedDisplayIDs,
        accountRemovalDates: removed.removedDisplayDates).applyingGlobalRemovals()
    #expect(filtered.snapshot.limits.count == 1)
    #expect(filtered.snapshot.limits.first?.companionAccountID == b.2.accountID)
}

@Test func removalOfOneVerifiedLanePreservesTheOtherLaneInOneSetup() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = integrationFixture(setupID: "combined", providerID: "account-one", used: 10)
    let b = integrationFixture(setupID: "combined", providerID: "account-two", used: 20)
    let stored = StoredUsageSnapshot(savedAt: integrationNow, snapshot: UsageSnapshot(generatedAt: integrationNow,
        limits: a.0.snapshot.limits + b.0.snapshot.limits), reports: a.0.reports + b.0.reports)
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try store.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [a.1], publisherID: "host"))
    let removed = AccountDisplayMetadata.safeID(.openAI, a.2.accountID)
    try store.applyGlobalRemovals([removed], storedSnapshot: stored, now: integrationNow, userScope: integrationScope)
    #expect(store.load(now: integrationNow).document.accounts == [a.1])
    let document = CompanionSyncDocument(storedSnapshot: stored, cloudKitUserScope: integrationScope,
        removedDisplayIDs: [removed]).applyingGlobalRemovals()
    #expect(document.snapshot.limits.count == 1)
    #expect(document.snapshot.limits.first?.companionAccountID == b.2.accountID)
}

@Test func authenticatedReAddSurvivesFailedRemoteSaveAndLaterOldRemovalRead() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = integrationFixture(setupID: "readded", providerID: "account-one", used: 10)
    var setup = fixture.1; setup.restorationRequestedAt = integrationNow.addingTimeInterval(-10)
    let removed = AccountDisplayMetadata.safeID(.openAI, fixture.2.accountID)
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try store.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [setup], removedDisplayIDs: [removed],
        removalUserScope: integrationScope, removedDisplayDates: [removed: integrationNow.addingTimeInterval(-30)]))
    let oldRemote = CompanionSyncDocument(snapshot: integrationDocument(fixture, publisher: "host").snapshot,
        cloudKitUserScope: integrationScope, removedDisplayIDs: [removed], accountRemovalDates: [removed: integrationNow.addingTimeInterval(-30)])
    try store.receiveSharedAccountIntents(oldRemote, scope: integrationScope, now: integrationNow)
    try store.applyGlobalRemovals([removed], storedSnapshot: fixture.0, now: integrationNow, userScope: integrationScope)
    #expect(store.load(now: integrationNow).document.accounts.count == 1)
    #expect(store.load(now: integrationNow).document.restoredDisplayDates?[removed] == setup.restorationRequestedAt)
    // The failed save left the old remote tombstone; repeat it without any provider payload.
    try store.receiveSharedAccountIntents(oldRemote, scope: integrationScope, now: integrationNow.addingTimeInterval(1))
    try store.applyGlobalRemovals([removed], storedSnapshot: nil, now: integrationNow.addingTimeInterval(1), userScope: integrationScope)
    #expect(store.load(now: integrationNow).document.accounts.count == 1)
    let newer = CompanionSyncDocument(snapshot: oldRemote.snapshot, cloudKitUserScope: integrationScope,
        removedDisplayIDs: [removed], accountRemovalDates: [removed: integrationNow.addingTimeInterval(2)])
    try store.receiveSharedAccountIntents(newer, scope: integrationScope, now: integrationNow.addingTimeInterval(2))
    try store.applyGlobalRemovals([removed], storedSnapshot: fixture.0, now: integrationNow.addingTimeInterval(2), userScope: integrationScope)
    #expect(store.load(now: integrationNow).document.accounts.isEmpty)
}

@Test func sharedAccountCacheLeaseAccommodatesSupportedLongRefreshIntervals() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = integrationFixture(setupID: "setup", providerID: "account-one", used: 10)
    let cache = MacSharedAccountCache(cacheURL: root.appending(path: MacSharedAccountCache.filename))
    try cache.save(integrationDocument(fixture, publisher: "host"), verifiedScope: integrationScope, checkedAt: integrationNow)
    try BackgroundRefreshSettingsStore(settingsURL: root.appending(path: "background-refresh-settings.json")).save(BackgroundRefreshSettings(intervalMinutes: 60))
    #expect(cache.load(now: integrationNow.addingTimeInterval(60 * 60 + 60)) != nil)
    #expect(cache.load(now: integrationNow.addingTimeInterval(71 * 60)) == nil)
    cache.invalidate()
    #expect(cache.load(now: integrationNow) == nil)
}

@Test func futureWidgetEntriesKeepTheCurrentlyScopeQualifiedRemoteAccount() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = integrationFixture(setupID: "remote", providerID: "account-one", used: 10)
    try MacSharedAccountCache(cacheURL: root.appending(path: MacSharedAccountCache.filename)).save(
        integrationDocument(fixture, publisher: "remote-host"), verifiedScope: integrationScope, checkedAt: integrationNow)
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: []))
    let provider = ContextPanelTimelineProvider(store: JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots")),
        containerFallbackStore: JSONSnapshotStore(rootDirectory: root.appending(path: "fallback")),
        preferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "preferences.json")),
        containerFallbackPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "fallback-preferences.json")),
        forecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json")),
        containerFallbackForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "fallback-forecast.json")),
        accountStore: accountStore, bookmarkStore: SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json")))
    let entries = provider.timelineEntries(date: integrationNow)
    #expect(entries.count > 1)
    #expect(entries.allSatisfy { $0.snapshot.limits.count == 1 })
    #expect(entries.last?.snapshot.status == .stale)
}

@Test func failedAuthenticationCannotPublishAnExplicitRestore() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = integrationFixture(setupID: "setup", providerID: "account-one", used: 10)
    var setup = fixture.1; setup.restorationRequestedAt = integrationNow
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [setup]))
    let failure = StoredUsageSnapshot(savedAt: integrationNow, snapshot: UsageSnapshot(generatedAt: integrationNow, limits: []),
        reports: [StoredProviderReport(provider: .openAI, accountID: fixture.0.reports[0].accountID,
            configuredAccountID: setup.id, accountName: "Account", generatedAt: integrationNow, status: .failure,
            errorMessage: "Login failed", sharedAccountIdentity: fixture.2)])
    let syncStore = CompanionSyncStore(documentURL: root.appending(path: "companion.json"))
    let publisher = CompanionSyncPublisher(stores: CompanionSyncStoreSet(stores: [syncStore]),
        widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "preferences.json")),
        fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json")),
        accountConfigurationURL: accountStore.configurationURL)
    #expect(publisher.publish(storedSnapshot: failure, publishedAt: integrationNow).succeeded)
    let published = try #require(syncStore.load(policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge), now: integrationNow).document)
    #expect(published.accountRestorationDates?.isEmpty ?? true)
}

private actor IntegrationReadConnector: ProviderConnector {
    nonisolated let provider = Provider.openAI
    let reports: [ProviderConnectorReport]
    var reads = 0
    init(reports: [ProviderConnectorReport]) { self.reports = reports }
    func refresh(now: Date) async -> ConnectorRefreshResult {
        reads += 1
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }
}

@Test func removalBeforeFirstStoredReadDeletesSetupAndStopsSubsequentProviderPolling() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = integrationFixture(setupID: "new-setup", providerID: "account-one", used: 10)
    let removed = AccountDisplayMetadata.safeID(.openAI, fixture.2.accountID)
    var setup = fixture.1; setup.restorationRequestedAt = integrationNow.addingTimeInterval(-30)
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [setup], removedDisplayIDs: [removed],
        removalUserScope: integrationScope, removedDisplayDates: [removed: integrationNow.addingTimeInterval(-10)]))
    let connector = IntegrationReadConnector(reports: [ProviderConnectorReport(provider: .openAI,
        accountID: fixture.0.reports[0].accountID, configuredAccountID: setup.id, accountName: "Account", generatedAt: integrationNow,
        limits: fixture.0.snapshot.limits, sharedAccountIdentity: fixture.2)])
    let snapshotStore = JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots"))
    let service = SnapshotRefreshService(accountStore: accountStore, stores: SnapshotRefreshStores(primary: snapshotStore),
        credentialStore: InMemoryProviderCredentialStore(storage: [:]), connectorFactory: { config in config.accounts.isEmpty ? [] : [connector] },
        promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] })
    _ = try await service.refresh(now: integrationNow)
    #expect(accountStore.load(now: integrationNow).document.accounts.isEmpty)
    _ = try await service.refresh(now: integrationNow.addingTimeInterval(300))
    #expect(await connector.reads == 1)
    #expect(snapshotStore.loadCurrent().snapshot?.snapshot.limits.isEmpty ?? true)
}

@Test func setupLevelFailureCannotPreserveOrRepublishRemovedSiblingQuota() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = integrationFixture(setupID: "combined", providerID: "account-one", used: 10)
    let b = integrationFixture(setupID: "combined", providerID: "account-two", used: 20)
    let removed = AccountDisplayMetadata.safeID(.openAI, a.2.accountID)
    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: integrationNow, accounts: [a.1], removedDisplayIDs: [removed], removalUserScope: integrationScope))
    let snapshotStore = JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots"))
    try snapshotStore.save(StoredUsageSnapshot(savedAt: integrationNow, snapshot: UsageSnapshot(generatedAt: integrationNow,
        limits: a.0.snapshot.limits + b.0.snapshot.limits), reports: a.0.reports + b.0.reports))
    let connector = IntegrationReadConnector(reports: [ProviderConnectorReport(provider: .openAI,
        accountID: "setup-failure", configuredAccountID: a.1.id, accountName: "Account", generatedAt: integrationNow,
        limits: [], status: .failure, errorMessage: "Auth file unavailable")])
    let service = SnapshotRefreshService(accountStore: accountStore, stores: SnapshotRefreshStores(primary: snapshotStore),
        credentialStore: InMemoryProviderCredentialStore(storage: [:]), connectorFactory: { _ in [connector] },
        promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] })
    _ = try await service.refresh(now: integrationNow.addingTimeInterval(300))
    let saved = try #require(snapshotStore.loadCurrent().snapshot)
    #expect(saved.snapshot.limits.count == 1)
    #expect(saved.snapshot.limits.first?.accountID == b.0.reports[0].accountID)
    #expect(accountStore.load(now: integrationNow).document.accounts.count == 1)
    #expect(CompanionSnapshot(storedSnapshot: saved).limits.count == 1)
}

@Test func agentAndWidgetHonorImmediateLocalRemovalBeforeCloudRoundTripOrRefresh() {
    let fixture = integrationFixture(setupID: "setup", providerID: "account-one", used: 10)
    let removed = AccountDisplayMetadata.safeID(.openAI, fixture.2.accountID)
    let configuration = AccountConfigurationDocument(updatedAt: integrationNow, accounts: [], removedDisplayIDs: [removed],
        removalUserScope: integrationScope, removedDisplayDates: [removed: integrationNow])
    let cached = integrationDocument(fixture, publisher: "host")
    let agent = AgentAccountSnapshot(configuration: configuration, stored: fixture.0, history: [], now: integrationNow, sharedDocument: cached)
    #expect(agent.accounts.isEmpty)
    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: fixture.0, status: .healthy), now: integrationNow,
        configuration: [], sharedDocument: cached, accountIntentDocument: configuration)
    #expect(widget.limits.isEmpty)
    let remoteOnly = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: nil, status: .unknown), now: integrationNow,
        configuration: [], sharedDocument: cached, accountIntentDocument: configuration)
    #expect(remoteOnly.limits.isEmpty)
}
