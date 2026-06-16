import Foundation
import OSLog

private let companionSyncLogger = Logger(subsystem: "com.shinycomputers.contextpanel", category: "companion-sync")

public struct CompanionSnapshot: Codable, Equatable, Sendable {
    /// Stored on the wire so older readers can detect newer companion payloads.
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let publishedAt: Date
    public let limits: [CompanionLimit]
    public let providerStatuses: [CompanionProviderStatus]
    public let promptCacheSummaries: [CompanionPromptCacheSummary]

    public init(
        generatedAt: Date,
        publishedAt: Date,
        limits: [CompanionLimit],
        providerStatuses: [CompanionProviderStatus],
        promptCacheSummaries: [CompanionPromptCacheSummary]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.publishedAt = publishedAt
        self.limits = limits
        self.providerStatuses = providerStatuses
        self.promptCacheSummaries = promptCacheSummaries
    }

    public init(storedSnapshot: StoredUsageSnapshot, publishedAt: Date = Date()) {
        self.init(
            generatedAt: storedSnapshot.snapshot.generatedAt,
            publishedAt: publishedAt,
            limits: storedSnapshot.snapshot.limits.map(CompanionLimit.init(limit:)),
            providerStatuses: storedSnapshot.reports.map(CompanionProviderStatus.init(report:)),
            promptCacheSummaries: CompanionPromptCacheSummary.summaries(
                observations: storedSnapshot.promptCacheObservations,
                accountAliases: CompanionPromptCacheAccountAliases(storedSnapshot: storedSnapshot)
            )
        )
    }
}

public struct CompanionSyncDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let snapshot: CompanionSnapshot
    public let widgetDisplayPreferences: WidgetDisplayPreferences
    public let fastModeForecastSettings: FastModeForecastSettings

    public init(
        snapshot: CompanionSnapshot,
        widgetDisplayPreferences: WidgetDisplayPreferences = .defaultPreferences,
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings
    ) {
        schemaVersion = Self.schemaVersion
        self.snapshot = snapshot
        self.widgetDisplayPreferences = widgetDisplayPreferences
        self.fastModeForecastSettings = fastModeForecastSettings
    }

    public init(
        storedSnapshot: StoredUsageSnapshot,
        publishedAt: Date = Date(),
        widgetDisplayPreferences: WidgetDisplayPreferences = .defaultPreferences,
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings
    ) {
        self.init(
            snapshot: CompanionSnapshot(storedSnapshot: storedSnapshot, publishedAt: publishedAt),
            widgetDisplayPreferences: widgetDisplayPreferences,
            fastModeForecastSettings: fastModeForecastSettings
        )
    }
}

public struct CompanionSyncLoadResult: Equatable, Sendable {
    public let document: CompanionSyncDocument?
    public let status: UsageStatus
    public let errorMessage: String?

    public init(document: CompanionSyncDocument?, status: UsageStatus, errorMessage: String? = nil) {
        self.document = document
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }
}

public struct CompanionSyncStoreFailure: Equatable, Sendable {
    public let documentURL: URL
    public let errorMessage: String

    public init(documentURL: URL, errorMessage: String) {
        self.documentURL = documentURL
        self.errorMessage = ConnectorRedactor.redact(errorMessage)
    }
}

public struct CompanionSyncSaveResult: Equatable, Sendable {
    public let attemptedStoreCount: Int
    public let successfulStoreCount: Int
    public let failures: [CompanionSyncStoreFailure]

    public init(attemptedStoreCount: Int, successfulStoreCount: Int, failures: [CompanionSyncStoreFailure]) {
        self.attemptedStoreCount = attemptedStoreCount
        self.successfulStoreCount = successfulStoreCount
        self.failures = failures
    }

    public var succeeded: Bool {
        successfulStoreCount > 0
    }
}

public struct CompanionSyncStore: Sendable {
    public let documentURL: URL

    public init(documentURL: URL) {
        self.documentURL = documentURL
    }

    public func save(_ document: CompanionSyncDocument) throws {
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(document)
        try coordinatedWrite(data: data)
    }

    public func load() -> CompanionSyncLoadResult {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return CompanionSyncLoadResult(document: nil, status: .unknown)
        }

        do {
            let document = try loadDocument()
            return CompanionSyncLoadResult(document: document, status: document.companionStatus)
        } catch {
            return CompanionSyncLoadResult(document: nil, status: .failure, errorMessage: error.localizedDescription)
        }
    }

    public func load(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> CompanionSyncLoadResult {
        let result = load()
        guard let document = result.document else { return result }
        let status = now.timeIntervalSince(document.snapshot.generatedAt) > policy.maximumAge
            ? .stale
            : document.companionStatus
        return CompanionSyncLoadResult(document: document, status: status, errorMessage: result.errorMessage)
    }

    public func saveResult(_ document: CompanionSyncDocument) -> CompanionSyncSaveResult {
        do {
            try save(document)
            return CompanionSyncSaveResult(attemptedStoreCount: 1, successfulStoreCount: 1, failures: [])
        } catch {
            return CompanionSyncSaveResult(
                attemptedStoreCount: 1,
                successfulStoreCount: 0,
                failures: [CompanionSyncStoreFailure(documentURL: documentURL, errorMessage: error.localizedDescription)]
            )
        }
    }

    private func loadDocument() throws -> CompanionSyncDocument {
        let document = try Self.makeDecoder().decode(
            CompanionSyncDocument.self,
            from: try coordinatedRead()
        )
        guard document.schemaVersion == CompanionSyncDocument.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
        }
        guard document.snapshot.schemaVersion == CompanionSnapshot.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.snapshot.schemaVersion)
        }
        return document
    }

    private func coordinatedRead() throws -> Data {
        var readData: Data?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: documentURL,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                readData = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let readError { throw readError }
        if let coordinatorError { throw coordinatorError }
        return try readData ?? Data(contentsOf: documentURL)
    }

    private func coordinatedWrite(data: Data) throws {
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: documentURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL)
            } catch {
                writeError = error
            }
        }

        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct CompanionSyncStoreResolver: Sendable {
    private let resolveStore: @Sendable () -> CompanionSyncStore?

    public init(_ resolveStore: @escaping @Sendable () -> CompanionSyncStore?) {
        self.resolveStore = resolveStore
    }

    public func resolve() -> CompanionSyncStore? {
        resolveStore()
    }
}

public struct CompanionSyncStoreSet: Sendable {
    public let stores: [CompanionSyncStore]
    public let lazyStores: [CompanionSyncStoreResolver]

    public init(stores: [CompanionSyncStore], lazyStores: [CompanionSyncStoreResolver] = []) {
        self.stores = stores
        self.lazyStores = lazyStores
    }

    @discardableResult
    public func save(_ document: CompanionSyncDocument) -> CompanionSyncSaveResult {
        var successfulStoreCount = 0
        var failures: [CompanionSyncStoreFailure] = []
        let stores = resolvedStores()
        for store in stores {
            let result = store.saveResult(document)
            successfulStoreCount += result.successfulStoreCount
            failures.append(contentsOf: result.failures)
        }
        return CompanionSyncSaveResult(
            attemptedStoreCount: stores.count,
            successfulStoreCount: successfulStoreCount,
            failures: failures
        )
    }

    public func load(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> CompanionSyncLoadResult {
        var bestResult: CompanionSyncLoadResult?
        var firstFailure: CompanionSyncLoadResult?
        for store in resolvedStores() {
            let result = store.load(policy: policy, now: now)
            if result.document != nil {
                bestResult = Self.preferredResult(lhs: bestResult, rhs: result)
                continue
            }
            if result.status == .failure, firstFailure == nil {
                firstFailure = result
            }
        }
        return bestResult ?? firstFailure ?? CompanionSyncLoadResult(document: nil, status: .unknown)
    }

    private func resolvedStores() -> [CompanionSyncStore] {
        stores + lazyStores.compactMap { $0.resolve() }
    }

    private static func preferredResult(
        lhs: CompanionSyncLoadResult?,
        rhs: CompanionSyncLoadResult
    ) -> CompanionSyncLoadResult {
        guard let lhs else { return rhs }
        guard let lhsDocument = lhs.document, let rhsDocument = rhs.document else { return lhs }

        if lhs.status == .stale, rhs.status != .stale { return rhs }
        if lhs.status != .stale, rhs.status == .stale { return lhs }
        if lhsDocument.snapshot.generatedAt != rhsDocument.snapshot.generatedAt {
            return lhsDocument.snapshot.generatedAt < rhsDocument.snapshot.generatedAt ? rhs : lhs
        }
        return lhsDocument.snapshot.publishedAt < rhsDocument.snapshot.publishedAt ? rhs : lhs
    }
}

public struct CompanionSyncPublisher: Sendable {
    public let stores: CompanionSyncStoreSet
    public let widgetPreferencesStore: WidgetDisplayPreferencesStore
    public let fastModeForecastSettingsStore: FastModeForecastSettingsStore

    public init(
        stores: CompanionSyncStoreSet,
        widgetPreferencesStore: WidgetDisplayPreferencesStore,
        fastModeForecastSettingsStore: FastModeForecastSettingsStore
    ) {
        self.stores = stores
        self.widgetPreferencesStore = widgetPreferencesStore
        self.fastModeForecastSettingsStore = fastModeForecastSettingsStore
    }

    public static func appDefault() -> CompanionSyncPublisher {
        CompanionSyncPublisher(
            stores: ContextPanelLocations.companionSyncStoreSet(),
            widgetPreferencesStore: WidgetDisplayPreferencesStore(
                preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            fastModeForecastSettingsStore: FastModeForecastSettingsStore(
                settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
            )
        )
    }

    @discardableResult
    public func publish(storedSnapshot: StoredUsageSnapshot, publishedAt: Date = Date()) -> CompanionSyncSaveResult {
        let document = CompanionSyncDocument(
            storedSnapshot: storedSnapshot,
            publishedAt: publishedAt,
            widgetDisplayPreferences: widgetPreferencesStore.load(),
            fastModeForecastSettings: fastModeForecastSettingsStore.load()
        )
        let result = stores.save(document)
        if !result.succeeded {
            companionSyncLogger.error("companion sync publish failed stores=\(result.attemptedStoreCount, privacy: .public)")
        } else if !result.failures.isEmpty {
            companionSyncLogger.warning("companion sync publish partially failed succeeded=\(result.successfulStoreCount, privacy: .public) failed=\(result.failures.count, privacy: .public)")
        }
        return result
    }
}

public struct CompanionLimit: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let label: String
    public let windowLabel: String?
    public let modelLabel: String?
    public let unit: UsageUnit
    public let used: Int?
    public let limit: Int?
    public let resetsAt: Date?
    public let lastUpdatedAt: Date?
    public let confidence: UsageConfidence
    public let status: UsageStatus

    public init(limit: UsageLimit) {
        provider = limit.provider
        companionAccountID = CompanionAccountIdentity.id(
            provider: limit.provider,
            accountID: limit.accountID,
            configuredAccountID: limit.configuredAccountID
        )
        accountName = CompanionAccountIdentity.displayName(limit.accountName)
        label = limit.label
        windowLabel = limit.windowLabel
        modelLabel = limit.modelLabel
        unit = limit.unit
        used = limit.used
        self.limit = limit.limit
        resetsAt = limit.resetsAt
        lastUpdatedAt = limit.lastUpdatedAt
        confidence = limit.confidence
        status = limit.status
    }

    public var usageLimit: UsageLimit {
        UsageLimit(
            provider: provider,
            accountID: companionAccountID,
            configuredAccountID: companionAccountID,
            accountName: accountName,
            label: label,
            windowLabel: windowLabel,
            modelLabel: modelLabel,
            unit: unit,
            used: used,
            limit: limit,
            resetsAt: resetsAt,
            lastUpdatedAt: lastUpdatedAt,
            confidence: confidence,
            statusOverride: status
        )
    }
}

public struct CompanionProviderStatus: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let generatedAt: Date
    public let status: UsageStatus

    public init(report: StoredProviderReport) {
        provider = report.provider
        companionAccountID = CompanionAccountIdentity.id(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID
        )
        accountName = CompanionAccountIdentity.displayName(report.accountName)
        generatedAt = report.generatedAt
        status = report.status
    }

    public var storedProviderReport: StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: companionAccountID,
            configuredAccountID: companionAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            status: status,
            errorMessage: nil
        )
    }
}

public struct CompanionPromptCacheSummary: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let latestObservedAt: Date
    public let latestHitRate: Double?
    public let tokenWeightedHitRate: Double?
    public let totalInputTokens: Int
    public let totalCachedInputTokens: Int

    public static func summaries(observations: [PromptCacheObservation]) -> [CompanionPromptCacheSummary] {
        summaries(observations: observations, accountAliases: CompanionPromptCacheAccountAliases())
    }

    fileprivate static func summaries(
        observations: [PromptCacheObservation],
        accountAliases: CompanionPromptCacheAccountAliases
    ) -> [CompanionPromptCacheSummary] {
        Dictionary(grouping: observations) { observation in
            CompanionPromptCacheGroup(observation: observation, accountAliases: accountAliases)
        }
            .map { group, observations in
                CompanionPromptCacheSummary(group: group, observations: observations)
            }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
                return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
    }

    private init(group: CompanionPromptCacheGroup, observations: [PromptCacheObservation]) {
        let summary = PromptCacheSummary(observations: observations)
        provider = group.provider
        companionAccountID = group.companionAccountID
        accountName = group.accountName
        latestObservedAt = summary.latest?.observedAt ?? observations.map(\.observedAt).max() ?? Date(timeIntervalSince1970: 0)
        latestHitRate = summary.latestHitRate
        tokenWeightedHitRate = summary.tokenWeightedHitRate
        totalInputTokens = summary.totalInputTokens
        totalCachedInputTokens = summary.totalCachedInputTokens
    }

    public var promptCacheObservation: PromptCacheObservation {
        PromptCacheObservation(
            provider: provider,
            accountID: companionAccountID,
            accountName: accountName,
            observedAt: latestObservedAt,
            windowLabel: "Latest synced",
            tokens: PromptCacheTokenSet(
                inputTokens: totalInputTokens,
                cachedInputTokens: totalCachedInputTokens
            )
        )
    }
}

private extension Array where Element == CompanionLimit {
    var contextPanelWorstStatus: UsageStatus {
        map(\.status).contextPanelWorstStatus
    }
}

private extension CompanionSyncDocument {
    var companionStatus: UsageStatus {
        let limitStatuses = snapshot.limits.map(\.status)
        let providerStatuses = snapshot.providerStatuses.map(\.status)
        let statuses = limitStatuses + providerStatuses
        guard !statuses.isEmpty else { return .unknown }
        return statuses.contextPanelWorstStatus
    }
}

private struct CompanionPromptCacheGroup: Hashable {
    let provider: Provider
    let companionAccountID: String
    let accountName: String

    init(observation: PromptCacheObservation, accountAliases: CompanionPromptCacheAccountAliases) {
        provider = observation.provider
        companionAccountID = CompanionAccountIdentity.id(
            provider: observation.provider,
            accountID: observation.accountID,
            configuredAccountID: accountAliases.configuredAccountID(
                provider: observation.provider,
                accountID: observation.accountID
            )
        )
        accountName = CompanionAccountIdentity.displayName(observation.accountName)
    }
}

private struct CompanionPromptCacheAccountAliases: Sendable {
    private let configuredAccountIDsByRawKey: [ProviderAccountKey: String]

    init(storedSnapshot: StoredUsageSnapshot? = nil) {
        guard let storedSnapshot else {
            configuredAccountIDsByRawKey = [:]
            return
        }

        var aliases: [ProviderAccountKey: String] = [:]
        for limit in storedSnapshot.snapshot.limits {
            guard let configuredAccountID = limit.configuredAccountID else { continue }
            aliases[ProviderAccountKey(provider: limit.provider, accountID: limit.accountID)] = configuredAccountID
        }
        for report in storedSnapshot.reports {
            guard let configuredAccountID = report.configuredAccountID else { continue }
            aliases[ProviderAccountKey(provider: report.provider, accountID: report.accountID)] = configuredAccountID
        }
        configuredAccountIDsByRawKey = aliases
    }

    func configuredAccountID(provider: Provider, accountID: String) -> String? {
        configuredAccountIDsByRawKey[ProviderAccountKey(provider: provider, accountID: accountID)]
    }
}

private struct ProviderAccountKey: Hashable, Sendable {
    let provider: Provider
    let accountID: String
}

private enum CompanionAccountIdentity {
    static func id(provider: Provider, accountID: String, configuredAccountID: String?) -> String {
        ConnectorRedactor.localAccountID(
            provider: provider,
            stableID: "companion:\(configuredAccountID ?? accountID)"
        )
    }

    static func displayName(_ value: String) -> String {
        let redacted = ConnectorRedactor.redact(value)
        let pathRedacted = ConnectorRedactor.redactedPath(redacted)
        return pathRedacted.isEmpty ? "Account" : pathRedacted
    }
}
