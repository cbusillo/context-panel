import ContextPanelCore
import ContextPanelWidgetUI
import Foundation

public enum CompanionSyncLoader {
    public static func load(now: Date = Date()) -> CompanionSyncLoadResult {
        let storeSet = ContextPanelLocations.companionSyncStoreSet(appGroupID: nil)
        for documentURL in storeSet.resolvedDocumentURLs {
            try? FileManager.default.startDownloadingUbiquitousItem(at: documentURL)
        }
        return storeSet.load(
            policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge),
            now: now
        )
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

private extension CompanionSyncStoreSet {
    var resolvedDocumentURLs: [URL] {
        stores.map(\.documentURL) + lazyStores.compactMap { $0.resolve()?.documentURL }
    }
}
