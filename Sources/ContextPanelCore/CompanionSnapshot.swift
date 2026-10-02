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

    public init(storedSnapshot original: StoredUsageSnapshot, publishedAt: Date = Date(), configuration: [LocalProviderAccountConfiguration] = [], publisherID: String? = nil) {
        let storedSnapshot = original.selectingSharedAccountObservations()
        self.init(
            generatedAt: storedSnapshot.snapshot.generatedAt,
            publishedAt: publishedAt,
            limits: storedSnapshot.snapshot.limits.map { limit in
                CompanionLimit(limit: limit, identityConfiguredAccountID: AccountDisplayMetadata.companionIdentityOverride(
                    provider: limit.provider, rawID: limit.accountID, configuredID: limit.configuredAccountID,
                    configuration: configuration, publisherID: publisherID),
                    sharedIdentity: storedSnapshot.reports.first { $0.provider == limit.provider && $0.accountID == limit.accountID }?.sharedAccountIdentity)
            },
            providerStatuses: storedSnapshot.reports.map { report in
                CompanionProviderStatus(report: report, identityConfiguredAccountID: AccountDisplayMetadata.companionIdentityOverride(
                    provider: report.provider, rawID: report.accountID, configuredID: report.configuredAccountID,
                    configuration: configuration, publisherID: publisherID))
            },
            promptCacheSummaries: CompanionPromptCacheSummary.summaries(
                observations: storedSnapshot.promptCacheObservations,
                accountAliases: CompanionPromptCacheAccountAliases(storedSnapshot: storedSnapshot, configuration: configuration, publisherID: publisherID)
            )
        )
    }
}

public struct CompanionSyncDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let snapshot: CompanionSnapshot
    public let widgetDisplayPreferences: WidgetDisplayPreferences
    public let observedBurnRates: [String: ObservedBurnRate]
    public let fastModeForecastSettings: FastModeForecastSettings
    public let accountRetentionStates: [CompanionAccountRetentionState]?
    public let cloudKitUserScope: CompanionCloudKitUserScope?
    public let accountDisplayMetadata: [AccountDisplayMetadata]?
    public let removedDisplayIDs: [String]?
    public let accountBurnRates: [String: [String: ObservedBurnRate]]?
    public let accountIdentityAliases: [CompanionAccountIdentityAlias]?
    public let accountRemovalDates: [String: Date]?
    public let accountRestorationDates: [String: Date]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshot
        case widgetDisplayPreferences
        case observedBurnRates
        case fastModeForecastSettings
        case accountRetentionStates
        case cloudKitUserScope
        case accountDisplayMetadata
        case removedDisplayIDs
        case accountBurnRates
        case accountIdentityAliases
        case accountRemovalDates
        case accountRestorationDates
    }

    public init(
        snapshot: CompanionSnapshot,
        widgetDisplayPreferences: WidgetDisplayPreferences = .defaultPreferences,
        observedBurnRates: [String: ObservedBurnRate] = [:],
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings,
        accountRetentionStates: [CompanionAccountRetentionState]? = nil,
        cloudKitUserScope: CompanionCloudKitUserScope? = nil,
        accountDisplayMetadata: [AccountDisplayMetadata]? = nil,
        removedDisplayIDs: [String]? = nil,
        accountBurnRates: [String: [String: ObservedBurnRate]]? = nil,
        accountIdentityAliases: [CompanionAccountIdentityAlias]? = nil,
        accountRemovalDates: [String: Date]? = nil,
        accountRestorationDates: [String: Date]? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.snapshot = snapshot
        self.widgetDisplayPreferences = widgetDisplayPreferences
        self.observedBurnRates = observedBurnRates
        self.fastModeForecastSettings = fastModeForecastSettings
        self.accountRetentionStates = accountRetentionStates
        self.cloudKitUserScope = cloudKitUserScope
        self.accountDisplayMetadata = accountDisplayMetadata
        self.removedDisplayIDs = removedDisplayIDs
        self.accountBurnRates = accountBurnRates
        self.accountIdentityAliases = accountIdentityAliases
        self.accountRemovalDates = accountRemovalDates
        self.accountRestorationDates = accountRestorationDates
    }

    public init(
        storedSnapshot: StoredUsageSnapshot,
        publishedAt: Date = Date(),
        widgetDisplayPreferences: WidgetDisplayPreferences = .defaultPreferences,
        observedBurnRates: [String: ObservedBurnRate] = [:],
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings,
        accountRetentionStates: [CompanionAccountRetentionState]? = nil,
        cloudKitUserScope: CompanionCloudKitUserScope? = nil,
        accountDisplayMetadata: [AccountDisplayMetadata]? = nil,
        removedDisplayIDs: [String]? = nil,
        accountBurnRates: [String: [String: ObservedBurnRate]]? = nil,
        accountIdentityAliases: [CompanionAccountIdentityAlias]? = nil,
        accountRemovalDates: [String: Date]? = nil,
        accountRestorationDates: [String: Date]? = nil
    ) {
        self.init(
            snapshot: CompanionSnapshot(storedSnapshot: storedSnapshot, publishedAt: publishedAt),
            widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: fastModeForecastSettings,
            accountRetentionStates: accountRetentionStates,
            cloudKitUserScope: cloudKitUserScope,
            accountDisplayMetadata: accountDisplayMetadata,
            removedDisplayIDs: removedDisplayIDs,
            accountBurnRates: accountBurnRates,
            accountIdentityAliases: accountIdentityAliases,
            accountRemovalDates: accountRemovalDates,
            accountRestorationDates: accountRestorationDates
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        snapshot = try container.decode(CompanionSnapshot.self, forKey: .snapshot)
        widgetDisplayPreferences = try container.decode(WidgetDisplayPreferences.self, forKey: .widgetDisplayPreferences)
        observedBurnRates = try container.decodeIfPresent(
            [String: ObservedBurnRate].self,
            forKey: .observedBurnRates
        ) ?? [:]
        fastModeForecastSettings = try container.decode(FastModeForecastSettings.self, forKey: .fastModeForecastSettings)
        accountRetentionStates = try container.decodeIfPresent(
            [CompanionAccountRetentionState].self,
            forKey: .accountRetentionStates
        )
        accountDisplayMetadata = try container.decodeIfPresent([AccountDisplayMetadata].self, forKey: .accountDisplayMetadata)
        removedDisplayIDs = try container.decodeIfPresent([String].self, forKey: .removedDisplayIDs)
        accountBurnRates = try container.decodeIfPresent([String: [String: ObservedBurnRate]].self, forKey: .accountBurnRates)
        accountIdentityAliases = try? container.decode([CompanionAccountIdentityAlias].self, forKey: .accountIdentityAliases)
        accountRemovalDates = try container.decodeIfPresent([String: Date].self, forKey: .accountRemovalDates)
        accountRestorationDates = try container.decodeIfPresent([String: Date].self, forKey: .accountRestorationDates)
        cloudKitUserScope = try container.decodeIfPresent(
            CompanionCloudKitUserScope.self,
            forKey: .cloudKitUserScope
        )
    }

    public func bound(to scope: CompanionCloudKitUserScope) -> CompanionSyncDocument {
        CompanionSyncDocument(
            snapshot: snapshot,
            widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: fastModeForecastSettings,
            accountRetentionStates: accountRetentionStates,
            cloudKitUserScope: scope,
            accountDisplayMetadata: accountDisplayMetadata,
            removedDisplayIDs: removedDisplayIDs,
            accountBurnRates: accountBurnRates,
            accountIdentityAliases: accountIdentityAliases,
            accountRemovalDates: accountRemovalDates,
            accountRestorationDates: accountRestorationDates
        )
    }
}

public struct CompanionAccountRetentionState: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let firstIncompleteObservationAt: Date

    public init(
        provider: Provider,
        companionAccountID: String,
        firstIncompleteObservationAt: Date
    ) {
        self.provider = provider
        self.companionAccountID = companionAccountID
        self.firstIncompleteObservationAt = firstIncompleteObservationAt
    }
}

public struct CompanionSyncLoadResult: Equatable, Sendable {
    public let document: CompanionSyncDocument?
    public let status: UsageStatus
    public let errorMessage: String?
    public let transportMetadata: CompanionSyncTransportMetadata?
    public let transportStatuses: [CompanionSyncTransportStatus]

    public init(
        document: CompanionSyncDocument?,
        status: UsageStatus,
        errorMessage: String? = nil,
        transportMetadata: CompanionSyncTransportMetadata? = nil,
        transportStatuses: [CompanionSyncTransportStatus] = []
    ) {
        self.document = document
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
        self.transportMetadata = transportMetadata
        self.transportStatuses = transportStatuses
    }
}

public struct CompanionSyncStoreFailure: Equatable, Sendable {
    public let documentURL: URL
    public let errorMessage: String
    public let errorDomain: String
    public let errorCode: Int

    public init(documentURL: URL, errorMessage: String) {
        self.init(documentURL: documentURL, errorMessage: errorMessage, errorDomain: "unknown", errorCode: 0)
    }

    public init(documentURL: URL, error: Error) {
        let nsError = error as NSError
        let storeRole = Self.storeRole(for: documentURL)
        self.init(
            documentURL: documentURL,
            errorMessage: Self.diagnosticErrorMessage(
                storeRole: storeRole,
                operation: "write",
                errorDomain: nsError.domain,
                errorCode: nsError.code
            ),
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
    }

    private init(documentURL: URL, errorMessage: String, errorDomain: String, errorCode: Int) {
        self.documentURL = documentURL
        self.errorMessage = ConnectorRedactor.safeErrorDescription(errorMessage)
        self.errorDomain = ConnectorRedactor.redact(errorDomain)
        self.errorCode = errorCode
    }

    public var storeRole: String {
        Self.storeRole(for: documentURL)
    }

    public static func storeRole(for documentURL: URL) -> String {
        let path = documentURL.path
        if path.contains("Mobile Documents") || path.contains(".icloud") {
            return "icloud"
        }
        if path.contains(ContextPanelLocations.appGroupID)
            || path.contains(ContextPanelLocations.companionAppGroupID)
        {
            return "app-group"
        }
        return "custom"
    }

    public static func diagnosticErrorMessage(
        storeRole: String,
        operation: String,
        errorDomain: String,
        errorCode: Int
    ) -> String {
        "\(storeDisplayName(storeRole)) sync store \(operation) failed (\(ConnectorRedactor.redact(errorDomain)) \(errorCode))."
    }

    public static func diagnosticErrorMessage(storeRole: String, operation: String, error: Error) -> String {
        let nsError = error as NSError
        return diagnosticErrorMessage(
            storeRole: storeRole,
            operation: operation,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
    }

    public static func storeDisplayName(_ storeRole: String) -> String {
        storeRole == "icloud" ? "iCloud" : storeRole
    }
}

public struct CompanionSyncSaveResult: Equatable, Sendable {
    public let attemptedStoreCount: Int
    public let successfulStoreCount: Int
    public let failures: [CompanionSyncStoreFailure]
    public let storeOutcomes: [CompanionSyncStoreOutcome]

    public init(
        attemptedStoreCount: Int,
        successfulStoreCount: Int,
        failures: [CompanionSyncStoreFailure],
        storeOutcomes: [CompanionSyncStoreOutcome] = []
    ) {
        self.attemptedStoreCount = attemptedStoreCount
        self.successfulStoreCount = successfulStoreCount
        self.failures = failures
        self.storeOutcomes = storeOutcomes
    }

    public var succeeded: Bool {
        successfulStoreCount > 0
    }

    public func diagnosticsRecord(at attemptedAt: Date) -> CompanionSyncDiagnosticsRecord {
        let appGroupOutcomes = storeOutcomes.filter { $0.storeRole == "app-group" }
        let iCloudOutcomes = storeOutcomes.filter { $0.storeRole == "icloud" }
        let cloudKitOutcomes = storeOutcomes.filter { $0.storeRole == CompanionRemoteSync.cloudKitStoreRole }
        let appGroupSucceeded = appGroupOutcomes.isEmpty ? nil : appGroupOutcomes.contains { $0.succeeded }
        let iCloudSucceeded = iCloudOutcomes.isEmpty ? nil : iCloudOutcomes.contains { $0.succeeded }
        let iCloudAvailable = iCloudOutcomes.isEmpty ? nil : iCloudOutcomes.contains { $0.isAvailable }
        let cloudKitSucceeded = cloudKitOutcomes.isEmpty ? nil : cloudKitOutcomes.contains { $0.succeeded }
        let cloudKitAvailable = cloudKitOutcomes.isEmpty ? nil : cloudKitOutcomes.contains { $0.isAvailable }
        let hasOutcomeFailure = storeOutcomes.contains { !$0.succeeded }
        let outcome: CompanionSyncDiagnosticsOutcome
        if !hasOutcomeFailure, successfulStoreCount == attemptedStoreCount, attemptedStoreCount > 0 {
            outcome = .healthy
        } else if successfulStoreCount > 0 {
            outcome = .partial
        } else {
            outcome = .failed
        }
        return CompanionSyncDiagnosticsRecord(
            operation: .publish,
            outcome: outcome,
            attemptedAt: attemptedAt,
            appGroupSucceeded: appGroupSucceeded,
            iCloudSucceeded: iCloudSucceeded,
            iCloudAvailable: iCloudAvailable,
            cloudKitSucceeded: cloudKitSucceeded,
            cloudKitAvailable: cloudKitAvailable,
            errorMessage: failures.first?.errorMessage ?? storeOutcomes.first(where: { !$0.succeeded })?.errorMessage
        )
    }
}

public enum CompanionSyncConditionalSaveResult: Equatable, Sendable {
    case saved(CompanionSyncSaveResult)
    case keptCurrent(CompanionSyncLoadResult)
}

public enum CompanionSyncScopedConditionalSaveResult: Equatable, Sendable {
    case saved(CompanionSyncSaveResult)
    case keptCurrent(CompanionSyncLoadResult)
    case scopeConflict
}

public enum CompanionSyncConditionalRemoveResult: Equatable, Sendable {
    case removed
    case keptCurrent(CompanionSyncLoadResult)
    case failed(String)
}

public struct CompanionSyncLoadDiagnosticsResult: Equatable, Sendable {
    public let result: CompanionSyncLoadResult
    public let storeOutcomes: [CompanionSyncStoreOutcome]
    public let selectedStoreRole: String?
    public let selectedStoreIsICloud: Bool

    public init(
        result: CompanionSyncLoadResult,
        storeOutcomes: [CompanionSyncStoreOutcome],
        selectedStoreRole: String? = nil,
        selectedStoreIsICloud: Bool = false
    ) {
        self.result = result
        self.storeOutcomes = storeOutcomes
        self.selectedStoreRole = selectedStoreRole.map { ConnectorRedactor.redact($0) }
        self.selectedStoreIsICloud = selectedStoreIsICloud
    }

    public func diagnosticsRecord(at attemptedAt: Date) -> CompanionSyncDiagnosticsRecord {
        let appGroupOutcomes = storeOutcomes.filter { $0.storeRole == "app-group" }
        let iCloudOutcomes = storeOutcomes.filter { $0.storeRole == "icloud" }
        let cloudKitOutcomes = storeOutcomes.filter { $0.storeRole == CompanionRemoteSync.cloudKitStoreRole }
        let appGroupSucceeded = appGroupOutcomes.isEmpty ? nil : appGroupOutcomes.contains { $0.succeeded }
        let iCloudSucceeded = iCloudOutcomes.isEmpty ? nil : iCloudOutcomes.contains { $0.succeeded }
        let iCloudAvailable = iCloudOutcomes.isEmpty ? nil : iCloudOutcomes.contains { $0.isAvailable }
        let cloudKitSucceeded = cloudKitOutcomes.isEmpty ? nil : cloudKitOutcomes.contains { $0.succeeded }
        let cloudKitAvailable = cloudKitOutcomes.isEmpty ? nil : cloudKitOutcomes.contains { $0.isAvailable }
        let loadedDocument = result.document != nil
        let hasOutcomeFailure = storeOutcomes.contains { !$0.succeeded }
        let outcome: CompanionSyncDiagnosticsOutcome
        if result.status == .stale {
            outcome = .stale
        } else if result.status == .failure {
            outcome = loadedDocument ? .partial : .failed
        } else if loadedDocument, !hasOutcomeFailure {
            outcome = .healthy
        } else if loadedDocument {
            outcome = .partial
        } else if iCloudAvailable == false || storeOutcomes.isEmpty {
            outcome = .unavailable
        } else {
            outcome = .failed
        }
        return CompanionSyncDiagnosticsRecord(
            operation: .load,
            outcome: outcome,
            attemptedAt: attemptedAt,
            appGroupSucceeded: appGroupSucceeded,
            iCloudSucceeded: iCloudSucceeded,
            iCloudAvailable: iCloudAvailable,
            cloudKitSucceeded: cloudKitSucceeded,
            cloudKitAvailable: cloudKitAvailable,
            loadedDocument: loadedDocument,
            stale: result.status == .stale,
            errorMessage: result.errorMessage ?? storeOutcomes.first(where: { !$0.succeeded })?.errorMessage
        )
    }
}

public struct CompanionSyncStoreOutcome: Equatable, Sendable {
    public let storeRole: String
    public let isAvailable: Bool
    public let succeeded: Bool
    public let errorMessage: String?

    public init(storeRole: String, isAvailable: Bool = true, succeeded: Bool, errorMessage: String? = nil) {
        self.storeRole = ConnectorRedactor.redact(storeRole)
        self.isAvailable = isAvailable
        self.succeeded = succeeded
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
    }
}

public struct CompanionSyncStore: Sendable {
    public let documentURL: URL
    private let source: CompanionSyncSource?
    private let readCoordinator: @Sendable (URL, @Sendable (URL) throws -> Data) throws -> Data?

    public init(documentURL: URL, source: CompanionSyncSource? = nil) {
        self.init(
            documentURL: documentURL,
            source: source,
            readCoordinator: Self.readWithFileCoordinator
        )
    }

    init(
        documentURL: URL,
        source: CompanionSyncSource? = nil,
        readCoordinator: @escaping @Sendable (URL, @Sendable (URL) throws -> Data) throws -> Data?
    ) {
        self.documentURL = documentURL
        self.source = source
        self.readCoordinator = readCoordinator
    }

    public func save(_ document: CompanionSyncDocument) throws {
        let data = try Self.makeEncoder().encode(document)
        try coordinatedWrite(data: data)
    }

    public func load() -> CompanionSyncLoadResult {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return CompanionSyncLoadResult(document: nil, status: .unknown)
        }

        do {
            let document = try loadDocument()
            return CompanionSyncLoadResult(
                document: document,
                status: document.companionStatus,
                transportMetadata: CompanionSyncTransportMetadata(
                    source: source ?? .storeRole(CompanionSyncStoreFailure.storeRole(for: documentURL)),
                    receivedAt: nil,
                    mirroredAt: nil,
                    deliveryStatus: .healthy
                )
            )
        } catch {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: CompanionSyncStoreFailure.diagnosticErrorMessage(
                    storeRole: CompanionSyncStoreFailure.storeRole(for: documentURL),
                    operation: "read",
                    error: error
                )
            )
        }
    }

    public func load(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> CompanionSyncLoadResult {
        let result = load()
        guard let document = result.document else { return result }
        let retainedDocument = document.mergingForRemotePublish(existing: nil, now: now)
        let status = retainedDocument.companionStatus(now: now, stalenessPolicy: policy)
        return CompanionSyncLoadResult(
            document: retainedDocument,
            status: status,
            errorMessage: result.errorMessage,
            transportMetadata: result.transportMetadata,
            transportStatuses: result.transportStatuses
        )
    }

    public func load(
        expectedUserScope: CompanionCloudKitUserScope,
        policy: SnapshotStoreStalenessPolicy,
        now: Date = Date()
    ) -> CompanionSyncLoadResult {
        let result = load(policy: policy, now: now)
        guard let document = result.document else { return result }
        guard document.cloudKitUserScope == expectedUserScope else {
            return purgeForeignDocument(
                document,
                expectedUserScope: expectedUserScope,
                policy: policy,
                now: now
            )
        }
        return result
    }

    public func saveResult(_ document: CompanionSyncDocument) -> CompanionSyncSaveResult {
        do {
            try save(document)
            return Self.successfulSaveResult(for: documentURL)
        } catch {
            return Self.failedSaveResult(for: documentURL, error: error)
        }
    }

    public func saveResult(
        _ document: CompanionSyncDocument,
        policy: SnapshotStoreStalenessPolicy,
        now: Date = Date(),
        unlessKeepingCurrent shouldKeepCurrent: @escaping @Sendable (CompanionSyncLoadResult) -> Bool
    ) -> CompanionSyncConditionalSaveResult {
        do {
            let retainedDocument = document.mergingForRemotePublish(existing: nil, now: now)
            let data = try Self.makeEncoder().encode(retainedDocument)
            if let keptCurrentResult = try coordinatedWrite(
                data: data,
                policy: policy,
                now: now,
                unlessKeepingCurrent: shouldKeepCurrent
            ) {
                return .keptCurrent(keptCurrentResult)
            }
            return .saved(Self.successfulSaveResult(for: documentURL))
        } catch {
            return .saved(Self.failedSaveResult(for: documentURL, error: error))
        }
    }

    public func saveResult(
        _ document: CompanionSyncDocument,
        expectedUserScope: CompanionCloudKitUserScope,
        policy: SnapshotStoreStalenessPolicy,
        now: Date = Date(),
        unlessKeepingCurrent shouldKeepCurrent: @escaping @Sendable (CompanionSyncLoadResult) -> Bool
    ) -> CompanionSyncScopedConditionalSaveResult {
        guard document.cloudKitUserScope == expectedUserScope else { return .scopeConflict }
        do {
            let retainedDocument = document.mergingForRemotePublish(existing: nil, now: now)
            let data = try Self.makeEncoder().encode(retainedDocument)
            return try coordinatedScopedWrite(
                data: data,
                expectedUserScope: expectedUserScope,
                policy: policy,
                now: now,
                unlessKeepingCurrent: shouldKeepCurrent
            )
        } catch {
            return .saved(Self.failedSaveResult(for: documentURL, error: error))
        }
    }

    public func removeIfCurrent(
        _ expectedDocument: CompanionSyncDocument?,
        policy: SnapshotStoreStalenessPolicy,
        now: Date = Date()
    ) -> CompanionSyncConditionalRemoveResult {
        do {
            return try coordinatedRemove(
                expectedDocument: expectedDocument,
                policy: policy,
                now: now
            )
        } catch {
            return .failed(CompanionSyncStoreFailure.diagnosticErrorMessage(
                storeRole: CompanionSyncStoreFailure.storeRole(for: documentURL),
                operation: "remove",
                error: error
            ))
        }
    }

    public func remove() throws {
        var removalError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: documentURL,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                removalError = error
            }
        }
        if let removalError { throw removalError }
        if let coordinatorError { throw coordinatorError }
    }

    private func purgeForeignDocument(
        _ document: CompanionSyncDocument,
        expectedUserScope: CompanionCloudKitUserScope,
        policy: SnapshotStoreStalenessPolicy,
        now: Date
    ) -> CompanionSyncLoadResult {
        switch removeIfCurrent(document, policy: policy, now: now) {
        case .removed:
            return CompanionSyncLoadResult(document: nil, status: .unknown)
        case let .keptCurrent(currentResult):
            guard currentResult.document?.cloudKitUserScope == expectedUserScope else {
                return CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: "Context Panel could not clear usage from another CloudKit account."
                )
            }
            return currentResult
        case let .failed(errorMessage):
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: errorMessage
            )
        }
    }

    private func loadDocument() throws -> CompanionSyncDocument {
        try Self.decodeDocument(from: try coordinatedRead())
    }

    private static func decodeDocument(from data: Data) throws -> CompanionSyncDocument {
        let document = try makeDecoder().decode(CompanionSyncDocument.self, from: data)
        guard document.schemaVersion == CompanionSyncDocument.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
        }
        guard document.snapshot.schemaVersion == CompanionSnapshot.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.snapshot.schemaVersion)
        }
        return document
    }

    private static func loadResult(
        at documentURL: URL,
        policy: SnapshotStoreStalenessPolicy,
        now: Date
    ) -> CompanionSyncLoadResult {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return CompanionSyncLoadResult(document: nil, status: .unknown)
        }

        do {
            let document = try decodeDocument(from: try Data(contentsOf: documentURL))
            let retainedDocument = document.mergingForRemotePublish(existing: nil, now: now)
            let status = retainedDocument.companionStatus(now: now, stalenessPolicy: policy)
            return CompanionSyncLoadResult(
                document: retainedDocument,
                status: status,
                transportMetadata: CompanionSyncTransportMetadata(
                    source: .storeRole(CompanionSyncStoreFailure.storeRole(for: documentURL)),
                    receivedAt: nil,
                    mirroredAt: nil,
                    deliveryStatus: .healthy
                )
            )
        } catch {
            return CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: CompanionSyncStoreFailure.diagnosticErrorMessage(
                    storeRole: CompanionSyncStoreFailure.storeRole(for: documentURL),
                    operation: "read",
                    error: error
                )
            )
        }
    }

    private func coordinatedRead() throws -> Data {
        guard let data = try readCoordinator(documentURL, { coordinatedURL in
            try Data(contentsOf: coordinatedURL)
        }) else {
            throw SnapshotStoreError.corruptStore("Companion sync document could not be read through file coordination.")
        }
        return data
    }

    private static func readWithFileCoordinator(
        documentURL: URL,
        read: @Sendable (URL) throws -> Data
    ) throws -> Data? {
        var readData: Data?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: documentURL,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                readData = try read(coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let readError { throw readError }
        if let coordinatorError { throw coordinatorError }
        return readData
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
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.replaceDocument(at: coordinatedURL, with: data)
            } catch {
                writeError = error
            }
        }

        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
    }

    private func coordinatedWrite(
        data: Data,
        policy: SnapshotStoreStalenessPolicy,
        now: Date,
        unlessKeepingCurrent shouldKeepCurrent: @escaping @Sendable (CompanionSyncLoadResult) -> Bool
    ) throws -> CompanionSyncLoadResult? {
        var keptCurrentResult: CompanionSyncLoadResult?
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: documentURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                let rawDocument = FileManager.default.fileExists(atPath: coordinatedURL.path)
                    ? try? Self.decodeDocument(from: Data(contentsOf: coordinatedURL))
                    : nil
                let currentResult = Self.loadResult(at: coordinatedURL, policy: policy, now: now)
                if shouldKeepCurrent(currentResult) {
                    if let retainedDocument = currentResult.document,
                       rawDocument != retainedDocument {
                        try Self.replaceDocument(
                            at: coordinatedURL,
                            with: Self.makeEncoder().encode(retainedDocument)
                        )
                    }
                    keptCurrentResult = currentResult
                    return
                }
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.replaceDocument(at: coordinatedURL, with: data)
            } catch {
                writeError = error
            }
        }

        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
        return keptCurrentResult
    }

    private func coordinatedScopedWrite(
        data: Data,
        expectedUserScope: CompanionCloudKitUserScope,
        policy: SnapshotStoreStalenessPolicy,
        now: Date,
        unlessKeepingCurrent shouldKeepCurrent: @escaping @Sendable (CompanionSyncLoadResult) -> Bool
    ) throws -> CompanionSyncScopedConditionalSaveResult {
        var result: CompanionSyncScopedConditionalSaveResult?
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: documentURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                let currentFileExists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                let rawDocument = currentFileExists
                    ? try? Self.decodeDocument(from: Data(contentsOf: coordinatedURL))
                    : nil
                if let rawDocument,
                   rawDocument.cloudKitUserScope != expectedUserScope {
                    result = .scopeConflict
                    return
                }
                let currentResult = Self.loadResult(at: coordinatedURL, policy: policy, now: now)
                if shouldKeepCurrent(currentResult) {
                    if let retainedDocument = currentResult.document,
                       rawDocument != retainedDocument {
                        try Self.replaceDocument(
                            at: coordinatedURL,
                            with: Self.makeEncoder().encode(retainedDocument)
                        )
                    }
                    result = .keptCurrent(currentResult)
                    return
                }
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.replaceDocument(at: coordinatedURL, with: data)
                result = .saved(Self.successfulSaveResult(for: documentURL))
            } catch {
                writeError = error
            }
        }

        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
        guard let result else {
            throw SnapshotStoreError.corruptStore("Scoped companion sync write did not complete.")
        }
        return result
    }

    private func coordinatedRemove(
        expectedDocument: CompanionSyncDocument?,
        policy: SnapshotStoreStalenessPolicy,
        now: Date
    ) throws -> CompanionSyncConditionalRemoveResult {
        var removalResult: CompanionSyncConditionalRemoveResult?
        var removalError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: documentURL,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                let currentFileExists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                let rawDocument = currentFileExists
                    ? try? Self.decodeDocument(from: Data(contentsOf: coordinatedURL))
                    : nil
                let currentResult = Self.loadResult(at: coordinatedURL, policy: policy, now: now)
                if currentFileExists, currentResult.document == nil {
                    removalResult = .keptCurrent(currentResult)
                    return
                }
                guard currentResult.document == expectedDocument else {
                    if let retainedDocument = currentResult.document,
                       rawDocument != retainedDocument {
                        try Self.replaceDocument(
                            at: coordinatedURL,
                            with: Self.makeEncoder().encode(retainedDocument)
                        )
                    }
                    removalResult = .keptCurrent(currentResult)
                    return
                }
                if currentFileExists {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                removalResult = .removed
            } catch {
                removalError = error
            }
        }

        if let removalError { throw removalError }
        if let coordinatorError { throw coordinatorError }
        guard let removalResult else {
            throw SnapshotStoreError.corruptStore("Companion sync document removal did not complete.")
        }
        return removalResult
    }

    private static func successfulSaveResult(for documentURL: URL) -> CompanionSyncSaveResult {
        CompanionSyncSaveResult(
            attemptedStoreCount: 1,
            successfulStoreCount: 1,
            failures: [],
            storeOutcomes: [CompanionSyncStoreOutcome(
                storeRole: CompanionSyncStoreFailure.storeRole(for: documentURL),
                succeeded: true
            )]
        )
    }

    private static func failedSaveResult(for documentURL: URL, error: Error) -> CompanionSyncSaveResult {
        let failure = CompanionSyncStoreFailure(documentURL: documentURL, error: error)
        return CompanionSyncSaveResult(
            attemptedStoreCount: 1,
            successfulStoreCount: 0,
            failures: [failure],
            storeOutcomes: [CompanionSyncStoreOutcome(
                storeRole: failure.storeRole,
                succeeded: false,
                errorMessage: failure.errorMessage
            )]
        )
    }

    private static func replaceDocument(at documentURL: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let temporaryURL = replacementTemporaryURL(for: documentURL)
        var removeTemporaryFile = true
        defer {
            if removeTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try data.write(to: temporaryURL, options: [.atomic])
        if fileManager.fileExists(atPath: documentURL.path) {
            _ = try fileManager.replaceItemAt(
                documentURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: documentURL)
        }
        removeTemporaryFile = false
    }

    private static func replacementTemporaryURL(for documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent()
            .appending(path: ".\(documentURL.lastPathComponent).\(UUID().uuidString).tmp")
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
    public let storeRole: String
    private let resolveStore: @Sendable () -> CompanionSyncStore?

    public init(storeRole: String = "custom", _ resolveStore: @escaping @Sendable () -> CompanionSyncStore?) {
        self.storeRole = ConnectorRedactor.redact(storeRole)
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
        var attemptedStoreCount = 0
        var failures: [CompanionSyncStoreFailure] = []
        var storeOutcomes: [CompanionSyncStoreOutcome] = []
        for store in stores {
            attemptedStoreCount += 1
            let result = store.saveResult(document)
            successfulStoreCount += result.successfulStoreCount
            failures.append(contentsOf: result.failures)
            storeOutcomes.append(contentsOf: result.storeOutcomes)
        }
        for resolver in lazyStores {
            guard let store = resolver.resolve() else {
                storeOutcomes.append(CompanionSyncStoreOutcome(
                    storeRole: resolver.storeRole,
                    isAvailable: false,
                    succeeded: false,
                    errorMessage: "Context Panel companion \(CompanionSyncStoreFailure.storeDisplayName(resolver.storeRole)) sync store is unavailable."
                ))
                continue
            }
            attemptedStoreCount += 1
            let result = store.saveResult(document)
            successfulStoreCount += result.successfulStoreCount
            failures.append(contentsOf: result.failures)
            storeOutcomes.append(contentsOf: result.storeOutcomes)
        }
        return CompanionSyncSaveResult(
            attemptedStoreCount: attemptedStoreCount,
            successfulStoreCount: successfulStoreCount,
            failures: failures,
            storeOutcomes: storeOutcomes
        )
    }

    public func load(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> CompanionSyncLoadResult {
        loadWithDiagnostics(policy: policy, now: now).result
    }

    public func loadWithDiagnostics(
        policy: SnapshotStoreStalenessPolicy,
        now: Date = Date()
    ) -> CompanionSyncLoadDiagnosticsResult {
        var bestCandidate: CompanionSyncLoadCandidate?
        var firstFailure: CompanionSyncLoadResult?
        var storeOutcomes: [CompanionSyncStoreOutcome] = []
        for store in stores {
            let result = store.load(policy: policy, now: now)
            let storeRole = CompanionSyncStoreFailure.storeRole(for: store.documentURL)
            storeOutcomes.append(Self.loadOutcome(storeRole: storeRole, result: result))
            if result.document != nil {
                bestCandidate = Self.preferredCandidate(
                    lhs: bestCandidate,
                    rhs: CompanionSyncLoadCandidate(result: result, storeRole: storeRole)
                )
                continue
            }
            if result.status == .failure, firstFailure == nil {
                firstFailure = result
            }
        }
        for resolver in lazyStores {
            guard let store = resolver.resolve() else {
                storeOutcomes.append(CompanionSyncStoreOutcome(
                    storeRole: resolver.storeRole,
                    isAvailable: false,
                    succeeded: false,
                    errorMessage: "Context Panel companion \(CompanionSyncStoreFailure.storeDisplayName(resolver.storeRole)) sync store is unavailable."
                ))
                continue
            }
            let storeRole = resolver.storeRole
            let result = Self.loadResultWithExplicitStoreRole(
                store.load(policy: policy, now: now),
                storeRole: storeRole
            )
            storeOutcomes.append(Self.loadOutcome(storeRole: storeRole, result: result))
            if result.document != nil {
                bestCandidate = Self.preferredCandidate(
                    lhs: bestCandidate,
                    rhs: CompanionSyncLoadCandidate(result: result, storeRole: storeRole)
                )
                continue
            }
            if result.status == .failure, firstFailure == nil {
                firstFailure = result
            }
        }
        return CompanionSyncLoadDiagnosticsResult(
            result: bestCandidate?.result ?? firstFailure ?? CompanionSyncLoadResult(document: nil, status: .unknown),
            storeOutcomes: storeOutcomes,
            selectedStoreRole: bestCandidate?.storeRole,
            selectedStoreIsICloud: bestCandidate?.storeRole == "icloud"
        )
    }

    private func resolvedStores() -> [CompanionSyncStore] {
        stores + lazyStores.compactMap { $0.resolve() }
    }

    private static func loadOutcome(storeRole: String, result: CompanionSyncLoadResult) -> CompanionSyncStoreOutcome {
        CompanionSyncStoreOutcome(
            storeRole: storeRole,
            succeeded: result.document != nil && result.status != .failure,
            errorMessage: result.errorMessage
        )
    }

    private static func loadResultWithExplicitStoreRole(
        _ result: CompanionSyncLoadResult,
        storeRole: String
    ) -> CompanionSyncLoadResult {
        guard result.document != nil else { return result }
        return CompanionSyncLoadResult(
            document: result.document,
            status: result.status,
            errorMessage: result.errorMessage,
            transportMetadata: CompanionSyncTransportMetadata(
                source: .storeRole(storeRole),
                receivedAt: result.transportMetadata?.receivedAt,
                mirroredAt: result.transportMetadata?.mirroredAt,
                deliveryStatus: result.transportMetadata?.deliveryStatus ?? .healthy
            ),
            transportStatuses: result.transportStatuses
        )
    }

    private static func preferredCandidate(
        lhs: CompanionSyncLoadCandidate?,
        rhs: CompanionSyncLoadCandidate
    ) -> CompanionSyncLoadCandidate {
        guard let lhs else { return rhs }
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

public struct CompanionSyncPublisher: Sendable {
    public let stores: CompanionSyncStoreSet
    public let remoteStore: CompanionRemoteSyncStore?
    public let widgetPreferencesStore: WidgetDisplayPreferencesStore
    public let fastModeForecastSettingsStore: FastModeForecastSettingsStore
    public let accountConfigurationURL: URL?
    public let sharedAccountCache: MacSharedAccountCache?

    public init(
        stores: CompanionSyncStoreSet,
        remoteStore: CompanionRemoteSyncStore? = nil,
        widgetPreferencesStore: WidgetDisplayPreferencesStore,
        fastModeForecastSettingsStore: FastModeForecastSettingsStore,
        accountConfigurationURL: URL? = nil,
        sharedAccountCache: MacSharedAccountCache? = nil
    ) {
        self.accountConfigurationURL = accountConfigurationURL
        self.sharedAccountCache = sharedAccountCache
        self.stores = stores
        self.remoteStore = remoteStore
        self.widgetPreferencesStore = widgetPreferencesStore
        self.fastModeForecastSettingsStore = fastModeForecastSettingsStore
    }

    public static func appDefault(remoteStore: CompanionRemoteSyncStore? = nil) -> CompanionSyncPublisher {
        CompanionSyncPublisher(
            stores: ContextPanelLocations.companionSyncStoreSet(),
            remoteStore: remoteStore,
            widgetPreferencesStore: WidgetDisplayPreferencesStore(
                preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            fastModeForecastSettingsStore: FastModeForecastSettingsStore(
                settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            accountConfigurationURL: ContextPanelLocations.accountConfigurationURL(),
            sharedAccountCache: MacSharedAccountCache(cacheURL: ContextPanelLocations.accountConfigurationURL().deletingLastPathComponent().appending(path: MacSharedAccountCache.filename))
        )
    }

    @discardableResult
    public func publish(
        storedSnapshot: StoredUsageSnapshot,
        publishedAt: Date = Date(),
        observedBurnRates: [String: ObservedBurnRate] = [:],
        accountBurnRates: [String: [String: ObservedBurnRate]] = [:]
    ) -> CompanionSyncSaveResult {
        publish(document: makeDocument(
            storedSnapshot: storedSnapshot,
            publishedAt: publishedAt,
            observedBurnRates: observedBurnRates,
            accountBurnRates: accountBurnRates
        ))
    }

    @discardableResult
    public func publish(document: CompanionSyncDocument) -> CompanionSyncSaveResult {
        let result = stores.save(document)
        logPublishResult(result)
        return result
    }

    @discardableResult
    public func publishAll(
        storedSnapshot: StoredUsageSnapshot,
        publishedAt: Date = Date(),
        observedBurnRates: [String: ObservedBurnRate] = [:],
        accountBurnRates: [String: [String: ObservedBurnRate]] = [:]
    ) async -> CompanionSyncSaveResult {
        let scope = await remoteStore?.currentUserScope()
        if let scope, let accountConfigurationURL {
            let store = AccountConfigurationStore(configurationURL: accountConfigurationURL)
            let result = store.load(now: publishedAt)
            if result.status == .healthy, !result.document.globalRemovedDisplayIDs.isEmpty {
                var configuration = result.document
                if let previous = configuration.removalUserScope, previous != scope {
                    configuration.removedDisplayIDs = []
                    configuration.removedDisplayDates = [:]
                }
                configuration.removedDisplayIDs = Array(Set(configuration.removedDisplayIDs ?? []).union(configuration.pendingRemovedDisplayIDs ?? [])).sorted()
                configuration.pendingRemovedDisplayIDs = nil
                configuration.removalUserScope = scope
                if configuration != result.document { try? store.save(configuration) }
            }
        }
        let document = makeDocument(
            storedSnapshot: storedSnapshot,
            publishedAt: publishedAt,
            observedBurnRates: observedBurnRates,
            removalUserScope: scope,
            accountBurnRates: accountBurnRates
        )
        var result = publish(document: document)
        if let remoteStore {
            let remoteOutcome = await remoteStore.save(document)
            result = result.appending(storeOutcome: remoteOutcome.storeOutcome)
            if remoteOutcome.succeeded { _ = await receiveSharedAccounts(now: publishedAt) }
        }
        return result
    }

    @discardableResult
    public func receiveSharedAccounts(now: Date) async -> CompanionSyncDocument? {
        guard let remoteStore, let scope = await remoteStore.currentUserScope() else {
            sharedAccountCache?.invalidate()
            return nil
        }
        let remote = await remoteStore.load(now: now)
        guard remote.outcome.succeeded, let document = remote.result.document,
              document.cloudKitUserScope == scope, await remoteStore.currentUserScope() == scope else {
            sharedAccountCache?.invalidate()
            return nil
        }
        try? sharedAccountCache?.save(document, verifiedScope: scope, checkedAt: now)
        return document
    }

    public func receiveGlobalRemovals(accountStore: AccountConfigurationStore, storedSnapshot: StoredUsageSnapshot?, now: Date) async throws {
        guard let document = await receiveSharedAccounts(now: now), let scope = document.cloudKitUserScope else { return }
        try accountStore.receiveSharedAccountIntents(document, scope: scope, now: now)
        try accountStore.applyGlobalRemovals(Array(document.effectiveRemovedDisplayIDs), storedSnapshot: storedSnapshot, now: now, userScope: scope)
    }

    public func presentationDocument(storedSnapshot: StoredUsageSnapshot, now: Date,
        accountBurnRates: [String: [String: ObservedBurnRate]] = [:], observedBurnRates: [String: ObservedBurnRate] = [:]) -> CompanionSyncDocument {
        let cached = sharedAccountCache?.load(now: now)?.verifiedAccountsOnly()
        let local = makeDocument(storedSnapshot: storedSnapshot, publishedAt: now,
            observedBurnRates: observedBurnRates, removalUserScope: cached?.cloudKitUserScope, accountBurnRates: accountBurnRates)
        return local.mergingForRemotePublish(existing: cached, now: now)
    }

    private func makeDocument(
        storedSnapshot: StoredUsageSnapshot,
        publishedAt: Date,
        observedBurnRates: [String: ObservedBurnRate],
        removalUserScope: CompanionCloudKitUserScope? = nil,
        accountBurnRates: [String: [String: ObservedBurnRate]] = [:]
    ) -> CompanionSyncDocument {
        let scopedReports = storedSnapshot.reports.filter { report in
            guard let bound = report.sharedAccountIdentity?.userScope, let removalUserScope else { return true }
            return bound == removalUserScope
        }
        let rejected = Set(storedSnapshot.reports.filter { !scopedReports.contains($0) }.map { $0.provider.rawValue + ":" + $0.accountID })
        let storedSnapshot = StoredUsageSnapshot(savedAt: storedSnapshot.savedAt,
            snapshot: UsageSnapshot(generatedAt: storedSnapshot.snapshot.generatedAt,
                limits: storedSnapshot.snapshot.limits.filter { !rejected.contains($0.provider.rawValue + ":" + $0.accountID) }),
            reports: scopedReports, promptCacheObservations: storedSnapshot.promptCacheObservations)
        let configuration = accountConfigurationURL.flatMap { url in
            (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder.contextPanelISO8601.decode(AccountConfigurationDocument.self, from: $0)
            }
        }
        let snapshot = CompanionSnapshot(storedSnapshot: storedSnapshot, publishedAt: publishedAt,
            configuration: configuration?.accounts ?? [], publisherID: configuration?.publisherID)
        var transportedRates: [String: [String: ObservedBurnRate]] = [:]
        for local in storedSnapshot.snapshot.limits {
            guard let rate = accountBurnRates[local.accountID]?[local.id], rate.sampleCount > 0 else { continue }
            let report = storedSnapshot.reports.first { $0.provider == local.provider && $0.accountID == local.accountID }
            let key = report?.sharedAccountIdentity?.accountID
                ?? CompanionLimit(limit: local, identityConfiguredAccountID: AccountDisplayMetadata.companionIdentityOverride(
                    provider: local.provider, rawID: local.accountID, configuredID: local.configuredAccountID,
                    configuration: configuration?.accounts ?? [], publisherID: configuration?.publisherID)).companionAccountID
            guard let transported = snapshot.limits.first(where: { $0.provider == local.provider && $0.companionAccountID == key
                && $0.label == local.label && $0.lastUpdatedAt == local.lastUpdatedAt && $0.used == local.used }) else { continue }
            let limitID = transported.usageLimit.id
            transportedRates[transported.companionAccountID, default: [:]][limitID] = ObservedBurnRate(
                limitID: limitID, unitsPerHour: rate.unitsPerHour,
                observedDurationHours: rate.observedDurationHours, sampleCount: rate.sampleCount)
        }
        return CompanionSyncDocument(
            snapshot: snapshot,
            widgetDisplayPreferences: widgetPreferencesStore.load(),
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: fastModeForecastSettingsStore.load(),
            cloudKitUserScope: removalUserScope,
            accountDisplayMetadata: configuration.map {
                AccountDisplayMetadata.companion(configuration: $0.accounts, stored: storedSnapshot, now: publishedAt, publisherID: $0.publisherID).filteringSharedPresentationMetadata(stored: storedSnapshot, configuration: $0.accounts, publisherID: $0.publisherID)
            },
            removedDisplayIDs: configuration.flatMap { configuration in
                if remoteStore != nil {
                    guard let removalUserScope, configuration.removalUserScope == removalUserScope else { return nil }
                    return configuration.removedDisplayIDs
                }
                return configuration.globalRemovedDisplayIDs
            },
            accountBurnRates: transportedRates.isEmpty ? nil : transportedRates,
            accountIdentityAliases: configuration.map { CompanionAccountIdentityAlias.verifiedAliases(stored: storedSnapshot, configuration: $0.accounts, publisherID: $0.publisherID) },
            accountRemovalDates: configuration?.removedDisplayDates,
            accountRestorationDates: configuration.map { configuration in
                var dates: [String: Date] = [:]
                for account in configuration.accounts {
                    guard let requested = account.restorationRequestedAt else { continue }
                    for report in storedSnapshot.reports where account.matchesProviderReport(report) {
                        guard let identity = report.sharedAccountIdentity else { continue }
                        let key = AccountDisplayMetadata.safeID(report.provider, identity.accountID)
                        dates[key] = max(dates[key] ?? .distantPast, requested)
                    }
                }
                return dates
            }
        )
    }

    private func logPublishResult(_ result: CompanionSyncSaveResult) {
        if !result.succeeded {
            companionSyncLogger.error("companion sync publish failed stores=\(result.attemptedStoreCount, privacy: .public)")
        } else if !result.failures.isEmpty {
            companionSyncLogger.warning("companion sync publish partially failed succeeded=\(result.successfulStoreCount, privacy: .public) failed=\(result.failures.count, privacy: .public)")
        }
        for failure in result.failures {
            companionSyncLogger.error(
                "companion sync publish store failed store=\(failure.storeRole, privacy: .public) domain=\(failure.errorDomain, privacy: .public) code=\(failure.errorCode, privacy: .public) error=\(failure.errorMessage, privacy: .public)"
            )
        }
    }
}

private extension CompanionSyncSaveResult {
    func appending(storeOutcome: CompanionSyncStoreOutcome) -> CompanionSyncSaveResult {
        CompanionSyncSaveResult(
            attemptedStoreCount: attemptedStoreCount + 1,
            successfulStoreCount: successfulStoreCount + (storeOutcome.succeeded ? 1 : 0),
            failures: failures,
            storeOutcomes: storeOutcomes + [storeOutcome]
        )
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
    public let freshnessMode: UsageFreshnessMode?
    public let status: UsageStatus

    public init(limit: UsageLimit) { self.init(limit: limit, identityConfiguredAccountID: nil) }

    public init(limit: UsageLimit, identityConfiguredAccountID: String?, sharedIdentity: SharedProviderAccountIdentity? = nil) {
        provider = limit.provider
        companionAccountID = sharedIdentity?.matches(provider: limit.provider, accountID: limit.accountID) == true
            ? sharedIdentity!.accountID : CompanionAccountIdentity.id(
                provider: limit.provider, accountID: limit.accountID,
                configuredAccountID: identityConfiguredAccountID ?? limit.configuredAccountID)
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
        freshnessMode = limit.freshnessMode
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
            freshnessMode: freshnessMode ?? legacyFreshnessMode,
            statusOverride: status
        )
    }

    private var legacyFreshnessMode: UsageFreshnessMode {
        provider == .google ? .eventDriven : .polling
    }
}

public struct CompanionProviderStatus: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let generatedAt: Date
    public let status: UsageStatus
    public let accessState: ProviderAccessState
    public let resetCredits: ProviderResetCreditSummary?
    public let sharedAccountIdentity: SharedProviderAccountIdentity?
    public let accountIdentityStatus: ProviderAccountIdentityStatus

    enum CodingKeys: String, CodingKey {
        case provider
        case companionAccountID
        case accountName
        case generatedAt
        case status
        case accessState
        case resetCredits
        case sharedAccountIdentity
        case accountIdentityStatus
    }

    public init(report: StoredProviderReport) { self.init(report: report, identityConfiguredAccountID: nil) }

    public init(report: StoredProviderReport, identityConfiguredAccountID: String?) {
        provider = report.provider
        companionAccountID = report.sharedAccountIdentity?.accountID ?? CompanionAccountIdentity.id(
            provider: report.provider, accountID: report.accountID,
            configuredAccountID: identityConfiguredAccountID ?? report.configuredAccountID)
        accountName = CompanionAccountIdentity.displayName(report.accountName)
        generatedAt = report.generatedAt
        status = report.status
        accessState = report.accessState.retainingCurrentProviderObservation(for: report.status)
        resetCredits = report.resetCredits
        sharedAccountIdentity = report.sharedAccountIdentity?.bound(toLocalAccountID: nil)
        accountIdentityStatus = report.accountIdentityStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        companionAccountID = try container.decode(String.self, forKey: .companionAccountID)
        accountName = try container.decode(String.self, forKey: .accountName)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        status = try container.decode(UsageStatus.self, forKey: .status)
        accessState = try container.decodeIfPresent(ProviderAccessState.self, forKey: .accessState)?
            .retainingCurrentProviderObservation(for: status) ?? .unknown
        resetCredits = try container.decodeIfPresent(ProviderResetCreditSummary.self, forKey: .resetCredits)
        let decodedIdentity = try? container.decode(SharedProviderAccountIdentity.self, forKey: .sharedAccountIdentity)
        sharedAccountIdentity = decodedIdentity?.matches(provider: provider, accountID: companionAccountID) == true ? decodedIdentity : nil
        accountIdentityStatus = SharedProviderAccountIdentity.status(
            (try? container.decode(ProviderAccountIdentityStatus.self, forKey: .accountIdentityStatus)) ?? .unverified, identity: sharedAccountIdentity)
    }

    public var storedProviderReport: StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: companionAccountID,
            configuredAccountID: companionAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            resetCredits: resetCredits,
            status: status,
            accessState: accessState,
            errorMessage: nil,
            sharedAccountIdentity: sharedAccountIdentity,
            accountIdentityStatus: accountIdentityStatus
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

public extension CompanionSyncDocument {
    var companionStatus: UsageStatus {
        let accessStatuses = snapshot.providerStatuses.compactMap(\.accessState.statusContribution)
        let limitStatuses = snapshot.limits.map(\.status) + accessStatuses
        if !limitStatuses.isEmpty {
            return limitStatuses.contextPanelWorstStatus
        }
        let providerStatuses = snapshot.providerStatuses.map(\.status)
        guard !providerStatuses.isEmpty else { return .unknown }
        return providerStatuses.contextPanelWorstStatus
    }

    func companionStatus(now: Date, maximumAge: TimeInterval) -> UsageStatus {
        companionStatus(
            now: now,
            stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: maximumAge)
        )
    }

    func companionStatus(
        now: Date,
        stalenessPolicy: SnapshotStoreStalenessPolicy
    ) -> UsageStatus {
        let statusesByAccount = Dictionary(grouping: snapshot.providerStatuses) {
            CompanionStatusAccountKey(status: $0)
        }
        let limitGroups = Dictionary(grouping: snapshot.limits) {
            CompanionStatusAccountKey(limit: $0)
        }
        let accountKeys = Set(limitGroups.keys).union(statusesByAccount.keys)
        guard !accountKeys.isEmpty else { return companionStatus }

        let accountStatuses = accountKeys.map { key -> UsageStatus in
            let limits = limitGroups[key] ?? []
            let providerStatuses = statusesByAccount[key] ?? []
            if limits.isEmpty {
                let statuses = providerStatuses.map(\.status)
                    + providerStatuses.compactMap(\.accessState.statusContribution)
                return statuses.contextPanelWorstStatus
            }
            let futureDatedAccessStatuses = providerStatuses.compactMap {
                $0.accessState.futureDatedCompanionStatusContribution(at: now)
            }
            let hasAgeSensitiveLimits = limits.contains { !$0.usageLimit.usesEventDrivenFreshness }
            let hasExpiredPollingReset = limits.contains {
                stalenessPolicy.presentationResetRefreshIsDue(for: $0.usageLimit, now: now)
            }
            if hasExpiredPollingReset {
                return ([.stale] + futureDatedAccessStatuses).contextPanelWorstStatus
            }
            let limitObservedAt = limits.compactMap(\.lastUpdatedAt).max()
            let statusObservedAt = providerStatuses
                .filter { $0.status.isCompanionObservationStatus }
                .map(\.generatedAt)
                .max()
            if hasAgeSensitiveLimits {
                guard let observedAt = limitObservedAt ?? statusObservedAt else { return .stale }
                if now.timeIntervalSince(observedAt) > stalenessPolicy.maximumAge {
                    return ([.stale] + futureDatedAccessStatuses).contextPanelWorstStatus
                }
            }
            let statuses = limits.map(\.status)
                + providerStatuses.compactMap(\.accessState.statusContribution)
            return statuses.contextPanelWorstStatus
        }
        let currentStatuses = accountStatuses.filter { $0 != .stale }
        return (currentStatuses.isEmpty ? accountStatuses : currentStatuses).contextPanelWorstStatus
    }
}

private struct CompanionStatusAccountKey: Hashable {
    let provider: Provider
    let companionAccountID: String

    init(limit: CompanionLimit) {
        provider = limit.provider
        companionAccountID = limit.companionAccountID
    }

    init(status: CompanionProviderStatus) {
        provider = status.provider
        companionAccountID = status.companionAccountID
    }
}

private extension ProviderAccessState {
    func futureDatedCompanionStatusContribution(at now: Date) -> UsageStatus? {
        switch kind {
        case .blockedUntilReset, .paidFallbackActive:
            guard let resetsAt, resetsAt > now else { return nil }
            return statusContribution
        case .available, .pressure, .unknown, .degraded:
            return nil
        }
    }
}

extension UsageStatus {
    var isCompanionObservationStatus: Bool {
        switch self {
        case .healthy, .close, .limited:
            true
        case .failure, .loading, .stale, .unknown:
            false
        }
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

    init(storedSnapshot: StoredUsageSnapshot? = nil, configuration: [LocalProviderAccountConfiguration] = [], publisherID: String? = nil) {
        guard let storedSnapshot else {
            configuredAccountIDsByRawKey = [:]
            return
        }

        var aliases: [ProviderAccountKey: String] = [:]
        for limit in storedSnapshot.snapshot.limits {
            guard let configuredAccountID = AccountDisplayMetadata.companionIdentityOverride(provider: limit.provider, rawID: limit.accountID, configuredID: limit.configuredAccountID, configuration: configuration, publisherID: publisherID) ?? limit.configuredAccountID else { continue }
            aliases[ProviderAccountKey(provider: limit.provider, accountID: limit.accountID)] = configuredAccountID
        }
        for report in storedSnapshot.reports {
            guard let configuredAccountID = AccountDisplayMetadata.companionIdentityOverride(provider: report.provider, rawID: report.accountID, configuredID: report.configuredAccountID, configuration: configuration, publisherID: publisherID) ?? report.configuredAccountID else { continue }
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
        if SharedProviderAccountIdentity.isSharedAccountID(accountID, provider: provider) { return accountID }
        let stableID = "companion:" + ProviderAccountIdentity.unique(
            accountID: accountID,
            configuredAccountID: configuredAccountID
        )

        return ConnectorRedactor.localAccountID(
            provider: provider,
            stableID: stableID
        )
    }

    static func displayName(_ value: String) -> String {
        let displayName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return "Account" }
        let pathRedacted = NSString(string: displayName).lastPathComponent
        return pathRedacted.isEmpty ? "Account" : pathRedacted
    }
}

public extension AccountDisplayMetadata {
    static func companion(configuration: [LocalProviderAccountConfiguration], stored: StoredUsageSnapshot, now: Date, publisherID: String? = nil) -> [Self] {
        let local = Self.local(configuration: configuration, stored: stored, now: now)
        return local.map { entry in
            let limit = stored.snapshot.limits.first { $0.provider == entry.provider && safeID($0.provider, $0.accountID) == entry.id }
            let report = stored.reports.first { $0.provider == entry.provider && safeID($0.provider, $0.accountID) == entry.id }
            // Match the existing companion identity formula, including legacy records without a configuration key.
            let rawID = limit?.accountID ?? report?.accountID ?? configuration.first {
                safeID($0.provider, $0.id) == entry.configurationID
            }?.id ?? entry.id
            let setup = configuration.first { safeID($0.provider, $0.id) == entry.configurationID }
            let placeholderID = setup.map { companionMembershipKey($0, publisherID: publisherID) } ?? rawID
            let identity = limit == nil && report == nil ? nil : companionIdentityOverride(provider: entry.provider, rawID: rawID,
                configuredID: limit?.configuredAccountID ?? report?.configuredAccountID,
                configuration: configuration, publisherID: publisherID) ?? limit?.configuredAccountID ?? report?.configuredAccountID
            let companionID = report?.sharedAccountIdentity?.accountID ?? CompanionAccountIdentity.id(provider: entry.provider,
                accountID: limit == nil && report == nil ? placeholderID : rawID,
                configuredAccountID: identity)
            return Self(id: safeID(entry.provider, companionID),
                        configurationID: setup.map { companionConfigurationID($0, publisherID: publisherID) } ?? entry.configurationID,
                        provider: entry.provider, label: entry.label, isEnabled: entry.isEnabled,
                        showInWidgets: entry.showInWidgets, useLast: entry.useLast,
                        sourceConfigured: entry.sourceConfigured, readState: entry.readState)
        }
    }
}

public extension AccountDisplayMetadata {
    static func companionMembershipKey(_ account: LocalProviderAccountConfiguration, publisherID: String?) -> String {
        guard account.isSharedDefaultMembership, let publisherID else { return account.id }
        return "publisher:" + publisherID + ":" + account.id
    }
    static func companionConfigurationID(_ account: LocalProviderAccountConfiguration, publisherID: String?) -> String {
        safeID(account.provider, companionMembershipKey(account, publisherID: publisherID))
    }
}

public extension AccountDisplayMetadata {
    /// Source-derived IDs identify a setup, not a provider login. Scope built-in defaults by publisher.
    static func companionIdentityOverride(provider: Provider, rawID: String, configuredID: String?,
        configuration: [LocalProviderAccountConfiguration], publisherID: String?) -> String? {
        guard let publisherID, let setup = configuration.first(where: {
            $0.provider == provider && ($0.id == configuredID || $0.id == rawID || $0.providerReportAccountIDs.contains(rawID))
        }), setup.isSharedDefaultMembership else { return nil }
        let sourceDerived = provider != .openAI || rawID == setup.id
            || rawID == ConnectorRedactor.localAccountID(provider: provider, stableID: setup.id)
            || setup.providerReportAccountIDs.contains(rawID)
        return sourceDerived ? companionMembershipKey(setup, publisherID: publisherID) : nil
    }

    static func legacyUnidentifiedDisplayIDs(_ setup: LocalProviderAccountConfiguration) -> [String] {
        let sourceIDs = Set(setup.providerReportAccountIDs + [ConnectorRedactor.localAccountID(provider: setup.provider, stableID: setup.id)])
        return sourceIDs.flatMap { raw in
            [nil, setup.id].map { configured in
                safeID(setup.provider, CompanionAccountIdentity.id(provider: setup.provider, accountID: raw, configuredAccountID: configured))
            }
        }
    }
}
