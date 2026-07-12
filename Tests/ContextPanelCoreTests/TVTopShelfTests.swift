import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import Testing

@Test func tvTopShelfDocumentExcludesAccountIdentityInEveryMode() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = makeTopShelfSnapshot(now: now)

    for mode in TVPresentationMode.allCases {
        let document = TVTopShelfDocument(snapshot: snapshot, mode: mode, now: now)
        let encoded = try JSONEncoder().encode(document)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(!json.contains("Private Account"))
        #expect(!json.contains("private-account-id"))
        #expect(document.cards.map(\.provider) == Provider.allCases.map(Optional.some))
        #expect(document.cards.allSatisfy { $0.actionURLString.hasPrefix("contextpaneltv://provider/") })
    }
}

@Test func tvTopShelfDocumentHonorsPresentationDetailWithoutChangingProviderCards() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = makeTopShelfSnapshot(now: now)
    let full = TVTopShelfDocument(snapshot: snapshot, mode: .fullDetail, now: now)
    let project = TVTopShelfDocument(snapshot: snapshot, mode: .projectOnly, now: now)
    let counts = TVTopShelfDocument(snapshot: snapshot, mode: .countsOnly, now: now)

    let fullOpenAI = try #require(full.cards.first { $0.provider == .openAI })
    let projectOpenAI = try #require(project.cards.first { $0.provider == .openAI })
    let countsOpenAI = try #require(counts.cards.first { $0.provider == .openAI })

    #expect(fullOpenAI.headline == projectOpenAI.headline)
    #expect(projectOpenAI.headline == countsOpenAI.headline)
    #expect(fullOpenAI.detail.contains("points remaining"))
    #expect(!projectOpenAI.detail.contains("points remaining"))
    #expect(!countsOpenAI.detail.contains("Resets"))
}

@Test func tvTopShelfDocumentUsesSavedPrimaryLane() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 85,
                limit: 100
            ),
        ],
        status: .close,
        message: "Synced"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    let fiveHourIndex = try #require(preferences.mainLimits.firstIndex {
        $0.provider == .openAI && $0.window == .fiveHour
    })
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: fiveHourIndex), toOffset: 0)

    let document = TVTopShelfDocument(
        snapshot: snapshot,
        preferences: preferences,
        mode: .countsOnly,
        now: now
    )
    let openAI = try #require(document.cards.first { $0.provider == .openAI })

    #expect(openAI.headline == "15% left")
    #expect(openAI.detail == "5-hour")
}

@Test func tvTopShelfDocumentKeepsActionableStatusWhenSavedPrimaryHasNoCapacity() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = TVTopShelfDocument(
        snapshot: makeTopShelfSnapshot(now: now),
        mode: .countsOnly,
        now: now
    )
    let anthropic = try #require(document.cards.first { $0.provider == .anthropic })

    #expect(anthropic.status == .failure)
    #expect(anthropic.headline == "Needs attention")
}

@Test func tvCompanionSyncCachePolicyKeepsTheNewestDocument() {
    let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let older = makeTVCompanionDocument(
        generatedAt: generatedAt,
        publishedAt: generatedAt
    )
    let newerGeneration = makeTVCompanionDocument(
        generatedAt: generatedAt.addingTimeInterval(60),
        publishedAt: generatedAt.addingTimeInterval(60)
    )
    let newerPublication = makeTVCompanionDocument(
        generatedAt: generatedAt,
        publishedAt: generatedAt.addingTimeInterval(30)
    )

    #expect(TVCompanionSyncCachePolicy.shouldKeepCurrent(
        CompanionSyncLoadResult(document: newerGeneration, status: .healthy),
        replacingWith: older
    ))
    #expect(!TVCompanionSyncCachePolicy.shouldKeepCurrent(
        CompanionSyncLoadResult(document: older, status: .healthy),
        replacingWith: newerGeneration
    ))
    #expect(TVCompanionSyncCachePolicy.shouldKeepCurrent(
        CompanionSyncLoadResult(document: newerPublication, status: .healthy),
        replacingWith: older
    ))
    #expect(TVCompanionSyncCachePolicy.shouldKeepCurrent(
        CompanionSyncLoadResult(document: older, status: .healthy),
        replacingWith: older
    ))
    #expect(!TVCompanionSyncCachePolicy.shouldKeepCurrent(
        CompanionSyncLoadResult(document: nil, status: .unknown),
        replacingWith: older
    ))
}

@Test func tvSystemSurfaceContentSelectionNeverRegressesToOlderData() {
    let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let olderDocument = makeTVCompanionDocument(
        generatedAt: generatedAt,
        publishedAt: generatedAt
    )
    let newerDocument = makeTVCompanionDocument(
        generatedAt: generatedAt.addingTimeInterval(60),
        publishedAt: generatedAt.addingTimeInterval(60)
    )
    let olderSnapshot = makeTopShelfSnapshot(now: generatedAt)
    let newerSnapshot = makeRecoveredTopShelfSnapshot(now: generatedAt.addingTimeInterval(60))
    var selection = TVSystemSurfaceContentSelection()

    let selectedNewer = selection.select(
        snapshot: newerSnapshot,
        preferences: .defaultPreferences,
        version: TVCompanionSyncVersion(document: newerDocument)
    )
    let selectedAfterOlderCompletion = selection.select(
        snapshot: olderSnapshot,
        preferences: .defaultPreferences,
        version: TVCompanionSyncVersion(document: olderDocument)
    )

    #expect(selectedNewer.snapshot == newerSnapshot)
    #expect(selectedAfterOlderCompletion.snapshot == newerSnapshot)
    #expect(selectedAfterOlderCompletion.version == TVCompanionSyncVersion(document: newerDocument))
}

@Test func tvSyncReceiptStoreNeverRegressesToAnOlderDocumentOrReceiptTime() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-receipt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TVSyncReceiptStore(receiptURL: root.appending(path: "receipt.json"))
    let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let olderDocument = makeTVCompanionDocument(
        generatedAt: generatedAt,
        publishedAt: generatedAt
    )
    let newerDocument = makeTVCompanionDocument(
        generatedAt: generatedAt.addingTimeInterval(60),
        publishedAt: generatedAt.addingTimeInterval(60)
    )
    let newerReceivedAt = generatedAt.addingTimeInterval(120)

    try store.save(document: newerDocument, receivedAt: newerReceivedAt)
    try store.save(document: olderDocument, receivedAt: generatedAt.addingTimeInterval(180))
    try store.save(document: newerDocument, receivedAt: generatedAt.addingTimeInterval(90))

    #expect(store.load(matching: olderDocument) == nil)
    #expect(store.load(matching: newerDocument)?.receivedAt == newerReceivedAt)
}

@Test func tvCompanionSyncAttemptPolicyRecognizesSupersedingCacheUpdates() {
    let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let startingDocument = makeTVCompanionDocument(
        generatedAt: startedAt.addingTimeInterval(-60),
        publishedAt: startedAt.addingTimeInterval(-60)
    )
    let newerDocument = makeTVCompanionDocument(
        generatedAt: startedAt,
        publishedAt: startedAt
    )
    let startingVersion = TVCompanionSyncVersion(document: startingDocument)
    let laterReceipt = TVSyncReceipt(
        document: startingDocument,
        receivedAt: startedAt.addingTimeInterval(5)
    )
    let earlierReceipt = TVSyncReceipt(
        document: startingDocument,
        receivedAt: startedAt.addingTimeInterval(-5)
    )

    #expect(TVCompanionSyncAttemptPolicy.cacheSupersedesAttempt(
        document: newerDocument,
        receipt: nil,
        startingVersion: startingVersion,
        startedAt: startedAt
    ))
    #expect(TVCompanionSyncAttemptPolicy.cacheSupersedesAttempt(
        document: startingDocument,
        receipt: laterReceipt,
        startingVersion: startingVersion,
        startedAt: startedAt
    ))
    #expect(!TVCompanionSyncAttemptPolicy.cacheSupersedesAttempt(
        document: startingDocument,
        receipt: earlierReceipt,
        startingVersion: startingVersion,
        startedAt: startedAt
    ))
    #expect(TVCompanionSyncAttemptPolicy.cacheSupersedesAttempt(
        document: newerDocument,
        receipt: nil,
        startingVersion: nil,
        startedAt: startedAt
    ))
}

@Test func tvAppRoutesRoundTripTopShelfURLs() throws {
    for provider in Provider.allCases {
        let route = TVAppRoute.provider(provider)
        #expect(TVAppRoute(url: route.url) == route)
    }
    #expect(TVAppRoute(url: TVAppRoute.runway.url) == .runway)
    #expect(TVAppRoute(url: URL(string: "contextpaneltv://provider/not-a-provider")!) == nil)
    #expect(TVAppRoute(url: URL(string: "https://example.com")!) == nil)
}

@Test func tvTopShelfDocumentKeepsStaleAndMissingStatesExplicit() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let fresh = TVTopShelfDocument(snapshot: makeTopShelfSnapshot(now: now), mode: .countsOnly, now: now)
    #expect(fresh.collectionTitle(at: now) == "Provider attention")
    #expect(!fresh.isStale(at: now))

    let later = now.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 1)
    #expect(fresh.isStale(at: later))
    #expect(fresh.collectionTitle(at: later) == "Saved provider runway")
    #expect(fresh.freshnessText(at: later).hasPrefix("Saved"))
    #expect(
        TVSnapshotFreshnessPolicy.expirationDate(generatedAt: now)
            == now.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge)
    )
    #expect(
        fresh.contentExpirationDate(at: now)
            == now.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge)
    )
    #expect(fresh.contentExpirationDate(at: later) == nil)

    let missing = WidgetSnapshot(
        state: .setupNeeded,
        generatedAt: now,
        limits: [],
        status: .unknown,
        message: "Waiting"
    )
    let missingDocument = TVTopShelfDocument(snapshot: missing, mode: .countsOnly, now: now)
    #expect(!missingDocument.containsProviderData)
    #expect(missingDocument.cards.count == 1)
    #expect(missingDocument.cards.first?.actionURLString == "contextpaneltv://runway")
}

@Test func tvTopShelfDocumentStoreRoundTripsAndRejectsUnsupportedSchema() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-top-shelf-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let documentURL = directory.appending(path: "top-shelf.json")
    let store = TVTopShelfDocumentStore(documentURL: documentURL)
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = TVTopShelfDocument(snapshot: makeTopShelfSnapshot(now: now), mode: .projectOnly, now: now)

    try store.save(document)
    #expect(store.load() == document)

    let data = try Data(contentsOf: documentURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = TVTopShelfDocument.schemaVersion + 1
    try JSONSerialization.data(withJSONObject: object).write(to: documentURL, options: .atomic)
    #expect(store.load() == nil)
}

@Test func tvTopShelfSharedLocationsUseTheCompanionAppGroupContainer() {
    let containerURL = URL(fileURLWithPath: "/group", isDirectory: true)
    let locations = TVTopShelfSharedLocations(containerURL: containerURL)

    #expect(locations.rootDirectory.path == "/group/Context Panel/TV")
    #expect(locations.documentURL.path == "/group/Context Panel/TV/top-shelf.json")
}

@Test func tvProviderAlertsCoalesceWorseningProvidersAndDeduplicateStableState() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = makeTopShelfSnapshot(now: now)
    let first = TVProviderAlertEvaluator.evaluate(snapshot: snapshot, previousState: .empty, now: now)

    #expect(first.attentionProviders == [.openAI, .anthropic])
    #expect(first.badgeCount == 2)
    #expect(first.events.map(\.provider) == [.openAI, .anthropic])

    let repeated = TVProviderAlertEvaluator.evaluate(
        snapshot: snapshot,
        previousState: first.state,
        now: now.addingTimeInterval(60)
    )
    #expect(repeated.badgeCount == 2)
    #expect(repeated.events.isEmpty)
}

@Test func tvProviderAlertsClearForRecoveredOrStaleData() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let attention = TVProviderAlertEvaluator.evaluate(
        snapshot: makeTopShelfSnapshot(now: now),
        previousState: .empty,
        now: now
    )
    let recovered = TVProviderAlertEvaluator.evaluate(
        snapshot: makeRecoveredTopShelfSnapshot(now: now.addingTimeInterval(60)),
        previousState: attention.state,
        now: now.addingTimeInterval(60)
    )
    #expect(recovered.badgeCount == 0)
    #expect(recovered.events.isEmpty)

    let staleSnapshot = WidgetSnapshot(
        state: .stale,
        generatedAt: now,
        limits: makeTopShelfSnapshot(now: now).limits,
        reports: makeTopShelfSnapshot(now: now).reports,
        status: .stale,
        message: "Saved data"
    )
    let stale = TVProviderAlertEvaluator.evaluate(
        snapshot: staleSnapshot,
        previousState: attention.state,
        now: now.addingTimeInterval(120)
    )
    #expect(stale.badgeCount == 0)
    #expect(stale.events.isEmpty)

    let agedReady = TVProviderAlertEvaluator.evaluate(
        snapshot: makeTopShelfSnapshot(now: now),
        previousState: attention.state,
        now: now.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 1)
    )
    #expect(agedReady.badgeCount == 0)
    #expect(agedReady.events.isEmpty)
}

@Test func tvAsyncDeadlineReturnsWithoutWaitingForANonCooperativeOperation() async {
    let blocker = TVDeadlineBlocker()
    let clock = ContinuousClock()
    let startedAt = clock.now

    let value = await TVAsyncDeadline.value(timeout: .milliseconds(20)) {
        await blocker.wait()
    }

    #expect(value == nil)
    #expect(startedAt.duration(to: clock.now) < .seconds(1))
    await blocker.resume(returning: 42)
}

@Test func tvAsyncDeadlineReturnsCompletedWork() async {
    let value = await TVAsyncDeadline.value(timeout: .seconds(1)) { 42 }
    #expect(value == 42)
}

@Test func tvCloudKitNotificationPolicyChecksSubscriptionContainerAndCurrentUser() {
    let expectedSubscriptionID = "companion-sync-updates"
    let expectedContainerIdentifier = "iCloud.com.example.contextpanel"
    let matching = TVCloudKitNotificationMetadata(
        subscriptionID: expectedSubscriptionID,
        containerIdentifier: expectedContainerIdentifier,
        subscriptionOwnerRecordName: "current-user"
    )
    #expect(TVCloudKitNotificationPolicy.accepts(
        matching,
        expectedSubscriptionID: expectedSubscriptionID,
        expectedContainerIdentifier: expectedContainerIdentifier,
        currentUserRecordName: "current-user"
    ))

    let prunedContainer = TVCloudKitNotificationMetadata(
        subscriptionID: expectedSubscriptionID,
        containerIdentifier: nil,
        subscriptionOwnerRecordName: "current-user"
    )
    #expect(TVCloudKitNotificationPolicy.accepts(
        prunedContainer,
        expectedSubscriptionID: expectedSubscriptionID,
        expectedContainerIdentifier: expectedContainerIdentifier,
        currentUserRecordName: "current-user"
    ))

    let missingOwner = TVCloudKitNotificationMetadata(
        subscriptionID: expectedSubscriptionID,
        containerIdentifier: expectedContainerIdentifier,
        subscriptionOwnerRecordName: nil
    )
    #expect(TVCloudKitNotificationPolicy.accepts(
        missingOwner,
        expectedSubscriptionID: expectedSubscriptionID,
        expectedContainerIdentifier: expectedContainerIdentifier,
        currentUserRecordName: nil
    ))

    let foreignOwner = TVCloudKitNotificationMetadata(
        subscriptionID: expectedSubscriptionID,
        containerIdentifier: expectedContainerIdentifier,
        subscriptionOwnerRecordName: "other-user"
    )
    #expect(!TVCloudKitNotificationPolicy.accepts(
        foreignOwner,
        expectedSubscriptionID: expectedSubscriptionID,
        expectedContainerIdentifier: expectedContainerIdentifier,
        currentUserRecordName: "current-user"
    ))

    let wrongSubscription = TVCloudKitNotificationMetadata(
        subscriptionID: "other-subscription",
        containerIdentifier: expectedContainerIdentifier,
        subscriptionOwnerRecordName: "current-user"
    )
    #expect(!TVCloudKitNotificationPolicy.accepts(
        wrongSubscription,
        expectedSubscriptionID: expectedSubscriptionID,
        expectedContainerIdentifier: expectedContainerIdentifier,
        currentUserRecordName: "current-user"
    ))

    let wrongContainer = TVCloudKitNotificationMetadata(
        subscriptionID: expectedSubscriptionID,
        containerIdentifier: "iCloud.com.example.other",
        subscriptionOwnerRecordName: "current-user"
    )
    #expect(!TVCloudKitNotificationPolicy.accepts(
        wrongContainer,
        expectedSubscriptionID: expectedSubscriptionID,
        expectedContainerIdentifier: expectedContainerIdentifier,
        currentUserRecordName: "current-user"
    ))
}

@Test func tvTopShelfProviderRegistersScaleTraitsSeparately() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelTVTopShelf/ContextPanelTVTopShelfProvider.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("item.setImageURL(oneXImageURL, for: .screenScale1x)"))
    #expect(source.contains("item.setImageURL(twoXImageURL, for: .screenScale2x)"))
    #expect(!source.contains("[.screenScale1x, .screenScale2x]"))
}

@Test func tvProviderBadgeExpiryUsesBadgeOnlyNotificationContent() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelTV/TVSystemSurfaces.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("content.badge = 0"))
    #expect(source.contains("context-panel-provider-badge-expiry"))
    #expect(!source.contains("content.title"))
    #expect(!source.contains("content.body"))
    #expect(!source.contains("content.sound"))
}

private actor TVDeadlineBlocker {
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

private func makeTopShelfSnapshot(now: Date) -> WidgetSnapshot {
    let limits = [
        UsageLimit(
            provider: .openAI,
            accountID: "private-account-id",
            configuredAccountID: "private-account-id",
            accountName: "Private Account",
            label: "OpenAI weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 100,
            limit: 100,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            statusOverride: .limited
        ),
        UsageLimit(
            provider: .google,
            accountID: "google-account",
            configuredAccountID: "google-account",
            accountName: "Private Google",
            label: "Gemini daily",
            windowLabel: "Daily",
            unit: .percent,
            used: 74,
            limit: 100,
            resetsAt: now.addingTimeInterval(8 * 60 * 60),
            statusOverride: .close
        ),
    ]
    let reports = [
        StoredProviderReport(
            provider: .anthropic,
            accountID: "anthropic-account",
            configuredAccountID: "anthropic-account",
            accountName: "Private Claude",
            generatedAt: now,
            status: .failure,
            errorMessage: "Reconnect required"
        ),
    ]
    return WidgetSnapshot(
        state: .failure,
        generatedAt: now,
        limits: limits,
        reports: reports,
        status: .failure,
        message: "One provider needs attention"
    )
}

private func makeTVCompanionDocument(
    generatedAt: Date,
    publishedAt: Date
) -> CompanionSyncDocument {
    CompanionSyncDocument(snapshot: CompanionSnapshot(
        generatedAt: generatedAt,
        publishedAt: publishedAt,
        limits: [],
        providerStatuses: [],
        promptCacheSummaries: []
    ))
}

private func makeRecoveredTopShelfSnapshot(now: Date) -> WidgetSnapshot {
    WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                configuredAccountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 20,
                limit: 100,
                statusOverride: .healthy
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic",
                configuredAccountID: "anthropic",
                accountName: "Anthropic",
                label: "Claude weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 25,
                limit: 100,
                statusOverride: .healthy
            ),
        ],
        status: .healthy,
        message: "Available"
    )
}
