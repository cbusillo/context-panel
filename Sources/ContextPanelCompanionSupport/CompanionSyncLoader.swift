import ContextPanelCore
import ContextPanelWidgetUI
import Foundation

public enum CompanionSyncLoader {
    public static func load(now: Date = Date()) -> CompanionSyncLoadResult {
        return load(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            iCloudDocumentURL: nil,
            remoteLoad: nil,
            mirrorLoadedDocument: false,
            diagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.companionAppGroupID)
            ),
            now: now
        )
    }

    public static func load(remoteStore: CompanionRemoteSyncStore?, now: Date = Date()) async -> CompanionSyncLoadResult {
        let remoteLoad = await remoteStore?.load(now: now)
        return load(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            iCloudDocumentURL: nil,
            remoteLoad: remoteLoad,
            mirrorLoadedDocument: remoteLoad?.result.document != nil,
            diagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.companionAppGroupID)
            ),
            now: now
        )
    }

    static func load(
        localMirrorURL: URL?,
        iCloudDocumentURL: URL?,
        remoteLoad: CompanionRemoteSyncLoadResult? = nil,
        mirrorLoadedDocument: Bool = true,
        diagnosticsStore: RefreshDiagnosticsStateStore? = nil,
        downloadUbiquitousItem: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        },
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
                    iCloudAvailable: iCloudDocumentURL != nil,
                    loadedDocument: false,
                    mirroredDocument: false,
                    errorMessage: result.errorMessage
                ),
                in: diagnosticsStore
            )
            return result
        }

        let localStore = CompanionSyncStore(documentURL: localMirrorURL)
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
        var storeResolvers = [
            CompanionSyncStoreResolver(storeRole: "app-group") {
                localStore
            },
        ]
        if let iCloudDocumentURL {
            storeResolvers.append(
                CompanionSyncStoreResolver(storeRole: "icloud") {
                    CompanionSyncStore(documentURL: iCloudDocumentURL)
                }
            )
        }
        let storeSet = CompanionSyncStoreSet(stores: [], lazyStores: storeResolvers)
        var downloadErrorMessage: String?
        if let iCloudDocumentURL {
            do {
                try downloadUbiquitousItem(iCloudDocumentURL)
            } catch {
                downloadErrorMessage = CompanionSyncStoreFailure.diagnosticErrorMessage(
                    storeRole: "icloud",
                    operation: "download",
                    error: error
                )
            }
        }
        let stalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge)
        let loadDiagnostics = storeSet.loadWithDiagnostics(
            policy: stalenessPolicy,
            now: now
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
        if let downloadErrorMessage {
            diagnosticRecord.iCloudAvailable = iCloudDocumentURL != nil
            diagnosticRecord.iCloudSucceeded = false
            diagnosticRecord.errorMessage = diagnosticRecord.errorMessage ?? downloadErrorMessage
            if diagnosticRecord.outcome == .healthy {
                diagnosticRecord.outcome = diagnosticRecord.loadedDocument == true ? .partial : .failed
            }
        }
        let shouldMirrorLoadedDocument = mirrorLoadedDocument
            && selectedCandidate?.storeRole != "app-group"
        if shouldMirrorLoadedDocument, let document = result.document {
            beforeMirrorLoadedDocument()
            let selectedResult = result
            let conditionalSaveResult = localStore.saveResult(
                document,
                policy: stalenessPolicy,
                now: now
            ) { currentLocalResult in
                Self.shouldKeepLocalMirror(currentLocalResult, over: selectedResult)
            }
            switch conditionalSaveResult {
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
                diagnosticRecord.outcome = downloadErrorMessage == nil
                    ? (keptCurrentResult.status == .stale ? .stale : .healthy)
                    : .partial
                diagnosticRecord.appGroupSucceeded = true
                diagnosticRecord.loadedDocument = true
                diagnosticRecord.stale = keptCurrentResult.status == .stale
                diagnosticRecord.errorMessage = downloadErrorMessage
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
        loadWidgetMirror(localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(), now: now)
    }

    static func loadWidgetMirror(
        localMirrorURL: URL?,
        resolveICloudDocumentURL: () -> URL?,
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        loadWidgetMirror(localMirrorURL: localMirrorURL, now: now)
    }

    static func loadWidgetMirror(
        localMirrorURL: URL?,
        iCloudDocumentURL: URL? = nil,
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
        return CompanionSyncStore(documentURL: localMirrorURL).load(policy: policy, now: now)
    }

    private static func mirrorFailureMessage(_ saveResult: CompanionSyncSaveResult) -> String {
        guard let failure = saveResult.failures.first else {
            return "Context Panel iOS app group mirror could not be updated."
        }
        return "Context Panel iOS app group mirror could not be updated: \(failure.errorMessage)"
    }

    private static func shouldKeepLocalMirror(
        _ localResult: CompanionSyncLoadResult,
        over selectedResult: CompanionSyncLoadResult
    ) -> Bool {
        guard let localDocument = localResult.document,
              let selectedDocument = selectedResult.document
        else { return false }

        if localResult.status == .stale, selectedResult.status != .stale { return false }
        if localResult.status != .stale, selectedResult.status == .stale { return true }
        if localDocument.snapshot.generatedAt != selectedDocument.snapshot.generatedAt {
            return localDocument.snapshot.generatedAt > selectedDocument.snapshot.generatedAt
        }
        return localDocument.snapshot.publishedAt >= selectedDocument.snapshot.publishedAt
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
        now.timeIntervalSince(document.snapshot.generatedAt) > policy.maximumAge
            ? .stale
            : document.companionStatus
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
    public static let links = ContextPanelWidgetLinks(
        overview: overview,
        reconnect: reconnect,
        cacheStatsSettings: cacheStatsSettings
    )
}
