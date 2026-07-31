import Foundation

public enum RuntimeReceiptRemoteSync {
    public static let cloudKitStoreRole = "runtime-receipt-relay"
    public static let cloudKitSessionRecordType = "RuntimeValidationSession"
    public static let cloudKitReceiptRecordType = "RuntimeReceipt"
    public static let cloudKitSessionRecordName = "runtime-validation-session-current-v1"
    public static let payloadFieldName = "payload"
    public static let schemaVersionFieldName = "schemaVersion"
    public static let sessionSchemaVersionFieldName = "sessionSchemaVersion"
    public static let receiptSchemaVersionFieldName = "receiptSchemaVersion"
    public static let sessionIDFieldName = "sessionID"
    public static let receiptIDFieldName = "receiptID"
    public static let surfaceFieldName = "surface"
    public static let createdAtFieldName = "createdAt"
    public static let expiresAtFieldName = "expiresAt"
    public static let observedAtFieldName = "observedAt"
    public static let retentionExpiresAtFieldName = "retentionExpiresAt"
    public static let expectedManifestIDFieldName = "expectedManifestID"
    public static let processInstanceIDFieldName = "processInstanceID"
    public static let processSequenceFieldName = "processSequence"
    public static let publishedAtFieldName = "publishedAt"
    public static let sessionStateFieldName = "sessionState"
    public static let stateUpdatedAtFieldName = "stateUpdatedAt"
    public static let payloadByteCountFieldName = "payloadByteCount"
    public static let maximumReceiptsPerSync = 64
    public static let maximumSessionsPerReceiptDownload = 4
    public static let sessionRefreshInterval: TimeInterval = 15 * 60
    public static let activeReceiptDownloadInterval: TimeInterval = 60
    public static let retainedReceiptDownloadInterval: TimeInterval = 15 * 60
    public static let maintenanceInterval: TimeInterval = 60 * 60
    public static let defaultRetryInterval: TimeInterval = 60
    public static let maximumRetryInterval: TimeInterval = 24 * 60 * 60
}

public struct RuntimeReceiptRemoteOutcome: Equatable, Sendable {
    public let storeRole: String
    public let isAvailable: Bool
    public let succeeded: Bool
    public let errorMessage: String?
    public let retryAfterSeconds: TimeInterval?

    public init(
        storeRole: String = RuntimeReceiptRemoteSync.cloudKitStoreRole,
        isAvailable: Bool = true,
        succeeded: Bool,
        errorMessage: String? = nil,
        retryAfterSeconds: TimeInterval? = nil
    ) {
        self.storeRole = ConnectorRedactor.redact(storeRole)
        self.isAvailable = isAvailable
        self.succeeded = succeeded
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
        self.retryAfterSeconds = retryAfterSeconds.map {
            min(max($0, 0), RuntimeReceiptRemoteSync.maximumRetryInterval)
        }
    }
}

public enum RuntimeValidationSessionRemoteState: String, Codable, Equatable, Sendable {
    case active
    case cleared
    case missing
}

public struct RuntimeValidationSessionRemoteLoadResult: Equatable, Sendable {
    public let session: RuntimeValidationSession?
    public let missingRecord: Bool
    public let state: RuntimeValidationSessionRemoteState
    public let stateUpdatedAt: Date?
    public let outcome: RuntimeReceiptRemoteOutcome

    public init(
        session: RuntimeValidationSession?,
        missingRecord: Bool = false,
        state: RuntimeValidationSessionRemoteState? = nil,
        stateUpdatedAt: Date? = nil,
        outcome: RuntimeReceiptRemoteOutcome
    ) {
        self.session = session
        self.missingRecord = missingRecord
        self.state = state ?? (session == nil ? .missing : .active)
        self.stateUpdatedAt = stateUpdatedAt
        self.outcome = outcome
    }
}

public struct RuntimeReceiptRemoteEnvelope: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let receipt: RuntimeReceipt
    public let serverReceivedAt: Date

    public init(receipt: RuntimeReceipt, serverReceivedAt: Date) {
        schemaVersion = Self.schemaVersion
        self.receipt = receipt
        self.serverReceivedAt = RuntimeValidationSession.wholeSecond(serverReceivedAt)
    }

    public var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && receipt.isStructurallyValid
            && serverReceivedAt >= receipt.sessionCreatedAt.addingTimeInterval(
                -RuntimeValidationSession.maximumClockSkew
            )
            && serverReceivedAt <= receipt.retentionExpiresAt.addingTimeInterval(
                RuntimeValidationSession.maximumClockSkew
            )
    }

    public static func ordered(
        _ envelopes: [RuntimeReceiptRemoteEnvelope]
    ) -> [RuntimeReceiptRemoteEnvelope] {
        struct OrderedEnvelope {
            let envelope: RuntimeReceiptRemoteEnvelope
            let effectiveServerReceivedAt: Date
        }

        var orderedEnvelopes: [OrderedEnvelope] = []
        for processEnvelopes in Dictionary(
            grouping: envelopes,
            by: { $0.receipt.processInstanceID }
        ).values {
            var effectiveServerReceivedAt = Date.distantPast
            for envelope in processEnvelopes.sorted(by: processOrder) {
                effectiveServerReceivedAt = max(
                    effectiveServerReceivedAt,
                    envelope.serverReceivedAt
                )
                orderedEnvelopes.append(
                    OrderedEnvelope(
                        envelope: envelope,
                        effectiveServerReceivedAt: effectiveServerReceivedAt
                    )
                )
            }
        }

        return orderedEnvelopes.sorted { lhs, rhs in
            if lhs.effectiveServerReceivedAt != rhs.effectiveServerReceivedAt {
                return lhs.effectiveServerReceivedAt < rhs.effectiveServerReceivedAt
            }
            if lhs.envelope.receipt.processInstanceID
                != rhs.envelope.receipt.processInstanceID {
                return lhs.envelope.receipt.processInstanceID.uuidString
                    < rhs.envelope.receipt.processInstanceID.uuidString
            }
            if lhs.envelope.receipt.processSequence
                != rhs.envelope.receipt.processSequence {
                return lhs.envelope.receipt.processSequence
                    < rhs.envelope.receipt.processSequence
            }
            return lhs.envelope.receipt.id < rhs.envelope.receipt.id
        }.map(\.envelope)
    }

    private static func processOrder(
        _ lhs: RuntimeReceiptRemoteEnvelope,
        _ rhs: RuntimeReceiptRemoteEnvelope
    ) -> Bool {
        if lhs.receipt.processSequence != rhs.receipt.processSequence {
            return lhs.receipt.processSequence < rhs.receipt.processSequence
        }
        if lhs.serverReceivedAt != rhs.serverReceivedAt {
            return lhs.serverReceivedAt < rhs.serverReceivedAt
        }
        return lhs.receipt.id < rhs.receipt.id
    }
}

public struct RuntimeReceiptRemoteSaveResult: Equatable, Sendable {
    public let acceptedReceiptIDs: [String]
    public let outcome: RuntimeReceiptRemoteOutcome

    public init(
        acceptedReceiptIDs: [String],
        outcome: RuntimeReceiptRemoteOutcome
    ) {
        self.acceptedReceiptIDs = Array(Set(acceptedReceiptIDs)).sorted()
        self.outcome = outcome
    }
}

public struct RuntimeReceiptRemoteLoadResult: Equatable, Sendable {
    public let envelopes: [RuntimeReceiptRemoteEnvelope]
    public let outcome: RuntimeReceiptRemoteOutcome

    public init(
        envelopes: [RuntimeReceiptRemoteEnvelope],
        outcome: RuntimeReceiptRemoteOutcome
    ) {
        self.envelopes = RuntimeReceiptRemoteEnvelope.ordered(envelopes)
        self.outcome = outcome
    }
}

public struct RuntimeReceiptRemotePruneResult: Equatable, Sendable {
    public let deletedReceiptCount: Int
    public let outcome: RuntimeReceiptRemoteOutcome

    public init(
        deletedReceiptCount: Int,
        outcome: RuntimeReceiptRemoteOutcome
    ) {
        self.deletedReceiptCount = max(deletedReceiptCount, 0)
        self.outcome = outcome
    }
}

public enum RuntimeValidationSessionRemoteMutation: Equatable, Sendable {
    case publish(RuntimeValidationSession)
    case clear(RuntimeValidationSession)
}

public struct RuntimeReceiptRemoteStore: Sendable {
    private let publishCurrentSession: @Sendable (RuntimeValidationSessionRemoteMutation) async -> RuntimeReceiptRemoteOutcome
    private let loadCurrentSession: @Sendable (Date) async -> RuntimeValidationSessionRemoteLoadResult
    private let saveReceiptBatch: @Sendable ([RuntimeReceipt], Date) async -> RuntimeReceiptRemoteSaveResult
    private let loadReceiptBatch: @Sendable (UUID, Date) async -> RuntimeReceiptRemoteLoadResult
    private let pruneExpiredReceiptBatch: @Sendable (Date) async -> RuntimeReceiptRemotePruneResult

    public init(
        publishCurrentSession: @escaping @Sendable (RuntimeValidationSessionRemoteMutation) async -> RuntimeReceiptRemoteOutcome,
        loadCurrentSession: @escaping @Sendable (Date) async -> RuntimeValidationSessionRemoteLoadResult,
        saveReceiptBatch: @escaping @Sendable ([RuntimeReceipt], Date) async -> RuntimeReceiptRemoteSaveResult,
        loadReceiptBatch: @escaping @Sendable (UUID, Date) async -> RuntimeReceiptRemoteLoadResult,
        pruneExpiredReceiptBatch: @escaping @Sendable (Date) async -> RuntimeReceiptRemotePruneResult
    ) {
        self.publishCurrentSession = publishCurrentSession
        self.loadCurrentSession = loadCurrentSession
        self.saveReceiptBatch = saveReceiptBatch
        self.loadReceiptBatch = loadReceiptBatch
        self.pruneExpiredReceiptBatch = pruneExpiredReceiptBatch
    }

    public func publishSession(
        _ mutation: RuntimeValidationSessionRemoteMutation
    ) async -> RuntimeReceiptRemoteOutcome {
        await publishCurrentSession(mutation)
    }

    public func loadSession(now: Date = Date()) async -> RuntimeValidationSessionRemoteLoadResult {
        await loadCurrentSession(now)
    }

    public func saveReceipts(
        _ receipts: [RuntimeReceipt],
        now: Date = Date()
    ) async -> RuntimeReceiptRemoteSaveResult {
        await saveReceiptBatch(receipts, now)
    }

    public func loadReceipts(
        sessionID: UUID,
        now: Date = Date()
    ) async -> RuntimeReceiptRemoteLoadResult {
        await loadReceiptBatch(sessionID, now)
    }

    public func pruneExpiredReceipts(now: Date = Date()) async -> RuntimeReceiptRemotePruneResult {
        await pruneExpiredReceiptBatch(now)
    }
}

public enum RuntimeValidationSessionPayloadCodec {
    public static func encode(_ session: RuntimeValidationSession) throws -> Data {
        try RuntimeReceiptJSON.makeEncoder().encode(session)
    }

    public static func decode(
        _ data: Data,
        now: Date,
        requiresActive: Bool
    ) throws -> RuntimeValidationSession {
        let session = try RuntimeReceiptJSON.makeDecoder().decode(RuntimeValidationSession.self, from: data)
        guard session.isStructurallyValid(now: now, requiresActive: requiresActive),
              try encode(session) == data
        else {
            throw RuntimeReceiptRemoteSyncError.invalidSession
        }
        return session
    }
}

public enum RuntimeReceiptPayloadCodec {
    public static func encode(_ receipt: RuntimeReceipt) throws -> Data {
        guard receipt.isStructurallyValid else {
            throw RuntimeReceiptRemoteSyncError.invalidReceipt
        }
        return try RuntimeReceiptJSON.makeEncoder().encode(receipt)
    }

    public static func decode(_ data: Data) throws -> RuntimeReceipt {
        let receipt = try RuntimeReceiptJSON.makeDecoder().decode(RuntimeReceipt.self, from: data)
        guard receipt.isStructurallyValid,
              try encode(receipt) == data
        else {
            throw RuntimeReceiptRemoteSyncError.invalidReceipt
        }
        return receipt
    }
}

public enum RuntimeReceiptRemoteSyncError: Error, Equatable, Sendable {
    case invalidSession
    case conflictingSession
    case invalidReceipt
    case invalidEnvelope
    case conflictingReceipt
    case busy
}

public struct RuntimeReceiptRelayStateStore: Sendable {
    public static let maximumAcknowledgementCount = RuntimeReceiptStore.maximumRetainedReceiptCount

    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func pendingReceipts(
        from receipts: [RuntimeReceipt],
        now: Date,
        limit: Int = RuntimeReceiptRemoteSync.maximumReceiptsPerSync
    ) -> [RuntimeReceipt] {
        let acknowledgedIDs = Set(loadState(now: now).acknowledgements.map(\.receiptID))
        return Array(
            RuntimeReceipt.ordered(
                receipts.filter {
                    now < $0.retentionExpiresAt && !acknowledgedIDs.contains($0.id)
                }
            )
                .prefix(max(limit, 0))
        )
    }

    public func allowsRemoteWork(now: Date) -> Bool {
        guard let retryNotBefore = loadState(now: now).retryNotBefore else { return true }
        return now >= retryNotBefore
    }

    public func sessionsNeedingClear(
        from sessions: [RuntimeValidationSession],
        activeSessionID: UUID?,
        now: Date
    ) -> [RuntimeValidationSession] {
        let clearedIDs = Set(loadState(now: now).clearedSessions.map(\.sessionID))
        return sessions.filter {
            $0.id != activeSessionID && !clearedIDs.contains($0.id) && $0.isRetained(now: now)
        }
    }

    public func shouldPublish(
        session: RuntimeValidationSession,
        now: Date
    ) -> Bool {
        let state = loadState(now: now)
        guard state.publishedSessionID == session.id else { return true }
        return state.nextSessionRefreshAt.map { now >= $0 } ?? true
    }

    public func shouldDownloadReceipts(now: Date) -> Bool {
        loadState(now: now).nextReceiptDownloadAt.map { now >= $0 } ?? true
    }

    public func receiptDownloadSessions(
        from sessions: [RuntimeValidationSession],
        activeSessionID: UUID?,
        now: Date
    ) -> [RuntimeValidationSession] {
        let sorted = sessions.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard sorted.count > RuntimeReceiptRemoteSync.maximumSessionsPerReceiptDownload else {
            return sorted
        }

        var selected: [RuntimeValidationSession] = []
        if let activeSessionID,
           let active = sorted.first(where: { $0.id == activeSessionID }) {
            selected.append(active)
        }
        let remaining = sorted.filter { $0.id != activeSessionID }
        guard !remaining.isEmpty else { return selected }
        let cursor = loadState(now: now).receiptDownloadSessionCursor
        let startIndex = cursor.flatMap { cursor in
            remaining.firstIndex(where: { $0.id == cursor }).map {
                remaining.index(after: $0) % remaining.count
            }
        } ?? 0
        let availableCount = RuntimeReceiptRemoteSync.maximumSessionsPerReceiptDownload
            - selected.count
        for offset in 0..<min(availableCount, remaining.count) {
            selected.append(remaining[(startIndex + offset) % remaining.count])
        }
        return selected
    }

    public func shouldRunMaintenance(now: Date) -> Bool {
        let state = loadState(now: now)
        guard state.remoteCleanupUntil != nil else { return false }
        return state.nextMaintenanceAt.map { now >= $0 } ?? true
    }

    public func acknowledge(
        receiptIDs: [String],
        from receipts: [RuntimeReceipt],
        now: Date
    ) throws {
        let acceptedIDs = Set(receiptIDs)
        guard !acceptedIDs.isEmpty else { return }
        try mutateState(now: now) { state in
            var acknowledgements: [String: RuntimeReceiptRelayAcknowledgement] = [:]
            for acknowledgement in state.acknowledgements {
                acknowledgements[acknowledgement.receiptID] = acknowledgement
            }
            for receipt in receipts where acceptedIDs.contains(receipt.id) {
                acknowledgements[receipt.id] = RuntimeReceiptRelayAcknowledgement(
                    receiptID: receipt.id,
                    retentionExpiresAt: receipt.retentionExpiresAt
                )
                state.remoteCleanupUntil = max(
                    state.remoteCleanupUntil ?? .distantPast,
                    receipt.retentionExpiresAt
                )
            }
            state.acknowledgements = Array(acknowledgements.values)
                .filter { now < $0.retentionExpiresAt }
                .sorted {
                    if $0.retentionExpiresAt != $1.retentionExpiresAt {
                        return $0.retentionExpiresAt < $1.retentionExpiresAt
                    }
                    return $0.receiptID < $1.receiptID
                }
                .suffix(Self.maximumAcknowledgementCount)
                .map { $0 }
        }
    }

    public func recordPublishedSession(
        _ session: RuntimeValidationSession,
        now: Date
    ) throws {
        try mutateState(now: now) { state in
            state.publishedSessionID = session.id
            state.nextSessionRefreshAt = now.addingTimeInterval(
                RuntimeReceiptRemoteSync.sessionRefreshInterval
            )
            state.remoteCleanupUntil = max(
                state.remoteCleanupUntil ?? .distantPast,
                session.receiptRetentionExpiresAt
            )
        }
    }

    public func recordClearedSession(
        _ session: RuntimeValidationSession,
        now: Date
    ) throws {
        try mutateState(now: now) { state in
            var cleared: [UUID: RuntimeReceiptRelaySessionAcknowledgement] = [:]
            for acknowledgement in state.clearedSessions {
                cleared[acknowledgement.sessionID] = acknowledgement
            }
            cleared[session.id] = RuntimeReceiptRelaySessionAcknowledgement(
                sessionID: session.id,
                retentionExpiresAt: session.receiptRetentionExpiresAt
            )
            state.clearedSessions = Array(cleared.values)
            if state.publishedSessionID == session.id {
                state.publishedSessionID = nil
                state.nextSessionRefreshAt = nil
            }
            state.remoteCleanupUntil = max(
                state.remoteCleanupUntil ?? .distantPast,
                session.receiptRetentionExpiresAt
            )
        }
    }

    public func recordReceiptDownload(
        hasActiveSession: Bool,
        lastSessionID: UUID?,
        now: Date
    ) throws {
        try mutateState(now: now) { state in
            state.nextReceiptDownloadAt = now.addingTimeInterval(
                hasActiveSession
                    ? RuntimeReceiptRemoteSync.activeReceiptDownloadInterval
                    : RuntimeReceiptRemoteSync.retainedReceiptDownloadInterval
            )
            state.receiptDownloadSessionCursor = lastSessionID
        }
    }

    public func recordMaintenance(
        deletedReceiptCount: Int,
        now: Date
    ) throws {
        try mutateState(now: now) { state in
            if let cleanupUntil = state.remoteCleanupUntil,
               now >= cleanupUntil.addingTimeInterval(
                   RuntimeReceiptRemoteSync.maintenanceInterval
               ),
               deletedReceiptCount < RuntimeReceiptRemoteSync.maximumReceiptsPerSync {
                state.remoteCleanupUntil = nil
                state.nextMaintenanceAt = nil
            } else {
                state.nextMaintenanceAt = now.addingTimeInterval(
                    deletedReceiptCount >= RuntimeReceiptRemoteSync.maximumReceiptsPerSync
                        ? RuntimeReceiptRemoteSync.defaultRetryInterval
                        : RuntimeReceiptRemoteSync.maintenanceInterval
                )
            }
        }
    }

    public func recordRemoteFailure(
        _ outcome: RuntimeReceiptRemoteOutcome,
        now: Date
    ) throws {
        try mutateState(now: now) { state in
            state.consecutiveFailureCount = min(state.consecutiveFailureCount + 1, 10)
            let exponentialDelay = RuntimeReceiptRemoteSync.defaultRetryInterval
                * pow(2, Double(state.consecutiveFailureCount - 1))
            let delay = min(
                max(outcome.retryAfterSeconds ?? 0, exponentialDelay),
                RuntimeReceiptRemoteSync.maximumRetryInterval
            )
            state.retryNotBefore = max(
                state.retryNotBefore ?? .distantPast,
                now.addingTimeInterval(delay)
            )
        }
    }

    public func recordRemoteSuccess(now: Date) throws {
        try mutateState(now: now) { state in
            state.retryNotBefore = nil
            state.consecutiveFailureCount = 0
        }
    }

    private func mutateState(
        now: Date,
        mutation: (inout RuntimeReceiptRelayState) -> Void
    ) throws {
        let directoryURL = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
            throw RuntimeReceiptRemoteSyncError.busy
        }
        defer { lock.unlock() }

        var state = loadState(now: now)
        mutation(&state)
        state.normalize(now: now)
        try RuntimeReceiptJSON.makeEncoder().encode(state).write(to: stateURL, options: [.atomic])
    }

    private func loadState(now: Date) -> RuntimeReceiptRelayState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return RuntimeReceiptRelayState()
        }
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? RuntimeReceiptJSON.makeDecoder().decode(
                  RuntimeReceiptRelayState.self,
                  from: data
              ),
              state.schemaVersion == RuntimeReceiptRelayState.schemaVersion
        else {
            return RuntimeReceiptRelayState()
        }
        state.normalize(now: now)
        return state
    }
}

public struct RuntimeReceiptInboxStore: Sendable {
    public let directoryURL: URL
    public let maximumRetainedReceiptCount: Int

    public init(
        directoryURL: URL,
        maximumRetainedReceiptCount: Int = RuntimeReceiptStore.maximumRetainedReceiptCount
    ) {
        self.directoryURL = directoryURL
        self.maximumRetainedReceiptCount = max(
            1,
            min(maximumRetainedReceiptCount, RuntimeReceiptStore.maximumRetainedReceiptCount)
        )
    }

    public func save(
        _ envelopes: [RuntimeReceiptRemoteEnvelope],
        now: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
            throw RuntimeReceiptRemoteSyncError.busy
        }
        defer { lock.unlock() }

        for envelope in envelopes where envelope.isStructurallyValid
            && now < envelope.receipt.retentionExpiresAt {
            let url = directoryURL.appending(path: "\(envelope.receipt.id).json")
            if let data = try? Data(contentsOf: url),
               let existing = try? RuntimeReceiptJSON.makeDecoder().decode(
                   RuntimeReceiptRemoteEnvelope.self,
                   from: data
               ) {
                guard existing == envelope else {
                    throw RuntimeReceiptRemoteSyncError.conflictingReceipt
                }
                continue
            }
            try RuntimeReceiptJSON.makeEncoder().encode(envelope).write(to: url, options: [.atomic])
        }
        prune(now: now)
    }

    public func loadEnvelopes(now: Date = Date()) -> [RuntimeReceiptRemoteEnvelope] {
        RuntimeReceiptRemoteEnvelope.ordered(
            loadKnownEnvelopes().filter { now < $0.receipt.retentionExpiresAt }
        )
    }

    public func pruneExpiredEnvelopes(now: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
            throw RuntimeReceiptRemoteSyncError.busy
        }
        defer { lock.unlock() }
        prune(now: now)
    }

    private func prune(now: Date) {
        let knownEnvelopes = loadKnownEnvelopes()
        let retained = RuntimeReceiptRemoteEnvelope.ordered(
            knownEnvelopes.filter { now < $0.receipt.retentionExpiresAt }
        )
            .suffix(maximumRetainedReceiptCount)
        let retainedIDs = Set(retained.map(\.receipt.id))
        for envelope in knownEnvelopes where !retainedIDs.contains(envelope.receipt.id) {
            try? FileManager.default.removeItem(
                at: directoryURL.appending(path: "\(envelope.receipt.id).json")
            )
        }
    }

    private func loadKnownEnvelopes() -> [RuntimeReceiptRemoteEnvelope] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? RuntimeReceiptJSON.makeDecoder().decode(
                          RuntimeReceiptRemoteEnvelope.self,
                          from: data
                      ),
                      envelope.isStructurallyValid
                else {
                    return nil
                }
                return envelope
            }
    }
}

public enum RuntimeReceiptSessionRelayAction: String, Codable, Equatable, Sendable {
    case published
    case cleared
    case mirrored
    case rejected
    case unchanged
    case failed
}

public struct RuntimeReceiptSessionRelayResult: Equatable, Sendable {
    public let action: RuntimeReceiptSessionRelayAction
    public let isHealthy: Bool
    public let message: String?

    public init(
        action: RuntimeReceiptSessionRelayAction,
        isHealthy: Bool,
        message: String? = nil
    ) {
        self.action = action
        self.isHealthy = isHealthy
        self.message = message.map(ConnectorRedactor.safeErrorDescription)
    }
}

public struct RuntimeReceiptRelaySummary: Equatable, Sendable {
    public let sessionAction: RuntimeReceiptSessionRelayAction
    public let uploadedReceiptCount: Int
    public let downloadedReceiptCount: Int
    public let deletedRemoteReceiptCount: Int
    public let isHealthy: Bool
    public let messages: [String]

    public init(
        sessionAction: RuntimeReceiptSessionRelayAction,
        uploadedReceiptCount: Int,
        downloadedReceiptCount: Int,
        deletedRemoteReceiptCount: Int,
        isHealthy: Bool,
        messages: [String]
    ) {
        self.sessionAction = sessionAction
        self.uploadedReceiptCount = max(uploadedReceiptCount, 0)
        self.downloadedReceiptCount = max(downloadedReceiptCount, 0)
        self.deletedRemoteReceiptCount = max(deletedRemoteReceiptCount, 0)
        self.isHealthy = isHealthy
        self.messages = Array(Set(messages.map(ConnectorRedactor.safeErrorDescription))).sorted()
    }
}

public enum RuntimeReceiptRelayRole: Equatable, Sendable {
    case publisher
    case receiver(expectedManifestID: String?, eligibleSurfaces: [RuntimeSurface])
}

public actor RuntimeReceiptRelayCoordinator {
    private let role: RuntimeReceiptRelayRole
    private let sessionStore: RuntimeValidationSessionStore
    private let receiptStore: RuntimeReceiptStore
    private let relayStateStore: RuntimeReceiptRelayStateStore
    private let inboxStore: RuntimeReceiptInboxStore?
    private let remoteStore: RuntimeReceiptRemoteStore
    private var sessionSyncTask: Task<RuntimeReceiptSessionRelayResult, Never>?
    private var receiptSyncTask: Task<RuntimeReceiptRelaySummary, Never>?

    public init(
        role: RuntimeReceiptRelayRole,
        sessionStore: RuntimeValidationSessionStore,
        receiptStore: RuntimeReceiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore,
        inboxStore: RuntimeReceiptInboxStore?,
        remoteStore: RuntimeReceiptRemoteStore
    ) {
        self.role = role
        self.sessionStore = sessionStore
        self.receiptStore = receiptStore
        self.relayStateStore = relayStateStore
        self.inboxStore = inboxStore
        self.remoteStore = remoteStore
    }

    public static func appDefaultPublisher(
        remoteStore: RuntimeReceiptRemoteStore,
        appGroupID: String = ContextPanelLocations.appGroupID
    ) -> RuntimeReceiptRelayCoordinator {
        let validationDirectory = ContextPanelLocations.runtimeValidationDirectory(
            appGroupID: appGroupID
        )
        return RuntimeReceiptRelayCoordinator(
            role: .publisher,
            sessionStore: RuntimeValidationSessionStore(
                sessionURL: validationDirectory.appending(path: "runtime-session.json")
            ),
            receiptStore: RuntimeReceiptStore(
                directoryURL: validationDirectory.appending(
                    path: "Runtime Receipts",
                    directoryHint: .isDirectory
                )
            ),
            relayStateStore: RuntimeReceiptRelayStateStore(
                stateURL: validationDirectory.appending(path: "runtime-receipt-relay-state.json")
            ),
            inboxStore: RuntimeReceiptInboxStore(
                directoryURL: validationDirectory.appending(
                    path: "Remote Runtime Receipts",
                    directoryHint: .isDirectory
                )
            ),
            remoteStore: remoteStore
        )
    }

    public static func appGroupReceiver(
        remoteStore: RuntimeReceiptRemoteStore,
        expectedManifestID: String?,
        eligibleSurfaces: [RuntimeSurface],
        appGroupID: String
    ) -> RuntimeReceiptRelayCoordinator? {
        guard let validationDirectory = ContextPanelLocations.sharedRuntimeValidationDirectory(
            appGroupID: appGroupID
        ) else {
            return nil
        }
        return RuntimeReceiptRelayCoordinator(
            role: .receiver(
                expectedManifestID: expectedManifestID,
                eligibleSurfaces: Array(Set(eligibleSurfaces)).sorted { $0.rawValue < $1.rawValue }
            ),
            sessionStore: RuntimeValidationSessionStore(
                sessionURL: validationDirectory.appending(path: "runtime-session.json")
            ),
            receiptStore: RuntimeReceiptStore(
                directoryURL: validationDirectory.appending(
                    path: "Runtime Receipts",
                    directoryHint: .isDirectory
                )
            ),
            relayStateStore: RuntimeReceiptRelayStateStore(
                stateURL: validationDirectory.appending(path: "runtime-receipt-relay-state.json")
            ),
            inboxStore: nil,
            remoteStore: remoteStore
        )
    }

    public func synchronizeSession(now: Date = Date()) async -> RuntimeReceiptSessionRelayResult {
        if let sessionSyncTask {
            return await sessionSyncTask.value
        }
        let task = Task { await self.performSynchronizeSession(now: now) }
        sessionSyncTask = task
        let result = await task.value
        sessionSyncTask = nil
        return result
    }

    private func performSynchronizeSession(
        now: Date
    ) async -> RuntimeReceiptSessionRelayResult {
        guard relayStateStore.allowsRemoteWork(now: now) else {
            return RuntimeReceiptSessionRelayResult(action: .unchanged, isHealthy: true)
        }

        switch role {
        case .publisher:
            let activeSession = sessionStore.activeSession(now: now)
            let retainedSessions = sessionStore.retainedSessions(now: now)
            guard !retainedSessions.isEmpty else {
                return RuntimeReceiptSessionRelayResult(action: .unchanged, isHealthy: true)
            }

            var action = RuntimeReceiptSessionRelayAction.unchanged
            var performedRemoteWork = false
            for session in relayStateStore.sessionsNeedingClear(
                from: retainedSessions,
                activeSessionID: activeSession?.id,
                now: now
            ) {
                performedRemoteWork = true
                let outcome = await remoteStore.publishSession(.clear(session))
                guard outcome.succeeded else {
                    try? relayStateStore.recordRemoteFailure(outcome, now: now)
                    return RuntimeReceiptSessionRelayResult(
                        action: .failed,
                        isHealthy: false,
                        message: outcome.errorMessage
                    )
                }
                do {
                    try relayStateStore.recordClearedSession(session, now: now)
                    action = .cleared
                } catch {
                    return RuntimeReceiptSessionRelayResult(
                        action: .failed,
                        isHealthy: false,
                        message: "The runtime receipt relay state could not be saved."
                    )
                }
            }

            if let activeSession,
               relayStateStore.shouldPublish(session: activeSession, now: now) {
                performedRemoteWork = true
                let outcome = await remoteStore.publishSession(.publish(activeSession))
                guard outcome.succeeded else {
                    try? relayStateStore.recordRemoteFailure(outcome, now: now)
                    return RuntimeReceiptSessionRelayResult(
                        action: .failed,
                        isHealthy: false,
                        message: outcome.errorMessage
                    )
                }
                do {
                    try relayStateStore.recordPublishedSession(activeSession, now: now)
                    action = .published
                } catch {
                    return RuntimeReceiptSessionRelayResult(
                        action: .failed,
                        isHealthy: false,
                        message: "The runtime receipt relay state could not be saved."
                    )
                }
            }

            if performedRemoteWork {
                try? relayStateStore.recordRemoteSuccess(now: now)
            }
            return RuntimeReceiptSessionRelayResult(action: action, isHealthy: true)
        case let .receiver(expectedManifestID, eligibleSurfaces):
            guard let expectedManifestID,
                  RuntimeSurfaceFingerprints.isSHA256(expectedManifestID),
                  !eligibleSurfaces.isEmpty
            else {
                return RuntimeReceiptSessionRelayResult(
                    action: .rejected,
                    isHealthy: false,
                    message: "Runtime receipt session delivery is unavailable for this build."
                )
            }
            let result = await remoteStore.loadSession(now: now)
            guard result.outcome.succeeded else {
                try? relayStateStore.recordRemoteFailure(result.outcome, now: now)
                return RuntimeReceiptSessionRelayResult(
                    action: .failed,
                    isHealthy: false,
                    message: result.outcome.errorMessage
                )
            }
            if result.state == .missing {
                try? relayStateStore.recordRemoteSuccess(now: now)
                return RuntimeReceiptSessionRelayResult(action: .unchanged, isHealthy: true)
            }
            if result.state == .cleared {
                do {
                    let applied = try sessionStore.applyRemoteState(
                        .cleared,
                        session: nil,
                        stateUpdatedAt: result.stateUpdatedAt,
                        now: now
                    )
                    try relayStateStore.recordRemoteSuccess(now: now)
                    return RuntimeReceiptSessionRelayResult(
                        action: applied ? .cleared : .unchanged,
                        isHealthy: true
                    )
                } catch {
                    return RuntimeReceiptSessionRelayResult(
                        action: .failed,
                        isHealthy: false,
                        message: "The local runtime validation session could not be cleared."
                    )
                }
            }
            guard let session = result.session else {
                return RuntimeReceiptSessionRelayResult(
                    action: .failed,
                    isHealthy: false,
                    message: "The remote runtime validation session is invalid."
                )
            }
            guard session.permitsRelay(
                expectedManifestID: expectedManifestID,
                eligibleSurfaces: eligibleSurfaces,
                now: now
            ) else {
                try? sessionStore.removeActiveSession(now: now)
                return RuntimeReceiptSessionRelayResult(
                    action: .rejected,
                    isHealthy: false,
                    message: "The remote runtime validation session does not match this build."
                )
            }
            do {
                let applied = try sessionStore.applyRemoteState(
                    .active,
                    session: session,
                    stateUpdatedAt: result.stateUpdatedAt,
                    now: now
                )
                try relayStateStore.recordRemoteSuccess(now: now)
                return RuntimeReceiptSessionRelayResult(
                    action: applied ? .mirrored : .unchanged,
                    isHealthy: true
                )
            } catch {
                return RuntimeReceiptSessionRelayResult(
                    action: .failed,
                    isHealthy: false,
                    message: "The runtime validation session could not be saved locally."
                )
            }
        }
    }

    public func relayReceipts(now: Date = Date()) async -> RuntimeReceiptRelaySummary {
        if let receiptSyncTask {
            return await receiptSyncTask.value
        }
        let task = Task { await self.performRelayReceipts(now: now) }
        receiptSyncTask = task
        let result = await task.value
        receiptSyncTask = nil
        return result
    }

    private func performRelayReceipts(now: Date) async -> RuntimeReceiptRelaySummary {
        receiptStore.pruneExpiredReceipts(now: now)
        let localReceipts = receiptStore.loadUnexpiredReceipts(now: now)
        let retainedSessions = sessionStore.retainedSessions(now: now)
        let pendingReceipts = relayStateStore.pendingReceipts(
            from: localReceipts,
            now: now
        )
        var messages: [String] = []
        var isHealthy = true
        var uploadedReceiptCount = 0
        var downloadedReceiptCount = 0
        var deletedRemoteReceiptCount = 0
        var performedRemoteWork = false
        do {
            try inboxStore?.pruneExpiredEnvelopes(now: now)
        } catch {
            isHealthy = false
            messages.append("Expired remote runtime receipts could not be removed locally.")
        }
        let shouldRunMaintenance: Bool
        if case .publisher = role {
            shouldRunMaintenance = relayStateStore.shouldRunMaintenance(now: now)
        } else {
            shouldRunMaintenance = false
        }

        guard !retainedSessions.isEmpty || !pendingReceipts.isEmpty || shouldRunMaintenance,
              relayStateStore.allowsRemoteWork(now: now)
        else {
            return RuntimeReceiptRelaySummary(
                sessionAction: .unchanged,
                uploadedReceiptCount: 0,
                downloadedReceiptCount: 0,
                deletedRemoteReceiptCount: 0,
                isHealthy: isHealthy,
                messages: messages
            )
        }

        if !pendingReceipts.isEmpty {
            performedRemoteWork = true
            let saveResult = await remoteStore.saveReceipts(pendingReceipts, now: now)
            do {
                try relayStateStore.acknowledge(
                    receiptIDs: saveResult.acceptedReceiptIDs,
                    from: pendingReceipts,
                    now: now
                )
            } catch {
                isHealthy = false
                messages.append("The runtime receipt relay state could not be saved.")
            }
            uploadedReceiptCount = saveResult.acceptedReceiptIDs.count
            if !saveResult.outcome.succeeded {
                try? relayStateStore.recordRemoteFailure(saveResult.outcome, now: now)
                if let errorMessage = saveResult.outcome.errorMessage {
                    messages.append(errorMessage)
                }
                return RuntimeReceiptRelaySummary(
                    sessionAction: .unchanged,
                    uploadedReceiptCount: uploadedReceiptCount,
                    downloadedReceiptCount: 0,
                    deletedRemoteReceiptCount: 0,
                    isHealthy: false,
                    messages: messages
                )
            }
        }

        if case .publisher = role,
           relayStateStore.shouldDownloadReceipts(now: now) {
            let activeSessionID = sessionStore.activeSession(now: now)?.id
            let downloadSessions = relayStateStore.receiptDownloadSessions(
                from: retainedSessions,
                activeSessionID: activeSessionID,
                now: now
            )
            performedRemoteWork = !downloadSessions.isEmpty || performedRemoteWork
            for session in downloadSessions {
                let loadResult = await remoteStore.loadReceipts(
                    sessionID: session.id,
                    now: now
                )
                if !loadResult.envelopes.isEmpty {
                    do {
                        try inboxStore?.save(loadResult.envelopes, now: now)
                        downloadedReceiptCount += loadResult.envelopes.count
                    } catch {
                        isHealthy = false
                        messages.append("Remote runtime receipts could not be saved locally.")
                        break
                    }
                }
                if !loadResult.outcome.succeeded {
                    isHealthy = false
                    try? relayStateStore.recordRemoteFailure(loadResult.outcome, now: now)
                    if let errorMessage = loadResult.outcome.errorMessage {
                        messages.append(errorMessage)
                    }
                    break
                }
            }
            if isHealthy {
                do {
                    try relayStateStore.recordReceiptDownload(
                        hasActiveSession: activeSessionID != nil,
                        lastSessionID: downloadSessions.last?.id,
                        now: now
                    )
                } catch {
                    isHealthy = false
                    messages.append("The runtime receipt relay state could not be saved.")
                }
            }
        }

        if case .publisher = role,
           isHealthy,
           shouldRunMaintenance {
            performedRemoteWork = true
            let pruneResult = await remoteStore.pruneExpiredReceipts(now: now)
            deletedRemoteReceiptCount = pruneResult.deletedReceiptCount
            if !pruneResult.outcome.succeeded {
                isHealthy = false
                try? relayStateStore.recordRemoteFailure(pruneResult.outcome, now: now)
                if let errorMessage = pruneResult.outcome.errorMessage {
                    messages.append(errorMessage)
                }
            } else {
                do {
                    try relayStateStore.recordMaintenance(
                        deletedReceiptCount: deletedRemoteReceiptCount,
                        now: now
                    )
                } catch {
                    isHealthy = false
                    messages.append("The runtime receipt relay state could not be saved.")
                }
            }
        }

        if isHealthy, performedRemoteWork {
            do {
                try relayStateStore.recordRemoteSuccess(now: now)
            } catch {
                isHealthy = false
                messages.append("The runtime receipt relay state could not be saved.")
            }
        }

        return RuntimeReceiptRelaySummary(
            sessionAction: .unchanged,
            uploadedReceiptCount: uploadedReceiptCount,
            downloadedReceiptCount: downloadedReceiptCount,
            deletedRemoteReceiptCount: deletedRemoteReceiptCount,
            isHealthy: isHealthy,
            messages: messages
        )
    }

    public func synchronize(now: Date = Date()) async -> RuntimeReceiptRelaySummary {
        let sessionResult = await synchronizeSession(now: now)
        let receiptResult = await relayReceipts(now: now)
        var messages = receiptResult.messages
        if let message = sessionResult.message {
            messages.append(message)
        }
        return RuntimeReceiptRelaySummary(
            sessionAction: sessionResult.action,
            uploadedReceiptCount: receiptResult.uploadedReceiptCount,
            downloadedReceiptCount: receiptResult.downloadedReceiptCount,
            deletedRemoteReceiptCount: receiptResult.deletedRemoteReceiptCount,
            isHealthy: sessionResult.isHealthy && receiptResult.isHealthy,
            messages: messages
        )
    }
}

private struct RuntimeReceiptRelayAcknowledgement: Codable, Equatable, Sendable {
    let receiptID: String
    let retentionExpiresAt: Date
}

private struct RuntimeReceiptRelaySessionAcknowledgement: Codable, Equatable, Sendable {
    let sessionID: UUID
    let retentionExpiresAt: Date
}

private struct RuntimeReceiptRelayState: Codable, Equatable, Sendable {
    static let schemaVersion = 4

    let schemaVersion: Int
    var acknowledgements: [RuntimeReceiptRelayAcknowledgement]
    var clearedSessions: [RuntimeReceiptRelaySessionAcknowledgement]
    var publishedSessionID: UUID?
    var nextSessionRefreshAt: Date?
    var nextReceiptDownloadAt: Date?
    var nextMaintenanceAt: Date?
    var retryNotBefore: Date?
    var consecutiveFailureCount: Int
    var receiptDownloadSessionCursor: UUID?
    var remoteCleanupUntil: Date?

    init() {
        schemaVersion = Self.schemaVersion
        acknowledgements = []
        clearedSessions = []
        publishedSessionID = nil
        nextSessionRefreshAt = nil
        nextReceiptDownloadAt = nil
        nextMaintenanceAt = nil
        retryNotBefore = nil
        consecutiveFailureCount = 0
        receiptDownloadSessionCursor = nil
        remoteCleanupUntil = nil
    }

    mutating func normalize(now: Date) {
        var acknowledgementsByID: [String: RuntimeReceiptRelayAcknowledgement] = [:]
        for acknowledgement in acknowledgements where
            RuntimeSurfaceFingerprints.isSHA256(acknowledgement.receiptID)
                && now < acknowledgement.retentionExpiresAt {
            acknowledgementsByID[acknowledgement.receiptID] = acknowledgement
        }
        acknowledgements = Array(acknowledgementsByID.values)
            .sorted {
                if $0.retentionExpiresAt != $1.retentionExpiresAt {
                    return $0.retentionExpiresAt < $1.retentionExpiresAt
                }
                return $0.receiptID < $1.receiptID
            }
            .suffix(RuntimeReceiptRelayStateStore.maximumAcknowledgementCount)
            .map { $0 }

        var clearedByID: [UUID: RuntimeReceiptRelaySessionAcknowledgement] = [:]
        for acknowledgement in clearedSessions where now < acknowledgement.retentionExpiresAt {
            clearedByID[acknowledgement.sessionID] = acknowledgement
        }
        clearedSessions = clearedByID.values.sorted {
            if $0.retentionExpiresAt != $1.retentionExpiresAt {
                return $0.retentionExpiresAt < $1.retentionExpiresAt
            }
            return $0.sessionID.uuidString < $1.sessionID.uuidString
        }
    }
}

private enum RuntimeReceiptJSON {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
