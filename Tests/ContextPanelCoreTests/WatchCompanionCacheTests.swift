@testable import ContextPanelCore
@testable import ContextPanelWatchSupport
import Foundation
import Testing

@Test func watchCompanionCacheUsesSharedAppGroupWhenAvailable() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var requestedAppGroupID: String?

    let cacheURL = ContextPanelLocations.watchCompanionAppGroupCacheURL(
        appGroupID: ContextPanelLocations.watchAppGroupID
    ) { appGroupID in
        requestedAppGroupID = appGroupID
        return root
    }

    #expect(ContextPanelLocations.watchAppGroupID == ContextPanelLocations.companionAppGroupID)
    #expect(requestedAppGroupID == "group.com.shinycomputers.contextpanel")
    #expect(cacheURL?.path == root
        .appending(path: "Context Panel", directoryHint: .isDirectory)
        .appending(path: "Companion", directoryHint: .isDirectory)
        .appending(path: "context-panel-watch-cache.json")
        .path)
}

@Test func watchCompanionCacheUsesProcessLocalFallbackWhenAppGroupIsUnavailable() {
    let cacheURL = ContextPanelLocations.watchCompanionAppGroupCacheURL(
        appGroupID: ContextPanelLocations.watchAppGroupID
    ) { _ in nil }

    #expect(cacheURL == nil)
    #expect(
        ContextPanelLocations.watchCompanionProcessCacheURL().lastPathComponent
            == "context-panel-watch-cache.json"
    )
}

@Test func watchUpgradeCanaryUsesSharedAppGroupDirectory() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var requestedAppGroupID: String?

    let directoryURL = ContextPanelLocations.watchUpgradeCanaryDirectoryURL(
        appGroupID: ContextPanelLocations.watchAppGroupID
    ) { appGroupID in
        requestedAppGroupID = appGroupID
        return root
    }

    #expect(requestedAppGroupID == "group.com.shinycomputers.contextpanel")
    #expect(directoryURL?.path == root
        .appending(path: "Context Panel", directoryHint: .isDirectory)
        .appending(path: "Companion", directoryHint: .isDirectory)
        .appending(path: "Watch Upgrade Canary", directoryHint: .isDirectory)
        .path)
}

@Test func watchUpgradeCanaryTracksAppAndWidgetBuildsIndependently() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
    let requestID = UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!
    let appDate = Date(timeIntervalSince1970: 1_800_000_000)
    let startedAt = appDate.addingTimeInterval(10)
    let widgetDate = appDate.addingTimeInterval(20)
    let appIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let widgetIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    let appReceipt = try #require(store.recordApp(
        identity: appIdentity,
        sessionID: sessionID,
        now: appDate
    ))
    #expect(store.recordTimelineStarted(
        family: .circular,
        requestContext: .live,
        requestID: requestID,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: startedAt
    ) != nil)
    let widgetReceipt = try #require(store.recordTimelineCompleted(
        family: .circular,
        requestContext: .live,
        requestID: requestID,
        startedAt: startedAt,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: widgetDate
    ))
    let snapshot = store.loadSnapshot()
    let circular = snapshot.observation(family: .circular, requestContext: .live)

    #expect(WatchUpgradeCanary.marker == "B")
    #expect(appReceipt.marker == "B")
    #expect(widgetReceipt.marker == "B")
    #expect(snapshot.app == appReceipt)
    #expect(snapshot.widget == widgetReceipt)
    #expect(circular.timeline == widgetReceipt)
    #expect(snapshot.app?.buildNumber == "202607211958")
    #expect(snapshot.widget?.sessionID == sessionID)
    #expect(snapshot.widget?.event == .widgetTimelineCompleted)
    #expect(snapshot.widget?.requestID == requestID)
    #expect(snapshot.widget?.requestStartedAt == startedAt)
    #expect(FileManager.default.fileExists(atPath: root
        .appending(path: "watch-app-canary-b-receipt.json").path))
    #expect(FileManager.default.fileExists(atPath: root
        .appending(path: "watch-widget-canary-b-circular-live-timeline-receipt.json").path))
}

@Test func watchUpgradeCanaryKeepsFamiliesAndContextsSeparate() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
    let appIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let widgetIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshotAt = startedAt.addingTimeInterval(2)
    let completedAt = startedAt.addingTimeInterval(4)
    let circularRequestID = UUID(uuidString: "B1000000-0000-0000-0000-000000000002")!
    let previewRequestID = UUID(uuidString: "B2000000-0000-0000-0000-000000000002")!
    let rectangularRequestID = UUID(uuidString: "B3000000-0000-0000-0000-000000000002")!

    #expect(store.recordApp(
        identity: appIdentity,
        sessionID: sessionID,
        now: startedAt.addingTimeInterval(-1)
    ) != nil)
    #expect(store.recordTimelineStarted(
        family: .circular,
        requestContext: .live,
        requestID: circularRequestID,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: startedAt
    )?.event == .widgetTimelineStarted)
    #expect(store.recordWidgetObservation(
        event: .widgetSnapshot,
        family: .circular,
        requestContext: .preview,
        requestID: previewRequestID,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: snapshotAt
    )?.event == .widgetSnapshot)
    #expect(store.recordWidgetObservation(
        event: .widgetSnapshot,
        family: .rectangular,
        requestContext: .live,
        requestID: rectangularRequestID,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: snapshotAt.addingTimeInterval(1)
    )?.event == .widgetSnapshot)
    #expect(store.recordTimelineCompleted(
        family: .circular,
        requestContext: .live,
        requestID: circularRequestID,
        startedAt: startedAt,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: completedAt
    )?.event == .widgetTimelineCompleted)

    let snapshot = store.loadSnapshot()
    let circularLive = snapshot.observation(family: .circular, requestContext: .live)
    let circularPreview = snapshot.observation(family: .circular, requestContext: .preview)
    let rectangularLive = snapshot.observation(family: .rectangular, requestContext: .live)
    #expect(snapshot.app?.sessionID == sessionID)
    #expect(circularLive.timeline?.observedAt == completedAt)
    #expect(circularPreview.snapshot?.observedAt == snapshotAt)
    #expect(rectangularLive.snapshot?.observedAt == snapshotAt.addingTimeInterval(1))
    #expect(circularLive.timeline?.requestContext == .live)
    #expect(circularPreview.snapshot?.requestContext == .preview)
    #expect(circularLive.strongestCurrentReceipt(
        marketingVersion: appIdentity.marketingVersion,
        buildNumber: appIdentity.buildNumber,
        sessionID: sessionID,
        appObservedAt: startedAt.addingTimeInterval(-1)
    )?.event == .widgetTimelineCompleted)
    #expect(circularPreview.strongestCurrentReceipt(
        marketingVersion: appIdentity.marketingVersion,
        buildNumber: appIdentity.buildNumber,
        sessionID: sessionID,
        appObservedAt: startedAt.addingTimeInterval(-1)
    )?.event == .widgetSnapshot)
    #expect(snapshot.observations.count == 3)
}

@Test func watchUpgradeCanaryIdentifiesOnlyTheCurrentBuildSession() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000003")!
    let appIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let widgetIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    #expect(store.recordApp(
        identity: appIdentity,
        sessionID: sessionID,
        now: Date(timeIntervalSince1970: 1_799_999_999)
    ) != nil)
    let receipt = try #require(store.recordWidgetObservation(
        event: .widgetSnapshot,
        family: .corner,
        requestContext: .preview,
        requestID: UUID(),
        identity: widgetIdentity,
        sessionID: sessionID,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    ))

    #expect(receipt.belongsToCanaryRun(
        marketingVersion: "1.0.49",
        buildNumber: "202607211958",
        sessionID: sessionID
    ))
    #expect(!receipt.belongsToCanaryRun(
        marketingVersion: "1.0.49",
        buildNumber: "202607211959",
        sessionID: sessionID
    ))
    #expect(!receipt.belongsToCanaryRun(
        marketingVersion: "1.0.49",
        buildNumber: "202607211958",
        sessionID: UUID()
    ))
    #expect(!receipt.belongsToCanaryRun(
        marketingVersion: "1.0.49",
        buildNumber: "202607211958",
        sessionID: sessionID,
        appObservedAt: receipt.observedAt.addingTimeInterval(1)
    ))
}

@Test func watchUpgradeCanaryRejectsMismatchedComponentAndEvent() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)

    #expect(store.recordWidgetObservation(
        event: .appLaunch,
        family: .inline,
        requestContext: .live,
        requestID: UUID(),
        sessionID: nil
    ) == nil)
    #expect(store.recordWidgetObservation(
        event: .widgetTimelineStarted,
        family: .inline,
        requestContext: .live,
        requestID: UUID(),
        sessionID: nil
    ) == nil)
    #expect(store.loadSnapshot() == .empty)
}

@Test func watchUpgradeCanaryRejectsCompletionFromPreviousAppSession() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let firstSessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000004")!
    let secondSessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000005")!
    let requestID = UUID(uuidString: "B1000000-0000-0000-0000-000000000004")!
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let appIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let widgetIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    #expect(store.recordApp(
        identity: appIdentity,
        sessionID: firstSessionID,
        now: startedAt.addingTimeInterval(-1)
    ) != nil)
    #expect(store.captureWidgetSessionID() == firstSessionID)
    #expect(store.recordTimelineStarted(
        family: .rectangular,
        requestContext: .live,
        requestID: requestID,
        identity: widgetIdentity,
        sessionID: firstSessionID,
        now: startedAt
    ) != nil)
    #expect(store.recordApp(
        identity: appIdentity,
        sessionID: secondSessionID,
        now: startedAt.addingTimeInterval(1)
    ) != nil)

    #expect(store.recordTimelineCompleted(
        family: .rectangular,
        requestContext: .live,
        requestID: requestID,
        startedAt: startedAt,
        identity: widgetIdentity,
        sessionID: firstSessionID
    ) == nil)
    #expect(store.loadSnapshot()
        .observation(family: .rectangular, requestContext: .live)
        .timeline?.event == .widgetTimelineStarted)
}

@Test func watchUpgradeCanaryRejectsCallbackThatBeganBeforeCurrentSession() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000008")!
    let callbackStartedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let appIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let widgetIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    #expect(store.recordApp(
        identity: appIdentity,
        sessionID: sessionID,
        now: callbackStartedAt.addingTimeInterval(1)
    ) != nil)
    #expect(store.recordWidgetObservation(
        event: .widgetSnapshot,
        family: .inline,
        requestContext: .live,
        requestID: UUID(),
        identity: widgetIdentity,
        sessionID: sessionID,
        now: callbackStartedAt
    ) == nil)
    #expect(store.loadSnapshot()
        .observation(family: .inline, requestContext: .live) == .empty)
}

@Test func watchUpgradeCanaryRequiresMatchingTimelineStart() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000009")!
    let requestID = UUID(uuidString: "B1000000-0000-0000-0000-000000000009")!
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    #expect(store.recordApp(
        identity: identity,
        sessionID: sessionID,
        now: startedAt.addingTimeInterval(-1)
    ) != nil)
    #expect(store.recordTimelineCompleted(
        family: .circular,
        requestContext: .live,
        requestID: requestID,
        startedAt: startedAt,
        identity: identity,
        sessionID: sessionID,
        now: startedAt.addingTimeInterval(1)
    ) == nil)

    #expect(store.recordTimelineStarted(
        family: .circular,
        requestContext: .live,
        requestID: requestID,
        identity: identity,
        sessionID: sessionID,
        now: startedAt
    ) != nil)
    let firstCompletion = try #require(store.recordTimelineCompleted(
        family: .circular,
        requestContext: .live,
        requestID: requestID,
        startedAt: startedAt,
        identity: identity,
        sessionID: sessionID,
        now: startedAt.addingTimeInterval(2)
    ))
    let duplicateCompletion = try #require(store.recordTimelineCompleted(
        family: .circular,
        requestContext: .live,
        requestID: requestID,
        startedAt: startedAt,
        identity: identity,
        sessionID: sessionID,
        now: startedAt.addingTimeInterval(3)
    ))
    #expect(duplicateCompletion == firstCompletion)
}

@Test func watchUpgradeCanaryRejectsSupersededTimelineCompletion() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000006")!
    let firstRequestID = UUID(uuidString: "B1000000-0000-0000-0000-000000000006")!
    let secondRequestID = UUID(uuidString: "B2000000-0000-0000-0000-000000000006")!
    let firstStartedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let secondStartedAt = firstStartedAt.addingTimeInterval(2)
    let appIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let widgetIdentity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    #expect(store.recordApp(
        identity: appIdentity,
        sessionID: sessionID,
        now: firstStartedAt.addingTimeInterval(-1)
    ) != nil)
    #expect(store.recordTimelineStarted(
        family: .corner,
        requestContext: .live,
        requestID: firstRequestID,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: firstStartedAt
    ) != nil)
    #expect(store.recordTimelineStarted(
        family: .corner,
        requestContext: .live,
        requestID: secondRequestID,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: secondStartedAt
    ) != nil)

    #expect(store.recordTimelineCompleted(
        family: .corner,
        requestContext: .live,
        requestID: firstRequestID,
        startedAt: firstStartedAt,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: secondStartedAt.addingTimeInterval(1)
    ) == nil)
    #expect(store.recordTimelineCompleted(
        family: .corner,
        requestContext: .live,
        requestID: secondRequestID,
        startedAt: secondStartedAt,
        identity: widgetIdentity,
        sessionID: sessionID,
        now: secondStartedAt.addingTimeInterval(2)
    )?.event == .widgetTimelineCompleted)

    let timeline = store.loadSnapshot()
        .observation(family: .corner, requestContext: .live)
        .timeline
    #expect(timeline?.requestID == secondRequestID)
    #expect(timeline?.event == .widgetTimelineCompleted)
}

@Test func watchUpgradeCanaryRejectsCorruptAndMismatchedReceipts() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let identity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )
    let appReceiptURL = root.appending(path: "watch-app-canary-b-receipt.json")
    let widgetReceiptURL = root.appending(
        path: "watch-widget-canary-b-circular-live-timeline-receipt.json"
    )
    let sessionID = UUID(uuidString: "B0000000-0000-0000-0000-000000000010")!
    let startedAt = Date(timeIntervalSince1970: 1_800_000_001)

    #expect(store.recordApp(
        identity: identity,
        sessionID: sessionID,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    ) != nil)
    try FileManager.default.copyItem(at: appReceiptURL, to: widgetReceiptURL)
    #expect(store.load(component: .widget) == nil)

    try Data("not-json".utf8).write(to: widgetReceiptURL, options: .atomic)
    #expect(store.load(component: .widget) == nil)
    #expect(store.recordTimelineStarted(
        family: .circular,
        requestContext: .live,
        requestID: UUID(uuidString: "B1000000-0000-0000-0000-000000000010")!,
        identity: identity,
        sessionID: sessionID,
        now: startedAt
    )?.event == .widgetTimelineStarted)
    #expect(store.loadSnapshot()
        .observation(family: .circular, requestContext: .live)
        .timeline?.requestStartedAt == startedAt)
}

@Test func watchUpgradeCanaryReceiptContainsOnlyBuildDiagnostics() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WatchUpgradeCanaryReceiptStore(directoryURL: root)
    let identity = WatchUpgradeCanaryBuildIdentity(
        bundleIdentifier: "com.shinycomputers.contextpanel.watch.widget",
        marketingVersion: "1.0.49",
        buildNumber: "202607211958"
    )

    #expect(store.recordWidgetObservation(
        event: .widgetSnapshot,
        family: .inline,
        requestContext: .preview,
        requestID: UUID(uuidString: "B1000000-0000-0000-0000-000000000007")!,
        identity: identity,
        sessionID: nil,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    ) != nil)
    let receiptData = try Data(contentsOf: root.appending(
        path: "watch-widget-canary-b-inline-preview-snapshot-receipt.json"
    ))
    let receiptText = try #require(String(data: receiptData, encoding: .utf8))

    #expect(receiptText.contains("bundleIdentifier"))
    #expect(receiptText.contains("buildNumber"))
    #expect(receiptText.contains("family"))
    #expect(receiptText.contains("requestContext"))
    #expect(receiptText.contains("requestID"))
    #expect(receiptText.contains("processIdentifier"))
    #expect(!receiptText.localizedCaseInsensitiveContains("account"))
    #expect(!receiptText.localizedCaseInsensitiveContains("usage"))
    #expect(!receiptText.localizedCaseInsensitiveContains("credential"))
    #expect(!receiptText.localizedCaseInsensitiveContains("provider"))
}

@Test func watchComplicationTimelineReloadsForAnyUsableDocument() {
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let cached = WatchCompanionCacheLoadResult(
        result: CompanionSyncLoadResult(
            document: watchCacheDocument(generatedAt: generatedAt),
            status: .stale,
            transportMetadata: CompanionSyncTransportMetadata(
                source: .localCache,
                deliveryStatus: .delayed
            )
        ),
        displayPreferences: .defaultPreferences
    )
    let missing = WatchCompanionCacheLoadResult(
        result: CompanionSyncLoadResult(document: nil, status: .failure),
        displayPreferences: nil
    )

    #expect(WatchComplicationTimelineReloadPolicy.shouldReload(after: cached))
    #expect(!WatchComplicationTimelineReloadPolicy.shouldReload(after: missing))
}

@Test func watchCompanionCacheRoundTripsDocumentsAndDisplayPreferences() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheURL = root.appending(path: "watch-cache.json")
    let cache = WatchCompanionCache(cacheURL: cacheURL)
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(generatedAt: generatedAt)
    let preferences = watchCachePreferences(provider: .anthropic)

    #expect(cache.save(document: document, displayPreferences: preferences, now: generatedAt))
    let loaded = cache.load()
    #expect(loaded.result.document == document)
    #expect(loaded.result.transportMetadata?.source == .localCache)
    #expect(loaded.displayPreferences == preferences)
    #expect(FileManager.default.fileExists(atPath: cacheURL.path))
}

@Test func watchCompanionCacheCreatesItsFirstNestedDirectory() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheURL = root
        .appending(path: "Context Panel", directoryHint: .isDirectory)
        .appending(path: "Companion", directoryHint: .isDirectory)
        .appending(path: "watch-cache.json")
    let cache = WatchCompanionCache(cacheURL: cacheURL)
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(generatedAt: generatedAt)

    #expect(cache.save(document: document, displayPreferences: .defaultPreferences, now: generatedAt))
    #expect(cache.load().result.document == document)
}

@Test func watchCompanionCacheKeepsANewerDocumentAndItsPreferences() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let newerDate = Date(timeIntervalSince1970: 1_800_000_100)
    let olderDate = newerDate.addingTimeInterval(-100)
    let newer = watchCacheDocument(generatedAt: newerDate)
    let older = watchCacheDocument(generatedAt: olderDate)
    let newerPreferences = watchCachePreferences(provider: .google)
    let olderPreferences = watchCachePreferences(provider: .openAI)

    #expect(cache.save(document: newer, displayPreferences: newerPreferences, now: newerDate))
    #expect(cache.save(document: older, displayPreferences: olderPreferences, now: newerDate))
    let loaded = cache.load()
    #expect(loaded.result.document == newer)
    #expect(loaded.displayPreferences == newerPreferences)
}

@Test func watchCompanionCacheTreatsAMissingPayloadAsNotYetSynced() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "missing.json"))

    let loaded = cache.load()

    #expect(loaded.result.document == nil)
    #expect(loaded.result.status == .unknown)
    #expect(loaded.displayPreferences == nil)
}

@Test func watchCompanionCacheRejectsACorruptPayload() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheURL = root.appending(path: "watch-cache.json")
    try Data("not-json".utf8).write(to: cacheURL)
    let cache = WatchCompanionCache(cacheURL: cacheURL)

    let loaded = cache.load()

    #expect(loaded.result.document == nil)
    #expect(loaded.result.status == .failure)
    #expect(loaded.displayPreferences == nil)
}

@Test func watchCompanionCacheMigratesLegacyPayloadIntoSharedCache() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedURL = root.appending(path: "shared.json")
    let legacyURL = root.appending(path: "legacy.json")
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(generatedAt: generatedAt)
    let preferences = watchCachePreferences(provider: .anthropic)
    try writeWatchLegacyCachePayload(
        to: legacyURL,
        document: document,
        displayPreferences: preferences,
        cachedAt: generatedAt
    )
    let cache = WatchCompanionCache(
        cacheURL: sharedURL,
        legacyCacheURL: legacyURL,
        source: .appGroup
    )

    let loaded = cache.load()

    #expect(loaded.result.document == document)
    #expect(loaded.result.transportMetadata?.source == .appGroup)
    #expect(loaded.displayPreferences == preferences)
    #expect(FileManager.default.fileExists(atPath: sharedURL.path))
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
}

@Test func watchCompanionCacheMergesLegacyPayloadIntoExistingSharedCache() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedURL = root.appending(path: "shared.json")
    let legacyURL = root.appending(path: "legacy.json")
    let sharedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let legacyDate = sharedDate.addingTimeInterval(100)
    let sharedDocument = watchCacheDocument(
        generatedAt: sharedDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "shared", used: 100, generatedAt: sharedDate)]
    )
    let legacyDocument = watchCacheDocument(
        generatedAt: legacyDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "legacy", used: 62, generatedAt: legacyDate)]
    )
    let sharedCache = WatchCompanionCache(cacheURL: sharedURL, source: .appGroup)
    #expect(sharedCache.save(
        document: sharedDocument,
        displayPreferences: .defaultPreferences,
        now: sharedDate
    ))
    try writeWatchLegacyCachePayload(
        to: legacyURL,
        document: legacyDocument,
        displayPreferences: .defaultPreferences,
        cachedAt: legacyDate
    )
    let convergedCache = WatchCompanionCache(
        cacheURL: sharedURL,
        legacyCacheURL: legacyURL,
        source: .appGroup
    )

    let loaded = convergedCache.load()
    let accountNames = Set(try #require(loaded.result.document).snapshot.limits.map(\.accountName))

    #expect(accountNames == ["Shared", "Legacy"])
    #expect(loaded.result.transportMetadata?.source == .appGroup)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
}

@Test func watchCompanionCacheMergesAppAndWidgetLegacySeeds() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedURL = root.appending(path: "shared.json")
    let appLegacyURL = root.appending(path: "app-legacy.json")
    let widgetLegacyURL = root.appending(path: "widget-legacy.json")
    let appDate = Date(timeIntervalSince1970: 1_800_000_000)
    let widgetDate = appDate.addingTimeInterval(100)
    try writeWatchLegacyCachePayload(
        to: appLegacyURL,
        document: watchCacheDocument(
            generatedAt: appDate,
            limits: [watchOpenAIWeeklyLimit(accountID: "app", used: 100, generatedAt: appDate)]
        ),
        displayPreferences: .defaultPreferences,
        cachedAt: appDate
    )
    try writeWatchLegacyCachePayload(
        to: widgetLegacyURL,
        document: watchCacheDocument(
            generatedAt: widgetDate,
            limits: [watchOpenAIWeeklyLimit(accountID: "widget", used: 62, generatedAt: widgetDate)]
        ),
        displayPreferences: .defaultPreferences,
        cachedAt: widgetDate
    )
    let appCache = WatchCompanionCache(
        cacheURL: sharedURL,
        legacyCacheURL: appLegacyURL,
        source: .appGroup
    )
    let widgetCache = WatchCompanionCache(
        cacheURL: sharedURL,
        legacyCacheURL: widgetLegacyURL,
        source: .appGroup
    )

    #expect(appCache.load().result.document != nil)
    let loaded = widgetCache.load()
    let accountNames = Set(try #require(loaded.result.document).snapshot.limits.map(\.accountName))

    #expect(accountNames == ["App", "Widget"])
    #expect(!FileManager.default.fileExists(atPath: appLegacyURL.path))
    #expect(!FileManager.default.fileExists(atPath: widgetLegacyURL.path))
}

@Test func watchCompanionCacheDoesNotResurrectMigratedLegacyPayload() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedURL = root.appending(path: "shared.json")
    let legacyURL = root.appending(path: "legacy.json")
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try writeWatchLegacyCachePayload(
        to: legacyURL,
        document: watchCacheDocument(generatedAt: generatedAt),
        displayPreferences: .defaultPreferences,
        cachedAt: generatedAt
    )
    let cache = WatchCompanionCache(
        cacheURL: sharedURL,
        legacyCacheURL: legacyURL,
        source: .appGroup
    )

    #expect(cache.load().result.document != nil)
    #expect(cache.remove())
    #expect(cache.load().result.document == nil)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
}

@Test func watchCompanionCacheUpdatesPreferencesWhenDocumentIsUnchanged() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let documentDate = Date(timeIntervalSince1970: 1_800_000_000)
    let preferenceDate = documentDate.addingTimeInterval(100)
    let document = watchCacheDocument(generatedAt: documentDate)
    let initialPreferences = watchCachePreferences(provider: .openAI)
    let updatedPreferences = watchCachePreferences(provider: .google)

    #expect(cache.save(
        document: document,
        displayPreferences: initialPreferences,
        displayPreferencesUpdatedAt: documentDate,
        now: documentDate
    ))
    #expect(cache.save(
        document: document,
        displayPreferences: updatedPreferences,
        displayPreferencesUpdatedAt: preferenceDate,
        now: preferenceDate
    ))

    let loaded = cache.load()
    #expect(loaded.displayPreferences == updatedPreferences)
    #expect(loaded.displayPreferencesUpdatedAt == preferenceDate)
}

@Test func watchCompanionCacheDoesNotRegressNewerPreferencesFromAnOlderWriter() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
    let newerPreferenceDate = initialDate.addingTimeInterval(200)
    let laterWriteDate = newerPreferenceDate.addingTimeInterval(100)
    let newerPreferences = watchCachePreferences(provider: .google)
    let olderPreferences = watchCachePreferences(provider: .openAI)
    #expect(cache.save(
        document: watchCacheDocument(generatedAt: initialDate),
        displayPreferences: newerPreferences,
        displayPreferencesUpdatedAt: newerPreferenceDate,
        now: newerPreferenceDate
    ))

    #expect(cache.save(
        document: watchCacheDocument(generatedAt: laterWriteDate),
        displayPreferences: olderPreferences,
        displayPreferencesUpdatedAt: initialDate,
        now: laterWriteDate
    ))

    let loaded = cache.load()
    #expect(loaded.result.document?.snapshot.generatedAt == laterWriteDate)
    #expect(loaded.displayPreferences == newerPreferences)
    #expect(loaded.displayPreferencesUpdatedAt == newerPreferenceDate)
}

@Test func watchCompanionCacheConditionalRemoveRequiresExactPayloadRevision() throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let preferenceDate = generatedAt.addingTimeInterval(100)
    let document = watchCacheDocument(generatedAt: generatedAt)
    #expect(cache.save(
        document: document,
        displayPreferences: watchCachePreferences(provider: .openAI),
        displayPreferencesUpdatedAt: generatedAt,
        now: generatedAt
    ))
    let expected = cache.load()
    let newerPreferences = watchCachePreferences(provider: .anthropic)
    #expect(cache.save(
        document: document,
        displayPreferences: newerPreferences,
        displayPreferencesUpdatedAt: preferenceDate,
        now: preferenceDate
    ))

    let outcome = cache.removeIfCurrent(expected, now: preferenceDate)

    guard case let .keptCurrent(current) = outcome else {
        Issue.record("Expected the newer shared payload to survive conditional removal")
        return
    }
    #expect(current.displayPreferences == newerPreferences)
    #expect(cache.load().displayPreferences == newerPreferences)
}

@Test func watchCompanionCacheMergesWritesFromIndependentCacheInstances() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheURL = root.appending(path: "shared.json")
    let appCache = WatchCompanionCache(cacheURL: cacheURL, source: .appGroup)
    let widgetCache = WatchCompanionCache(cacheURL: cacheURL, source: .appGroup)
    let appDate = Date(timeIntervalSince1970: 1_800_000_000)
    let widgetDate = appDate.addingTimeInterval(100)
    let appDocument = watchCacheDocument(
        generatedAt: appDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "app", used: 100, generatedAt: appDate)]
    )
    let widgetDocument = watchCacheDocument(
        generatedAt: widgetDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "widget", used: 62, generatedAt: widgetDate)]
    )

    let appTask = Task.detached {
        appCache.save(document: appDocument, displayPreferences: .defaultPreferences, now: appDate)
    }
    let widgetTask = Task.detached {
        widgetCache.save(document: widgetDocument, displayPreferences: .defaultPreferences, now: widgetDate)
    }
    #expect(await appTask.value)
    #expect(await widgetTask.value)

    let loaded = appCache.load()
    let accountNames = Set(try #require(loaded.result.document).snapshot.limits.map(\.accountName))
    #expect(accountNames == ["App", "Widget"])
    #expect(loaded.result.transportMetadata?.source == .appGroup)
}

@Test func watchCompanionLoaderCachesFreshCloudKitUsage() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(generatedAt: generatedAt)
    let preferences = watchCachePreferences(provider: .google)
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in watchRemoteLoad(document: document, receivedAt: generatedAt) },
        loadPresentation: {
            CompanionPresentationRemoteLoadResult(
                document: CompanionPresentationDocument(widgetDisplayPreferences: preferences),
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole,
                    succeeded: true
                )
            )
        }
    )

    let loaded = await loader.load(now: generatedAt)

    #expect(loaded.result.document == document)
    #expect(loaded.result.transportMetadata?.source == .cloudKit)
    #expect(loaded.displayPreferences == preferences)
    #expect(cache.load().result.document == document)
    #expect(cache.load().displayPreferences == preferences)
}

@Test func watchCompanionLoaderKeepsNewerCachedUsageOverOlderCloudKitUsage() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let newerDate = Date(timeIntervalSince1970: 1_800_000_100)
    let olderDate = newerDate.addingTimeInterval(-100)
    let newerDocument = watchCacheDocument(generatedAt: newerDate)
    let olderDocument = watchCacheDocument(generatedAt: olderDate)
    #expect(cache.save(
        document: newerDocument,
        displayPreferences: .defaultPreferences,
        now: newerDate
    ))
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in watchRemoteLoad(document: olderDocument, receivedAt: newerDate) },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load(now: newerDate)

    #expect(loaded.result.document == newerDocument)
    #expect(loaded.result.transportMetadata?.source == .localCache)
    #expect(cache.load().result.document == newerDocument)
}

@Test func watchCompanionLoaderUsesNewerAccountObservationFromOlderRemoteDocument() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let cachedObservation = Date(timeIntervalSince1970: 1_800_000_000)
    let remoteObservation = cachedObservation.addingTimeInterval(100)
    let cachedFailureDate = remoteObservation.addingTimeInterval(100)
    let cachedDocument = watchCacheDocument(
        generatedAt: cachedFailureDate,
        limits: [watchOpenAIWeeklyLimit(
            accountID: "shared",
            used: 7,
            generatedAt: cachedObservation
        )],
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "shared",
            accountName: "Shared",
            generatedAt: cachedFailureDate,
            status: .failure,
            errorMessage: "Authentication unavailable"
        )]
    )
    let remoteDocument = watchCacheDocument(
        generatedAt: remoteObservation,
        limits: [watchOpenAIWeeklyLimit(
            accountID: "shared",
            used: 34,
            generatedAt: remoteObservation
        )]
    )
    #expect(cache.save(
        document: cachedDocument,
        displayPreferences: .defaultPreferences,
        now: cachedFailureDate
    ))
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in watchRemoteLoad(document: remoteDocument, receivedAt: cachedFailureDate) },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load(now: cachedFailureDate)

    #expect(loaded.result.document?.snapshot.generatedAt == cachedFailureDate)
    #expect(loaded.result.document?.snapshot.limits.first?.used == 34)
    #expect(loaded.result.document?.snapshot.providerStatuses.isEmpty == true)
    #expect(loaded.result.status == .healthy)
    #expect(loaded.result.transportMetadata?.source == .cloudKit)
    #expect(cache.load().result.document == loaded.result.document)
}

@Test func watchCompanionLoaderKeepsNewerUsageWrittenDuringCloudKitLoad() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let newerDate = Date(timeIntervalSince1970: 1_800_000_100)
    let olderDate = newerDate.addingTimeInterval(-100)
    let newerDocument = watchCacheDocument(generatedAt: newerDate)
    let olderLoad = watchRemoteLoad(
        document: watchCacheDocument(generatedAt: olderDate),
        receivedAt: newerDate
    )
    let probe = WatchRemoteLoadProbe()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in await probe.load() },
        loadPresentation: { watchPresentationLoad() }
    )
    let loadTask = Task { await loader.load(now: newerDate) }
    while await probe.count() == 0 {
        await Task.yield()
    }
    #expect(cache.save(
        document: newerDocument,
        displayPreferences: .defaultPreferences,
        now: newerDate
    ))

    await probe.resume(returning: olderLoad)
    let loaded = await loadTask.value

    #expect(loaded.result.document == newerDocument)
    #expect(loaded.result.transportMetadata?.source == .localCache)
    #expect(cache.load().result.document == newerDocument)
}

@Test func watchCompanionLoaderMergesRemoteAccountsWithNewerConcurrentCacheWrite() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let remoteDate = Date(timeIntervalSince1970: 1_800_000_000)
    let concurrentDate = remoteDate.addingTimeInterval(100)
    let remoteDocument = watchCacheDocument(
        generatedAt: remoteDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "remote", used: 20, generatedAt: remoteDate)]
    )
    let concurrentDocument = watchCacheDocument(
        generatedAt: concurrentDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "concurrent", used: 40, generatedAt: concurrentDate)]
    )
    let probe = WatchRemoteLoadProbe()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in await probe.load() },
        loadPresentation: { watchPresentationLoad() }
    )
    let loadTask = Task { await loader.load(now: concurrentDate) }
    while await probe.count() == 0 {
        await Task.yield()
    }
    #expect(cache.save(
        document: concurrentDocument,
        displayPreferences: .defaultPreferences,
        now: concurrentDate
    ))

    await probe.resume(returning: watchRemoteLoad(document: remoteDocument, receivedAt: concurrentDate))
    let loaded = await loadTask.value
    let accountNames = Set(try #require(loaded.result.document).snapshot.limits.map(\.accountName))

    #expect(accountNames == ["Remote", "Concurrent"])
    #expect(cache.load().result.document == loaded.result.document)
}

@Test func watchCompanionLoaderPreservesNewerConcurrentCacheWhenCloudKitRecordDisappears() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
    let newerDate = initialDate.addingTimeInterval(100)
    let initialDocument = watchCacheDocument(generatedAt: initialDate)
    let newerDocument = watchCacheDocument(
        generatedAt: newerDate,
        limits: [watchOpenAIWeeklyLimit(accountID: "newer", used: 20, generatedAt: newerDate)]
    )
    #expect(cache.save(
        document: initialDocument,
        displayPreferences: .defaultPreferences,
        now: initialDate
    ))
    let probe = WatchRemoteLoadProbe()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in await probe.load() },
        loadPresentation: { watchPresentationLoad() }
    )
    let loadTask = Task { await loader.load(now: newerDate) }
    while await probe.count() == 0 {
        await Task.yield()
    }
    #expect(cache.save(
        document: newerDocument,
        displayPreferences: .defaultPreferences,
        now: newerDate
    ))
    await probe.resume(returning: CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(document: nil, status: .unknown),
        outcome: CompanionRemoteSyncOutcome(succeeded: true, missingRecord: true)
    ))

    let loaded = await loadTask.value

    #expect(loaded.result.document == newerDocument)
    #expect(cache.load().result.document == newerDocument)
}

@Test func watchCompanionLoaderUsesStaleCacheWhenCloudKitTimesOut() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(generatedAt: generatedAt)
    let preferences = watchCachePreferences(provider: .openAI)
    #expect(cache.save(document: document, displayPreferences: preferences, now: generatedAt))
    let blocker = WatchDeadlineBlocker()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .milliseconds(20),
        loadDocument: { _ in
            _ = await blocker.wait()
            return watchRemoteLoad(document: document, receivedAt: generatedAt)
        },
        loadPresentation: { watchPresentationLoad() }
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let loaded = await loader.load(now: generatedAt.addingTimeInterval(100))

    #expect(startedAt.duration(to: clock.now) < .seconds(1))
    #expect(loaded.result.document == document)
    #expect(loaded.result.status == .stale)
    #expect(loaded.result.transportMetadata?.source == .localCache)
    #expect(loaded.result.transportMetadata?.deliveryStatus == .delayed)
    #expect(loaded.displayPreferences == preferences)
    await blocker.resume(returning: 1)
}

@Test func watchCompanionLoaderPreservesAppGroupSourceWhenCloudKitTimesOut() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(
        cacheURL: root.appending(path: "watch-cache.json"),
        source: .appGroup
    )
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(
        generatedAt: generatedAt,
        limits: [watchOpenAIWeeklyLimit(accountID: "shared", used: 20, generatedAt: generatedAt)]
    )
    #expect(cache.save(
        document: document,
        displayPreferences: .defaultPreferences,
        now: generatedAt
    ))
    let blocker = WatchDeadlineBlocker()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .milliseconds(20),
        loadDocument: { _ in
            _ = await blocker.wait()
            return watchRemoteLoad(document: document, receivedAt: generatedAt)
        },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load(now: generatedAt.addingTimeInterval(100))
    let snapshot = WidgetSnapshot.fromCompanionSync(
        loaded.result,
        now: generatedAt.addingTimeInterval(100),
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 1_000)
    )

    #expect(loaded.result.document == document)
    #expect(loaded.result.status == .stale)
    #expect(loaded.result.transportMetadata?.source == .appGroup)
    #expect(loaded.result.transportMetadata?.deliveryStatus == .delayed)
    #expect(snapshot.state == .stale)
    #expect(snapshot.status == .stale)
    await blocker.resume(returning: 1)
}

@Test func watchCompanionTimeoutKeepsPooledCapacityForStaleComplication() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let displayDate = generatedAt.addingTimeInterval(SnapshotFreshness.widgetMaximumAge + 60)
    let document = watchCacheDocument(
        generatedAt: generatedAt,
        limits: [
            watchOpenAIWeeklyLimit(accountID: "primary", used: 100, generatedAt: generatedAt),
            watchOpenAIWeeklyLimit(accountID: "secondary", used: 2, generatedAt: generatedAt),
            watchOpenAIWeeklyLimit(accountID: "tertiary", used: 77, generatedAt: generatedAt),
        ]
    )
    #expect(cache.save(document: document, displayPreferences: .defaultPreferences, now: generatedAt))
    let blocker = WatchDeadlineBlocker()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .milliseconds(20),
        loadDocument: { _ in
            _ = await blocker.wait()
            return watchRemoteLoad(document: document, receivedAt: displayDate)
        },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load(now: displayDate)
    let snapshot = WidgetSnapshot.fromCompanionSync(
        loaded.result,
        now: displayDate,
        stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
            maximumAge: SnapshotFreshness.widgetMaximumAge
        )
    )
    let row = try #require(WatchLimitDisplay.mainLaneRows(
        from: snapshot,
        preferences: loaded.displayPreferences ?? .defaultPreferences,
        maximumCount: 1
    ).first)

    #expect(loaded.result.status == .stale)
    #expect(row.id == "summary:openai:weekly")
    #expect(row.context == "3 accounts")
    #expect(row.usedText == "60%")
    #expect(row.remainingComplicationText == "40% left · saved")
    await blocker.resume(returning: 1)
}

@Test func watchCompanionLoaderCoalescesOverlappingCloudKitLoads() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let expected = watchRemoteLoad(
        document: watchCacheDocument(generatedAt: generatedAt),
        receivedAt: generatedAt
    )
    let probe = WatchRemoteLoadProbe()
    let loader = WatchCompanionLoader(
        cache: WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json")),
        timeout: .seconds(1),
        loadDocument: { _ in await probe.load() },
        loadPresentation: { watchPresentationLoad() }
    )
    let first = Task { await loader.load(now: generatedAt) }
    while await probe.count() == 0 {
        await Task.yield()
    }
    let second = Task { await loader.load(now: generatedAt) }
    for _ in 0 ..< 10 {
        await Task.yield()
    }

    #expect(await probe.count() == 1)
    await probe.resume(returning: expected)
    let firstResult = await first.value
    let secondResult = await second.value

    #expect(await probe.count() == 1)
    #expect(firstResult == secondResult)
    #expect(firstResult.result.document == expected.result.document)
}

@Test func watchCompanionLoaderUsesCachedPreferencesWhenPresentationTimesOut() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchCacheDocument(generatedAt: generatedAt)
    let cachedPreferences = watchCachePreferences(provider: .openAI)
    #expect(cache.save(document: document, displayPreferences: cachedPreferences, now: generatedAt))
    let blocker = WatchDeadlineBlocker()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .milliseconds(20),
        loadDocument: { _ in watchRemoteLoad(document: document, receivedAt: generatedAt) },
        loadPresentation: {
            _ = await blocker.wait()
            return CompanionPresentationRemoteLoadResult(
                document: CompanionPresentationDocument(
                    widgetDisplayPreferences: watchCachePreferences(provider: .google)
                ),
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole,
                    succeeded: true
                )
            )
        }
    )

    let loaded = await loader.load(now: generatedAt)

    #expect(loaded.result.document == document)
    #expect(loaded.displayPreferences == cachedPreferences)
    await blocker.resume(returning: 1)
}

@Test func watchCompanionLoaderClearsCachedOverrideWhenPresentationRecordIsMissing() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let refreshedAt = generatedAt.addingTimeInterval(100)
    let syncedPreferences = watchCachePreferences(provider: .google)
    let cachedOverride = watchCachePreferences(provider: .openAI)
    let document = watchCacheDocument(
        generatedAt: generatedAt,
        widgetDisplayPreferences: syncedPreferences
    )
    #expect(cache.save(
        document: document,
        displayPreferences: cachedOverride,
        displayPreferencesUpdatedAt: generatedAt,
        now: generatedAt
    ))
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in watchRemoteLoad(document: document, receivedAt: refreshedAt) },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load(now: refreshedAt)

    #expect(loaded.displayPreferences == syncedPreferences)
    #expect(cache.load().displayPreferences == syncedPreferences)
    #expect(cache.load().displayPreferencesUpdatedAt == refreshedAt)
}

@Test func watchCompanionLoaderClearsCacheWhenCloudKitRecordIsMissing() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(cache.save(
        document: watchCacheDocument(generatedAt: generatedAt),
        displayPreferences: .defaultPreferences,
        now: generatedAt
    ))
    let loader = WatchCompanionLoader(
        cache: cache,
        loadDocument: { _ in
            CompanionRemoteSyncLoadResult(
                result: CompanionSyncLoadResult(document: nil, status: .unknown),
                outcome: CompanionRemoteSyncOutcome(succeeded: true, missingRecord: true)
            )
        },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load(now: generatedAt)

    #expect(loaded.result.document == nil)
    #expect(loaded.result.status == .unknown)
    #expect(cache.load().result.document == nil)
}

@Test func watchCompanionLoaderKeepsCachedUsageWhenMissingRecordRemovalFails() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheURL = root.appending(path: "watch-cache.json")
    let cache = WatchCompanionCache(cacheURL: cacheURL)
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let refreshedAt = generatedAt.addingTimeInterval(100)
    let document = watchCacheDocument(generatedAt: generatedAt)
    #expect(cache.save(
        document: document,
        displayPreferences: .defaultPreferences,
        now: generatedAt
    ))
    let probe = WatchRemoteLoadProbe()
    let loader = WatchCompanionLoader(
        cache: cache,
        timeout: .seconds(1),
        loadDocument: { _ in await probe.load() },
        loadPresentation: { watchPresentationLoad() }
    )
    let loadTask = Task { await loader.load(now: refreshedAt) }
    while await probe.count() == 0 {
        await Task.yield()
    }
    try Data("not-json".utf8).write(to: cacheURL, options: .atomic)
    await probe.resume(returning: CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(document: nil, status: .unknown),
        outcome: CompanionRemoteSyncOutcome(succeeded: true, missingRecord: true)
    ))

    let loaded = await loadTask.value

    #expect(loaded.result.document == document)
    #expect(loaded.result.status == .stale)
    #expect(loaded.result.errorMessage == "Context Panel Watch could not clear saved usage.")
    #expect(try String(decoding: Data(contentsOf: cacheURL), as: UTF8.self) == "not-json")
}

@Test func watchCompanionLoaderReportsFailureWithoutCache() async throws {
    let root = try watchCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = WatchCompanionLoader(
        cache: WatchCompanionCache(cacheURL: root.appending(path: "watch-cache.json")),
        loadDocument: { _ in
            CompanionRemoteSyncLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: "CloudKit unavailable"
                ),
                outcome: CompanionRemoteSyncOutcome(
                    isAvailable: false,
                    succeeded: false,
                    errorMessage: "CloudKit unavailable"
                )
            )
        },
        loadPresentation: { watchPresentationLoad() }
    )

    let loaded = await loader.load()

    #expect(loaded.result.document == nil)
    #expect(loaded.result.status == .failure)
    #expect(loaded.result.errorMessage != nil)
}

@Test func watchAsyncDeadlineReturnsWithoutWaitingForANonCooperativeOperation() async {
    let blocker = WatchDeadlineBlocker()
    let clock = ContinuousClock()
    let startedAt = clock.now

    let value = await WatchAsyncDeadline.value(timeout: .milliseconds(20)) {
        await blocker.wait()
    }

    #expect(value == nil)
    #expect(startedAt.duration(to: clock.now) < .seconds(1))
    await blocker.resume(returning: 42)
}

private func watchCacheDocument(
    generatedAt: Date,
    limits: [UsageLimit] = [],
    reports: [StoredProviderReport] = [],
    widgetDisplayPreferences: WidgetDisplayPreferences = .defaultPreferences
) -> CompanionSyncDocument {
    CompanionSyncDocument(
        snapshot: CompanionSnapshot(
            generatedAt: generatedAt,
            publishedAt: generatedAt.addingTimeInterval(5),
            limits: limits.map(CompanionLimit.init),
            providerStatuses: reports.map(CompanionProviderStatus.init),
            promptCacheSummaries: []
        ),
        widgetDisplayPreferences: widgetDisplayPreferences
    )
}

private func watchOpenAIWeeklyLimit(
    accountID: String,
    used: Int,
    generatedAt: Date
) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: accountID,
        accountName: accountID.capitalized,
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: generatedAt.addingTimeInterval(7 * 24 * 60 * 60),
        lastUpdatedAt: generatedAt,
        confidence: .observed
    )
}

private func watchCachePreferences(provider: Provider) -> WidgetDisplayPreferences {
    WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: provider, window: .weekly, isVisible: true, sortOrder: 0),
    ])
}

private func watchRemoteLoad(
    document: CompanionSyncDocument,
    receivedAt: Date
) -> CompanionRemoteSyncLoadResult {
    CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(
            document: document,
            status: .healthy,
            transportMetadata: CompanionSyncTransportMetadata(
                source: .cloudKit,
                receivedAt: receivedAt,
                deliveryStatus: .healthy
            )
        ),
        outcome: CompanionRemoteSyncOutcome(succeeded: true)
    )
}

private func watchPresentationLoad() -> CompanionPresentationRemoteLoadResult {
    CompanionPresentationRemoteLoadResult(
        document: nil,
        outcome: CompanionRemoteSyncOutcome(
            storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole,
            succeeded: true,
            missingRecord: true
        )
    )
}

private func watchCacheTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-watch-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeWatchLegacyCachePayload(
    to url: URL,
    document: CompanionSyncDocument,
    displayPreferences: WidgetDisplayPreferences,
    cachedAt: Date
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(WatchLegacyCachePayload(
        schemaVersion: 1,
        document: document,
        displayPreferences: displayPreferences,
        cachedAt: cachedAt
    )).write(to: url, options: .atomic)
}

private struct WatchLegacyCachePayload: Encodable {
    let schemaVersion: Int
    let document: CompanionSyncDocument
    let displayPreferences: WidgetDisplayPreferences
    let cachedAt: Date
}

private actor WatchDeadlineBlocker {
    private var continuation: CheckedContinuation<Int, Never>?
    private var bufferedValue: Int?

    func wait() async -> Int {
        if let bufferedValue {
            self.bufferedValue = nil
            return bufferedValue
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(returning value: Int) {
        guard let continuation else {
            bufferedValue = value
            return
        }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

private actor WatchRemoteLoadProbe {
    private var continuation: CheckedContinuation<CompanionRemoteSyncLoadResult, Never>?
    private var bufferedResult: CompanionRemoteSyncLoadResult?
    private var callCount = 0

    func load() async -> CompanionRemoteSyncLoadResult {
        callCount += 1
        if let bufferedResult {
            self.bufferedResult = nil
            return bufferedResult
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(returning result: CompanionRemoteSyncLoadResult) {
        guard let continuation else {
            bufferedResult = result
            return
        }
        self.continuation = nil
        continuation.resume(returning: result)
    }

    func count() -> Int {
        callCount
    }
}
