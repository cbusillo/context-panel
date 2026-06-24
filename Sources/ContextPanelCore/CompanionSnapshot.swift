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
    public let transportMetadata: CompanionSyncTransportMetadata?

    public init(
        document: CompanionSyncDocument?,
        status: UsageStatus,
        errorMessage: String? = nil,
        transportMetadata: CompanionSyncTransportMetadata? = nil
    ) {
        self.document = document
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
        self.transportMetadata = transportMetadata
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
        self.errorMessage = ConnectorRedactor.redact(errorMessage)
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
        self.errorMessage = errorMessage.map { ConnectorRedactor.redact($0) }
    }
}

public struct CompanionSyncStore: Sendable {
    public let documentURL: URL
    private let readCoordinator: @Sendable (URL, @Sendable (URL) throws -> Data) throws -> Data?

    public init(documentURL: URL) {
        self.init(documentURL: documentURL, readCoordinator: Self.readWithFileCoordinator)
    }

    init(
        documentURL: URL,
        readCoordinator: @escaping @Sendable (URL, @Sendable (URL) throws -> Data) throws -> Data?
    ) {
        self.documentURL = documentURL
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

    public func load(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> CompanionSyncLoadResult {
        let result = load()
        guard let document = result.document else { return result }
        let status = now.timeIntervalSince(document.snapshot.generatedAt) > policy.maximumAge
            ? .stale
            : document.companionStatus
        return CompanionSyncLoadResult(
            document: document,
            status: status,
            errorMessage: result.errorMessage,
            transportMetadata: result.transportMetadata
        )
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
            let data = try Self.makeEncoder().encode(document)
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
            let status = now.timeIntervalSince(document.snapshot.generatedAt) > policy.maximumAge
                ? .stale
                : document.companionStatus
            return CompanionSyncLoadResult(
                document: document,
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
                let currentResult = Self.loadResult(at: coordinatedURL, policy: policy, now: now)
                if shouldKeepCurrent(currentResult) {
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
            )
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

    public init(
        stores: CompanionSyncStoreSet,
        remoteStore: CompanionRemoteSyncStore? = nil,
        widgetPreferencesStore: WidgetDisplayPreferencesStore,
        fastModeForecastSettingsStore: FastModeForecastSettingsStore
    ) {
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
            )
        )
    }

    @discardableResult
    public func publish(storedSnapshot: StoredUsageSnapshot, publishedAt: Date = Date()) -> CompanionSyncSaveResult {
        publish(document: makeDocument(storedSnapshot: storedSnapshot, publishedAt: publishedAt))
    }

    @discardableResult
    public func publish(document: CompanionSyncDocument) -> CompanionSyncSaveResult {
        let result = stores.save(document)
        logPublishResult(result)
        return result
    }

    @discardableResult
    public func publishAll(storedSnapshot: StoredUsageSnapshot, publishedAt: Date = Date()) async -> CompanionSyncSaveResult {
        let document = makeDocument(storedSnapshot: storedSnapshot, publishedAt: publishedAt)
        var result = publish(document: document)
        if let remoteStore {
            let remoteOutcome = await remoteStore.save(document)
            result = result.appending(storeOutcome: remoteOutcome.storeOutcome)
        }
        return result
    }

    private func makeDocument(storedSnapshot: StoredUsageSnapshot, publishedAt: Date) -> CompanionSyncDocument {
        CompanionSyncDocument(
            storedSnapshot: storedSnapshot,
            publishedAt: publishedAt,
            widgetDisplayPreferences: widgetPreferencesStore.load(),
            fastModeForecastSettings: fastModeForecastSettingsStore.load()
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

public extension CompanionSyncDocument {
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
        let redacted = ConnectorRedactor.redact(value)
        let pathRedacted = ConnectorRedactor.redactedPath(redacted)
        return pathRedacted.isEmpty ? "Account" : pathRedacted
    }
}
