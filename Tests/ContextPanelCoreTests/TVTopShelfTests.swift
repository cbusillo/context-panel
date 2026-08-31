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

@Test func tvTopShelfRuntimeReceiptEvidenceIsPrivateStableAndStateful() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let firstDocument = TVTopShelfDocument(
        snapshot: makeRecoveredTopShelfSnapshot(now: now, identitySuffix: "-a"),
        mode: .fullDetail,
        now: now
    )
    let renamedDocument = TVTopShelfDocument(
        snapshot: makeRecoveredTopShelfSnapshot(now: now, identitySuffix: "-b"),
        mode: .fullDetail,
        now: now
    )
    let first = TVTopShelfRuntimeReceiptEvidence(
        document: firstDocument,
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let renamed = TVTopShelfRuntimeReceiptEvidence(
        document: renamedDocument,
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let actionChanged = TVTopShelfRuntimeReceiptEvidence(
        document: try mutatedTopShelfDocument(firstDocument) { cards in
            cards[0]["actionURLString"] = "contextpaneltv://ignored-action"
        },
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let sameCapacityBucket = TVTopShelfRuntimeReceiptEvidence(
        document: try mutatedTopShelfDocument(firstDocument) { cards in
            guard let index = cards.firstIndex(where: { $0["remainingPercent"] != nil }),
                  let remaining = cards[index]["remainingPercent"] as? Int else {
                return
            }
            cards[index]["remainingPercent"] = min((remaining / 5) * 5 + 4, 100)
        },
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let fullDocument = TVTopShelfDocument(
        snapshot: makeTopShelfSnapshot(now: now),
        mode: .fullDetail,
        now: now
    )
    let full = TVTopShelfRuntimeReceiptEvidence(
        document: fullDocument,
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let unrenderedCard = TVTopShelfRuntimeReceiptEvidence(
        document: try mutatedTopShelfDocument(fullDocument) { cards in
            cards.append(cards[0])
        },
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let countsOnly = TVTopShelfRuntimeReceiptEvidence(
        document: TVTopShelfDocument(
            snapshot: makeRecoveredTopShelfSnapshot(now: now),
            mode: .countsOnly,
            now: now
        ),
        loadedDocument: true,
        contentReturned: true,
        now: now
    )
    let stale = TVTopShelfRuntimeReceiptEvidence(
        document: firstDocument,
        loadedDocument: true,
        contentReturned: true,
        now: now.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 60)
    )
    let renderFailure = TVTopShelfRuntimeReceiptEvidence(
        document: firstDocument,
        loadedDocument: true,
        contentReturned: false,
        now: now
    )

    #expect(first.presentationDigest == renamed.presentationDigest)
    #expect(first.presentationDigest == actionChanged.presentationDigest)
    #expect(first.presentationDigest == sameCapacityBucket.presentationDigest)
    #expect(full.presentationDigest == unrenderedCard.presentationDigest)
    #expect(first.presentationDigest != countsOnly.presentationDigest)
    #expect(first.presentationDigest != stale.presentationDigest)
    #expect(first.selectedSource == .companionAppGroup)
    #expect(first.stateBranch == .ready)
    #expect(first.outcome == .success)
    #expect(stale.stateBranch == .stale)
    #expect(stale.outcome == .degraded)
    #expect(renderFailure.outcome == .failure)
}

@Test func tvTopShelfMissingRuntimeReceiptEvidenceIsStableAndDegraded() {
    let firstDate = Date(timeIntervalSince1970: 1_750_000_000)
    let secondDate = firstDate.addingTimeInterval(120)
    let first = TVTopShelfRuntimeReceiptEvidence(
        document: TVTopShelfDocument(
            snapshot: WidgetSnapshot(
                state: .setupNeeded,
                generatedAt: firstDate,
                limits: [],
                status: .unknown,
                message: "Waiting for your Mac."
            ),
            mode: .countsOnly,
            now: firstDate
        ),
        loadedDocument: false,
        contentReturned: true,
        now: firstDate
    )
    let second = TVTopShelfRuntimeReceiptEvidence(
        document: TVTopShelfDocument(
            snapshot: WidgetSnapshot(
                state: .setupNeeded,
                generatedAt: secondDate,
                limits: [],
                status: .unknown,
                message: "Waiting for your Mac."
            ),
            mode: .countsOnly,
            now: secondDate
        ),
        loadedDocument: false,
        contentReturned: true,
        now: secondDate
    )

    #expect(first.presentationDigest == second.presentationDigest)
    #expect(first.selectedSource == .none)
    #expect(first.stateBranch == .setupNeeded)
    #expect(first.outcome == .degraded)
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

@Test func tvTopShelfCardCountsOneAccountOnceAcrossGoogleWeeklyBuckets() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: makeGoogleAntigravityWeeklyLimits(
            accountID: "google-account",
            accountName: "Antigravity",
            thirdPartyUsed: 1,
            geminiUsed: 2,
            now: now
        ),
        status: .healthy,
        message: "Synced"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    let weeklyIndex = try #require(preferences.mainLimits.firstIndex {
        $0.provider == .google && $0.window == .weekly
    })
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: weeklyIndex), toOffset: 0)

    let document = TVTopShelfDocument(
        snapshot: snapshot,
        preferences: preferences,
        mode: .fullDetail,
        now: now
    )
    let google = try #require(document.cards.first { $0.provider == .google })

    #expect(google.headline == "99% left")
    #expect(google.remainingPercent == 99)
    #expect(google.detail.contains("99 of 100 points remaining"))
    #expect(!google.detail.contains("of 200 points"))
}

@Test func tvTopShelfPrioritizesBlockedAccessOverHealthyPooledCapacity() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let resetsAt = now.addingTimeInterval(3_600)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "blocked-claude",
                accountName: "Blocked Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Claude",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: resetsAt,
                lastUpdatedAt: now,
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "available-claude",
                accountName: "Available Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Claude",
                unit: .percent,
                used: 10,
                limit: 100,
                resetsAt: resetsAt,
                lastUpdatedAt: now,
                confidence: .observed
            ),
        ],
        reports: [
            StoredProviderReport(
                provider: .anthropic,
                accountID: "blocked-claude",
                accountName: "Blocked Claude",
                generatedAt: now,
                status: .limited,
                accessState: ProviderAccessState(kind: .blockedUntilReset, resetsAt: resetsAt),
                errorMessage: nil
            ),
            StoredProviderReport(
                provider: .anthropic,
                accountID: "available-claude",
                accountName: "Available Claude",
                generatedAt: now,
                status: .healthy,
                accessState: ProviderAccessState(kind: .available),
                errorMessage: nil
            ),
        ],
        status: .limited,
        message: "Claude limited"
    )
    #expect(snapshot.usageSnapshot.mainLimitSummaries.first { $0.provider == .anthropic }?.status == .healthy)

    let document = TVTopShelfDocument(snapshot: snapshot, mode: .fullDetail, now: now)
    let anthropic = try #require(document.cards.first { $0.provider == .anthropic })

    #expect(anthropic.status == .limited)
    #expect(anthropic.headline == "Claude limited")
    #expect(anthropic.remainingPercent == nil)
    #expect(anthropic.detail.contains("Usage credits unavailable"))
    #expect(!anthropic.title.contains("45% left"))
    #expect(!anthropic.detail.contains("Blocked Claude"))
}

@Test func tvTopShelfDistinguishesPaidFallbackFromBlockedAccess() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let resetsAt = now.addingTimeInterval(3_600)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "fallback-claude",
                accountName: "Fallback Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Claude",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: resetsAt,
                lastUpdatedAt: now,
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "available-claude",
                accountName: "Available Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Claude",
                unit: .percent,
                used: 10,
                limit: 100,
                resetsAt: resetsAt,
                lastUpdatedAt: now,
                confidence: .observed
            ),
        ],
        reports: [
            StoredProviderReport(
                provider: .anthropic,
                accountID: "fallback-claude",
                accountName: "Fallback Claude",
                generatedAt: now,
                status: .limited,
                accessState: ProviderAccessState(kind: .paidFallbackActive, resetsAt: resetsAt),
                errorMessage: nil
            ),
        ],
        status: .limited,
        message: "Claude using paid fallback"
    )

    let document = TVTopShelfDocument(snapshot: snapshot, mode: .fullDetail, now: now)
    let anthropic = try #require(document.cards.first { $0.provider == .anthropic })

    #expect(anthropic.status == .close)
    #expect(anthropic.headline == "Claude using paid fallback")
    #expect(anthropic.remainingPercent == nil)
    #expect(anthropic.detail.contains("Plan limit reached; usage credits available"))
    #expect(!anthropic.detail.contains("Fallback Claude"))
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
        version: TVCompanionSyncVersion(document: newerDocument),
        cloudKitUserScope: tvTestUserScope
    )
    let selectedAfterOlderCompletion = selection.select(
        snapshot: olderSnapshot,
        preferences: .defaultPreferences,
        version: TVCompanionSyncVersion(document: olderDocument),
        cloudKitUserScope: tvTestUserScope
    )

    #expect(selectedNewer.snapshot == newerSnapshot)
    #expect(selectedAfterOlderCompletion.snapshot == newerSnapshot)
    #expect(selectedAfterOlderCompletion.version == TVCompanionSyncVersion(document: newerDocument))
}

@Test func tvSystemSurfaceContentSelectionResetsWhenCloudKitUserChanges() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let olderSnapshot = makeTopShelfSnapshot(now: now)
    let newerSnapshot = makeRecoveredTopShelfSnapshot(now: now.addingTimeInterval(60))
    let otherScope = CompanionCloudKitUserScope.derive(
        containerIdentifier: ContextPanelLocations.iCloudContainerID,
        userRecordName: "tv-other-user"
    )
    var selection = TVSystemSurfaceContentSelection()

    _ = selection.select(
        snapshot: newerSnapshot,
        preferences: .defaultPreferences,
        version: TVCompanionSyncVersion(
            generatedAt: now.addingTimeInterval(60),
            publishedAt: now.addingTimeInterval(60)
        ),
        cloudKitUserScope: tvTestUserScope
    )
    let selected = selection.select(
        snapshot: olderSnapshot,
        preferences: .defaultPreferences,
        version: TVCompanionSyncVersion(generatedAt: now, publishedAt: now),
        cloudKitUserScope: otherScope
    )

    #expect(selected.snapshot == olderSnapshot)
    #expect(selected.cloudKitUserScope == otherScope)
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

    try store.save(
        document: newerDocument,
        receivedAt: newerReceivedAt,
        cloudKitUserScope: tvTestUserScope
    )
    try store.save(
        document: olderDocument,
        receivedAt: generatedAt.addingTimeInterval(180),
        cloudKitUserScope: tvTestUserScope
    )
    try store.save(
        document: newerDocument,
        receivedAt: generatedAt.addingTimeInterval(90),
        cloudKitUserScope: tvTestUserScope
    )

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
        receivedAt: startedAt.addingTimeInterval(5),
        cloudKitUserScope: tvTestUserScope
    )
    let earlierReceipt = TVSyncReceipt(
        document: startingDocument,
        receivedAt: startedAt.addingTimeInterval(-5),
        cloudKitUserScope: tvTestUserScope
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
    #expect(TVAppRoute(url: TVAppRoute.validationGallery.url) == .validationGallery)
    #expect(TVAppRoute(url: URL(string: "contextpaneltv://provider/not-a-provider")!) == nil)
    for invalidGalleryURL in [
        "contextpaneltv://validation-gallery/extra",
        "contextpaneltv://validation-gallery?payload=private",
        "contextpaneltv://validation-gallery?",
        "contextpaneltv://validation-gallery#private",
        "contextpaneltv://operator@validation-gallery",
        "contextpaneltv://operator:private@validation-gallery",
        "contextpaneltv://validation-gallery:443",
    ] {
        #expect(TVAppRoute(url: URL(string: invalidGalleryURL)!) == nil)
    }
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
    let document = TVTopShelfDocument(
        snapshot: makeTopShelfSnapshot(now: now),
        mode: .projectOnly,
        cloudKitUserScope: tvTestUserScope,
        now: now
    )

    try store.save(document)
    #expect(store.load(expectedScope: tvTestUserScope) == document)

    let data = try Data(contentsOf: documentURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = TVTopShelfDocument.schemaVersion + 1
    try JSONSerialization.data(withJSONObject: object).write(to: documentURL, options: .atomic)
    #expect(store.load(expectedScope: tvTestUserScope) == nil)
}

@Test func tvTopShelfDocumentStoreRejectsAndPurgesAnotherUsersDocument() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-top-shelf-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let documentURL = directory.appending(path: "top-shelf.json")
    let imageDirectoryURL = directory.appending(path: "Top Shelf", directoryHint: .isDirectory)
    let store = TVTopShelfDocumentStore(
        documentURL: documentURL,
        imageDirectoryURL: imageDirectoryURL
    )
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = TVTopShelfDocument(
        snapshot: makeTopShelfSnapshot(now: now),
        mode: .countsOnly,
        cloudKitUserScope: tvTestUserScope,
        now: now
    )
    let otherScope = CompanionCloudKitUserScope.derive(
        containerIdentifier: ContextPanelLocations.iCloudContainerID,
        userRecordName: "tv-other-user"
    )

    try store.save(document)
    try FileManager.default.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
    try Data("foreign-image".utf8).write(to: imageDirectoryURL.appending(path: "foreign.png"))
    #expect(store.load(expectedScope: otherScope) == nil)
    #expect(!FileManager.default.fileExists(atPath: documentURL.path))
    #expect(!FileManager.default.fileExists(atPath: imageDirectoryURL.path))
}

@Test func tvTopShelfDocumentStorePurgesUndecodableDocumentAndImages() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-top-shelf-corrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let documentURL = directory.appending(path: "top-shelf.json")
    let imageDirectoryURL = directory.appending(path: "Top Shelf", directoryHint: .isDirectory)
    let store = TVTopShelfDocumentStore(
        documentURL: documentURL,
        imageDirectoryURL: imageDirectoryURL
    )
    try FileManager.default.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: documentURL, options: .atomic)
    try Data("stale-image".utf8).write(to: imageDirectoryURL.appending(path: "stale.png"))

    #expect(store.load(expectedScope: tvTestUserScope) == nil)
    #expect(!FileManager.default.fileExists(atPath: documentURL.path))
    #expect(!FileManager.default.fileExists(atPath: imageDirectoryURL.path))
}

@Test func tvTopShelfSharedLocationsUseTheCompanionAppGroupContainer() {
    let containerURL = URL(fileURLWithPath: "/group", isDirectory: true)
    let locations = TVTopShelfSharedLocations(containerURL: containerURL)

    #expect(locations.rootDirectory.path == "/group/Library/Caches/Context Panel/TV")
    #expect(locations.documentURL.path == "/group/Library/Caches/Context Panel/TV/top-shelf.json")
    #expect(locations.imageDirectoryURL.path == "/group/Library/Caches/Context Panel/TV/Top Shelf")
    #expect(locations.cloudKitUserScopeStateURL.path == "/group/Library/Caches/Context Panel/TV/cloudkit-user-scope.json")
}

@Test func tvAsyncDeadlineReturnsWithoutWaitingForANonCooperativeOperation() async {
    let blocker = TVDeadlineBlocker()
    let clock = ContinuousClock()
    let startedAt = clock.now

    let value = await TVAsyncDeadline.value(timeout: .milliseconds(20)) {
        await blocker.wait()
    }

    #expect(value == nil)
    #expect(startedAt.duration(to: clock.now) < .seconds(10))
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
    #expect(!TVCloudKitNotificationPolicy.accepts(
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
        currentUserRecordName: "current-user"
    ))
    #expect(!TVCloudKitNotificationPolicy.accepts(
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
    #expect(source.contains("return TVTopShelfInsetContent(items: [item])"))
    #expect(source.contains("let requestedSize = TVTopShelfInsetContent.imageSize"))
    #expect(source.contains("let action = TVTopShelfAction(url: TVAppRoute.runway.url)"))
    #expect(source.contains("item.title = semanticTitle(document: document, cards: cards, now: now)"))
    #expect(source.contains("TVTopShelfRenderer(imageDirectory: locations.imageDirectoryURL)"))
    #expect(!source.contains("TVTopShelfSectionedContent"))
    #expect(!source.contains("[.screenScale1x, .screenScale2x]"))
    #expect(!source.contains("fileManager.urls(for: .cachesDirectory"))
}

@Test func tvRetiredProviderBadgeCleanupClearsStoredStateAndReturnsZeroBadgeCount() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-badge-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "ContextPanelTVBadgeCleanupTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let alertStateURL = directory.appending(path: "provider-alert-state.json")
    try Data("retired-state".utf8).write(to: alertStateURL)
    defaults.set(true, forKey: TVRetiredProviderBadgeCleanup.badgesPreferenceKey)
    var removedRequestIdentifiers: [[String]] = []
    let cleanup = TVRetiredProviderBadgeCleanup(providerAlertStateURL: alertStateURL)

    #expect(TVRetiredProviderBadgeCleanup.expiryRequestIdentifier == "context-panel-provider-badge-expiry")
    #expect(TVRetiredProviderBadgeCleanup.badgesPreferenceKey == "tv-provider-badges-enabled")
    let badgeCount = cleanup.perform(
        defaults: defaults,
        removePendingNotificationRequests: { removedRequestIdentifiers.append($0) }
    )

    #expect(badgeCount == 0)
    #expect(removedRequestIdentifiers == [[TVRetiredProviderBadgeCleanup.expiryRequestIdentifier]])
    #expect(defaults.object(forKey: TVRetiredProviderBadgeCleanup.badgesPreferenceKey) == nil)
    #expect(!FileManager.default.fileExists(atPath: alertStateURL.path))

    let repeatedBadgeCount = cleanup.perform(
        defaults: defaults,
        removePendingNotificationRequests: { removedRequestIdentifiers.append($0) }
    )
    #expect(repeatedBadgeCount == 0)
    #expect(removedRequestIdentifiers == [
        [TVRetiredProviderBadgeCleanup.expiryRequestIdentifier],
        [TVRetiredProviderBadgeCleanup.expiryRequestIdentifier],
    ])
}

@Test func tvOSAppDelegateDoesNotScheduleReplacementProviderBadgeNotifications() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelTV/TVSystemSurfaces.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("TVRetiredProviderBadgeCleanup("))
    #expect(source.contains("notificationCenter.setBadgeCount(badgeCount)"))
    #expect(!source.contains("UNTimeIntervalNotificationTrigger"))
    #expect(!source.contains(".badge"))
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
    )).bound(to: tvTestUserScope)
}

private let tvTestUserScope = CompanionCloudKitUserScope.derive(
    containerIdentifier: ContextPanelLocations.iCloudContainerID,
    userRecordName: "tv-test-user"
)

private func mutatedTopShelfDocument(
    _ document: TVTopShelfDocument,
    mutate: (inout [[String: Any]]) -> Void
) throws -> TVTopShelfDocument {
    let data = try JSONEncoder().encode(document)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var cards = try #require(object["cards"] as? [[String: Any]])
    mutate(&cards)
    object["cards"] = cards
    return try JSONDecoder().decode(
        TVTopShelfDocument.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func makeRecoveredTopShelfSnapshot(
    now: Date,
    identitySuffix: String = ""
) -> WidgetSnapshot {
    WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai\(identitySuffix)",
                configuredAccountID: "openai\(identitySuffix)",
                accountName: "OpenAI\(identitySuffix)",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 20,
                limit: 100,
                statusOverride: .healthy
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic\(identitySuffix)",
                configuredAccountID: "anthropic\(identitySuffix)",
                accountName: "Anthropic\(identitySuffix)",
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
