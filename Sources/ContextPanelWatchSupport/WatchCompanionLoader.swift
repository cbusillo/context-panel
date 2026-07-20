import ContextPanelCore
import Foundation

public actor WatchCompanionLoader {
    private let cache: WatchCompanionCache
    private let timeout: Duration
    private let loadDocument: @Sendable (Date) async -> CompanionRemoteSyncLoadResult
    private let loadPresentation: @Sendable () async -> CompanionPresentationRemoteLoadResult
    private var inFlightLoad: Task<WatchCompanionCacheLoadResult, Never>?

    public init(
        cache: WatchCompanionCache = WatchCompanionCache(),
        timeout: Duration = .seconds(5),
        loadDocument: @escaping @Sendable (Date) async -> CompanionRemoteSyncLoadResult,
        loadPresentation: @escaping @Sendable () async -> CompanionPresentationRemoteLoadResult
    ) {
        self.cache = cache
        self.timeout = timeout
        self.loadDocument = loadDocument
        self.loadPresentation = loadPresentation
    }

    public func load(now: Date = Date()) async -> WatchCompanionCacheLoadResult {
        if let inFlightLoad {
            return await inFlightLoad.value
        }
        let cached = cache.load(now: now)
        let timeout = timeout
        let loadDocument = loadDocument
        let loadPresentation = loadPresentation
        let inFlightLoad = Task {
            await Self.performLoad(
                cached: cached,
                cache: cache,
                timeout: timeout,
                now: now,
                loadDocument: loadDocument,
                loadPresentation: loadPresentation
            )
        }
        self.inFlightLoad = inFlightLoad
        let result = await inFlightLoad.value
        self.inFlightLoad = nil
        return result
    }

    private static func performLoad(
        cached: WatchCompanionCacheLoadResult,
        cache: WatchCompanionCache,
        timeout: Duration,
        now: Date,
        loadDocument: @escaping @Sendable (Date) async -> CompanionRemoteSyncLoadResult,
        loadPresentation: @escaping @Sendable () async -> CompanionPresentationRemoteLoadResult
    ) async -> WatchCompanionCacheLoadResult {
        async let remoteDocument = WatchAsyncDeadline.value(timeout: timeout) {
            await loadDocument(now)
        }
        async let remotePresentation = WatchAsyncDeadline.value(timeout: timeout) {
            await loadPresentation()
        }
        let (documentLoad, presentationLoad) = await (remoteDocument, remotePresentation)

        guard let documentLoad else {
            return fallback(
                cached: cached,
                errorMessage: "Context Panel Watch timed out while refreshing usage."
            )
        }
        if documentLoad.outcome.missingRecord {
            switch cache.removeIfCurrent(
                cached,
                now: now
            ) {
            case let .keptCurrent(current):
                return current
            case .failed:
                return fallback(
                    cached: cached,
                    errorMessage: "Context Panel Watch could not clear saved usage."
                )
            case .removed:
                break
            }
            return WatchCompanionCacheLoadResult(
                result: documentLoad.result,
                displayPreferences: presentationLoad?.document?.widgetDisplayPreferences
            )
        }
        guard let document = documentLoad.result.document else {
            if documentLoad.outcome.succeeded {
                return WatchCompanionCacheLoadResult(
                    result: documentLoad.result,
                    displayPreferences: presentationLoad?.document?.widgetDisplayPreferences
                        ?? cached.displayPreferences
                )
            }
            return fallback(
                cached: cached,
                errorMessage: documentLoad.result.errorMessage
                    ?? "Context Panel Watch could not refresh usage."
            )
        }

        let selectedDocument = document.mergingForRemotePublish(existing: cached.result.document)
        let selectedResult: CompanionSyncLoadResult
        if selectedDocument == cached.result.document {
            selectedResult = cached.result
        } else {
            selectedResult = CompanionSyncLoadResult(
                document: selectedDocument,
                status: selectedDocument.companionStatus(
                    now: now,
                    maximumAge: SnapshotFreshness.companionProviderMaximumAge
                ),
                errorMessage: documentLoad.result.errorMessage,
                transportMetadata: documentLoad.result.transportMetadata,
                transportStatuses: documentLoad.result.transportStatuses
            )
        }
        let displayPreferences: WidgetDisplayPreferences
        let displayPreferencesUpdatedAt: Date?
        if let presentationDocument = presentationLoad?.document {
            displayPreferences = WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: presentationDocument.widgetDisplayPreferences,
                synced: selectedDocument.widgetDisplayPreferences
            )
            displayPreferencesUpdatedAt = presentationDocument.updatedAt
        } else if presentationLoad?.outcome.succeeded == true,
                  presentationLoad?.outcome.missingRecord == true {
            displayPreferences = selectedDocument.widgetDisplayPreferences
            displayPreferencesUpdatedAt = now
        } else {
            displayPreferences = WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: cached.displayPreferences,
                synced: selectedDocument.widgetDisplayPreferences
            )
            displayPreferencesUpdatedAt = cached.displayPreferencesUpdatedAt
        }
        let saveOutcome = cache.saveSelectingNewest(
            document: selectedDocument,
            displayPreferences: displayPreferences,
            displayPreferencesUpdatedAt: displayPreferencesUpdatedAt,
            now: now
        )
        switch saveOutcome {
        case let .keptCurrent(current):
            return current
        case let .saved(saved) where saved.result.document != selectedDocument:
            return saved
        case .saved, .failed:
            break
        }
        return WatchCompanionCacheLoadResult(
            result: selectedResult,
            displayPreferences: displayPreferences
        )
    }

    private static func fallback(
        cached: WatchCompanionCacheLoadResult,
        errorMessage: String
    ) -> WatchCompanionCacheLoadResult {
        guard let document = cached.result.document else {
            return WatchCompanionCacheLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: errorMessage
                ),
                displayPreferences: cached.displayPreferences
            )
        }
        return WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(
                document: document,
                status: .stale,
                errorMessage: errorMessage,
                transportMetadata: CompanionSyncTransportMetadata(
                    source: cached.result.transportMetadata?.source ?? .localCache,
                    receivedAt: cached.result.transportMetadata?.receivedAt,
                    mirroredAt: cached.result.transportMetadata?.mirroredAt,
                    deliveryStatus: .delayed
                )
            ),
            displayPreferences: cached.displayPreferences
        )
    }
}

public enum WatchComplicationTimelineReloadPolicy {
    public static func shouldReload(after loaded: WatchCompanionCacheLoadResult) -> Bool {
        loaded.result.document != nil
    }
}
