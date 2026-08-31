import ContextPanelCore
import ContextPanelWidgetUI
import Foundation

private enum CompanionUserScopeResolution: Sendable {
    case resolved(CompanionCloudKitUserScope)
    case unavailable
    case transientFailure
    case timedOut
}

public enum CompanionSyncLoader {
    public static func load(now: Date = Date()) -> CompanionSyncLoadResult {
        CompanionSyncLoadResult(document: nil, status: .unknown)
    }

    public static func load(remoteStore: CompanionRemoteSyncStore?, now: Date = Date()) async -> CompanionSyncLoadResult {
        guard let remoteStore else { return load(now: now) }
        let localMirrorURL = ContextPanelLocations.companionAppGroupSyncDocumentURL()
        let scopeStateURL = ContextPanelLocations.companionCloudKitUserScopeStateURL()
        let initialScopeResolution = await remoteStore.currentUserScopeResolution()
        guard case let .resolved(userScope) = initialScopeResolution else {
            if initialScopeResolution == .transientFailure {
                return deferredIdentityResult(
                    localMirrorURL: localMirrorURL,
                    scopeStateURL: scopeStateURL,
                    now: now,
                    errorMessage: "CloudKit account identity is temporarily unavailable."
                )
            }
            return invalidateIdentity(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                errorMessage: "CloudKit account identity is unavailable."
            )
        }
        guard activateScope(
            userScope,
            localMirrorURL: localMirrorURL,
            scopeStateURL: scopeStateURL
        ) else {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel could not update its CloudKit account scope."
            )
        }
        let remoteLoad = await remoteStore.load(now: now)
        let finalScopeResolution = await remoteStore.currentUserScopeResolution()
        guard finalScopeResolution == .resolved(userScope) else {
            if finalScopeResolution == .transientFailure {
                return deferredIdentityResult(
                    localMirrorURL: localMirrorURL,
                    scopeStateURL: scopeStateURL,
                    now: now,
                    errorMessage: "CloudKit account identity is temporarily unavailable."
                )
            }
            return invalidateIdentity(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                errorMessage: "CloudKit account changed while refreshing usage."
            )
        }
        guard remoteLoadMatchesScope(remoteLoad, expectedScope: userScope) else {
            purgeMirror(at: localMirrorURL)
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "CloudKit returned usage for another account scope."
            )
        }
        return load(
            localMirrorURL: localMirrorURL,
            expectedUserScope: userScope,
            remoteLoad: remoteLoad,
            mirrorLoadedDocument: remoteLoad.result.document != nil,
            diagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.companionAppGroupID)
            ),
            now: now
        )
    }

    public static func loadWidgetTimeline(
        remoteStore: CompanionRemoteSyncStore?,
        timeout: Duration = .seconds(5),
        now: Date = Date()
    ) async -> CompanionSyncLoadResult {
        await loadWidgetTimeline(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            scopeStateURL: ContextPanelLocations.companionCloudKitUserScopeStateURL(),
            remoteStore: remoteStore,
            timeout: timeout,
            now: now
        )
    }

    static func loadWidgetTimeline(
        localMirrorURL: URL?,
        scopeStateURL: URL? = nil,
        remoteStore: CompanionRemoteSyncStore?,
        timeout: Duration,
        now: Date
    ) async -> CompanionSyncLoadResult {
        guard let remoteStore else {
            return loadWidgetMirror(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                now: now
            )
        }

        let initialScopeResolution = await resolveUserScope(
            remoteStore: remoteStore,
            timeout: timeout
        )
        let userScope: CompanionCloudKitUserScope
        switch initialScopeResolution {
        case let .resolved(resolvedScope):
            userScope = resolvedScope
        case .unavailable:
            return invalidateIdentity(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                errorMessage: "CloudKit account identity is unavailable."
            )
        case .transientFailure, .timedOut:
            return deferredIdentityResult(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                now: now,
                errorMessage: "Context Panel widget timed out while checking its CloudKit account."
            )
        }
        guard activateScope(
            userScope,
            localMirrorURL: localMirrorURL,
            scopeStateURL: scopeStateURL
        ) else {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel widget could not update its CloudKit account scope."
            )
        }
        let localAtStart = loadWidgetMirror(
            localMirrorURL: localMirrorURL,
            expectedUserScope: userScope,
            now: now
        )
        let remoteLoad = await CompanionAsyncDeadline.value(timeout: timeout) {
            await remoteStore.load(now: now)
        } ?? timedOutRemoteLoad(userScope: userScope)
        let finalScopeResolution = await resolveUserScope(
            remoteStore: remoteStore,
            timeout: timeout
        )
        switch finalScopeResolution {
        case let .resolved(resolvedScope) where resolvedScope == userScope:
            break
        case .transientFailure, .timedOut:
            return deferredIdentityResult(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                now: now,
                errorMessage: "Context Panel widget timed out while rechecking its CloudKit account."
            )
        case .unavailable, .resolved:
            return invalidateIdentity(
                localMirrorURL: localMirrorURL,
                scopeStateURL: scopeStateURL,
                errorMessage: "CloudKit account changed while refreshing widget usage."
            )
        }
        guard remoteLoadMatchesScope(remoteLoad, expectedScope: userScope) else {
            purgeMirror(at: localMirrorURL)
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "CloudKit returned widget usage for another account scope."
            )
        }
        if remoteLoad.outcome.succeeded,
           remoteLoad.outcome.missingRecord,
           remoteLoad.result.document == nil,
           remoteLoad.result.status == .unknown,
           remoteLoad.result.errorMessage == nil {
            return removeMissingWidgetMirror(
                localMirrorURL: localMirrorURL,
                expectedDocument: localAtStart.document,
                expectedUserScope: userScope,
                remoteLoad: remoteLoad,
                now: now
            )
        }
        let result = load(
            localMirrorURL: localMirrorURL,
            expectedUserScope: userScope,
            remoteLoad: remoteLoad,
            mirrorLoadedDocument: remoteLoad.result.document != nil,
            diagnosticsStore: nil,
            now: now
        )
        guard !remoteLoad.outcome.succeeded else {
            return result
        }
        return CompanionSyncLoadResult(
            document: result.document,
            status: result.document == nil ? .failure : result.status,
            errorMessage: result.errorMessage
                ?? remoteLoad.result.errorMessage
                ?? remoteLoad.outcome.errorMessage
                ?? "Context Panel widget could not refresh usage.",
            transportMetadata: result.transportMetadata,
            transportStatuses: result.transportStatuses
        )
    }

    static func load(
        localMirrorURL: URL?,
        expectedUserScope: CompanionCloudKitUserScope,
        remoteLoad: CompanionRemoteSyncLoadResult? = nil,
        mirrorLoadedDocument: Bool = true,
        diagnosticsStore: RefreshDiagnosticsStateStore? = nil,
        beforeMirrorLoadedDocument: () -> Void = {},
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        let transportStatuses = transportStatuses(remoteLoad: remoteLoad)
        guard let localMirrorURL else {
            let result = CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel iOS app group is unavailable.",
                transportStatuses: transportStatuses
            )
            recordDiagnostics(
                CompanionSyncDiagnosticsRecord(
                    operation: .load,
                    outcome: .failed,
                    attemptedAt: now,
                    appGroupSucceeded: false,
                    loadedDocument: false,
                    mirroredDocument: false,
                    errorMessage: result.errorMessage
                ),
                in: diagnosticsStore
            )
            return result
        }

        let localStore = CompanionSyncStore(
            documentURL: localMirrorURL,
            source: .appGroup
        )
        var remoteOutcome: CompanionRemoteSyncOutcome?
        var remoteCandidate: CompanionSyncLoadCandidate?
        if let remoteLoad {
            remoteOutcome = remoteLoad.outcome
            if let document = remoteLoad.result.document {
                let status = providerStatus(
                    for: document,
                    policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge),
                    now: now
                )
                remoteCandidate = CompanionSyncLoadCandidate(
                    result: CompanionSyncLoadResult(
                        document: document,
                        status: status,
                        errorMessage: remoteLoad.result.errorMessage,
                        transportMetadata: CompanionSyncTransportMetadata(
                            source: .cloudKit,
                            receivedAt: now,
                            mirroredAt: nil,
                            deliveryStatus: .healthy
                        ),
                        transportStatuses: transportStatuses
                    ),
                    storeRole: CompanionRemoteSync.cloudKitStoreRole
                )
            }
        }
        let stalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge)
        let localResult = localStore.load(
            expectedUserScope: expectedUserScope,
            policy: stalenessPolicy,
            now: now
        )
        let localSucceeded = localResult.status != .failure
        let loadDiagnostics = CompanionSyncLoadDiagnosticsResult(
            result: localResult,
            storeOutcomes: [CompanionSyncStoreOutcome(
                storeRole: "app-group",
                succeeded: localSucceeded,
                errorMessage: localResult.errorMessage
            )],
            selectedStoreRole: localResult.document == nil ? nil : "app-group"
        )
        let selectedCandidate = preferredCandidate(
            lhs: remoteCandidate,
            rhs: CompanionSyncLoadCandidate(
                result: loadDiagnostics.result,
                storeRole: loadDiagnostics.selectedStoreRole ?? "custom"
            )
        )
        var result = withTransportStatuses(
            selectedCandidate?.result ?? loadDiagnostics.result,
            transportStatuses
        )
        var mirrorSucceeded: Bool?
        var diagnosticRecord = loadDiagnostics.diagnosticsRecord(at: now)
        if let remoteOutcome {
            diagnosticRecord.cloudKitAvailable = remoteOutcome.isAvailable
            diagnosticRecord.cloudKitSucceeded = remoteOutcome.succeeded
            diagnosticRecord.cloudKitMissingRecord = remoteOutcome.missingRecord ? true : nil
            if !remoteOutcome.succeeded {
                diagnosticRecord.errorMessage = diagnosticRecord.errorMessage ?? remoteOutcome.errorMessage
                if diagnosticRecord.outcome == .healthy {
                    diagnosticRecord.outcome = diagnosticRecord.loadedDocument == true ? .partial : .failed
                }
            } else if let remoteCandidate, remoteCandidate.result.document != nil {
                diagnosticRecord.loadedDocument = selectedCandidate?.result.document != nil
                diagnosticRecord.stale = selectedCandidate?.result.status == .stale
                if selectedCandidate?.storeRole == CompanionRemoteSync.cloudKitStoreRole {
                    diagnosticRecord.outcome = remoteCandidate.result.status == .stale ? .stale : .healthy
                    diagnosticRecord.errorMessage = nil
                } else if diagnosticRecord.outcome == .failed || diagnosticRecord.outcome == .unavailable {
                    diagnosticRecord.outcome = .partial
                }
            }
        }
        let shouldMirrorLoadedDocument = mirrorLoadedDocument
            && selectedCandidate?.storeRole != "app-group"
        if shouldMirrorLoadedDocument, let document = result.document {
            beforeMirrorLoadedDocument()
            let selectedResult = result
            let conditionalSaveResult = localStore.saveResult(
                document,
                expectedUserScope: expectedUserScope,
                policy: stalenessPolicy,
                now: now
            ) { currentLocalResult in
                Self.shouldKeepLocalMirror(currentLocalResult, over: selectedResult)
            }
            switch conditionalSaveResult {
            case .scopeConflict:
                let failedResult = CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: "CloudKit account changed before the app-group mirror was updated.",
                    transportStatuses: transportStatuses
                )
                diagnosticRecord.outcome = .failed
                diagnosticRecord.appGroupSucceeded = false
                diagnosticRecord.loadedDocument = false
                diagnosticRecord.mirroredDocument = false
                diagnosticRecord.errorMessage = failedResult.errorMessage
                recordDiagnostics(diagnosticRecord, in: diagnosticsStore)
                return failedResult
            case let .keptCurrent(keptCurrentResult):
                if selectedResult.document == keptCurrentResult.document,
                   let metadata = selectedResult.transportMetadata {
                    result = CompanionSyncLoadResult(
                        document: keptCurrentResult.document,
                        status: keptCurrentResult.status,
                        errorMessage: selectedResult.errorMessage ?? keptCurrentResult.errorMessage,
                        transportMetadata: CompanionSyncTransportMetadata(
                            source: metadata.source,
                            receivedAt: metadata.receivedAt,
                            mirroredAt: metadata.mirroredAt ?? now,
                            deliveryStatus: metadata.deliveryStatus
                        ),
                        transportStatuses: transportStatuses
                    )
                } else {
                    result = withTransportStatuses(keptCurrentResult, transportStatuses)
                }
                diagnosticRecord.outcome = keptCurrentResult.status == .stale ? .stale : .healthy
                diagnosticRecord.appGroupSucceeded = true
                diagnosticRecord.loadedDocument = true
                diagnosticRecord.stale = keptCurrentResult.status == .stale
                diagnosticRecord.errorMessage = nil
            case let .saved(saveResult):
                if !saveResult.succeeded {
                    mirrorSucceeded = false
                    let failedResult = CompanionSyncLoadResult(
                        document: document,
                        status: .failure,
                        errorMessage: Self.mirrorFailureMessage(saveResult),
                        transportMetadata: result.transportMetadata,
                        transportStatuses: transportStatuses
                    )
                    diagnosticRecord.outcome = .partial
                    diagnosticRecord.appGroupSucceeded = false
                    diagnosticRecord.loadedDocument = true
                    diagnosticRecord.mirroredDocument = false
                    diagnosticRecord.errorMessage = failedResult.errorMessage
                    recordDiagnostics(
                        diagnosticRecord,
                        in: diagnosticsStore
                    )
                    return failedResult
                }
                mirrorSucceeded = true
                result = CompanionSyncLoadResult(
                    document: document,
                    status: result.status,
                    errorMessage: result.errorMessage,
                    transportMetadata: result.transportMetadata.map { metadata in
                        CompanionSyncTransportMetadata(
                            source: metadata.source,
                            receivedAt: metadata.receivedAt,
                            mirroredAt: now,
                            deliveryStatus: metadata.deliveryStatus
                        )
                    },
                    transportStatuses: transportStatuses
                )
            }
        } else if shouldMirrorLoadedDocument {
            mirrorSucceeded = false
        }
        if let mirrorSucceeded {
            diagnosticRecord.mirroredDocument = mirrorSucceeded
            if mirrorSucceeded {
                diagnosticRecord.appGroupSucceeded = true
                diagnosticRecord.loadedDocument = result.document != nil
                diagnosticRecord.stale = result.status == .stale
                if diagnosticRecord.outcome != .partial {
                    diagnosticRecord.outcome = result.status == .stale ? .stale : .healthy
                }
            } else if mirrorLoadedDocument {
                diagnosticRecord.appGroupSucceeded = false
                if diagnosticRecord.outcome == .healthy {
                    diagnosticRecord.outcome = .partial
                }
            }
        }
        recordDiagnostics(
            diagnosticRecord,
            in: diagnosticsStore
        )
        return result
    }

    public static func loadWidgetMirror(now: Date = Date()) -> CompanionSyncLoadResult {
        CompanionSyncLoadResult(document: nil, status: .unknown)
    }

    static func loadWidgetMirror(
        localMirrorURL: URL?,
        scopeStateURL: URL? = nil,
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        guard let scopeStateURL,
              let expectedUserScope = CompanionCloudKitUserScopeStateStore(
                  stateURL: scopeStateURL
              ).load()
        else {
            purgeMirror(at: localMirrorURL)
            return CompanionSyncLoadResult(document: nil, status: .unknown)
        }
        return loadWidgetMirror(
            localMirrorURL: localMirrorURL,
            expectedUserScope: expectedUserScope,
            now: now
        )
    }

    static func loadWidgetMirror(
        localMirrorURL: URL?,
        expectedUserScope: CompanionCloudKitUserScope,
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        guard let localMirrorURL else {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel iOS app group is unavailable."
            )
        }
        let policy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionMirrorMaximumAge)
        return CompanionSyncStore(documentURL: localMirrorURL).load(
            expectedUserScope: expectedUserScope,
            policy: policy,
            now: now
        )
    }

    private static func mirrorFailureMessage(_ saveResult: CompanionSyncSaveResult) -> String {
        guard let failure = saveResult.failures.first else {
            return "Context Panel iOS app group mirror could not be updated."
        }
        return "Context Panel iOS app group mirror could not be updated: \(failure.errorMessage)"
    }

    private static func timedOutRemoteLoad(
        userScope: CompanionCloudKitUserScope
    ) -> CompanionRemoteSyncLoadResult {
        let message = "Context Panel widget timed out while refreshing usage."
        return CompanionRemoteSyncLoadResult(
            result: CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: message
            ),
            outcome: CompanionRemoteSyncOutcome(
                succeeded: false,
                errorMessage: message,
                cloudKitUserScope: userScope
            )
        )
    }

    private static func resolveUserScope(
        remoteStore: CompanionRemoteSyncStore,
        timeout: Duration
    ) async -> CompanionUserScopeResolution {
        guard let resolvedScope = await CompanionAsyncDeadline.value(
            timeout: timeout,
            operation: { await remoteStore.currentUserScopeResolution() }
        ) else {
            return .timedOut
        }
        return switch resolvedScope {
        case let .resolved(userScope): .resolved(userScope)
        case .unavailable: .unavailable
        case .transientFailure: .transientFailure
        }
    }

    private static func deferredIdentityResult(
        localMirrorURL: URL?,
        scopeStateURL: URL?,
        now: Date,
        errorMessage: String
    ) -> CompanionSyncLoadResult {
        let cached = loadWidgetMirror(
            localMirrorURL: localMirrorURL,
            scopeStateURL: scopeStateURL,
            now: now
        )
        return CompanionSyncLoadResult(
            document: cached.document,
            status: cached.document == nil ? .unknown : .stale,
            errorMessage: errorMessage,
            transportMetadata: cached.transportMetadata,
            transportStatuses: cached.transportStatuses
        )
    }

    private static func activateScope(
        _ userScope: CompanionCloudKitUserScope,
        localMirrorURL: URL?,
        scopeStateURL: URL?
    ) -> Bool {
        guard let scopeStateURL else { return true }
        let stateStore = CompanionCloudKitUserScopeStateStore(stateURL: scopeStateURL)
        do {
            try stateStore.save(userScope)
            return true
        } catch {
            purgeMirror(at: localMirrorURL)
            return false
        }
    }

    private static func invalidateIdentity(
        localMirrorURL: URL?,
        scopeStateURL: URL?,
        errorMessage: String
    ) -> CompanionSyncLoadResult {
        if let scopeStateURL {
            try? CompanionCloudKitUserScopeStateStore(stateURL: scopeStateURL).clear()
        }
        purgeMirror(at: localMirrorURL)
        return CompanionSyncLoadResult(
            document: nil,
            status: .failure,
            errorMessage: errorMessage
        )
    }

    private static func purgeMirror(at localMirrorURL: URL?) {
        guard let localMirrorURL else { return }
        try? CompanionSyncStore(documentURL: localMirrorURL).remove()
    }

    private static func remoteLoadMatchesScope(
        _ remoteLoad: CompanionRemoteSyncLoadResult,
        expectedScope: CompanionCloudKitUserScope
    ) -> Bool {
        guard remoteLoad.outcome.cloudKitUserScope == expectedScope else { return false }
        guard let document = remoteLoad.result.document else { return true }
        return document.cloudKitUserScope == expectedScope
    }

    private static func removeMissingWidgetMirror(
        localMirrorURL: URL?,
        expectedDocument: CompanionSyncDocument?,
        expectedUserScope: CompanionCloudKitUserScope,
        remoteLoad: CompanionRemoteSyncLoadResult,
        now: Date
    ) -> CompanionSyncLoadResult {
        let transportStatuses = transportStatuses(remoteLoad: remoteLoad)
        guard let localMirrorURL else {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel iOS app group is unavailable.",
                transportStatuses: transportStatuses
            )
        }

        let policy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge)
        let localStore = CompanionSyncStore(documentURL: localMirrorURL)
        switch localStore.removeIfCurrent(expectedDocument, policy: policy, now: now) {
        case .removed:
            return CompanionSyncLoadResult(
                document: nil,
                status: remoteLoad.result.status,
                errorMessage: remoteLoad.result.errorMessage,
                transportStatuses: transportStatuses
            )
        case let .keptCurrent(current):
            guard let currentDocument = current.document else {
                return withTransportStatuses(current, transportStatuses)
            }
            guard currentDocument.cloudKitUserScope == expectedUserScope else {
                _ = localStore.removeIfCurrent(current.document, policy: policy, now: now)
                return CompanionSyncLoadResult(
                    document: nil,
                    status: remoteLoad.result.status,
                    errorMessage: remoteLoad.result.errorMessage,
                    transportStatuses: transportStatuses
                )
            }
            return withTransportStatuses(current, transportStatuses)
        case let .failed(errorMessage):
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: errorMessage,
                transportStatuses: transportStatuses
            )
        }
    }

    private static func shouldKeepLocalMirror(
        _ localResult: CompanionSyncLoadResult,
        over selectedResult: CompanionSyncLoadResult
    ) -> Bool {
        guard let localDocument = localResult.document,
              let selectedDocument = selectedResult.document
        else { return false }

        if localDocument == selectedDocument { return true }
        if localResult.status == .stale, selectedResult.status != .stale { return false }
        if localResult.status != .stale, selectedResult.status == .stale { return true }
        if localDocument.snapshot.generatedAt != selectedDocument.snapshot.generatedAt {
            return localDocument.snapshot.generatedAt > selectedDocument.snapshot.generatedAt
        }
        return localDocument.snapshot.publishedAt > selectedDocument.snapshot.publishedAt
    }

    private static func recordDiagnostics(
        _ record: CompanionSyncDiagnosticsRecord,
        in store: RefreshDiagnosticsStateStore?
    ) {
        try? store?.update { state in
            state.recordCompanionSync(record)
        }
    }

    private static func providerStatus(
        for document: CompanionSyncDocument,
        policy: SnapshotStoreStalenessPolicy,
        now: Date
    ) -> UsageStatus {
        document.companionStatus(now: now, stalenessPolicy: policy)
    }

    private static func transportStatuses(remoteLoad: CompanionRemoteSyncLoadResult?) -> [CompanionSyncTransportStatus] {
        guard let remoteLoad else { return [] }
        return [
            CompanionSyncTransportStatus(
                source: .cloudKit,
                isAvailable: remoteLoad.outcome.isAvailable,
                succeeded: remoteLoad.outcome.succeeded,
                loadedDocument: remoteLoad.result.document != nil,
                missingRecord: remoteLoad.outcome.missingRecord,
                errorMessage: remoteLoad.outcome.errorMessage ?? remoteLoad.result.errorMessage
            ),
        ]
    }

    private static func withTransportStatuses(
        _ result: CompanionSyncLoadResult,
        _ transportStatuses: [CompanionSyncTransportStatus]
    ) -> CompanionSyncLoadResult {
        guard !transportStatuses.isEmpty else { return result }
        return CompanionSyncLoadResult(
            document: result.document,
            status: result.status,
            errorMessage: result.errorMessage,
            transportMetadata: result.transportMetadata,
            transportStatuses: transportStatuses
        )
    }

    private static func preferredCandidate(
        lhs: CompanionSyncLoadCandidate?,
        rhs: CompanionSyncLoadCandidate?
    ) -> CompanionSyncLoadCandidate? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        guard let lhsDocument = lhs.result.document, let rhsDocument = rhs.result.document else { return lhs }

        if lhs.result.status == .stale, rhs.result.status != .stale { return rhs }
        if lhs.result.status != .stale, rhs.result.status == .stale { return lhs }
        if lhsDocument.snapshot.generatedAt != rhsDocument.snapshot.generatedAt {
            return lhsDocument.snapshot.generatedAt < rhsDocument.snapshot.generatedAt ? rhs : lhs
        }
        return lhsDocument.snapshot.publishedAt < rhsDocument.snapshot.publishedAt ? rhs : lhs
    }
}

private struct CompanionSyncLoadCandidate: Equatable, Sendable {
    let result: CompanionSyncLoadResult
    let storeRole: String
}

public enum CompanionDeepLinks {
    public static let overview = URL(string: "contextpanelcompanion://overview")!
    public static let reconnect = URL(string: "contextpanelcompanion://overview")!
    public static let cacheStatsSettings = URL(string: "contextpanelcompanion://overview")!
    public static let widgetLinks = ContextPanelWidgetLinks(
        overview: overview,
        reconnect: reconnect,
        cacheStatsSettings: cacheStatsSettings,
        resetCreditInteraction: .destination(
            overview,
            accessibilityHint: "Opens the synced usage overview"
        )
    )
    public static let previewLinks = ContextPanelWidgetLinks(
        overview: overview,
        reconnect: reconnect,
        cacheStatsSettings: cacheStatsSettings,
        resetCreditInteraction: .none
    )
}
