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
