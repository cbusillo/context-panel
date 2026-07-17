import Foundation

public enum CompanionRemoteSync {
    public static let cloudKitStoreRole = "cloudkit"
    public static let cloudKitPresentationStoreRole = "cloudkit-presentation"
    public static let cloudKitRecordType = "CompanionSyncDocument"
    public static let cloudKitRecordName = "current-v2"
    public static let cloudKitLegacyRecordNames = ["current"]
    public static let cloudKitPresentationRecordName = "companion-presentation"
    public static let cloudKitSubscriptionID = "companion-sync-updates-v3"
    public static let cloudKitRetiredSubscriptionIDs = ["companion-sync-updates", "companion-sync-updates-v2"]
    public static let payloadFieldName = "payload"
    public static let schemaVersionFieldName = "schemaVersion"
    public static let documentSchemaVersionFieldName = "documentSchemaVersion"
    public static let snapshotSchemaVersionFieldName = "snapshotSchemaVersion"
    public static let generatedAtFieldName = "generatedAt"
    public static let publishedAtFieldName = "publishedAt"
    public static let payloadByteCountFieldName = "payloadByteCount"
}

public enum CompanionSyncSource: String, Codable, Equatable, Sendable {
    case appGroup
    case iCloud
    case cloudKit
    case localCache
    case custom
}

public enum CompanionSyncDeliveryStatus: String, Codable, Equatable, Sendable {
    case healthy
    case delayed
    case unavailable
    case failed
    case unknown
}

public struct CompanionSyncTransportMetadata: Codable, Equatable, Sendable {
    public let source: CompanionSyncSource
    public let receivedAt: Date?
    public let mirroredAt: Date?
    public let deliveryStatus: CompanionSyncDeliveryStatus

    public init(
        source: CompanionSyncSource = .custom,
        receivedAt: Date? = nil,
        mirroredAt: Date? = nil,
        deliveryStatus: CompanionSyncDeliveryStatus = .unknown
    ) {
        self.source = source
        self.receivedAt = receivedAt
        self.mirroredAt = mirroredAt
        self.deliveryStatus = deliveryStatus
    }
}

public struct CompanionSyncTransportStatus: Equatable, Sendable {
    public let source: CompanionSyncSource
    public let isAvailable: Bool
    public let succeeded: Bool
    public let loadedDocument: Bool?
    public let missingRecord: Bool
    public let errorMessage: String?

    public init(
        source: CompanionSyncSource,
        isAvailable: Bool,
        succeeded: Bool,
        loadedDocument: Bool? = nil,
        missingRecord: Bool = false,
        errorMessage: String? = nil
    ) {
        self.source = source
        self.isAvailable = isAvailable
        self.succeeded = succeeded
        self.loadedDocument = loadedDocument
        self.missingRecord = missingRecord
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
    }
}

public struct CompanionRemoteSyncOutcome: Equatable, Sendable {
    public let storeRole: String
    public let isAvailable: Bool
    public let succeeded: Bool
    public let missingRecord: Bool
    public let errorMessage: String?

    public init(
        storeRole: String = CompanionRemoteSync.cloudKitStoreRole,
        isAvailable: Bool = true,
        succeeded: Bool,
        missingRecord: Bool = false,
        errorMessage: String? = nil
    ) {
        self.storeRole = ConnectorRedactor.redact(storeRole)
        self.isAvailable = isAvailable
        self.succeeded = succeeded
        self.missingRecord = missingRecord
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
    }

    public var storeOutcome: CompanionSyncStoreOutcome {
        CompanionSyncStoreOutcome(
            storeRole: storeRole,
            isAvailable: isAvailable,
            succeeded: succeeded,
            errorMessage: errorMessage
        )
    }
}

public struct CompanionRemoteSyncLoadResult: Equatable, Sendable {
    public let result: CompanionSyncLoadResult
    public let outcome: CompanionRemoteSyncOutcome

    public init(result: CompanionSyncLoadResult, outcome: CompanionRemoteSyncOutcome) {
        self.result = result
        self.outcome = outcome
    }
}

public struct CompanionRemoteSyncStore: Sendable {
    public let storeRole: String
    private let saveDocument: @Sendable (CompanionSyncDocument) async -> CompanionRemoteSyncOutcome
    private let loadDocument: @Sendable (Date) async -> CompanionRemoteSyncLoadResult
    private let registerForUpdates: @Sendable () async -> CompanionRemoteSyncOutcome

    public init(
        storeRole: String = CompanionRemoteSync.cloudKitStoreRole,
        saveDocument: @escaping @Sendable (CompanionSyncDocument) async -> CompanionRemoteSyncOutcome,
        loadDocument: @escaping @Sendable (Date) async -> CompanionRemoteSyncLoadResult,
        registerForUpdates: @escaping @Sendable () async -> CompanionRemoteSyncOutcome = {
            CompanionRemoteSyncOutcome(succeeded: true)
        }
    ) {
        self.storeRole = ConnectorRedactor.redact(storeRole)
        self.saveDocument = saveDocument
        self.loadDocument = loadDocument
        self.registerForUpdates = registerForUpdates
    }

    public func save(_ document: CompanionSyncDocument) async -> CompanionRemoteSyncOutcome {
        await saveDocument(document)
    }

    public func load(now: Date = Date()) async -> CompanionRemoteSyncLoadResult {
        await loadDocument(now)
    }

    public func registerSubscription() async -> CompanionRemoteSyncOutcome {
        await registerForUpdates()
    }
}

public struct CompanionPresentationDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let updatedAt: Date
    public let widgetDisplayPreferences: WidgetDisplayPreferences

    public init(
        updatedAt: Date = Date(),
        widgetDisplayPreferences: WidgetDisplayPreferences
    ) {
        schemaVersion = Self.schemaVersion
        self.updatedAt = updatedAt
        self.widgetDisplayPreferences = widgetDisplayPreferences
    }
}

public struct CompanionPresentationRemoteLoadResult: Equatable, Sendable {
    public let document: CompanionPresentationDocument?
    public let outcome: CompanionRemoteSyncOutcome

    public init(
        document: CompanionPresentationDocument?,
        outcome: CompanionRemoteSyncOutcome
    ) {
        self.document = document
        self.outcome = outcome
    }
}

public struct CompanionPresentationRemoteStore: Sendable {
    public let storeRole: String
    private let saveDocument: @Sendable (CompanionPresentationDocument) async -> CompanionRemoteSyncOutcome
    private let loadDocument: @Sendable () async -> CompanionPresentationRemoteLoadResult

    public init(
        storeRole: String = CompanionRemoteSync.cloudKitPresentationStoreRole,
        saveDocument: @escaping @Sendable (CompanionPresentationDocument) async -> CompanionRemoteSyncOutcome,
        loadDocument: @escaping @Sendable () async -> CompanionPresentationRemoteLoadResult
    ) {
        self.storeRole = ConnectorRedactor.redact(storeRole)
        self.saveDocument = saveDocument
        self.loadDocument = loadDocument
    }

    public func save(_ document: CompanionPresentationDocument) async -> CompanionRemoteSyncOutcome {
        await saveDocument(document)
    }

    public func load() async -> CompanionPresentationRemoteLoadResult {
        await loadDocument()
    }
}

public enum CompanionSyncPayloadCodec {
    public static func encode(_ document: CompanionSyncDocument) throws -> Data {
        try makeEncoder().encode(document)
    }

    public static func decode(_ data: Data) throws -> CompanionSyncDocument {
        let document = try makeDecoder().decode(CompanionSyncDocument.self, from: data)
        guard document.schemaVersion == CompanionSyncDocument.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
        }
        guard document.snapshot.schemaVersion == CompanionSnapshot.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.snapshot.schemaVersion)
        }
        return document
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

public enum CompanionPresentationPayloadCodec {
    public static func encode(_ document: CompanionPresentationDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> CompanionPresentationDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CompanionPresentationDocument.self, from: data)
        guard document.schemaVersion == CompanionPresentationDocument.schemaVersion else {
            throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
        }
        return document
    }
}

public extension CompanionSyncSource {
    static func storeRole(_ storeRole: String) -> CompanionSyncSource {
        switch storeRole {
        case "app-group": .appGroup
        case "icloud": .iCloud
        case CompanionRemoteSync.cloudKitStoreRole,
             CompanionRemoteSync.cloudKitPresentationStoreRole: .cloudKit
        default: .custom
        }
    }
}
