import ContextPanelCore
import ContextPanelWatchSupport
import Foundation
import Testing

@Test func watchCompanionCacheUsesProcessLocalApplicationSupport() {
    #expect(ContextPanelLocations.watchCompanionCacheURL().lastPathComponent == "context-panel-watch-cache.json")
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

private func watchCacheDocument(generatedAt: Date) -> CompanionSyncDocument {
    CompanionSyncDocument(snapshot: CompanionSnapshot(
        generatedAt: generatedAt,
        publishedAt: generatedAt.addingTimeInterval(5),
        limits: [],
        providerStatuses: [],
        promptCacheSummaries: []
    ))
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
