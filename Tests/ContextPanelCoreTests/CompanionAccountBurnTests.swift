import Foundation
import Testing
@testable import ContextPanelCore

private let burnNow = Date(timeIntervalSince1970: 1_800_000_000)
private func burnFixture(at date: Date, used: Int, rate: Double?, failed: Bool = false) -> CompanionSyncDocument {
    let setup = LocalProviderAccountConfiguration(id: "source-a", provider: .anthropic, connectorKind: .claudeOAuthUsage, displayName: "Synthetic account")
    let local = UsageLimit(provider: .anthropic, accountID: setup.id, configuredAccountID: setup.id, accountName: setup.displayName,
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: used, limit: 100,
        resetsAt: burnNow.addingTimeInterval(7 * 86400), lastUpdatedAt: date)
    let stored = StoredUsageSnapshot(savedAt: date, snapshot: UsageSnapshot(generatedAt: date, limits: failed ? [] : [local]),
        reports: [StoredProviderReport(provider: .anthropic, accountID: setup.id, configuredAccountID: setup.id,
            accountName: setup.displayName, generatedAt: date, status: failed ? .failure : .healthy, errorMessage: nil)])
    let snapshot = CompanionSnapshot(storedSnapshot: stored, publishedAt: date)
    let transported = CompanionLimit(limit: local)
    let id = transported.usageLimit.id
    let rates = rate.map { [transported.companionAccountID: [id: ObservedBurnRate(limitID: id, unitsPerHour: $0, observedDurationHours: 2, sampleCount: 3)]] }
    return CompanionSyncDocument(snapshot: snapshot, accountDisplayMetadata: AccountDisplayMetadata.companion(configuration: [setup], stored: stored, now: date), accountBurnRates: rates)
}

@Test func companionBurnFollowsTheRetainedAccountObservationAndDoesNotBorrowOlderPace() throws {
    let old = burnFixture(at: burnNow, used: 20, rate: 2)
    let failed = burnFixture(at: burnNow.addingTimeInterval(60), used: 20, rate: 99, failed: true)
    let retained = failed.mergingForRemotePublish(existing: old, now: burnNow.addingTimeInterval(60))
    #expect(retained.accountBurnRates == old.accountBurnRates)
    let fresh = burnFixture(at: burnNow.addingTimeInterval(120), used: 30, rate: 4)
    let updated = fresh.mergingForRemotePublish(existing: retained, now: burnNow.addingTimeInterval(120))
    #expect(updated.accountBurnRates == fresh.accountBurnRates)
    let noHistory = burnFixture(at: burnNow.addingTimeInterval(180), used: 35, rate: nil)
    let unknownPace = noHistory.mergingForRemotePublish(existing: updated, now: burnNow.addingTimeInterval(180))
    #expect(unknownPace.accountBurnRates?.isEmpty == true)
    let widget = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: updated, status: .healthy), now: burnNow.addingTimeInterval(120))
    let window = try #require(widget.accountOverview(now: burnNow.addingTimeInterval(120)).accounts.first?.windows.first)
    #expect(window.burnFractionPerHour == 0.04)
    #expect(try CompanionSyncPayloadCodec.decode(CompanionSyncPayloadCodec.encode(updated)).accountBurnRates == updated.accountBurnRates)
}

@Test func globalRemovalPrunesAccountBurnWithoutChangingOtherFields() throws {
    let original = burnFixture(at: burnNow, used: 20, rate: 2)
    let account = try #require(original.accountDisplayMetadata?.first)
    let deleted = CompanionSyncDocument(snapshot: original.snapshot, accountDisplayMetadata: original.accountDisplayMetadata,
        removedDisplayIDs: [account.id], accountBurnRates: original.accountBurnRates).applyingGlobalRemovals()
    #expect(deleted.snapshot.limits.isEmpty)
    #expect(deleted.accountBurnRates?.isEmpty == true)
    let legacy = burnFixture(at: burnNow, used: 20, rate: nil)
    #expect(try CompanionSyncPayloadCodec.decode(CompanionSyncPayloadCodec.encode(legacy)).accountBurnRates == nil)
}

@Test func publisherMapsAccountAndWindowBurnKeysToTheSameSanitizedTransportIdentities() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let setup = try #require(AccountConfigurationStore.defaultDocument(now: burnNow).accounts.first { $0.provider == .google })
    let config = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try config.save(AccountConfigurationDocument(updatedAt: burnNow, accounts: [setup], publisherID: "synthetic-publisher"))
    let local = UsageLimit(provider: .google, accountID: ConnectorRedactor.localAccountID(provider: .google, stableID: setup.id),
        configuredAccountID: setup.id, accountName: "Synthetic account", label: "Weekly", windowLabel: "Weekly", unit: .percent,
        used: 20, limit: 100, resetsAt: burnNow.addingTimeInterval(7 * 86400), lastUpdatedAt: burnNow)
    let stored = StoredUsageSnapshot(savedAt: burnNow, snapshot: UsageSnapshot(generatedAt: burnNow, limits: [local]), reports: [])
    let sync = CompanionSyncStore(documentURL: root.appending(path: "sync.json"))
    let publisher = CompanionSyncPublisher(stores: CompanionSyncStoreSet(stores: [sync]),
        widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "widget.json")),
        fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json")), accountConfigurationURL: config.configurationURL)
    let rate = ObservedBurnRate(limitID: local.id, unitsPerHour: 3, observedDurationHours: 2, sampleCount: 3)
    #expect(publisher.publish(storedSnapshot: stored, publishedAt: burnNow, accountBurnRates: [local.accountID: [local.id: rate]]).succeeded)
    let document = try #require(sync.load(policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge), now: burnNow).document)
    let transported = try #require(document.snapshot.limits.first)
    let estimate = try #require(document.accountBurnRates?[transported.companionAccountID]?[transported.usageLimit.id])
    #expect(estimate.limitID == transported.usageLimit.id)
    #expect(estimate.unitsPerHour == rate.unitsPerHour)
    #expect(estimate.sampleCount == rate.sampleCount)
    #expect(document.accountDisplayMetadata?.first?.id == AccountDisplayMetadata.safeID(.google, transported.companionAccountID))
}

@Test func republishingTheSameObservationWithoutRatesKeepsItsObservedCompanionPace() {
    let measured = burnFixture(at: burnNow, used: 20, rate: 2)
    let setupOnly = burnFixture(at: burnNow, used: 20, rate: nil)
    let retained = setupOnly.mergingForRemotePublish(existing: measured, now: burnNow)
    #expect(retained.accountBurnRates == measured.accountBurnRates)
}
