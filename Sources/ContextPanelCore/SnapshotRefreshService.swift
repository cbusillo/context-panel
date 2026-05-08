import Foundation

public struct SnapshotRefreshStores: Sendable {
    public let primary: JSONSnapshotStore
    public let developmentMirrors: [JSONSnapshotStore]

    public init(primary: JSONSnapshotStore, developmentMirrors: [JSONSnapshotStore] = []) {
        self.primary = primary
        self.developmentMirrors = developmentMirrors
    }

    public static func appDefault(appGroupID: String = ContextPanelLocations.appGroupID) -> SnapshotRefreshStores {
        SnapshotRefreshStores(
            primary: JSONSnapshotStore(rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: appGroupID)),
            developmentMirrors: [
                JSONSnapshotStore(rootDirectory: ContextPanelLocations.widgetDevelopmentContainerSnapshotDirectory()),
                JSONSnapshotStore(rootDirectory: ContextPanelLocations.hostDevelopmentSnapshotDirectory()),
            ]
        )
    }
}

public struct SnapshotRefreshOutcome: Equatable, Sendable {
    public let savedAt: Date
    public let refreshResult: ConnectorRefreshResult

    public init(savedAt: Date, refreshResult: ConnectorRefreshResult) {
        self.savedAt = savedAt
        self.refreshResult = refreshResult
    }
}

public struct SnapshotRefreshService: Sendable {
    private let accountStore: AccountConfigurationStore
    private let stores: SnapshotRefreshStores

    public init(accountStore: AccountConfigurationStore, stores: SnapshotRefreshStores) {
        self.accountStore = accountStore
        self.stores = stores
    }

    public static func appDefault() -> SnapshotRefreshService {
        SnapshotRefreshService(
            accountStore: AccountConfigurationStore(configurationURL: ContextPanelLocations.accountConfigurationURL()),
            stores: .appDefault()
        )
    }

    public func loadConfiguredAccounts(now: Date = Date()) -> AccountConfigurationLoadResult {
        accountStore.load(now: now)
    }

    public func loadCurrent(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> SnapshotStoreLoadResult {
        stores.primary.loadCurrent(policy: policy, now: now)
    }

    public func loadHistory(query: SnapshotStoreQuery = SnapshotStoreQuery()) -> [StoredUsageSnapshot] {
        stores.primary.loadHistory(query: query)
    }

    public func refresh(now: Date = Date()) async throws -> SnapshotRefreshOutcome {
        let accountDocument = accountStore.load(now: now).document
        let connectors = AccountConnectorFactory.connectors(from: accountDocument)
        let refreshResult = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: now)
        try stores.primary.saveMerged(refreshResult: refreshResult, savedAt: now)
        try mirrorPrimarySnapshotToDevelopmentStores()
        return SnapshotRefreshOutcome(savedAt: now, refreshResult: refreshResult)
    }

    public func mirrorPrimarySnapshotToDevelopmentStores() throws {
        try mirrorCurrentSnapshotToDevelopmentStores()
        try mirrorHistoryToDevelopmentStores()
    }

    private func mirrorCurrentSnapshotToDevelopmentStores() throws {
        let sourceURL = stores.primary.currentSnapshotURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        for destinationStore in stores.developmentMirrors {
            if destinationStore.currentSnapshotURL.standardizedFileURL == sourceURL.standardizedFileURL {
                continue
            }
            try FileManager.default.createDirectory(
                at: destinationStore.rootDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationStore.currentSnapshotURL.path) {
                try FileManager.default.removeItem(at: destinationStore.currentSnapshotURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationStore.currentSnapshotURL)
        }
    }

    private func mirrorHistoryToDevelopmentStores() throws {
        guard FileManager.default.fileExists(atPath: stores.primary.historyDirectoryURL.path) else { return }
        let historyURLs = try FileManager.default.contentsOfDirectory(
            at: stores.primary.historyDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        for destinationStore in stores.developmentMirrors {
            if destinationStore.historyDirectoryURL.standardizedFileURL == stores.primary.historyDirectoryURL.standardizedFileURL {
                continue
            }
            try FileManager.default.createDirectory(
                at: destinationStore.historyDirectoryURL,
                withIntermediateDirectories: true
            )
            for destinationURL in try FileManager.default.contentsOfDirectory(
                at: destinationStore.historyDirectoryURL,
                includingPropertiesForKeys: nil
            ) where destinationURL.pathExtension == "json" {
                try FileManager.default.removeItem(at: destinationURL)
            }

            for sourceURL in historyURLs {
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destinationStore.historyDirectoryURL.appending(path: sourceURL.lastPathComponent)
                )
            }
        }
    }
}
