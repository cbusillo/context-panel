import ContextPanelCore
import Foundation

private enum WatchUserScopeResolution: Sendable {
    case resolved(CompanionCloudKitUserScope)
    case unavailable
    case transientFailure
    case timedOut
}

public actor WatchCompanionLoader {
    private let cache: WatchCompanionCache
    private let timeout: Duration
    private let resolveUserScope: @Sendable () async -> CompanionRemoteUserScopeResolution
    private let loadDocument: @Sendable (Date) async -> CompanionRemoteSyncLoadResult
    private let loadPresentation: @Sendable () async -> CompanionPresentationRemoteLoadResult
    private var inFlightLoad: InFlightLoad?

    public init(
        cache: WatchCompanionCache = WatchCompanionCache(),
        timeout: Duration = .seconds(5),
        resolveUserScope: @escaping @Sendable () async -> CompanionCloudKitUserScope?,
        loadDocument: @escaping @Sendable (Date) async -> CompanionRemoteSyncLoadResult,
        loadPresentation: @escaping @Sendable () async -> CompanionPresentationRemoteLoadResult
    ) {
        self.cache = cache
        self.timeout = timeout
        self.resolveUserScope = {
            guard let userScope = await resolveUserScope() else { return .unavailable }
            return .resolved(userScope)
        }
        self.loadDocument = loadDocument
        self.loadPresentation = loadPresentation
    }

    public init(
        cache: WatchCompanionCache = WatchCompanionCache(),
        timeout: Duration = .seconds(5),
        resolveUserScopeResolution: @escaping @Sendable () async -> CompanionRemoteUserScopeResolution,
        loadDocument: @escaping @Sendable (Date) async -> CompanionRemoteSyncLoadResult,
        loadPresentation: @escaping @Sendable () async -> CompanionPresentationRemoteLoadResult
    ) {
        self.cache = cache
        self.timeout = timeout
        resolveUserScope = resolveUserScopeResolution
        self.loadDocument = loadDocument
        self.loadPresentation = loadPresentation
    }

    public func load(now: Date = Date()) async -> WatchCompanionCacheLoadResult {
        let initialScopeResolution = await Self.resolveUserScope(
            resolveUserScope,
            timeout: timeout
        )
        let userScope: CompanionCloudKitUserScope
        switch initialScopeResolution {
        case let .resolved(resolvedScope):
            userScope = resolvedScope
        case .unavailable:
            _ = cache.invalidateUserScope()
            return Self.identityUnavailableResult()
        case .transientFailure, .timedOut:
            return Self.identityResolutionTimedOutResult()
        }
        if let inFlightLoad,
           inFlightLoad.userScope == userScope {
            return await inFlightLoad.task.value
        }
        let cached = cache.load(expectedScope: userScope, now: now)
        let timeout = timeout
        let resolveUserScope = resolveUserScope
        let loadDocument = loadDocument
        let loadPresentation = loadPresentation
        let loadID = UUID()
        let task = Task {
            await Self.performLoad(
                cached: cached,
                cache: cache,
                timeout: timeout,
                userScope: userScope,
                now: now,
                resolveUserScope: resolveUserScope,
                loadDocument: loadDocument,
                loadPresentation: loadPresentation
            )
        }
        inFlightLoad = InFlightLoad(
            id: loadID,
            userScope: userScope,
            task: task
        )
        let result = await task.value
        if inFlightLoad?.id == loadID {
            inFlightLoad = nil
        }
        return result
    }

    private static func performLoad(
        cached: WatchCompanionCacheLoadResult,
        cache: WatchCompanionCache,
        timeout: Duration,
        userScope: CompanionCloudKitUserScope,
        now: Date,
        resolveUserScope: @escaping @Sendable () async -> CompanionRemoteUserScopeResolution,
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

        let firstScopeRecheck = await Self.resolveUserScope(resolveUserScope, timeout: timeout)
        switch firstScopeRecheck {
        case let .resolved(resolvedScope) where resolvedScope == userScope:
            break
        case .transientFailure, .timedOut:
            return identityResolutionTimedOutResult()
        case .unavailable, .resolved:
            _ = cache.invalidateUserScope()
            return identityChangedResult()
        }

        guard let documentLoad else {
            return fallback(
                cached: cached,
                errorMessage: "Context Panel Watch timed out while refreshing usage.",
                disposition: .deadlineExceeded
            )
        }
        guard documentLoad.outcome.cloudKitUserScope == userScope else {
            _ = cache.invalidateUserScope()
            return identityChangedResult()
        }
        if let document = documentLoad.result.document,
           document.cloudKitUserScope != userScope {
            _ = cache.invalidateUserScope()
            return identityChangedResult()
        }
        if let presentationLoad,
           presentationLoad.outcome.cloudKitUserScope != userScope {
            _ = cache.invalidateUserScope()
            return identityChangedResult()
        }
        if let presentationDocument = presentationLoad?.document,
           presentationDocument.cloudKitUserScope != userScope {
            _ = cache.invalidateUserScope()
            return identityChangedResult()
        }
        if documentLoad.outcome.missingRecord {
            switch cache.removeIfCurrent(
                cached,
                now: now
            ) {
            case let .keptCurrent(current):
                guard current.result.document?.cloudKitUserScope == userScope else {
                    _ = cache.removeIfCurrent(current, now: now)
                    return identityChangedResult()
                }
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

        let selectedDocument = document.mergingForRemotePublish(
            existing: cached.result.document,
            now: now
        )
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
        let preSaveScopeRecheck = await Self.resolveUserScope(resolveUserScope, timeout: timeout)
        switch preSaveScopeRecheck {
        case let .resolved(resolvedScope) where resolvedScope == userScope:
            break
        case .transientFailure, .timedOut:
            return identityResolutionTimedOutResult()
        case .unavailable, .resolved:
            _ = cache.removeIfCurrent(cached, now: now)
            return identityChangedResult()
        }
        let saveOutcome = cache.saveSelectingNewest(
            document: selectedDocument,
            displayPreferences: displayPreferences,
            userScope: userScope,
            displayPreferencesUpdatedAt: displayPreferencesUpdatedAt,
            now: now
        )
        let postSaveScopeRecheck = await Self.resolveUserScope(resolveUserScope, timeout: timeout)
        switch postSaveScopeRecheck {
        case .transientFailure, .timedOut:
            return identityResolutionTimedOutResult()
        case let .resolved(resolvedScope) where resolvedScope == userScope:
            break
        case .unavailable, .resolved:
            switch saveOutcome {
            case let .saved(saved), let .keptCurrent(saved):
                _ = cache.removeIfCurrent(saved, now: now)
            case .scopeConflict, .failed:
                break
            }
            return identityChangedResult()
        }
        switch saveOutcome {
        case .scopeConflict:
            return identityChangedResult()
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

    private static func resolveUserScope(
        _ resolver: @escaping @Sendable () async -> CompanionRemoteUserScopeResolution,
        timeout: Duration
    ) async -> WatchUserScopeResolution {
        guard let resolvedScope = await WatchAsyncDeadline.value(
            timeout: timeout,
            operation: { await resolver() }
        ) else {
            return .timedOut
        }
        return switch resolvedScope {
        case let .resolved(userScope): .resolved(userScope)
        case .unavailable: .unavailable
        case .transientFailure: .transientFailure
        }
    }

    private static func identityResolutionTimedOutResult() -> WatchCompanionCacheLoadResult {
        WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(
                document: nil,
                status: .unknown,
                errorMessage: "Context Panel Watch timed out while checking its CloudKit account."
            ),
            displayPreferences: nil,
            disposition: .deadlineExceeded
        )
    }

    private static func fallback(
        cached: WatchCompanionCacheLoadResult,
        errorMessage: String,
        disposition: WatchCompanionLoadDisposition = .completed
    ) -> WatchCompanionCacheLoadResult {
        guard let document = cached.result.document else {
            return WatchCompanionCacheLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: disposition == .deadlineExceeded ? .unknown : .failure,
                    errorMessage: errorMessage
                ),
                displayPreferences: cached.displayPreferences,
                disposition: disposition
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
            displayPreferences: cached.displayPreferences,
            disposition: disposition
        )
    }

    private static func identityUnavailableResult() -> WatchCompanionCacheLoadResult {
        WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "CloudKit account identity is unavailable."
            ),
            displayPreferences: nil
        )
    }

    private static func identityChangedResult() -> WatchCompanionCacheLoadResult {
        WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "CloudKit account changed while refreshing Watch usage."
            ),
            displayPreferences: nil
        )
    }

    private struct InFlightLoad {
        let id: UUID
        let userScope: CompanionCloudKitUserScope
        let task: Task<WatchCompanionCacheLoadResult, Never>
    }
}

public enum WatchComplicationTimelineReloadPolicy {
    public static func shouldReload(after loaded: WatchCompanionCacheLoadResult) -> Bool {
        loaded.result.document != nil
    }
}
