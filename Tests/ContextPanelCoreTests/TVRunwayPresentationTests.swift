import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import Testing

@Test func tvRunwayPresentationPoolsAccountsByProviderWindow() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let presentation = TVRunwayPresentation(
        snapshot: makeTVSnapshot(now: now),
        mode: .fullDetail,
        now: now
    )

    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })
    let weekly = try #require(openAI.lanes.first { $0.title == "Weekly" })

    #expect(weekly.remainingPercent == 70)
    #expect(weekly.capacityRatio == 0.7)
    #expect(weekly.exactCapacityText == "140 of 200 points remaining")
    #expect(weekly.accountCountText == "2 accounts")
    #expect(weekly.accountNames == ["Personal", "Work"])
    #expect(weekly.metrics.count == 2)
}

@Test func tvRunwayPresentationModesRemoveSensitiveDetail() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = makeTVSnapshot(now: now)

    let projectOnly = TVRunwayPresentation(snapshot: snapshot, mode: .projectOnly, now: now)
    let projectLane = try #require(
        projectOnly.sections.first { $0.provider == .openAI }?.lanes.first { $0.title == "Weekly" }
    )
    #expect(projectLane.accountNames.isEmpty)
    #expect(projectLane.exactCapacityText == nil)
    #expect(projectLane.accountCountText == "2 accounts")
    #expect(projectLane.metrics.count == 1)
    #expect(projectLane.metrics.first?.exactCapacityText == nil)

    let countsOnly = TVRunwayPresentation(snapshot: snapshot, mode: .countsOnly, now: now)
    let countsLane = try #require(
        countsOnly.sections.first { $0.provider == .openAI }?.lanes.first { $0.title == "1w" }
    )
    #expect(countsLane.accountNames.isEmpty)
    #expect(countsLane.exactCapacityText == nil)
    #expect(countsLane.accountCountText == nil)
    #expect(countsLane.resetText == nil)
    #expect(countsLane.metrics.isEmpty)
}

@Test func tvRunwayPresentationKeepsStaleDataExplicit() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ready = makeTVSnapshot(now: now)
    let stale = WidgetSnapshot(
        state: .stale,
        generatedAt: ready.generatedAt,
        limits: ready.limits,
        reports: ready.reports,
        status: .stale,
        message: "Saved snapshot"
    )

    let presentation = TVRunwayPresentation(snapshot: stale, mode: .fullDetail, now: now)

    #expect(presentation.headline == "Showing saved runway")
    #expect(presentation.detail.contains("may no longer reflect current usage"))
    #expect(!presentation.sections.isEmpty)
}

@Test func tvRunwayPresentationSurfacesRefreshFailuresBesideCapacityLanes() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ready = makeTVSnapshot(now: now)
    let personalLimit = try #require(
        ready.limits.first { $0.provider == .openAI && $0.accountName == "Personal" }
    )
    let partial = WidgetSnapshot(
        state: .ready,
        generatedAt: ready.generatedAt,
        limits: ready.limits,
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: personalLimit.accountID,
                configuredAccountID: personalLimit.configuredAccountID,
                accountName: "Personal",
                generatedAt: now,
                status: .healthy,
                errorMessage: nil
            ),
            StoredProviderReport(
                provider: .openAI,
                accountID: "team",
                configuredAccountID: "team",
                accountName: "Team",
                generatedAt: now,
                status: .failure,
                errorMessage: "Reconnect required"
            ),
        ],
        status: .failure,
        message: "One account needs attention"
    )

    let presentation = TVRunwayPresentation(snapshot: partial, mode: .fullDetail, now: now)
    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })
    let statusLane = try #require(openAI.lanes.first { $0.kind == .accountStatus })

    #expect(openAI.status == .failure)
    #expect(openAI.trackedWindowCount == 1)
    #expect(openAI.trackedWindowText == "1 window tracked")
    #expect(openAI.lanes.filter { $0.kind == .accountStatus }.count == 1)
    #expect(statusLane.title == "Team status")
    #expect(statusLane.status == .failure)
    #expect(statusLane.detailText == "No fresh capacity data")
    #expect(statusLane.accountNames == ["Team"])
}

@Test func tvRunwayPresentationMakesRefreshStateExplicitWithoutDroppingSavedData() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let presentation = TVRunwayPresentation(
        snapshot: makeTVSnapshot(now: now),
        mode: .fullDetail,
        isRefreshing: true,
        now: now
    )

    #expect(presentation.status == .loading)
    #expect(presentation.headline == "Checking runway")
    #expect(presentation.detail == "Refreshing provider capacity published by your Mac.")
    #expect(!presentation.sections.isEmpty)
}

@Test func tvRunwayPresentationDoesNotCountAccountStatusAsAWindow() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .failure,
        generatedAt: now,
        limits: [],
        reports: [
            StoredProviderReport(
                provider: .google,
                accountID: "google",
                configuredAccountID: "google",
                accountName: "Google",
                generatedAt: now,
                status: .failure,
                errorMessage: "Reconnect required"
            ),
        ],
        status: .failure,
        message: "Reconnect required"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let google = try #require(presentation.sections.first { $0.provider == .google })

    #expect(google.trackedWindowCount == 0)
    #expect(google.trackedWindowText == "No capacity windows")
    #expect(google.lanes.count == 1)
    #expect(google.lanes.first?.kind == .accountStatus)
}

@Test func tvSyncReceiptStoreRejectsAReceiptForAnotherDocument() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-receipt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = TVSyncReceiptStore(receiptURL: directory.appending(path: "receipt.json"))
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = makeTVDocument(now: now)
    let receivedAt = now.addingTimeInterval(42)

    try store.save(document: document, receivedAt: receivedAt)
    #expect(store.load(matching: document)?.receivedAt == receivedAt)

    let newerDocument = makeTVDocument(now: now.addingTimeInterval(60))
    #expect(store.load(matching: newerDocument) == nil)
}

@Test func tvSyncReceiptStoreRejectsAnUnsupportedSchema() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-receipt-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let receiptURL = directory.appending(path: "receipt.json")
    let store = TVSyncReceiptStore(receiptURL: receiptURL)
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = makeTVDocument(now: now)

    try store.save(document: document, receivedAt: now)
    let data = try Data(contentsOf: receiptURL)
    var receiptObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    receiptObject["schemaVersion"] = TVSyncReceipt.schemaVersion + 1
    try JSONSerialization.data(withJSONObject: receiptObject).write(to: receiptURL, options: .atomic)

    #expect(store.load(matching: document) == nil)
}

@Test func tvSyncNoticePolicyUsesTransportOutcomeInsteadOfProviderStatus() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let providerFailure = CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(
            document: makeTVDocument(now: now),
            status: .failure
        ),
        outcome: CompanionRemoteSyncOutcome(succeeded: true)
    )
    let transportFailure = CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(document: nil, status: .failure),
        outcome: CompanionRemoteSyncOutcome(isAvailable: false, succeeded: false)
    )

    #expect(!TVSyncNoticePolicy.shouldShowCloudUnavailable(for: providerFailure))
    #expect(TVSyncNoticePolicy.shouldShowCloudUnavailable(for: transportFailure))
}

@Test func tvLocalCacheLocationsUseTheCachesContainer() {
    let cachesDirectory = URL(fileURLWithPath: "/container/Library/Caches", isDirectory: true)
    let locations = TVLocalCacheLocations(cachesDirectory: cachesDirectory)

    #expect(locations.rootDirectory.path == "/container/Library/Caches/Context Panel")
    #expect(
        locations.companionDocumentURL.path
            == "/container/Library/Caches/Context Panel/Companion/context-panel-companion.json"
    )
    #expect(locations.receiptURL.path == "/container/Library/Caches/Context Panel/tv-sync-receipt.json")
}

private func makeTVSnapshot(now: Date) -> WidgetSnapshot {
    let document = makeTVDocument(now: now)
    return WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: document, status: document.companionStatus),
        now: now
    )
}

private func makeTVDocument(now: Date) -> CompanionSyncDocument {
    let limits = [
        UsageLimit(
            provider: .openAI,
            accountID: "personal",
            configuredAccountID: "personal",
            accountName: "Personal",
            label: "OpenAI weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 20,
            limit: 100,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            confidence: .official
        ),
        UsageLimit(
            provider: .openAI,
            accountID: "work",
            configuredAccountID: "work",
            accountName: "Work",
            label: "OpenAI weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 40,
            limit: 100,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            confidence: .official
        ),
        UsageLimit(
            provider: .anthropic,
            accountID: "claude",
            configuredAccountID: "claude",
            accountName: "Claude",
            label: "Claude 5-hour",
            windowLabel: "5-hour",
            unit: .percent,
            used: 82,
            limit: 100,
            resetsAt: now.addingTimeInterval(2 * 60 * 60),
            confidence: .official
        ),
    ]
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: limits)
    )
    return CompanionSyncDocument(storedSnapshot: stored, publishedAt: now)
}
