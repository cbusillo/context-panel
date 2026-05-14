import Foundation
import Darwin

public struct SnapshotRefreshStores: Sendable {
    public let primary: JSONSnapshotStore

    public init(primary: JSONSnapshotStore) {
        self.primary = primary
    }

    public static func appDefault(appGroupID: String = ContextPanelLocations.appGroupID) -> SnapshotRefreshStores {
        return SnapshotRefreshStores(
            primary: JSONSnapshotStore(rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: appGroupID))
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
    case skippedNoReports
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
        service.importConfiguredAuthFiles(now: now)
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
            guard !outcome.refreshResult.reports.isEmpty else { return .skippedNoReports }
            return .refreshed(outcome)
        }

        let outcome = try await service.refresh(now: now)
        guard !outcome.refreshResult.reports.isEmpty else { return .skippedNoReports }
        return .refreshed(outcome)
    }

    public func saveMerged(refreshResult: ConnectorRefreshResult, savedAt: Date) async throws -> SnapshotRefreshRunDecision {
        try await saveMerged(refreshResult: refreshResult, savedAt: savedAt, retryFor: .zero)
    }

    public func saveMerged(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date,
        retryFor: Duration,
        retryInterval: Duration = .milliseconds(250),
        preservesUnreportedAccounts: Bool = false
    ) async throws -> SnapshotRefreshRunDecision {
        let startedAt = ContinuousClock.now

        while true {
            let decision = try await saveMergedOnce(
                refreshResult: refreshResult,
                savedAt: savedAt,
                preservesUnreportedAccounts: preservesUnreportedAccounts
            )
            if decision != .skippedAlreadyRunning {
                return decision
            }
            if startedAt.duration(to: ContinuousClock.now) >= retryFor {
                return decision
            }
            try await Task.sleep(for: retryInterval)
        }
    }

    private func saveMergedOnce(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date,
        preservesUnreportedAccounts: Bool
    ) async throws -> SnapshotRefreshRunDecision {
        guard !refreshResult.reports.isEmpty else { return .skippedNoReports }
        if let lock {
            guard let outcome = try await lock.withLock(now: savedAt, {
                try service.saveMerged(
                    refreshResult: refreshResult,
                    savedAt: savedAt,
                    preservesUnreportedAccounts: preservesUnreportedAccounts
                )
            }) else { return .skippedAlreadyRunning }
            return .refreshed(outcome)
        }

        return .refreshed(try service.saveMerged(
            refreshResult: refreshResult,
            savedAt: savedAt,
            preservesUnreportedAccounts: preservesUnreportedAccounts
        ))
    }
}

public struct SnapshotRefreshService: Sendable {
    private let accountStore: AccountConfigurationStore
    private let stores: SnapshotRefreshStores
    private let bookmarkStore: SecureFileBookmarkStore?
    private let credentialStore: (any ProviderCredentialStoring)?

    public init(
        accountStore: AccountConfigurationStore,
        stores: SnapshotRefreshStores,
        bookmarkStore: SecureFileBookmarkStore? = nil,
        credentialStore: (any ProviderCredentialStoring)? = nil
    ) {
        self.accountStore = accountStore
        self.stores = stores
        self.bookmarkStore = bookmarkStore
        self.credentialStore = credentialStore
    }

    public static func appDefault() -> SnapshotRefreshService {
        SnapshotRefreshService(
            accountStore: AccountConfigurationStore(
                configurationURL: ContextPanelLocations.accountConfigurationURL(),
                fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
            ),
            stores: .appDefault(),
            bookmarkStore: SecureFileBookmarkStore(storeURL: ContextPanelLocations.bookmarkStoreURL()),
            credentialStore: ProviderCredentialStore()
        )
    }

    public func loadConfiguredAccounts(now: Date = Date()) -> AccountConfigurationLoadResult {
        accountStore.load(now: now)
    }

    public func loadCurrent(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> SnapshotStoreLoadResult {
        stores.primary.loadCurrent(policy: policy, now: now)
    }

    public func importConfiguredAuthFiles(now: Date = Date()) {
        guard let bookmarkStore, let credentialStore else { return }
        let accountDocument = accountStore.load(now: now).document
        for account in accountDocument.accounts where account.isEnabled {
            guard account.connectorKind.importsAuthFileCredential,
                  let authPath = account.authPath
            else { continue }
            let expanded = NSString(string: authPath).expandingTildeInPath
            guard let data = try? bookmarkStore.readData(for: expanded) else { continue }
            try? credentialStore.save(data, accountID: account.id)
        }
    }

    public func loadHistory(query: SnapshotStoreQuery = SnapshotStoreQuery()) -> [StoredUsageSnapshot] {
        stores.primary.loadHistory(query: query)
    }

    public func refresh(now: Date = Date()) async throws -> SnapshotRefreshOutcome {
        importConfiguredAuthFiles(now: now)
        let accountDocument = accountStore.load(now: now).document
        let connectors = AccountConnectorFactory.connectors(
            from: accountDocument,
            bookmarkStore: bookmarkStore,
            credentialStore: credentialStore,
            requiresBookmarkedAuthFiles: ContextPanelLocations.isRunningInAppSandbox
        )
        let refreshResult = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: now)
        guard !refreshResult.reports.isEmpty else {
            return SnapshotRefreshOutcome(savedAt: now, refreshResult: refreshResult)
        }
        return try saveMerged(refreshResult: refreshResult, savedAt: now)
    }

    public func saveMerged(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date = Date(),
        preservesUnreportedAccounts: Bool = false
    ) throws -> SnapshotRefreshOutcome {
        try stores.primary.saveMerged(
            refreshResult: refreshResult,
            savedAt: savedAt,
            preservesUnreportedAccounts: preservesUnreportedAccounts
        )
        return SnapshotRefreshOutcome(savedAt: savedAt, refreshResult: refreshResult)
    }
}

private extension AccountConnectorKind {
    var importsAuthFileCredential: Bool {
        switch self {
        case .codexRateLimits, .geminiCodeAssist:
            true
        case .claudeLocalStatus, .claudeOAuthUsage:
            false
        }
    }
}
