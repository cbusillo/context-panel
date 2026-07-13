import Foundation
import Darwin
import OSLog

private let refreshDiagnosticsLogger = Logger(subsystem: "com.shinycomputers.contextpanel", category: "refresh")

public struct SnapshotRefreshStores: Sendable {
    public let primary: JSONSnapshotStore
    public let mirrors: [JSONSnapshotStore]

    public init(primary: JSONSnapshotStore, mirrors: [JSONSnapshotStore] = []) {
        self.primary = primary
        self.mirrors = mirrors
    }

    public static func appDefault(
        appGroupID: String = ContextPanelLocations.appGroupID,
        isRunningInAppSandbox: Bool = ContextPanelLocations.isRunningInAppSandbox
    ) -> SnapshotRefreshStores {
        let mirrors = isRunningInAppSandbox
            ? []
            : [JSONSnapshotStore(rootDirectory: ContextPanelLocations.widgetContainerLocalSnapshotDirectory())]
        return SnapshotRefreshStores(
            primary: JSONSnapshotStore(rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: appGroupID)),
            mirrors: mirrors
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

    public var diagnosticsDecision: RefreshDiagnosticsDecision {
        switch self {
        case .refreshed:
            .refreshed
        case .skippedFresh:
            .skippedFresh
        case .skippedAlreadyRunning:
            .skippedAlreadyRunning
        case .skippedNoReports:
            .skippedNoReports
        }
    }

    public var diagnosticsReportCount: Int? {
        guard case let .refreshed(outcome) = self else { return nil }
        return outcome.refreshResult.reports.count
    }

    public var diagnosticsLimitCount: Int? {
        guard case let .refreshed(outcome) = self else { return nil }
        return outcome.refreshResult.reports.flatMap(\.limits).count
    }

    public var diagnosticsFailureCount: Int? {
        guard case let .refreshed(outcome) = self else { return nil }
        return outcome.refreshResult.reports.filter { $0.status == .failure }.count
    }

    public var diagnosticsSavedSnapshotAt: Date? {
        guard case let .refreshed(outcome) = self else { return nil }
        return outcome.savedAt
    }
}

public struct SnapshotRefreshLock: Sendable {
    public let lockURL: URL
    public let staleAfter: TimeInterval
    public let legacyLockGracePeriod: TimeInterval

    public init(
        lockURL: URL,
        staleAfter: TimeInterval = 10 * 60,
        legacyLockGracePeriod: TimeInterval = 60
    ) {
        self.lockURL = lockURL
        self.staleAfter = staleAfter
        self.legacyLockGracePeriod = legacyLockGracePeriod
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
            if shouldPreserveExistingLock(fileManager: fileManager, now: now) {
                return nil
            }
            try? fileManager.removeItem(at: lockURL)
        }

        let descriptor = open(lockURL.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }
        do {
            try writeLockMetadata(to: descriptor)
            close(descriptor)
        } catch {
            close(descriptor)
            try? fileManager.removeItem(at: lockURL)
            throw error
        }
        defer { try? fileManager.removeItem(at: lockURL) }
        return try await operation()
    }

    private func shouldPreserveExistingLock(fileManager: FileManager, now: Date) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return false }
        let age = max(now.timeIntervalSince(modifiedAt), 0)
        guard age <= staleAfter else { return false }

        guard let data = try? Data(contentsOf: lockURL), !data.isEmpty else {
            return age <= legacyLockGracePeriod
        }
        guard let metadata = try? SnapshotRefreshLockMetadata.makeDecoder().decode(
            SnapshotRefreshLockMetadata.self,
            from: data
        ) else {
            return age <= legacyLockGracePeriod
        }
        return Self.processIsRunning(metadata.processID)
    }

    private func writeLockMetadata(to descriptor: Int32) throws {
        let metadata = SnapshotRefreshLockMetadata(processID: getpid())
        let data = try SnapshotRefreshLockMetadata.makeEncoder().encode(metadata)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                guard result > 0 else {
                    throw POSIXError(.EIO)
                }
                written += result
            }
        }
    }

    private static func processIsRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }
}

private struct SnapshotRefreshLockMetadata: Codable {
    let processID: Int32

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public struct SnapshotRefreshRunner: Sendable {
    public let service: SnapshotRefreshService
    public let stalenessPolicy: SnapshotStoreStalenessPolicy
    public let resetExpiryRefreshStore: ResetExpiryRefreshStateStore?
    public let lock: SnapshotRefreshLock?

    public init(
        service: SnapshotRefreshService,
        stalenessPolicy: SnapshotStoreStalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.refreshNeededAge),
        resetExpiryRefreshStore: ResetExpiryRefreshStateStore? = .appDefault(),
        lock: SnapshotRefreshLock? = .appDefault()
    ) {
        self.service = service
        self.stalenessPolicy = stalenessPolicy
        self.resetExpiryRefreshStore = resetExpiryRefreshStore
        self.lock = lock
    }

    public static func appDefault() -> SnapshotRefreshRunner {
        SnapshotRefreshRunner(service: .appDefault())
    }

    public func refreshIfNeeded(now: Date = Date()) async throws -> SnapshotRefreshRunDecision {
        service.importConfiguredAuthFiles(now: now)
        let stalenessPolicy = effectiveStalenessPolicy()
        let current = service.loadCurrent(policy: stalenessPolicy, now: now)
        let resetRefreshIsDue = stalenessPolicy.needsResetRefresh(for: current.snapshot, now: now)
        let promptCacheObservations = service.promptCacheObservations(now: now)
        if shouldSavePromptCacheOnly(
            current: current.snapshot,
            currentStatus: current.status,
            promptCacheObservations: promptCacheObservations,
            now: now
        ) {
            return try await saveMerged(
                refreshResult: ConnectorRefreshResult(
                    generatedAt: now,
                    reports: [],
                    promptCacheObservations: promptCacheObservations
                ),
                savedAt: now,
                retryFor: .zero,
                preservesUnreportedAccounts: true
            )
        }
        if isFreshPromptCacheOnly(current: current.snapshot, promptCacheObservations: promptCacheObservations, now: now) {
            return .skippedFresh
        }
        guard current.snapshot == nil
            || current.status == .unknown
            || current.status == .stale
            || current.status == .failure
            || resetRefreshIsDue
        else {
            return .skippedFresh
        }
        return try await refresh(now: now)
    }

    public func refresh(now: Date = Date()) async throws -> SnapshotRefreshRunDecision {
        let previousSnapshot = service.loadCurrent().snapshot?.snapshot
        if let lock {
            guard let outcome = try await lock.withLock(now: now, {
                try await service.refresh(now: now)
            }) else {
                deferResetExpiryRefreshAfterLockContention(previousSnapshot: previousSnapshot, savedAt: now)
                return .skippedAlreadyRunning
            }
            guard outcome.refreshResult.hasSnapshotPayload else {
                recordResetExpiryRefreshAttemptWithoutSnapshot(
                    previousSnapshot: previousSnapshot,
                    savedAt: outcome.savedAt
                )
                return .skippedNoReports
            }
            recordResetExpiryRefreshAttempt(
                previousSnapshot: previousSnapshot,
                refreshedSnapshot: service.loadCurrent().snapshot?.snapshot ?? outcome.refreshResult.snapshot,
                refreshResult: outcome.refreshResult,
                savedAt: outcome.savedAt
            )
            return .refreshed(outcome)
        }

        let outcome = try await service.refresh(now: now)
        guard outcome.refreshResult.hasSnapshotPayload else {
            recordResetExpiryRefreshAttemptWithoutSnapshot(previousSnapshot: previousSnapshot, savedAt: outcome.savedAt)
            return .skippedNoReports
        }
        recordResetExpiryRefreshAttempt(
            previousSnapshot: previousSnapshot,
            refreshedSnapshot: service.loadCurrent().snapshot?.snapshot ?? outcome.refreshResult.snapshot,
            refreshResult: outcome.refreshResult,
            savedAt: outcome.savedAt
        )
        return .refreshed(outcome)
    }

    public func nextRefreshCheckDate(now: Date = Date()) -> Date? {
        let current = service.loadCurrent().snapshot
        return Self.nextRefreshCheckDate(
            snapshot: current?.snapshot,
            resetExpiryRefreshState: resetExpiryRefreshStore?.load() ?? .empty,
            now: now
        )
    }

    public static func nextRefreshCheckDate(
        snapshot: UsageSnapshot?,
        resetExpiryRefreshState: ResetExpiryRefreshState = .empty,
        now: Date = Date()
    ) -> Date? {
        guard let snapshot else { return nil }
        return resetExpiryRefreshState.nextRefreshCheckDate(for: snapshot, now: now)
    }

    public static func nextRefreshCheckInterval(
        normalInterval: TimeInterval,
        nextCheckDate: Date?,
        startedAt: Date,
        finishedAt: Date
    ) -> TimeInterval {
        let normalWakeAt = startedAt.addingTimeInterval(normalInterval)
        let wakeAt = [normalWakeAt, nextCheckDate].compactMap { $0 }.min() ?? normalWakeAt
        return max(wakeAt.timeIntervalSince(finishedAt), 0)
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
        guard refreshResult.hasSnapshotPayload else { return .skippedNoReports }
        let previousSnapshot = service.loadCurrent().snapshot?.snapshot
        if let lock {
            guard let outcome = try await lock.withLock(now: savedAt, {
                try await service.saveMergedAsync(
                    refreshResult: refreshResult,
                    savedAt: savedAt,
                    preservesUnreportedAccounts: preservesUnreportedAccounts
                )
            }) else { return .skippedAlreadyRunning }
            recordResetExpiryRefreshAttempt(
                previousSnapshot: previousSnapshot,
                refreshedSnapshot: service.loadCurrent().snapshot?.snapshot ?? refreshResult.snapshot,
                refreshResult: refreshResult,
                savedAt: savedAt
            )
            return .refreshed(outcome)
        }

        let outcome = try await service.saveMergedAsync(
            refreshResult: refreshResult,
            savedAt: savedAt,
            preservesUnreportedAccounts: preservesUnreportedAccounts
        )
        recordResetExpiryRefreshAttempt(
            previousSnapshot: previousSnapshot,
            refreshedSnapshot: service.loadCurrent().snapshot?.snapshot ?? refreshResult.snapshot,
            refreshResult: refreshResult,
            savedAt: savedAt
        )
        return .refreshed(outcome)
    }

    private func effectiveStalenessPolicy() -> SnapshotStoreStalenessPolicy {
        SnapshotStoreStalenessPolicy(
            maximumAge: stalenessPolicy.maximumAge,
            resetExpiryRefreshState: resetExpiryRefreshStore?.load()
        )
    }

    private func recordResetExpiryRefreshAttempt(
        previousSnapshot: UsageSnapshot?,
        refreshedSnapshot: UsageSnapshot,
        refreshResult: ConnectorRefreshResult,
        savedAt: Date
    ) {
        guard let resetExpiryRefreshStore else { return }
        let attemptedAccounts = Set(refreshResult.reports.map(ResetExpiryRefreshAccountKey.init(report:)))
        try? resetExpiryRefreshStore.update { state in
            state.recordAttempt(
                previousSnapshot: previousSnapshot,
                refreshedSnapshot: refreshedSnapshot,
                attemptedAccounts: attemptedAccounts.isEmpty ? nil : attemptedAccounts,
                attemptedAt: savedAt
            )
        }
    }

    private func recordResetExpiryRefreshAttemptWithoutSnapshot(previousSnapshot: UsageSnapshot?, savedAt: Date) {
        guard let resetExpiryRefreshStore else { return }
        try? resetExpiryRefreshStore.update { state in
            state.recordAttemptWithoutSnapshot(previousSnapshot: previousSnapshot, attemptedAt: savedAt)
        }
    }

    private func deferResetExpiryRefreshAfterLockContention(previousSnapshot: UsageSnapshot?, savedAt: Date) {
        guard let resetExpiryRefreshStore else { return }
        try? resetExpiryRefreshStore.update { state in
            state.deferDueResets(previousSnapshot: previousSnapshot, attemptedAt: savedAt)
        }
    }

    private func shouldSavePromptCacheOnly(
        current: StoredUsageSnapshot?,
        currentStatus: UsageStatus,
        promptCacheObservations: [PromptCacheObservation],
        now: Date
    ) -> Bool {
        guard !promptCacheObservations.isEmpty else { return false }
        guard let current else { return false }
        guard current.snapshot.limits.isEmpty && current.reports.isEmpty || currentStatus != .stale && currentStatus != .failure && currentStatus != .unknown else {
            return false
        }
        let currentObservations = PromptCacheTelemetryReader.filteredRecentObservations(
            current.promptCacheObservations,
            now: now
        )
        return sortedPromptCacheObservations(currentObservations) != sortedPromptCacheObservations(promptCacheObservations)
    }

    private func isFreshPromptCacheOnly(
        current: StoredUsageSnapshot?,
        promptCacheObservations: [PromptCacheObservation],
        now: Date
    ) -> Bool {
        guard let current, current.snapshot.limits.isEmpty, current.reports.isEmpty else { return false }
        guard now.timeIntervalSince(current.savedAt) <= stalenessPolicy.maximumAge else { return false }
        return !promptCacheObservations.isEmpty && !shouldSavePromptCacheOnly(
            current: current,
            currentStatus: .healthy,
            promptCacheObservations: promptCacheObservations,
            now: now
        )
    }

    private func sortedPromptCacheObservations(_ observations: [PromptCacheObservation]) -> [PromptCacheObservation] {
        observations.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.observedAt < rhs.observedAt
        }
    }
}

public struct SnapshotRefreshService: Sendable {
    private let accountStore: AccountConfigurationStore
    private let stores: SnapshotRefreshStores
    private let bookmarkStore: SecureFileBookmarkStore?
    private let credentialStore: (any ProviderCredentialStoring)?
    private let googleAntigravitySnapshotLoader: (any GoogleAntigravityQuotaSnapshotLoading)?
    private let companionSyncPublisher: CompanionSyncPublisher?
    private let refreshDiagnosticsStore: RefreshDiagnosticsStateStore?
    private let promptCacheTelemetryMirror: @Sendable (SecureFileBookmarkStore?, [URL]) -> Void
    private let promptCacheTelemetryReader: @Sendable (Date) -> [PromptCacheObservation]

    public init(
        accountStore: AccountConfigurationStore,
        stores: SnapshotRefreshStores,
        bookmarkStore: SecureFileBookmarkStore? = nil,
        credentialStore: (any ProviderCredentialStoring)? = nil,
        googleAntigravitySnapshotLoader: (any GoogleAntigravityQuotaSnapshotLoading)? = nil,
        companionSyncPublisher: CompanionSyncPublisher? = nil,
        refreshDiagnosticsStore: RefreshDiagnosticsStateStore? = nil,
        promptCacheTelemetryMirror: @escaping @Sendable (SecureFileBookmarkStore?, [URL]) -> Void = { bookmarkStore, sourceDirectories in
            _ = try? PromptCacheTelemetryMirrorService.mirror(
                bookmarkStore: bookmarkStore,
                sourceDirectories: sourceDirectories
            )
        },
        promptCacheTelemetryReader: @escaping @Sendable (Date) -> [PromptCacheObservation] = { now in
            PromptCacheTelemetryReader.everyCodeUsageObservations(now: now)
        }
    ) {
        self.accountStore = accountStore
        self.stores = stores
        self.bookmarkStore = bookmarkStore
        self.credentialStore = credentialStore
        self.googleAntigravitySnapshotLoader = googleAntigravitySnapshotLoader
        self.companionSyncPublisher = companionSyncPublisher
        self.refreshDiagnosticsStore = refreshDiagnosticsStore
        self.promptCacheTelemetryMirror = promptCacheTelemetryMirror
        self.promptCacheTelemetryReader = promptCacheTelemetryReader
    }

    public static func appDefault(
        companionRemoteStore: CompanionRemoteSyncStore? = nil
    ) -> SnapshotRefreshService {
        SnapshotRefreshService(
            accountStore: AccountConfigurationStore(
                configurationURL: ContextPanelLocations.accountConfigurationURL(),
                fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
            ),
            stores: .appDefault(),
            bookmarkStore: SecureFileBookmarkStore(storeURL: ContextPanelLocations.bookmarkStoreURL()),
            credentialStore: ProviderCredentialStore(),
            companionSyncPublisher: .appDefault(remoteStore: companionRemoteStore),
            refreshDiagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
            )
        )
    }

    public func loadConfiguredAccounts(now: Date = Date()) -> AccountConfigurationLoadResult {
        let result = accountStore.load(now: now)
        migrateClaudeStateIfNeeded(accounts: result.document.accounts, now: now)
        return result
    }

    public func loadCurrent(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> SnapshotStoreLoadResult {
        stores.primary.loadCurrent(policy: policy, now: now)
    }

    public func loadCurrent() -> SnapshotStoreLoadResult {
        stores.primary.loadCurrent()
    }

    public func promptCacheObservations(now: Date = Date()) -> [PromptCacheObservation] {
        promptCacheTelemetryMirror(bookmarkStore, promptCacheTelemetrySourceDirectories(now: now))
        return promptCacheTelemetryReader(now)
    }

    public func promptCacheTelemetrySourceDirectories(now: Date = Date()) -> [URL] {
        let accounts = accountStore.load(now: now).document.accounts
        var sources = accounts.compactMap { account -> URL? in
            guard account.isEnabled, account.connectorKind == .codexRateLimits else { return nil }
            return Self.promptCacheTelemetryDirectory(for: account)
        }
        if sources.isEmpty {
            sources = ContextPanelLocations.everyCodeUsageDirectories()
        }
        return deduplicatedDirectories(sources)
    }

    private static func promptCacheTelemetryDirectory(for account: LocalProviderAccountConfiguration) -> URL? {
        ContextPanelLocations.promptCacheUsageDirectory(forAuthPath: account.effectiveAuthPath)
    }

    private func deduplicatedDirectories(_ directories: [URL]) -> [URL] {
        directories.reduce(into: [URL]()) { result, directory in
            let path = ContextPanelLocations.normalizedPath(directory.path)
            guard !result.contains(where: { ContextPanelLocations.normalizedPath($0.path) == path }) else { return }
            result.append(directory)
        }
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

    public func historyCount() -> Int {
        stores.primary.historyCount()
    }

    public func refresh(now: Date = Date()) async throws -> SnapshotRefreshOutcome {
        importConfiguredAuthFiles(now: now)
        let accountResult = accountStore.load(now: now)
        migrateClaudeStateIfNeeded(accounts: accountResult.document.accounts, now: now)
        let connectors = AccountConnectorFactory.connectors(
            from: accountResult.document,
            bookmarkStore: bookmarkStore,
            credentialStore: credentialStore,
            googleAntigravitySnapshotLoader: googleAntigravitySnapshotLoader,
            requiresBookmarkedAuthFiles: ContextPanelLocations.isRunningInAppSandbox
        )
        RefreshDiagnostics.logRefreshStarted(
            enabledAccountCount: accountResult.document.accounts.filter(\.isEnabled).count,
            connectorCount: connectors.count
        )
        let connectorResult = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: now)
        let refreshResult = ConnectorRefreshResult(
            generatedAt: connectorResult.generatedAt,
            reports: connectorResult.reports,
            promptCacheObservations: connectorResult.promptCacheObservations + promptCacheObservations(now: now)
        )
        RefreshDiagnostics.logProviderReports(refreshResult.reports, previous: stores.primary.loadCurrent().snapshot)
        guard refreshResult.hasSnapshotPayload else {
            RefreshDiagnostics.logRefreshSkippedNoPayload(reportCount: refreshResult.reports.count)
            return SnapshotRefreshOutcome(savedAt: now, refreshResult: refreshResult)
        }
        return try await saveMergedAsync(refreshResult: refreshResult, savedAt: now)
    }

    public func saveMergedAsync(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date = Date(),
        preservesUnreportedAccounts: Bool = false
    ) async throws -> SnapshotRefreshOutcome {
        try stores.primary.saveMerged(
            refreshResult: refreshResult,
            savedAt: savedAt,
            preservesUnreportedAccounts: preservesUnreportedAccounts
        )
        if let storedSnapshot = stores.primary.loadCurrent().snapshot {
            mirrorSnapshotToFallbackStores(storedSnapshot)
            let companionResult: CompanionSyncSaveResult? = if let companionSyncPublisher {
                await companionSyncPublisher.publishAll(
                    storedSnapshot: storedSnapshot,
                    publishedAt: savedAt,
                    observedBurnRates: companionObservedBurnRates(
                        storedSnapshot: storedSnapshot,
                        savedAt: savedAt
                    )
                )
            } else {
                nil
            }
            if let companionResult {
                let companionLoadRecord = companionSyncPublisher?.stores.loadWithDiagnostics(
                    policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge),
                    now: savedAt
                ).diagnosticsRecord(at: savedAt)
                try? refreshDiagnosticsStore?.update { state in
                    state.recordCompanionSync(companionResult.diagnosticsRecord(at: savedAt))
                    if let companionLoadRecord {
                        state.recordCompanionSync(companionLoadRecord)
                    }
                }
            }
        }
        return SnapshotRefreshOutcome(savedAt: savedAt, refreshResult: refreshResult)
    }

    private func mirrorSnapshotToFallbackStores(_ storedSnapshot: StoredUsageSnapshot) {
        for mirror in stores.mirrors {
            try? mirror.save(storedSnapshot)
        }
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
        if let storedSnapshot = stores.primary.loadCurrent().snapshot {
            mirrorSnapshotToFallbackStores(storedSnapshot)
            let companionResult = companionSyncPublisher?.publish(
                storedSnapshot: storedSnapshot,
                publishedAt: savedAt,
                observedBurnRates: companionObservedBurnRates(
                    storedSnapshot: storedSnapshot,
                    savedAt: savedAt
                )
            )
            if let companionResult {
                let companionLoadRecord = companionSyncPublisher?.stores.loadWithDiagnostics(
                    policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge),
                    now: savedAt
                ).diagnosticsRecord(at: savedAt)
                try? refreshDiagnosticsStore?.update { state in
                    state.recordCompanionSync(companionResult.diagnosticsRecord(at: savedAt))
                    if let companionLoadRecord {
                        state.recordCompanionSync(companionLoadRecord)
                    }
                }
            }
        }
        return SnapshotRefreshOutcome(savedAt: savedAt, refreshResult: refreshResult)
    }

    private func companionObservedBurnRates(
        storedSnapshot: StoredUsageSnapshot,
        savedAt: Date
    ) -> [String: ObservedBurnRate] {
        MainLimitBurnRateEstimator.observedBurnRates(
            current: storedSnapshot.snapshot,
            history: stores.primary.loadHistory(query: SnapshotStoreQuery(
                since: savedAt.addingTimeInterval(-24 * 3_600)
            )),
            now: savedAt
        )
    }

    private func migrateClaudeStateIfNeeded(accounts: [LocalProviderAccountConfiguration], now: Date) {
        if let credentialStore {
            ClaudeAccountMigration.migrateClaudeCredentials(credentialStore)
        }
        let migratedDocument = ClaudeAccountMigration.migrateAccountConfiguration(
            AccountConfigurationDocument(updatedAt: now, accounts: accounts),
            now: now
        )
        if migratedDocument.accounts != accounts {
            try? accountStore.save(migratedDocument)
        }
    }
}

private extension ConnectorRefreshResult {
    var hasSnapshotPayload: Bool {
        !reports.isEmpty || !promptCacheObservations.isEmpty
    }
}

enum RefreshDiagnostics {
    static func logRefreshStarted(enabledAccountCount: Int, connectorCount: Int) {
        refreshDiagnosticsLogger.notice(
            "provider refresh started enabledAccounts=\(enabledAccountCount, privacy: .public) connectors=\(connectorCount, privacy: .public)"
        )
    }

    static func logProviderReports(_ reports: [ProviderConnectorReport], previous: StoredUsageSnapshot?) {
        let ordinals = reportOrdinals(reports.map { ($0.provider, $0.accountID) })
        refreshDiagnosticsLogger.notice(
            "provider refresh completed reports=\(reports.count, privacy: .public) failures=\(reports.filter { $0.status == .failure }.count, privacy: .public) limits=\(reports.flatMap(\.limits).count, privacy: .public)"
        )
        for report in reports {
            let previousSummary = PreviousLimitSummary(
                limits: previous?.snapshot.limits.filter { $0.provider == report.provider && $0.accountID == report.accountID } ?? []
            )
            let ordinal = ordinals[ProviderAccountOrdinalKey(provider: report.provider, accountID: report.accountID)] ?? 0
            logProviderReport(report, ordinal: ordinal, previousSummary: previousSummary)
        }
    }

    static func logRefreshSkippedNoPayload(reportCount: Int) {
        refreshDiagnosticsLogger.notice(
            "provider refresh produced no snapshot payload reports=\(reportCount, privacy: .public)"
        )
    }

    private static func logProviderReport(
        _ report: ProviderConnectorReport,
        ordinal: Int,
        previousSummary: PreviousLimitSummary
    ) {
        refreshDiagnosticsLogger.notice(
            "provider report provider=\(report.provider.rawValue, privacy: .public) ordinal=\(ordinal, privacy: .public) status=\(report.status.rawValue, privacy: .public) limits=\(report.limits.count, privacy: .public) failureCategory=\(RefreshFailureCategory(errorMessage: report.errorMessage).rawValue, privacy: .public) previousLimits=\(previousSummary.count, privacy: .public) previousLimited=\(previousSummary.limitedCount, privacy: .public) previousMaxUsedPercent=\(previousSummary.maxUsedPercentDescription, privacy: .public) previousSoonestReset=\(previousSummary.soonestResetDescription, privacy: .public)"
        )
    }

    private static func reportOrdinals(_ keys: [(provider: Provider, accountID: String)]) -> [ProviderAccountOrdinalKey: Int] {
        var nextOrdinalByProvider: [Provider: Int] = [:]
        var ordinals: [ProviderAccountOrdinalKey: Int] = [:]
        for key in keys {
            let ordinalKey = ProviderAccountOrdinalKey(provider: key.provider, accountID: key.accountID)
            if ordinals[ordinalKey] != nil { continue }
            let ordinal = (nextOrdinalByProvider[key.provider] ?? 0) + 1
            nextOrdinalByProvider[key.provider] = ordinal
            ordinals[ordinalKey] = ordinal
        }
        return ordinals
    }
}

private struct ProviderAccountOrdinalKey: Hashable {
    let provider: Provider
    let accountID: String
}

private struct PreviousLimitSummary {
    let count: Int
    let limitedCount: Int
    let maxUsedPercent: Int?
    let soonestReset: Date?

    init(limits: [UsageLimit]) {
        count = limits.count
        limitedCount = limits.filter { $0.status == .limited }.count
        maxUsedPercent = limits
            .filter { $0.unit == .percent }
            .compactMap(\.used)
            .max()
        soonestReset = limits.compactMap(\.resetsAt).min()
    }

    var maxUsedPercentDescription: String {
        maxUsedPercent.map(String.init) ?? "none"
    }

    var soonestResetDescription: String {
        soonestReset.map { ContextPanelDateFormatting.string(from: $0) } ?? "none"
    }
}

enum RefreshFailureCategory: String {
    case none
    case providerAuthorization
    case oauthInvalidClient
    case oauthExpired
    case oauthMissingRefreshToken
    case credentialFormat
    case missingAuth
    case httpFailure
    case rateLimited
    case decoding
    case processFailure
    case filePermission
    case unknown

    init(errorMessage: String?) {
        guard let message = errorMessage?.lowercased(), !message.isEmpty else {
            self = .none
            return
        }
        if message.contains("no longer authorized") || message.contains("not authorized") || message.contains("unauthorized") || message.contains("rejected quota access") || message.contains("rejected") {
            self = .providerAuthorization
        } else if message.contains("invalid_client") || message.contains("oauth client was not found") {
            self = .oauthInvalidClient
        } else if message.contains("session has expired") || message.contains("invalid_grant") {
            self = .oauthExpired
        } else if message.contains("refresh token") {
            self = .oauthMissingRefreshToken
        } else if message.contains("unexpected format") || message.contains("does not contain") {
            self = .credentialFormat
        } else if message.contains("not connected")
            || message.contains("local login is missing an access token")
            || message.contains("local login was not found")
        {
            self = .missingAuth
        } else if message.contains("rate limited") {
            self = .rateLimited
        } else if message.contains("http") || message.contains("status code") || message.contains("response code") {
            self = .httpFailure
        } else if message.contains("decode") || message.contains("decoding") {
            self = .decoding
        } else if message.contains("exit code") {
            self = .processFailure
        } else if message.contains("permission") {
            self = .filePermission
        } else {
            self = .unknown
        }
    }
}

private extension AccountConnectorKind {
    var importsAuthFileCredential: Bool {
        switch self {
        case .codexRateLimits:
            true
        case .googleAntigravityQuota, .claudeOAuthUsage:
            false
        }
    }
}
