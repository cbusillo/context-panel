import ContextPanelCore
import ContextPanelWidgetUI
import Foundation

public enum CompanionSyncLoader {
    public static func load(now: Date = Date()) -> CompanionSyncLoadResult {
        let iCloudDocumentURL = ContextPanelLocations.cachedCompanionUbiquitySyncDocumentURL()
            ?? ContextPanelLocations.refreshCachedCompanionUbiquitySyncDocumentURL()
        return load(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            iCloudDocumentURL: iCloudDocumentURL,
            mirrorLoadedDocument: iCloudDocumentURL != nil,
            diagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.companionAppGroupID)
            ),
            now: now
        )
    }

    static func load(
        localMirrorURL: URL?,
        iCloudDocumentURL: URL?,
        mirrorLoadedDocument: Bool = true,
        diagnosticsStore: RefreshDiagnosticsStateStore? = nil,
        downloadUbiquitousItem: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        },
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        guard let localMirrorURL else {
            let result = CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel iOS app group is unavailable."
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
        let storeSet = CompanionSyncStoreSet(
            stores: [localStore],
            lazyStores: [CompanionSyncStoreResolver(storeRole: "icloud") {
                iCloudDocumentURL.map(CompanionSyncStore.init(documentURL:))
            }]
        )
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
        let loadDiagnostics = storeSet.loadWithDiagnostics(
            policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge),
            now: now
        )
        let result = loadDiagnostics.result
        var mirrorSucceeded: Bool?
        var diagnosticRecord = loadDiagnostics.diagnosticsRecord(at: now)
        if let downloadErrorMessage {
            diagnosticRecord.iCloudAvailable = iCloudDocumentURL != nil
            diagnosticRecord.iCloudSucceeded = false
            diagnosticRecord.errorMessage = diagnosticRecord.errorMessage ?? downloadErrorMessage
            if diagnosticRecord.outcome == .healthy {
                diagnosticRecord.outcome = diagnosticRecord.loadedDocument == true ? .partial : .failed
            }
        }
        if mirrorLoadedDocument, let document = result.document {
            let saveResult = localStore.saveResult(document)
            if !saveResult.succeeded {
                mirrorSucceeded = false
                let failedResult = CompanionSyncLoadResult(
                    document: document,
                    status: .failure,
                    errorMessage: Self.mirrorFailureMessage(saveResult)
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
        } else if mirrorLoadedDocument {
            mirrorSucceeded = false
        }
        if let mirrorSucceeded {
            diagnosticRecord.mirroredDocument = mirrorSucceeded
            if mirrorSucceeded {
                diagnosticRecord.appGroupSucceeded = true
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
        loadWidgetMirror(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            now: now
        )
    }

    static func loadWidgetMirror(
        localMirrorURL: URL?,
        iCloudDocumentURL: URL? = nil,
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        load(
            localMirrorURL: localMirrorURL,
            iCloudDocumentURL: iCloudDocumentURL,
            mirrorLoadedDocument: iCloudDocumentURL != nil,
            now: now
        )
    }

    private static func mirrorFailureMessage(_ saveResult: CompanionSyncSaveResult) -> String {
        guard let failure = saveResult.failures.first else {
            return "Context Panel iOS app group mirror could not be updated."
        }
        return "Context Panel iOS app group mirror could not be updated: \(failure.errorMessage)"
    }

    private static func recordDiagnostics(
        _ record: CompanionSyncDiagnosticsRecord,
        in store: RefreshDiagnosticsStateStore?
    ) {
        try? store?.update { state in
            state.recordCompanionSync(record)
        }
    }
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
