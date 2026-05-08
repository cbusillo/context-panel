import Foundation
import Darwin

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

public enum SnapshotRefreshRunDecision: Equatable, Sendable {
    case refreshed(SnapshotRefreshOutcome)
    case skippedFresh
    case skippedAlreadyRunning
}

public struct SnapshotRefreshLock: Sendable {
    public let lockURL: URL
    public let staleAfter: TimeInterval

    public init(lockURL: URL, staleAfter: TimeInterval = 10 * 60) {
        self.lockURL = lockURL
        self.staleAfter = staleAfter
    }

    public static func appDefault() -> SnapshotRefreshLock {
        SnapshotRefreshLock(
            lockURL: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
                .appending(path: "refresh.lock")
        )
    }

    public func withLock<T>(now: Date = Date(), _ operation: () async throws -> T) async throws -> T? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: lockURL.path) {
            if let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
               let modifiedAt = attributes[.modificationDate] as? Date,
               now.timeIntervalSince(modifiedAt) <= staleAfter {
                return nil
            }
            try? fileManager.removeItem(at: lockURL)
        }

        let descriptor = open(lockURL.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }
        close(descriptor)
        defer { try? fileManager.removeItem(at: lockURL) }
        return try await operation()
    }
}

public struct SnapshotRefreshRunner: Sendable {
    public let service: SnapshotRefreshService
    public let stalenessPolicy: SnapshotStoreStalenessPolicy
    public let lock: SnapshotRefreshLock?

    public init(
        service: SnapshotRefreshService,
        stalenessPolicy: SnapshotStoreStalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60),
        lock: SnapshotRefreshLock? = .appDefault()
    ) {
        self.service = service
        self.stalenessPolicy = stalenessPolicy
        self.lock = lock
    }

    public static func appDefault() -> SnapshotRefreshRunner {
        SnapshotRefreshRunner(service: .appDefault())
    }

    public func refreshIfNeeded(now: Date = Date()) async throws -> SnapshotRefreshRunDecision {
        let current = service.loadCurrent(policy: stalenessPolicy, now: now)
        guard current.snapshot == nil || current.status == .unknown || current.status == .stale || current.status == .failure else {
            return .skippedFresh
        }
        return try await refresh(now: now)
    }

    public func refresh(now: Date = Date()) async throws -> SnapshotRefreshRunDecision {
        if let lock {
            guard let outcome = try await lock.withLock(now: now, {
                try await service.refresh(now: now)
            }) else { return .skippedAlreadyRunning }
            return .refreshed(outcome)
        }

        let outcome = try await service.refresh(now: now)
        return .refreshed(outcome)
    }

    public func saveMerged(refreshResult: ConnectorRefreshResult, savedAt: Date) async throws -> SnapshotRefreshRunDecision {
        try await saveMerged(refreshResult: refreshResult, savedAt: savedAt, retryFor: .zero)
    }

    public func saveMerged(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date,
        retryFor: Duration,
        retryInterval: Duration = .milliseconds(250)
    ) async throws -> SnapshotRefreshRunDecision {
        let startedAt = ContinuousClock.now

        while true {
            let decision = try await saveMergedOnce(refreshResult: refreshResult, savedAt: savedAt)
            if decision != .skippedAlreadyRunning {
                return decision
            }
            if startedAt.duration(to: ContinuousClock.now) >= retryFor {
                return decision
            }
            try await Task.sleep(for: retryInterval)
        }
    }

    private func saveMergedOnce(refreshResult: ConnectorRefreshResult, savedAt: Date) async throws -> SnapshotRefreshRunDecision {
        if let lock {
            guard let outcome = try await lock.withLock(now: savedAt, {
                try service.saveMerged(refreshResult: refreshResult, savedAt: savedAt)
            }) else { return .skippedAlreadyRunning }
            return .refreshed(outcome)
        }

        return .refreshed(try service.saveMerged(refreshResult: refreshResult, savedAt: savedAt))
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
            accountStore: AccountConfigurationStore(
                configurationURL: ContextPanelLocations.accountConfigurationURL(),
                fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
            ),
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
        return try saveMerged(refreshResult: refreshResult, savedAt: now)
    }

    public func saveMerged(refreshResult: ConnectorRefreshResult, savedAt: Date = Date()) throws -> SnapshotRefreshOutcome {
        try stores.primary.saveMerged(refreshResult: refreshResult, savedAt: savedAt)
        try mirrorPrimarySnapshotToDevelopmentStores()
        return SnapshotRefreshOutcome(savedAt: savedAt, refreshResult: refreshResult)
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
