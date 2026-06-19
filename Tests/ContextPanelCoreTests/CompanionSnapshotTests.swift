import Foundation
import Testing

@testable import ContextPanelCore
@testable import ContextPanelCompanionSupport

@Test func companionSnapshotOmitsSensitiveStoredFields() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "raw-provider-account-id",
                configuredAccountID: "configured-local-account-id",
                accountName: "Work OpenAI",
                label: "Codex weekly",
                windowLabel: "Weekly",
                modelLabel: "GPT-5.5",
                unit: .percent,
                used: 91,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(3_600),
                lastUpdatedAt: generatedAt,
                confidence: .observed,
                statusOverride: .close,
                note: "private local note"
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "raw-provider-account-id",
                configuredAccountID: "configured-local-account-id",
                accountName: "Work OpenAI",
                generatedAt: generatedAt,
                status: .failure,
                errorMessage: "Token sk-secret-123 read from /Users/chris/.code/auth.json failed"
            ),
        ],
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "prompt-cache-account-id",
                accountName: "Every Code",
                observedAt: generatedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
        ]
    )

    let companion = CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt.addingTimeInterval(5))
    let data = try JSONEncoder.contextPanelCompanionEncoder.encode(companion)
    let json = String(decoding: data, as: UTF8.self)

    #expect(json.contains("Work OpenAI"))
    #expect(json.contains("Codex weekly"))
    #expect(json.contains("Every Code"))
    #expect(json.contains("schemaVersion"))
    #expect(json.contains("companionAccountID"))
    #expect(json.contains("raw-provider-account-id") == false)
    #expect(json.contains("configured-local-account-id") == false)
    #expect(json.contains("prompt-cache-account-id") == false)
    #expect(json.contains("sk-secret-123") == false)
    #expect(json.contains("/Users/chris") == false)
    #expect(json.contains("private local note") == false)
    #expect(json.contains("accountID") == false)
    #expect(json.contains("configuredAccountID") == false)
    #expect(json.contains("errorMessage") == false)
    #expect(json.contains("note") == false)

    let roundTrip = try JSONDecoder.contextPanelCompanionDecoder.decode(CompanionSnapshot.self, from: data)
    #expect(roundTrip == companion)
    #expect(roundTrip.schemaVersion == CompanionSnapshot.schemaVersion)
    #expect(roundTrip.limits.first?.status == .close)
    #expect(roundTrip.providerStatuses.first?.status == .failure)
    #expect(roundTrip.promptCacheSummaries.first?.latestHitRate == 0.9)
}

@Test func companionSnapshotKeepsDuplicateAccountNamesDistinctWithSafeIDs() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_500)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "raw-account-a",
                configuredAccountID: "configured-account-a",
                accountName: "Work",
                label: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "raw-account-b",
                configuredAccountID: "configured-account-b",
                accountName: "Work",
                label: "Weekly",
                unit: .percent,
                used: 20,
                limit: 100
            ),
        ]),
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "cache-account-a",
                accountName: "Every Code",
                observedAt: generatedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
            PromptCacheObservation(
                provider: .openAI,
                accountID: "cache-account-b",
                accountName: "Every Code",
                observedAt: generatedAt.addingTimeInterval(1),
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 300)
            ),
        ]
    )

    let companion = CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt)

    #expect(companion.limits.map(\.accountName) == ["Work", "Work"])
    #expect(Set(companion.limits.map(\.companionAccountID)).count == 2)
    #expect(companion.promptCacheSummaries.map(\.accountName) == ["Every Code", "Every Code"])
    #expect(Set(companion.promptCacheSummaries.map(\.companionAccountID)).count == 2)
}

@Test func companionSnapshotSanitizesPathAndEmailDisplayNames() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_600)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "path-account",
                accountName: "/Users/chris/.code/auth.json",
                label: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "email-account",
                accountName: "chris@example.com",
                label: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
        ])
    )

    let data = try JSONEncoder.contextPanelCompanionEncoder.encode(
        CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt)
    )
    let json = String(decoding: data, as: UTF8.self)
    let roundTrip = try JSONDecoder.contextPanelCompanionDecoder.decode(CompanionSnapshot.self, from: data)

    #expect(json.contains("/Users/chris") == false)
    #expect(json.contains("chris@example.com") == false)
    #expect(roundTrip.limits.map(\.accountName).contains("auth.json"))
    #expect(roundTrip.limits.map(\.accountName).contains("[email redacted]"))
}

@Test func companionSnapshotStaysWithinLatestSnapshotSizeBudget() throws {
    let generatedAt = Date(timeIntervalSince1970: 2_000)
    let limits = (0..<75).map { index in
        UsageLimit(
            provider: Provider.allCases[index % Provider.allCases.count],
            accountID: "raw-account-\(index)",
            configuredAccountID: "configured-account-\(index)",
            accountName: "Account \(index)",
            label: "Window \(index)",
            windowLabel: index.isMultiple(of: 2) ? "Weekly" : "5h",
            modelLabel: index.isMultiple(of: 3) ? "Model \(index)" : nil,
            unit: .percent,
            used: index % 100,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(Double(index) * 60),
            lastUpdatedAt: generatedAt,
            confidence: .official
        )
    }
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: limits)
    )

    let data = try JSONEncoder.contextPanelCompanionEncoder.encode(
        CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt)
    )

    #expect(data.count < 500_000)
}

@Test func companionSyncStoreRoundTripsDocumentAndReportsStaleness() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let generatedAt = Date(timeIntervalSince1970: 3_000)
    let publishedAt = generatedAt.addingTimeInterval(60)
    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.setMainLimit(provider: .openAI, window: .fiveHour, isVisible: true)
    let forecastSettings = FastModeForecastSettings(
        defaultStandardBurnRateUnitsPerHour: 4,
        fastModeMultiplier: 3,
        reserveUnits: 8,
        minimumSafeHours: 2
    )
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: generatedAt),
        publishedAt: publishedAt,
        widgetDisplayPreferences: preferences,
        fastModeForecastSettings: forecastSettings
    )
    let store = CompanionSyncStore(documentURL: root.appending(path: "companion.json"))

    try store.save(document)

    let fresh = store.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 5 * 60), now: publishedAt.addingTimeInterval(10))
    #expect(fresh.document == document)
    #expect(fresh.status == .close)
    #expect(fresh.document?.widgetDisplayPreferences == preferences)
    #expect(fresh.document?.fastModeForecastSettings == forecastSettings)

    let stale = store.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 5 * 60), now: publishedAt.addingTimeInterval(10 * 60))
    #expect(stale.document == document)
    #expect(stale.status == .stale)
}

@Test func companionSyncStoreStalenessUsesSourceGenerationTime() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let generatedAt = Date(timeIntervalSince1970: 3_050)
    let publishedAt = generatedAt.addingTimeInterval(60 * 60)
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: generatedAt),
        publishedAt: publishedAt
    )
    let store = CompanionSyncStore(documentURL: root.appending(path: "companion.json"))

    try store.save(document)

    let result = store.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 5 * 60), now: publishedAt)
    #expect(result.document == document)
    #expect(result.status == .stale)
}

@Test func companionSyncStoreReplacesExistingDocumentThroughTemporarySibling() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = root.appending(path: "Companion/context-panel-companion.json")
    let store = CompanionSyncStore(documentURL: documentURL)
    let oldDate = Date(timeIntervalSince1970: 3_060)
    let newDate = Date(timeIntervalSince1970: 3_120)
    let oldDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: oldDate),
        publishedAt: oldDate
    )
    let newDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: newDate),
        publishedAt: newDate
    )

    try store.save(oldDocument)
    try store.save(newDocument)

    let result = store.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: newDate)
    let directoryContents = try FileManager.default.contentsOfDirectory(
        at: documentURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    #expect(result.document == newDocument)
    #expect(directoryContents.map(\.lastPathComponent) == ["context-panel-companion.json"])
}

@Test func companionSyncStoreStatusIncludesProviderFailuresWithoutLimits() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_075)
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: []),
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "raw-openai",
            configuredAccountID: "configured-openai",
            accountName: "Work OpenAI",
            generatedAt: now,
            status: .failure,
            errorMessage: "sk-secret should not sync"
        )]
    )
    let document = CompanionSyncDocument(storedSnapshot: stored, publishedAt: now)
    let store = CompanionSyncStore(documentURL: root.appending(path: "companion.json"))

    try store.save(document)

    let result = store.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: now)
    #expect(result.status == .failure)
    #expect(result.document?.snapshot.providerStatuses.first?.status == .failure)
}

@Test func companionSyncPresentationSeparatesSyncHealthFromLimitPressure() throws {
    let now = Date(timeIntervalSince1970: 3_080)
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: [
            companionUsageLimit(status: .limited, accountID: "openai-weekly"),
        ])
    )
    let document = CompanionSyncDocument(storedSnapshot: stored, publishedAt: now)

    let presentation = CompanionSyncPresentation(
        result: CompanionSyncLoadResult(document: document, status: .limited)
    )

    #expect(presentation.title == "Synced from Mac")
    #expect(presentation.detail == "Latest Mac snapshot received through iCloud.")
    #expect(presentation.symbol == "checkmark.icloud")
    #expect(presentation.usageSummary == "1 usage lane needs attention.")
    #expect(presentation.title.contains("Limited") == false)
    #expect(presentation.usageSummary?.contains("Limited") == false)
}

@Test func companionSyncPresentationSeparatesSyncHealthFromProviderFailures() throws {
    let now = Date(timeIntervalSince1970: 3_085)
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: []),
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "raw-openai",
            configuredAccountID: "configured-openai",
            accountName: "Work OpenAI",
            generatedAt: now,
            status: .failure,
            errorMessage: "Provider read failed"
        )]
    )
    let document = CompanionSyncDocument(storedSnapshot: stored, publishedAt: now)

    let presentation = CompanionSyncPresentation(
        result: CompanionSyncLoadResult(document: document, status: .failure)
    )

    #expect(presentation.title == "Synced from Mac")
    #expect(presentation.detail == "Latest Mac snapshot received through iCloud.")
    #expect(presentation.symbol == "checkmark.icloud")
    #expect(presentation.usageSummary == "1 provider needs attention on your Mac.")
}

@Test func companionSyncPresentationKeepsTransportFailuresSeparate() throws {
    let now = Date(timeIntervalSince1970: 3_088)
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )

    let presentation = CompanionSyncPresentation(
        result: CompanionSyncLoadResult(
            document: document,
            status: .failure,
            errorMessage: "app group mirror could not be updated"
        )
    )

    #expect(presentation.title == "Sync failed")
    #expect(presentation.detail == "app group mirror could not be updated")
    #expect(presentation.symbol == "icloud.slash")
    #expect(presentation.usageSummary == nil)
}

@Test func companionSyncPresentationUsesSyncProblemTitlesForTransportStates() {
    let stale = CompanionSyncPresentation(
        result: CompanionSyncLoadResult(document: nil, status: .stale)
    )
    let failure = CompanionSyncPresentation(
        result: CompanionSyncLoadResult(document: nil, status: .failure)
    )
    let unknown = CompanionSyncPresentation(
        result: CompanionSyncLoadResult(document: nil, status: .unknown)
    )

    #expect(stale.title == "Mac sync is stale")
    #expect(failure.title == "Sync failed")
    #expect(unknown.title == "Waiting for Mac sync")
}

@Test func companionSyncStoreStatusIsUnknownForEmptyDocument() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_090)
    let document = CompanionSyncDocument(
        snapshot: CompanionSnapshot(
            generatedAt: now,
            publishedAt: now,
            limits: [],
            providerStatuses: [],
            promptCacheSummaries: []
        )
    )
    let store = CompanionSyncStore(documentURL: root.appending(path: "companion.json"))

    try store.save(document)

    let result = store.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: now)
    #expect(result.status == .unknown)
}

@Test func companionSyncStoreSetFallsBackPastFailedMirror() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_100)
    let failedURL = root.appending(path: "failed.json")
    let reachableURL = root.appending(path: "reachable.json")
    try Data("not json".utf8).write(to: failedURL)
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )
    try CompanionSyncStore(documentURL: reachableURL).save(document)
    let storeSet = CompanionSyncStoreSet(stores: [
        CompanionSyncStore(documentURL: failedURL),
        CompanionSyncStore(documentURL: reachableURL),
    ])

    let result = storeSet.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: now)

    #expect(result.document == document)
    #expect(result.status == .close)
    #expect(result.errorMessage == nil)
}

@Test func companionSyncStoreSetChoosesFreshestAvailableMirror() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldGeneratedAt = Date(timeIntervalSince1970: 3_120)
    let newGeneratedAt = Date(timeIntervalSince1970: 3_300)
    let oldDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: oldGeneratedAt),
        publishedAt: oldGeneratedAt
    )
    let newDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: newGeneratedAt),
        publishedAt: newGeneratedAt
    )
    let oldStore = CompanionSyncStore(documentURL: root.appending(path: "old.json"))
    let newStore = CompanionSyncStore(documentURL: root.appending(path: "new.json"))
    try oldStore.save(oldDocument)
    try newStore.save(newDocument)
    let storeSet = CompanionSyncStoreSet(stores: [oldStore, newStore])

    let result = storeSet.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: newGeneratedAt)

    #expect(result.document == newDocument)
    #expect(result.status == .close)
}

@Test func companionSyncStoreSetPrefersFreshDocumentOverNewerStaleDocument() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staleGeneratedAt = Date(timeIntervalSince1970: 3_120)
    let freshGeneratedAt = Date(timeIntervalSince1970: 3_400)
    let staleDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: staleGeneratedAt),
        publishedAt: freshGeneratedAt.addingTimeInterval(10)
    )
    let freshDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: freshGeneratedAt),
        publishedAt: freshGeneratedAt
    )
    let staleStore = CompanionSyncStore(documentURL: root.appending(path: "stale.json"))
    let freshStore = CompanionSyncStore(documentURL: root.appending(path: "fresh.json"))
    try staleStore.save(staleDocument)
    try freshStore.save(freshDocument)
    let storeSet = CompanionSyncStoreSet(stores: [staleStore, freshStore])

    let result = storeSet.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: freshGeneratedAt)

    #expect(result.document == freshDocument)
    #expect(result.status == .close)
}

@Test func companionSyncStoreSetReportsPartialAndCompleteSaveFailures() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_500)
    let blockedFile = root.appending(path: "blocked")
    try Data().write(to: blockedFile)
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )
    let failingStore = CompanionSyncStore(documentURL: blockedFile.appending(path: "companion.json"))
    let reachableStore = CompanionSyncStore(documentURL: root.appending(path: "reachable/companion.json"))

    let partial = CompanionSyncStoreSet(stores: [failingStore, reachableStore]).save(document)
    #expect(partial.attemptedStoreCount == 2)
    #expect(partial.successfulStoreCount == 1)
    #expect(partial.succeeded)
    #expect(partial.failures.count == 1)
    #expect(partial.failures.first?.storeRole == "custom")
    #expect(partial.failures.first?.errorDomain.isEmpty == false)
    #expect(partial.failures.first?.errorCode != 0)
    #expect(partial.failures.first?.errorMessage.isEmpty == false)

    let complete = CompanionSyncStoreSet(stores: [failingStore]).save(document)
    #expect(complete.attemptedStoreCount == 1)
    #expect(complete.successfulStoreCount == 0)
    #expect(complete.succeeded == false)
    #expect(complete.failures.count == 1)
}

@Test func companionSyncStoreSetResolvesLazyMirrorsOnlyDuringOperations() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_520)
    let localURL = root.appending(path: "local/companion.json")
    let lazyURL = root.appending(path: "lazy/companion.json")
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )
    let resolveCount = LockedCounter()
    let storeSet = CompanionSyncStoreSet(
        stores: [CompanionSyncStore(documentURL: localURL)],
        lazyStores: [CompanionSyncStoreResolver {
            resolveCount.increment()
            return CompanionSyncStore(documentURL: lazyURL)
        }]
    )

    #expect(resolveCount.value == 0)

    let saveResult = storeSet.save(document)
    #expect(saveResult.attemptedStoreCount == 2)
    #expect(saveResult.successfulStoreCount == 2)
    #expect(resolveCount.value == 1)

    let loadResult = storeSet.load(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: now)
    #expect(loadResult.document == document)
    #expect(resolveCount.value == 2)
}

@Test func companionSyncLoaderMirrorsICloudDocumentIntoLocalAppGroupStore() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_540)
    let localURL = root.appending(path: "local/companion.json")
    let iCloudURL = root.appending(path: "icloud/companion.json")
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )
    try CompanionSyncStore(documentURL: iCloudURL).save(document)

    let result = CompanionSyncLoader.load(
        localMirrorURL: localURL,
        iCloudDocumentURL: iCloudURL,
        now: now
    )
    let mirrored = CompanionSyncLoader.loadWidgetMirror(localMirrorURL: localURL, now: now)

    #expect(result.document == document)
    #expect(result.status == .close)
    #expect(mirrored.document == document)
    #expect(mirrored.status == .close)
}

@Test func companionWidgetLoaderRefreshesStaleMirrorFromICloudDocument() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_545)
    let staleGeneratedAt = now.addingTimeInterval(-SnapshotFreshness.widgetMaximumAge - 30)
    let localURL = root.appending(path: "local/companion.json")
    let iCloudURL = root.appending(path: "icloud/companion.json")
    let staleDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: staleGeneratedAt),
        publishedAt: staleGeneratedAt
    )
    let freshDocument = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )
    try CompanionSyncStore(documentURL: localURL).save(staleDocument)
    try CompanionSyncStore(documentURL: iCloudURL).save(freshDocument)

    let result = CompanionSyncLoader.loadWidgetMirror(
        localMirrorURL: localURL,
        iCloudDocumentURL: iCloudURL,
        now: now
    )
    let mirrored = CompanionSyncStore(documentURL: localURL).load(
        policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge),
        now: now
    )

    #expect(result.document == freshDocument)
    #expect(result.status == .close)
    #expect(mirrored.document == freshDocument)
    #expect(mirrored.status == .close)
}

@Test func companionSyncLoaderReportsMirrorWriteFailures() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_550)
    let blockedFile = root.appending(path: "blocked")
    let localURL = blockedFile.appending(path: "companion.json")
    let iCloudURL = root.appending(path: "icloud/companion.json")
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: now),
        publishedAt: now
    )
    try Data().write(to: blockedFile)
    try CompanionSyncStore(documentURL: iCloudURL).save(document)

    let result = CompanionSyncLoader.load(
        localMirrorURL: localURL,
        iCloudDocumentURL: iCloudURL,
        now: now
    )

    #expect(result.document == document)
    #expect(result.status == .failure)
    #expect(result.errorMessage?.contains("app group mirror could not be updated") == true)
}

@Test func companionSyncLoaderRequiresResolvedAppGroupMirror() {
    let now = Date(timeIntervalSince1970: 3_560)

    let appLoad = CompanionSyncLoader.load(
        localMirrorURL: nil,
        iCloudDocumentURL: nil,
        now: now
    )
    let widgetLoad = CompanionSyncLoader.loadWidgetMirror(localMirrorURL: nil, now: now)

    #expect(appLoad.document == nil)
    #expect(appLoad.status == .failure)
    #expect(appLoad.errorMessage?.contains("app group is unavailable") == true)
    #expect(widgetLoad.document == nil)
    #expect(widgetLoad.status == .failure)
    #expect(widgetLoad.errorMessage?.contains("app group is unavailable") == true)
}

@Test func widgetSnapshotFromCompanionSyncReusesSyncedDisplayPayload() throws {
    let generatedAt = Date(timeIntervalSince1970: 3_200)
    let publishedAt = generatedAt.addingTimeInterval(5)
    let forecastSettings = FastModeForecastSettings(
        defaultStandardBurnRateUnitsPerHour: 6,
        fastModeMultiplier: 2.5,
        reserveUnits: 9,
        minimumSafeHours: 1.5
    )
    let document = CompanionSyncDocument(
        storedSnapshot: companionStoredSnapshot(generatedAt: generatedAt),
        publishedAt: publishedAt,
        fastModeForecastSettings: forecastSettings
    )

    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: document, status: .close),
        now: publishedAt
    )

    #expect(widget.state == .ready)
    #expect(widget.status == .close)
    #expect(widget.generatedAt == generatedAt)
    #expect(widget.fastModeForecastSettings == forecastSettings)
    #expect(widget.limits.count == 1)
    #expect(widget.limits.first?.accountName == "Work OpenAI")
    #expect(widget.limits.first?.accountID != "raw-openai")
    #expect(widget.limits.first?.configuredAccountID == widget.limits.first?.accountID)
    #expect(widget.reports.first?.accountID == widget.limits.first?.accountID)
    #expect(widget.reports.first?.errorMessage == nil)
    #expect(widget.promptCacheObservations.first?.accountID == widget.limits.first?.accountID)
    #expect(widget.promptCacheWidgetState == .available)
    #expect(widget.promptCacheSummary.latestHitRate == 0.9)
    #expect(widget.message == "You're good to keep working.")
}

@Test func widgetSnapshotFromCompanionSyncUsesProvidedStalenessPolicy() throws {
    let savedAt = Date(timeIntervalSince1970: 3_200)
    let expiredAt = savedAt.addingTimeInterval(60)
    let expiredLimit = UsageLimit(
        provider: .openAI,
        accountID: "openai",
        configuredAccountID: "openai",
        accountName: "OpenAI",
        label: "Weekly",
        unit: .percent,
        used: 100,
        limit: 100,
        resetsAt: expiredAt,
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
    let snapshot = UsageSnapshot(generatedAt: savedAt, limits: [expiredLimit])
    let document = CompanionSyncDocument(
        storedSnapshot: StoredUsageSnapshot(savedAt: savedAt, snapshot: snapshot),
        publishedAt: savedAt
    )
    let companionSnapshot = UsageSnapshot(
        generatedAt: document.snapshot.generatedAt,
        limits: document.snapshot.limits.map(\.usageLimit)
    )
    var resetState = ResetExpiryRefreshState()
    resetState.recordAttempt(
        previousSnapshot: companionSnapshot,
        refreshedSnapshot: companionSnapshot,
        attemptedAt: expiredAt.addingTimeInterval(10)
    )

    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: document, status: .stale),
        now: expiredAt.addingTimeInterval(20),
        stalenessPolicy: SnapshotStoreStalenessPolicy(
            maximumAge: SnapshotFreshness.widgetMaximumAge,
            resetExpiryRefreshState: resetState
        )
    )

    #expect(widget.refreshAttentionSummary == nil)
    #expect(widget.message == "Refresh Context Panel to update data.")
}

@Test func widgetSnapshotFromMissingCompanionSyncAsksForMacSync() {
    let now = Date(timeIntervalSince1970: 3_300)

    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown),
        now: now
    )

    #expect(widget.state == .setupNeeded)
    #expect(widget.generatedAt == now)
    #expect(widget.message == "Sync Context Panel from your Mac.")
}

@Test func companionSyncPublisherIncludesCurrentPreferencesAndForecastSettings() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let generatedAt = Date(timeIntervalSince1970: 3_400)
    let publishedAt = generatedAt.addingTimeInterval(20)
    let preferencesURL = root.appending(path: "preferences.json")
    let settingsURL = root.appending(path: "forecast.json")
    let companionURL = root.appending(path: "companion.json")
    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: 6), toOffset: 0)
    let forecastSettings = FastModeForecastSettings(
        defaultStandardBurnRateUnitsPerHour: 5,
        fastModeMultiplier: 4,
        reserveUnits: 12,
        minimumSafeHours: 3
    )
    try WidgetDisplayPreferencesStore(preferencesURL: preferencesURL).save(preferences)
    try FastModeForecastSettingsStore(settingsURL: settingsURL).save(forecastSettings)
    let publisher = CompanionSyncPublisher(
        stores: CompanionSyncStoreSet(stores: [CompanionSyncStore(documentURL: companionURL)]),
        widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: preferencesURL),
        fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: settingsURL)
    )

    publisher.publish(storedSnapshot: companionStoredSnapshot(generatedAt: generatedAt), publishedAt: publishedAt)

    let result = CompanionSyncStore(documentURL: companionURL).load()
    #expect(result.document?.snapshot.generatedAt == generatedAt)
    #expect(result.document?.snapshot.publishedAt == publishedAt)
    #expect(result.document?.widgetDisplayPreferences == preferences)
    #expect(result.document?.fastModeForecastSettings == forecastSettings)
}

@Test func snapshotRefreshServicePublishesCompanionSyncAfterSavingSnapshot() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let savedAt = Date(timeIntervalSince1970: 3_500)
    let primary = JSONSnapshotStore(rootDirectory: root.appending(path: "snapshots", directoryHint: .isDirectory))
    let companionURL = root.appending(path: "companion.json")
    let publisher = CompanionSyncPublisher(
        stores: CompanionSyncStoreSet(stores: [CompanionSyncStore(documentURL: companionURL)]),
        widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "preferences.json")),
        fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json"))
    )
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")),
        stores: SnapshotRefreshStores(primary: primary),
        companionSyncPublisher: publisher,
        promptCacheTelemetryReader: { _ in [] }
    )
    let report = ProviderConnectorReport(
        provider: .openAI,
        accountID: "raw-openai",
        configuredAccountID: "configured-openai",
        accountName: "Work OpenAI",
        generatedAt: savedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: "raw-openai",
            configuredAccountID: "configured-openai",
            accountName: "Work OpenAI",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 94,
            limit: 100,
            statusOverride: .close
        )],
        status: .close
    )

    _ = try service.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: savedAt, reports: [report]),
        savedAt: savedAt
    )

    let result = CompanionSyncStore(documentURL: companionURL).load()
    #expect(primary.loadCurrent().snapshot?.snapshot.limits.first?.accountID == "raw-openai")
    #expect(result.document?.snapshot.publishedAt == savedAt)
    #expect(result.document?.snapshot.limits.first?.accountName == "Work OpenAI")
    #expect(result.document?.snapshot.limits.first?.companionAccountID != "raw-openai")
}

private func companionStoredSnapshot(generatedAt: Date) -> StoredUsageSnapshot {
    StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "raw-openai",
                configuredAccountID: "configured-openai",
                accountName: "Work OpenAI",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 91,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(7 * 24 * 3_600),
                lastUpdatedAt: generatedAt,
                confidence: .observed,
                statusOverride: .close
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "raw-openai",
                configuredAccountID: "configured-openai",
                accountName: "Work OpenAI",
                generatedAt: generatedAt,
                status: .close,
                errorMessage: "sk-secret should not sync"
            ),
        ],
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "raw-openai",
                accountName: "Work OpenAI",
                observedAt: generatedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
        ]
    )
}

private func companionUsageLimit(status: UsageStatus, accountID: String) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: accountID,
        configuredAccountID: accountID,
        accountName: "Work OpenAI",
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: status == .limited ? 100 : 90,
        limit: 100,
        statusOverride: status
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-companion-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock {
            storedValue += 1
        }
    }
}

private extension JSONEncoder {
    static var contextPanelCompanionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var contextPanelCompanionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
