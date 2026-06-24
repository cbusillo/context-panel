import Foundation

public enum RefreshDiagnosticsSource: String, Codable, Equatable, Sendable {
    case app
    case refreshAgent
}

public enum RefreshDiagnosticsDecision: String, Codable, Equatable, Sendable {
    case refreshed
    case skippedFresh
    case skippedAlreadyRunning
    case skippedNoReports
    case failed
}

public enum RefreshDiagnosticsAlertChannel: String, Codable, Equatable, Sendable {
    case localNotification
    case webhook
}

public struct RefreshDiagnosticsRun: Codable, Equatable, Sendable {
    public var id: String
    public var source: RefreshDiagnosticsSource
    public var startedAt: Date
    public var finishedAt: Date?
    public var decision: RefreshDiagnosticsDecision?
    public var intervalSeconds: Int?
    public var enabledAccountCount: Int?
    public var connectorCount: Int?
    public var reportCount: Int?
    public var failureCount: Int?
    public var limitCount: Int?
    public var savedSnapshotAt: Date?
    public var errorMessage: String?

    public init(
        id: String,
        source: RefreshDiagnosticsSource,
        startedAt: Date,
        finishedAt: Date? = nil,
        decision: RefreshDiagnosticsDecision? = nil,
        intervalSeconds: Int? = nil,
        enabledAccountCount: Int? = nil,
        connectorCount: Int? = nil,
        reportCount: Int? = nil,
        failureCount: Int? = nil,
        limitCount: Int? = nil,
        savedSnapshotAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.source = source
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.decision = decision
        self.intervalSeconds = intervalSeconds
        self.enabledAccountCount = enabledAccountCount
        self.connectorCount = connectorCount
        self.reportCount = reportCount
        self.failureCount = failureCount
        self.limitCount = limitCount
        self.savedSnapshotAt = savedSnapshotAt
        self.errorMessage = errorMessage.map { ConnectorRedactor.redact($0) }
    }
}

public struct RefreshDiagnosticsAlertRecord: Codable, Equatable, Sendable {
    public var channel: RefreshDiagnosticsAlertChannel
    public var attemptedAt: Date
    public var succeededAt: Date?
    public var eventCount: Int
    public var lastHTTPStatus: Int?
    public var errorMessage: String?

    public init(
        channel: RefreshDiagnosticsAlertChannel,
        attemptedAt: Date,
        succeededAt: Date? = nil,
        eventCount: Int,
        lastHTTPStatus: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.channel = channel
        self.attemptedAt = attemptedAt
        self.succeededAt = succeededAt
        self.eventCount = eventCount
        self.lastHTTPStatus = lastHTTPStatus
        self.errorMessage = errorMessage.map { ConnectorRedactor.redact($0) }
    }

    public var succeeded: Bool { succeededAt != nil }
}

public enum CompanionSyncDiagnosticsOperation: String, Codable, Equatable, Sendable {
    case publish
    case load
}

public enum CompanionSyncDiagnosticsOutcome: String, Codable, Equatable, Sendable {
    case healthy
    case partial
    case unavailable
    case stale
    case failed
}

public struct CompanionSyncDiagnosticsRecord: Codable, Equatable, Sendable {
    public var operation: CompanionSyncDiagnosticsOperation
    public var outcome: CompanionSyncDiagnosticsOutcome
    public var attemptedAt: Date
    public var appGroupSucceeded: Bool?
    public var iCloudSucceeded: Bool?
    public var iCloudAvailable: Bool?
    public var cloudKitSucceeded: Bool?
    public var cloudKitAvailable: Bool?
    public var cloudKitMissingRecord: Bool?
    public var loadedDocument: Bool?
    public var mirroredDocument: Bool?
    public var stale: Bool?
    public var errorMessage: String?

    public init(
        operation: CompanionSyncDiagnosticsOperation,
        outcome: CompanionSyncDiagnosticsOutcome,
        attemptedAt: Date,
        appGroupSucceeded: Bool? = nil,
        iCloudSucceeded: Bool? = nil,
        iCloudAvailable: Bool? = nil,
        cloudKitSucceeded: Bool? = nil,
        cloudKitAvailable: Bool? = nil,
        cloudKitMissingRecord: Bool? = nil,
        loadedDocument: Bool? = nil,
        mirroredDocument: Bool? = nil,
        stale: Bool? = nil,
        errorMessage: String? = nil
    ) {
        self.operation = operation
        self.outcome = outcome
        self.attemptedAt = attemptedAt
        self.appGroupSucceeded = appGroupSucceeded
        self.iCloudSucceeded = iCloudSucceeded
        self.iCloudAvailable = iCloudAvailable
        self.cloudKitSucceeded = cloudKitSucceeded
        self.cloudKitAvailable = cloudKitAvailable
        self.cloudKitMissingRecord = cloudKitMissingRecord
        self.loadedDocument = loadedDocument
        self.mirroredDocument = mirroredDocument
        self.stale = stale
        self.errorMessage = errorMessage.map { ConnectorRedactor.redact($0) }
    }
}

public struct RefreshDiagnosticsState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var lastRun: RefreshDiagnosticsRun?
    public var lastSuccessfulRun: RefreshDiagnosticsRun?
    public var lastAlertEvaluationAt: Date?
    public var lastAlertEvaluationEventCount: Int?
    public var lastLocalNotification: RefreshDiagnosticsAlertRecord?
    public var lastWebhook: RefreshDiagnosticsAlertRecord?
    public var lastCompanionPublish: CompanionSyncDiagnosticsRecord?
    public var lastCompanionLoad: CompanionSyncDiagnosticsRecord?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lastRun
        case lastSuccessfulRun
        case lastAlertEvaluationAt
        case lastAlertEvaluationEventCount
        case lastLocalNotification
        case lastWebhook
        case lastCompanionPublish
        case lastCompanionLoad
    }

    public init(
        lastRun: RefreshDiagnosticsRun? = nil,
        lastSuccessfulRun: RefreshDiagnosticsRun? = nil,
        lastAlertEvaluationAt: Date? = nil,
        lastAlertEvaluationEventCount: Int? = nil,
        lastLocalNotification: RefreshDiagnosticsAlertRecord? = nil,
        lastWebhook: RefreshDiagnosticsAlertRecord? = nil,
        lastCompanionPublish: CompanionSyncDiagnosticsRecord? = nil,
        lastCompanionLoad: CompanionSyncDiagnosticsRecord? = nil
    ) {
        schemaVersion = 1
        self.lastRun = lastRun
        self.lastSuccessfulRun = lastSuccessfulRun
        self.lastAlertEvaluationAt = lastAlertEvaluationAt
        self.lastAlertEvaluationEventCount = lastAlertEvaluationEventCount
        self.lastLocalNotification = lastLocalNotification
        self.lastWebhook = lastWebhook
        self.lastCompanionPublish = lastCompanionPublish
        self.lastCompanionLoad = lastCompanionLoad
    }

    public static var empty: RefreshDiagnosticsState { RefreshDiagnosticsState() }

    public mutating func recordRunStarted(
        id: String,
        source: RefreshDiagnosticsSource,
        at startedAt: Date,
        intervalSeconds: Int? = nil
    ) {
        lastRun = RefreshDiagnosticsRun(
            id: id,
            source: source,
            startedAt: startedAt,
            intervalSeconds: intervalSeconds
        )
    }

    public mutating func recordRunFinished(
        id: String,
        decision: RefreshDiagnosticsDecision,
        finishedAt: Date,
        enabledAccountCount: Int? = nil,
        connectorCount: Int? = nil,
        reportCount: Int? = nil,
        failureCount: Int? = nil,
        limitCount: Int? = nil,
        savedSnapshotAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        guard lastRun?.id == id else { return }
        var run = lastRun ?? RefreshDiagnosticsRun(id: id, source: .app, startedAt: finishedAt)
        run.finishedAt = finishedAt
        run.decision = decision
        run.enabledAccountCount = enabledAccountCount ?? run.enabledAccountCount
        run.connectorCount = connectorCount ?? run.connectorCount
        run.reportCount = reportCount ?? run.reportCount
        run.failureCount = failureCount ?? run.failureCount
        run.limitCount = limitCount ?? run.limitCount
        run.savedSnapshotAt = savedSnapshotAt
        run.errorMessage = errorMessage.map { ConnectorRedactor.redact($0) }
        lastRun = run
        if decision == .refreshed {
            lastSuccessfulRun = run
        }
    }

    public mutating func recordAlertEvaluation(at evaluatedAt: Date, eventCount: Int) {
        lastAlertEvaluationAt = evaluatedAt
        lastAlertEvaluationEventCount = eventCount
    }

    public mutating func recordAlert(_ record: RefreshDiagnosticsAlertRecord) {
        switch record.channel {
        case .localNotification:
            lastLocalNotification = record
        case .webhook:
            lastWebhook = record
        }
    }

    public mutating func recordCompanionSync(_ record: CompanionSyncDiagnosticsRecord) {
        switch record.operation {
        case .publish:
            lastCompanionPublish = record
        case .load:
            lastCompanionLoad = record
        }
    }
}

public struct RefreshDiagnosticsStateStore: Sendable {
    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func load() -> RefreshDiagnosticsState {
        loadIfAvailable() ?? .empty
    }

    public func loadIfAvailable() -> RefreshDiagnosticsState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        do {
            let state = try Self.makeDecoder().decode(
                RefreshDiagnosticsState.self,
                from: try Data(contentsOf: stateURL)
            )
            guard state.schemaVersion == 1 else { return nil }
            return state
        } catch {
            return nil
        }
    }

    public func save(_ state: RefreshDiagnosticsState) throws {
        try withExclusiveLock {
            try saveUnlocked(state)
        }
    }

    public func update(_ body: (inout RefreshDiagnosticsState) -> Void) throws {
        try withExclusiveLock {
            var state = loadIfAvailable() ?? .empty
            body(&state)
            try saveUnlocked(state)
        }
    }

    private func saveUnlocked(_ state: RefreshDiagnosticsState) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        var coordinationError: NSError?
        var operationError: Error?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: stateURL,
            options: .forReplacing,
            error: &coordinationError
        ) { _ in
            do {
                result = .success(try body())
            } catch {
                operationError = error
                result = .failure(error)
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
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
