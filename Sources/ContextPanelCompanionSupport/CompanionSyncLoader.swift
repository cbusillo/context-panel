import ContextPanelCore
import ContextPanelWidgetUI
import Foundation

public enum CompanionSyncLoader {
    public static func load(now: Date = Date()) -> CompanionSyncLoadResult {
        load(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            iCloudDocumentURL: ContextPanelLocations.companionUbiquitySyncDocumentURL(),
            now: now
        )
    }

    static func load(
        localMirrorURL: URL?,
        iCloudDocumentURL: URL?,
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        guard let localMirrorURL else {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel iOS app group is unavailable."
            )
        }

        let localStore = CompanionSyncStore(documentURL: localMirrorURL)
        let storeSet = CompanionSyncStoreSet(
            stores: [localStore],
            lazyStores: [CompanionSyncStoreResolver {
                iCloudDocumentURL.map(CompanionSyncStore.init(documentURL:))
            }]
        )
        if let iCloudDocumentURL {
            try? FileManager.default.startDownloadingUbiquitousItem(at: iCloudDocumentURL)
        }
        let result = storeSet.load(
            policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge),
            now: now
        )
        if let document = result.document {
            let saveResult = localStore.saveResult(document)
            if !saveResult.succeeded {
                return CompanionSyncLoadResult(
                    document: document,
                    status: .failure,
                    errorMessage: Self.mirrorFailureMessage(saveResult)
                )
            }
        }
        return result
    }

    public static func loadWidgetMirror(now: Date = Date()) -> CompanionSyncLoadResult {
        loadWidgetMirror(
            localMirrorURL: ContextPanelLocations.companionAppGroupSyncDocumentURL(),
            now: now
        )
    }

    static func loadWidgetMirror(localMirrorURL: URL?, now: Date = Date()) -> CompanionSyncLoadResult {
        guard let localMirrorURL else {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: "Context Panel iOS app group is unavailable."
            )
        }

        return CompanionSyncStore(documentURL: localMirrorURL).load(
            policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge),
            now: now
        )
    }

    private static func mirrorFailureMessage(_ saveResult: CompanionSyncSaveResult) -> String {
        guard let failure = saveResult.failures.first else {
            return "Context Panel iOS app group mirror could not be updated."
        }
        return "Context Panel iOS app group mirror could not be updated: \(failure.errorMessage)"
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
