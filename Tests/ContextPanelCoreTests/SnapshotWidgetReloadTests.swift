import Foundation
import Testing
@testable import ContextPanelCore

@Test(arguments: [false, true])
func snapshotWidgetReloadOnlyForChangedWrites(asyncSave: Bool) async throws {
    let root = try widgetReloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = JSONSnapshotStore(rootDirectory: root.appending(path: "primary"))
    let mirror = JSONSnapshotStore(rootDirectory: root.appending(path: "widget"))
    let reloads = WidgetReloadRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")),
        stores: SnapshotRefreshStores(primary: primary, mirrors: [mirror]),
        snapshotDidChange: {
            #expect(primary.loadCurrent().snapshot == mirror.loadCurrent().snapshot)
            reloads.record()
        },
        promptCacheTelemetryReader: { _ in [] }
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000.25)
    for (index, used) in [32, 32, 0].enumerated() {
        let refresh = widgetReloadResult(now: now, used: used, resetCount: 0)
        if asyncSave {
            _ = try await service.saveMergedAsync(refreshResult: refresh, savedAt: now)
        } else {
            _ = try service.saveMerged(refreshResult: refresh, savedAt: now)
        }
        #expect(reloads.count == (index == 2 ? 2 : 1))
    }
    // A new observation refreshes freshness even when quota is unchanged.
    let later = now.addingTimeInterval(60)
    let refresh = widgetReloadResult(now: later, used: 0, resetCount: 0)
    if asyncSave {
        _ = try await service.saveMergedAsync(refreshResult: refresh, savedAt: later)
    } else {
        _ = try service.saveMerged(refreshResult: refresh, savedAt: later)
    }
    #expect(reloads.count == 3)
}

@Test func snapshotWidgetReloadForcedRefreshPrecedesCompanionSyncAndClearsAppliedReset() async throws {
    let root = try widgetReloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let primary = JSONSnapshotStore(rootDirectory: root.appending(path: "primary"))
    let mirror = JSONSnapshotStore(rootDirectory: root.appending(path: "widget"))
    let previous = StoredUsageSnapshot(savedAt: now, refreshResult: widgetReloadResult(now: now, used: 32, resetCount: 1))
    try primary.save(previous)
    try mirror.save(previous)
    #expect(WidgetSnapshot.fromStore(mirror.loadCurrent(), now: now).resetCreditSurfaceSummary(now: now) != nil)
    let reloads = WidgetReloadRecorder()
    let publisher = CompanionSyncPublisher(
        stores: CompanionSyncStoreSet(stores: []),
        remoteStore: CompanionRemoteSyncStore(
            saveDocument: { _ in
                #expect(reloads.count == 1)
                return CompanionRemoteSyncOutcome(succeeded: false)
            },
            loadDocument: { _ in
                CompanionRemoteSyncLoadResult(result: CompanionSyncLoadResult(document: nil, status: .unknown),
                    outcome: CompanionRemoteSyncOutcome(succeeded: false))
            },
            resolveUserScope: {
                return nil
            }
        ),
        widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "display.json")),
        fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json"))
    )
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")),
        stores: SnapshotRefreshStores(primary: primary, mirrors: [mirror]),
        companionSyncPublisher: publisher,
        connectorFactory: { _ in [WidgetReloadConnector()] },
        promptCacheTelemetryMirror: { _, _ in },
        snapshotDidChange: {
            let widget = WidgetSnapshot.fromStore(mirror.loadCurrent(), now: now)
            #expect(widget.limits.first?.remaining == 100)
            #expect(widget.resetCreditSurfaceSummary(now: now) == nil)
            #expect(primary.loadCurrent().snapshot == mirror.loadCurrent().snapshot)
            reloads.record()
        },
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(service: service, resetExpiryRefreshStore: nil, lock: nil)
    // Force refresh despite the existing snapshot being fresh.
    let decision = try await runner.refresh(now: now)
    #expect(decision.diagnosticsDecision == .refreshed)
    #expect(reloads.count == 1)
    _ = try await runner.refresh(now: now)
    #expect(reloads.count == 1)
}

@Test func snapshotWidgetReloadNoPayloadDoesNotReload() async throws {
    let root = try widgetReloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let reloads = WidgetReloadRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")),
        stores: SnapshotRefreshStores(primary: JSONSnapshotStore(rootDirectory: root)),
        connectorFactory: { _ in [] },
        promptCacheTelemetryMirror: { _, _ in },
        snapshotDidChange: { reloads.record() },
        promptCacheTelemetryReader: { _ in [] }
    )
    let outcome = try await service.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(!outcome.didSaveSnapshot)
    #expect(reloads.count == 0)
}

private struct WidgetReloadConnector: ProviderConnector {
    let provider = Provider.openAI
    func refresh(now: Date) async -> ConnectorRefreshResult {
        widgetReloadResult(now: now, used: 0, resetCount: 0)
    }
}

private func widgetReloadResult(now: Date, used: Int, resetCount: Int) -> ConnectorRefreshResult {
    ConnectorRefreshResult(generatedAt: now, reports: [ProviderConnectorReport(
        provider: .openAI, accountID: "test-account", accountName: "Test", generatedAt: now,
        limits: [UsageLimit(provider: .openAI, accountID: "test-account", accountName: "Test", label: "Weekly",
            windowLabel: "Weekly", unit: .percent, used: used, limit: 100, resetsAt: now.addingTimeInterval(86_400))],
        resetCredits: ProviderResetCreditSummary(availableCount: resetCount, observedAt: now, coverage: .complete,
            knownExpiries: resetCount == 0 ? [] : [now.addingTimeInterval(60)])
    )])
}

private func widgetReloadTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "widget-reload-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class WidgetReloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reloadCount = 0
    var count: Int { lock.withLock { reloadCount } }
    func record() { lock.withLock { reloadCount += 1 } }
}
