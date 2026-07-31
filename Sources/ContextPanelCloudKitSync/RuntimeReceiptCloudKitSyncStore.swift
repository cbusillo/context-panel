import CloudKit
import ContextPanelCore
import Foundation

public enum RuntimeReceiptCloudKitStoreFactory {
    public static func make(
        containerIdentifier: String = ContextPanelLocations.iCloudContainerID
    ) -> RuntimeReceiptRemoteStore {
        let client = RuntimeReceiptCloudKitClient(containerIdentifier: containerIdentifier)
        return RuntimeReceiptRemoteStore(
            publishCurrentSession: { mutation in
                await client.publishSession(mutation, now: Date())
            },
            loadCurrentSession: { now in await client.loadSession(now: now) },
            saveReceiptBatch: { receipts, now in await client.saveReceipts(receipts, now: now) },
            loadReceiptBatch: { sessionID, now in
                await client.loadReceipts(sessionID: sessionID, now: now)
            },
            pruneExpiredReceiptBatch: { now in await client.pruneExpiredReceipts(now: now) }
        )
    }
}

enum RuntimeValidationSessionCloudKitState: String, Equatable, Sendable {
    case active
    case cleared
}

struct RuntimeValidationSessionCloudKitDocument: Equatable, Sendable {
    let session: RuntimeValidationSession
    let state: RuntimeValidationSessionCloudKitState
    let publishedAt: Date
    let stateUpdatedAt: Date

    func canBeSuperseded(by session: RuntimeValidationSession) -> Bool {
        session.createdAt > self.session.createdAt
    }
}

struct RuntimeValidationSessionCloudKitRecordBuilder {
    let recordID = CKRecord.ID(recordName: RuntimeReceiptRemoteSync.cloudKitSessionRecordName)

    func makeRecord(
        session: RuntimeValidationSession,
        state: RuntimeValidationSessionCloudKitState = .active,
        publishedAt: Date,
        stateUpdatedAt: Date? = nil,
        existingRecord: CKRecord? = nil
    ) throws -> (record: CKRecord, payload: Data) {
        let stateUpdatedAt = stateUpdatedAt ?? publishedAt
        guard session.isStructurallyValid(
            now: stateUpdatedAt,
            requiresActive: state == .active
        ),
        session.isRetained(now: stateUpdatedAt),
        publishedAt >= session.createdAt.addingTimeInterval(
            -RuntimeValidationSession.maximumClockSkew
        ),
        publishedAt <= stateUpdatedAt.addingTimeInterval(
            RuntimeValidationSession.maximumClockSkew
        ) else {
            throw RuntimeReceiptRemoteSyncError.invalidSession
        }
        let payload = try RuntimeValidationSessionPayloadCodec.encode(session)
        let record = existingRecord ?? CKRecord(
            recordType: RuntimeReceiptRemoteSync.cloudKitSessionRecordType,
            recordID: recordID
        )
        guard record.recordType == RuntimeReceiptRemoteSync.cloudKitSessionRecordType,
              record.recordID == recordID
        else {
            throw RuntimeReceiptRemoteSyncError.invalidSession
        }
        record[RuntimeReceiptRemoteSync.payloadFieldName] = payload as CKRecordValue
        record[RuntimeReceiptRemoteSync.schemaVersionFieldName] = 1 as CKRecordValue
        record[RuntimeReceiptRemoteSync.sessionSchemaVersionFieldName] = session.schemaVersion as CKRecordValue
        record[RuntimeReceiptRemoteSync.sessionIDFieldName] = session.id.uuidString.lowercased() as CKRecordValue
        record[RuntimeReceiptRemoteSync.createdAtFieldName] = session.createdAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.expiresAtFieldName] = session.expiresAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.retentionExpiresAtFieldName]
            = session.receiptRetentionExpiresAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.expectedManifestIDFieldName] = session.expectedManifestID as CKRecordValue
        record[RuntimeReceiptRemoteSync.publishedAtFieldName] = publishedAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.sessionStateFieldName] = state.rawValue as CKRecordValue
        record[RuntimeReceiptRemoteSync.stateUpdatedAtFieldName] = stateUpdatedAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.payloadByteCountFieldName] = payload.count as CKRecordValue
        return (record, payload)
    }

    func decodeDocument(
        from record: CKRecord,
        now: Date
    ) throws -> RuntimeValidationSessionCloudKitDocument {
        guard record.recordType == RuntimeReceiptRemoteSync.cloudKitSessionRecordType,
              record.recordID == recordID,
              let payload = record[RuntimeReceiptRemoteSync.payloadFieldName] as? Data,
              record[RuntimeReceiptRemoteSync.schemaVersionFieldName] as? Int64 == 1,
              let stateRawValue = record[RuntimeReceiptRemoteSync.sessionStateFieldName] as? String,
              let state = RuntimeValidationSessionCloudKitState(rawValue: stateRawValue),
              let publishedAt = record[RuntimeReceiptRemoteSync.publishedAtFieldName] as? Date,
              let stateUpdatedAt = record[RuntimeReceiptRemoteSync.stateUpdatedAtFieldName] as? Date,
              record[RuntimeReceiptRemoteSync.payloadByteCountFieldName] as? Int64
                == Int64(payload.count)
        else {
            throw RuntimeReceiptRemoteSyncError.invalidSession
        }
        let session = try RuntimeValidationSessionPayloadCodec.decode(
            payload,
            now: now,
            requiresActive: false
        )
        guard record[RuntimeReceiptRemoteSync.sessionSchemaVersionFieldName] as? Int64
                == Int64(session.schemaVersion),
              record[RuntimeReceiptRemoteSync.sessionIDFieldName] as? String
                == session.id.uuidString.lowercased(),
              record[RuntimeReceiptRemoteSync.createdAtFieldName] as? Date == session.createdAt,
              record[RuntimeReceiptRemoteSync.expiresAtFieldName] as? Date == session.expiresAt,
              record[RuntimeReceiptRemoteSync.retentionExpiresAtFieldName] as? Date
                == session.receiptRetentionExpiresAt,
              record[RuntimeReceiptRemoteSync.expectedManifestIDFieldName] as? String
                == session.expectedManifestID,
              publishedAt >= session.createdAt.addingTimeInterval(
                  -RuntimeValidationSession.maximumClockSkew
              ),
              publishedAt <= stateUpdatedAt.addingTimeInterval(
                  RuntimeValidationSession.maximumClockSkew
              ),
              stateUpdatedAt <= now.addingTimeInterval(
                  RuntimeValidationSession.maximumClockSkew
              )
        else {
            throw RuntimeReceiptRemoteSyncError.invalidSession
        }
        return RuntimeValidationSessionCloudKitDocument(
            session: session,
            state: state,
            publishedAt: publishedAt,
            stateUpdatedAt: stateUpdatedAt
        )
    }
}

struct RuntimeReceiptCloudKitRecordBuilder {
    func recordID(for receipt: RuntimeReceipt) -> CKRecord.ID {
        CKRecord.ID(recordName: "runtime-receipt-\(receipt.id)")
    }

    func makeRecord(_ receipt: RuntimeReceipt) throws -> (record: CKRecord, payload: Data) {
        guard receipt.isStructurallyValid else {
            throw RuntimeReceiptRemoteSyncError.invalidReceipt
        }
        let payload = try RuntimeReceiptPayloadCodec.encode(receipt)
        let record = CKRecord(
            recordType: RuntimeReceiptRemoteSync.cloudKitReceiptRecordType,
            recordID: recordID(for: receipt)
        )
        record[RuntimeReceiptRemoteSync.payloadFieldName] = payload as CKRecordValue
        record[RuntimeReceiptRemoteSync.schemaVersionFieldName] = 1 as CKRecordValue
        record[RuntimeReceiptRemoteSync.receiptSchemaVersionFieldName] = receipt.schemaVersion as CKRecordValue
        record[RuntimeReceiptRemoteSync.sessionIDFieldName] = receipt.sessionID.uuidString.lowercased() as CKRecordValue
        record[RuntimeReceiptRemoteSync.receiptIDFieldName] = receipt.id as CKRecordValue
        record[RuntimeReceiptRemoteSync.surfaceFieldName] = receipt.buildIdentity.surface.rawValue as CKRecordValue
        record[RuntimeReceiptRemoteSync.observedAtFieldName] = receipt.observedAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.retentionExpiresAtFieldName] = receipt.retentionExpiresAt as CKRecordValue
        record[RuntimeReceiptRemoteSync.processInstanceIDFieldName] = receipt.processInstanceID.uuidString.lowercased() as CKRecordValue
        record[RuntimeReceiptRemoteSync.processSequenceFieldName] = Int64(receipt.processSequence) as CKRecordValue
        record[RuntimeReceiptRemoteSync.payloadByteCountFieldName] = payload.count as CKRecordValue
        return (record, payload)
    }

    func decodeReceipt(from record: CKRecord) throws -> RuntimeReceipt {
        guard record.recordType == RuntimeReceiptRemoteSync.cloudKitReceiptRecordType,
              let payload = record[RuntimeReceiptRemoteSync.payloadFieldName] as? Data,
              record[RuntimeReceiptRemoteSync.schemaVersionFieldName] as? Int64 == 1,
              record[RuntimeReceiptRemoteSync.payloadByteCountFieldName] as? Int64
                == Int64(payload.count)
        else {
            throw RuntimeReceiptRemoteSyncError.invalidReceipt
        }
        let receipt = try RuntimeReceiptPayloadCodec.decode(payload)
        guard record.recordID == recordID(for: receipt),
              record[RuntimeReceiptRemoteSync.receiptSchemaVersionFieldName] as? Int64
                == Int64(receipt.schemaVersion),
              record[RuntimeReceiptRemoteSync.sessionIDFieldName] as? String
                == receipt.sessionID.uuidString.lowercased(),
              record[RuntimeReceiptRemoteSync.receiptIDFieldName] as? String == receipt.id,
              record[RuntimeReceiptRemoteSync.surfaceFieldName] as? String
                == receipt.buildIdentity.surface.rawValue,
              record[RuntimeReceiptRemoteSync.observedAtFieldName] as? Date == receipt.observedAt,
              record[RuntimeReceiptRemoteSync.retentionExpiresAtFieldName] as? Date
                == receipt.retentionExpiresAt,
              record[RuntimeReceiptRemoteSync.processInstanceIDFieldName] as? String
                == receipt.processInstanceID.uuidString.lowercased(),
              record[RuntimeReceiptRemoteSync.processSequenceFieldName] as? Int64
                == Int64(receipt.processSequence)
        else {
            throw RuntimeReceiptRemoteSyncError.invalidReceipt
        }
        return receipt
    }
}

private actor RuntimeReceiptCloudKitClient {
    private let container: CKContainer
    private let sessionBuilder = RuntimeValidationSessionCloudKitRecordBuilder()
    private let receiptBuilder = RuntimeReceiptCloudKitRecordBuilder()

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func publishSession(
        _ mutation: RuntimeValidationSessionRemoteMutation,
        now: Date
    ) async -> RuntimeReceiptRemoteOutcome {
        do {
            switch mutation {
            case let .clear(session):
                try await saveClearedSession(session, now: now)
            case let .publish(session):
                try await saveActiveSession(session, now: now)
            }
            return RuntimeReceiptRemoteOutcome(succeeded: true)
        } catch {
            return failureOutcome(operation: "session publish", error: error)
        }
    }

    func loadSession(now: Date) async -> RuntimeValidationSessionRemoteLoadResult {
        do {
            guard let record = try await loadRecord(sessionBuilder.recordID) else {
                return RuntimeValidationSessionRemoteLoadResult(
                    session: nil,
                    missingRecord: true,
                    state: .missing,
                    outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
                )
            }
            let document = try sessionBuilder.decodeDocument(from: record, now: now)
            guard document.state == .active,
                  document.session.isStructurallyValid(now: now, requiresActive: true)
            else {
                return RuntimeValidationSessionRemoteLoadResult(
                    session: nil,
                    missingRecord: true,
                    state: .cleared,
                    stateUpdatedAt: document.stateUpdatedAt,
                    outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
                )
            }
            return RuntimeValidationSessionRemoteLoadResult(
                session: document.session,
                state: .active,
                stateUpdatedAt: document.stateUpdatedAt,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        } catch {
            return RuntimeValidationSessionRemoteLoadResult(
                session: nil,
                outcome: failureOutcome(operation: "session load", error: error)
            )
        }
    }

    func saveReceipts(
        _ receipts: [RuntimeReceipt],
        now: Date
    ) async -> RuntimeReceiptRemoteSaveResult {
        do {
            var receiptsByID: [String: RuntimeReceipt] = [:]
            var firstError: Error?
            for receipt in receipts.prefix(RuntimeReceiptRemoteSync.maximumReceiptsPerSync) {
                guard receipt.isStructurallyValid, now < receipt.retentionExpiresAt else {
                    firstError = firstError ?? RuntimeReceiptRemoteSyncError.invalidReceipt
                    continue
                }
                if let existing = receiptsByID[receipt.id], existing != receipt {
                    firstError = firstError ?? RuntimeReceiptRemoteSyncError.conflictingReceipt
                    continue
                }
                receiptsByID[receipt.id] = receipt
            }

            let pending = try receiptsByID.values.map { receipt in
                (receipt, try receiptBuilder.makeRecord(receipt))
            }
            guard !pending.isEmpty else {
                if let firstError {
                    throw firstError
                }
                return RuntimeReceiptRemoteSaveResult(
                    acceptedReceiptIDs: [],
                    outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
                )
            }

            let result = try await privateDatabase.modifyRecords(
                saving: pending.map { $0.1.record },
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            var acceptedReceiptIDs: [String] = []
            var conflicts: [(receipt: RuntimeReceipt, record: CKRecord, payload: Data, error: Error)] = []
            for (receipt, pendingRecord) in pending {
                guard let saveResult = result.saveResults[pendingRecord.record.recordID] else {
                    firstError = firstError ?? RuntimeReceiptRemoteSyncError.invalidReceipt
                    continue
                }
                do {
                    let saved = try saveResult.get()
                    guard try receiptBuilder.decodeReceipt(from: saved) == receipt,
                          saved[RuntimeReceiptRemoteSync.payloadFieldName] as? Data
                            == pendingRecord.payload
                    else {
                        throw RuntimeReceiptRemoteSyncError.invalidReceipt
                    }
                    acceptedReceiptIDs.append(receipt.id)
                } catch {
                    guard CompanionCloudKitRecordConflict.isRetryable(error) else {
                        firstError = firstError ?? error
                        continue
                    }
                    conflicts.append((receipt, pendingRecord.record, pendingRecord.payload, error))
                }
            }

            var conflictRecords: [CKRecord.ID: CKRecord] = [:]
            var recordIDsToFetch: [CKRecord.ID] = []
            for conflict in conflicts {
                if let serverRecord = CompanionCloudKitRecordConflict.serverRecord(
                    from: conflict.error
                ) {
                    conflictRecords[serverRecord.recordID] = serverRecord
                } else {
                    recordIDsToFetch.append(conflict.record.recordID)
                }
            }
            if !recordIDsToFetch.isEmpty {
                let fetched = try await privateDatabase.records(for: recordIDsToFetch)
                for recordID in recordIDsToFetch {
                    guard let result = fetched[recordID] else {
                        firstError = firstError ?? RuntimeReceiptRemoteSyncError.conflictingReceipt
                        continue
                    }
                    do {
                        conflictRecords[recordID] = try result.get()
                    } catch {
                        firstError = firstError ?? error
                    }
                }
            }
            for conflict in conflicts {
                guard let serverRecord = conflictRecords[conflict.record.recordID],
                      try receiptBuilder.decodeReceipt(from: serverRecord) == conflict.receipt,
                      serverRecord[RuntimeReceiptRemoteSync.payloadFieldName] as? Data
                        == conflict.payload
                else {
                    firstError = firstError ?? RuntimeReceiptRemoteSyncError.conflictingReceipt
                    continue
                }
                acceptedReceiptIDs.append(conflict.receipt.id)
            }

            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: acceptedReceiptIDs,
                outcome: firstError.map {
                    failureOutcome(operation: "receipt publish", error: $0)
                } ?? RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        } catch {
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: [],
                outcome: failureOutcome(operation: "receipt publish", error: error)
            )
        }
    }

    func loadReceipts(
        sessionID: UUID,
        now: Date
    ) async -> RuntimeReceiptRemoteLoadResult {
        do {
            let query = CKQuery(
                recordType: RuntimeReceiptRemoteSync.cloudKitReceiptRecordType,
                predicate: NSPredicate(
                    format: "%K == %@",
                    RuntimeReceiptRemoteSync.sessionIDFieldName,
                    sessionID.uuidString.lowercased()
                )
            )
            let records = try await queryRecords(
                query,
                maximumCount: RuntimeReceiptStore.maximumRetainedReceiptCount
            )
            var envelopes: [RuntimeReceiptRemoteEnvelope] = []
            var invalidRecordCount = 0
            for record in records {
                do {
                    let receipt = try receiptBuilder.decodeReceipt(from: record)
                    guard receipt.sessionID == sessionID,
                          now < receipt.retentionExpiresAt,
                          let serverReceivedAt = record.creationDate
                    else {
                        continue
                    }
                    let envelope = RuntimeReceiptRemoteEnvelope(
                        receipt: receipt,
                        serverReceivedAt: serverReceivedAt
                    )
                    guard envelope.isStructurallyValid else {
                        throw RuntimeReceiptRemoteSyncError.invalidEnvelope
                    }
                    envelopes.append(envelope)
                } catch {
                    invalidRecordCount += 1
                }
            }
            return RuntimeReceiptRemoteLoadResult(
                envelopes: envelopes,
                outcome: invalidRecordCount == 0
                    ? RuntimeReceiptRemoteOutcome(succeeded: true)
                    : RuntimeReceiptRemoteOutcome(
                        succeeded: false,
                        errorMessage: "CloudKit runtime receipt load ignored \(invalidRecordCount) invalid record(s)."
                    )
            )
        } catch {
            return RuntimeReceiptRemoteLoadResult(
                envelopes: [],
                outcome: failureOutcome(operation: "receipt load", error: error)
            )
        }
    }

    func pruneExpiredReceipts(now: Date) async -> RuntimeReceiptRemotePruneResult {
        do {
            let query = CKQuery(
                recordType: RuntimeReceiptRemoteSync.cloudKitReceiptRecordType,
                predicate: NSPredicate(
                    format: "%K <= %@",
                    RuntimeReceiptRemoteSync.retentionExpiresAtFieldName,
                    now as NSDate
                )
            )
            let records = try await queryRecords(
                query,
                maximumCount: RuntimeReceiptRemoteSync.maximumReceiptsPerSync,
                allowsTruncatedResults: true
            )
            guard !records.isEmpty else {
                return RuntimeReceiptRemotePruneResult(
                    deletedReceiptCount: 0,
                    outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
                )
            }
            let result = try await privateDatabase.modifyRecords(
                saving: [],
                deleting: records.map(\.recordID),
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            var deletedReceiptCount = 0
            var firstError: Error?
            for record in records {
                guard let deleteResult = result.deleteResults[record.recordID] else {
                    firstError = firstError ?? RuntimeReceiptRemoteSyncError.invalidReceipt
                    continue
                }
                do {
                    _ = try deleteResult.get()
                    deletedReceiptCount += 1
                } catch let error as CKError where error.code == .unknownItem {
                    deletedReceiptCount += 1
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                return RuntimeReceiptRemotePruneResult(
                    deletedReceiptCount: deletedReceiptCount,
                    outcome: failureOutcome(operation: "receipt retention cleanup", error: firstError)
                )
            }
            return RuntimeReceiptRemotePruneResult(
                deletedReceiptCount: deletedReceiptCount,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        } catch {
            return RuntimeReceiptRemotePruneResult(
                deletedReceiptCount: 0,
                outcome: failureOutcome(operation: "receipt retention cleanup", error: error)
            )
        }
    }

    private var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    private func saveActiveSession(
        _ session: RuntimeValidationSession,
        now: Date
    ) async throws {
        var existingRecord = try await loadRecord(sessionBuilder.recordID)
        for _ in 0..<3 {
            let existingDocument = try existingRecord.map {
                try sessionBuilder.decodeDocument(from: $0, now: now)
            }
            if let existingDocument {
                if existingDocument.session.id == session.id {
                    guard existingDocument.session == session else {
                        throw RuntimeReceiptRemoteSyncError.conflictingSession
                    }
                    guard existingDocument.state == .active else {
                        throw RuntimeReceiptRemoteSyncError.conflictingSession
                    }
                    return
                }
                guard existingDocument.canBeSuperseded(by: session) else {
                    throw RuntimeReceiptRemoteSyncError.conflictingSession
                }
                if existingDocument.state == .active,
                   existingDocument.session.isStructurallyValid(
                       now: now,
                       requiresActive: true
                   ) {
                    throw RuntimeReceiptRemoteSyncError.conflictingSession
                }
            }

            let stateUpdatedAt = nextSessionStateUpdatedAt(
                now: now,
                existingDocument: existingDocument
            )
            let pending = try sessionBuilder.makeRecord(
                session: session,
                state: .active,
                publishedAt: now,
                stateUpdatedAt: stateUpdatedAt,
                existingRecord: existingRecord
            )
            do {
                let saved = try await saveRecord(
                    pending.record,
                    savePolicy: .ifServerRecordUnchanged
                )
                let savedDocument = try sessionBuilder.decodeDocument(from: saved, now: now)
                guard savedDocument.session == session,
                      savedDocument.state == .active,
                      saved[RuntimeReceiptRemoteSync.payloadFieldName] as? Data == pending.payload
                else {
                    throw RuntimeReceiptRemoteSyncError.invalidSession
                }
                return
            } catch {
                guard CompanionCloudKitRecordConflict.isRetryable(error) else { throw error }
                if let conflictRecord = CompanionCloudKitRecordConflict.serverRecord(from: error) {
                    existingRecord = conflictRecord
                } else {
                    existingRecord = try await loadRecord(sessionBuilder.recordID)
                }
            }
        }
        throw RuntimeReceiptRemoteSyncError.conflictingSession
    }

    private func saveClearedSession(
        _ session: RuntimeValidationSession,
        now: Date
    ) async throws {
        var existingRecord = try await loadRecord(sessionBuilder.recordID)
        for _ in 0..<3 {
            let existingDocument = try existingRecord.map {
                try sessionBuilder.decodeDocument(from: $0, now: now)
            }
            if let existingDocument {
                guard existingDocument.session.id == session.id else { return }
                guard existingDocument.session == session else {
                    throw RuntimeReceiptRemoteSyncError.conflictingSession
                }
                if existingDocument.state == .cleared {
                    return
                }
            }

            let stateUpdatedAt = nextSessionStateUpdatedAt(
                now: now,
                existingDocument: existingDocument
            )
            let pending = try sessionBuilder.makeRecord(
                session: session,
                state: .cleared,
                publishedAt: existingDocument?.publishedAt ?? now,
                stateUpdatedAt: stateUpdatedAt,
                existingRecord: existingRecord
            )
            do {
                let saved = try await saveRecord(
                    pending.record,
                    savePolicy: .ifServerRecordUnchanged
                )
                let savedDocument = try sessionBuilder.decodeDocument(from: saved, now: now)
                guard savedDocument.session == session,
                      savedDocument.state == .cleared,
                      saved[RuntimeReceiptRemoteSync.payloadFieldName] as? Data == pending.payload
                else {
                    throw RuntimeReceiptRemoteSyncError.invalidSession
                }
                return
            } catch {
                guard CompanionCloudKitRecordConflict.isRetryable(error) else { throw error }
                if let conflictRecord = CompanionCloudKitRecordConflict.serverRecord(from: error) {
                    existingRecord = conflictRecord
                } else {
                    existingRecord = try await loadRecord(sessionBuilder.recordID)
                }
            }
        }
        throw RuntimeReceiptRemoteSyncError.conflictingSession
    }

    private func nextSessionStateUpdatedAt(
        now: Date,
        existingDocument: RuntimeValidationSessionCloudKitDocument?
    ) -> Date {
        guard let existingDocument else { return now }
        return max(now, existingDocument.stateUpdatedAt.addingTimeInterval(0.001))
    }

    private func loadRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await privateDatabase.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func saveRecord(
        _ record: CKRecord,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> CKRecord {
        let result = try await privateDatabase.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: savePolicy,
            atomically: true
        )
        guard let saveResult = result.saveResults[record.recordID] else {
            throw RuntimeReceiptRemoteSyncError.invalidReceipt
        }
        return try saveResult.get()
    }

    private func queryRecords(
        _ query: CKQuery,
        maximumCount: Int,
        allowsTruncatedResults: Bool = false
    ) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var page = try await privateDatabase.records(
            matching: query,
            desiredKeys: nil,
            resultsLimit: min(maximumCount, 100)
        )
        try append(page.matchResults, to: &records, maximumCount: maximumCount)

        while let cursor = page.queryCursor, records.count < maximumCount {
            page = try await privateDatabase.records(
                continuingMatchFrom: cursor,
                desiredKeys: nil,
                resultsLimit: min(maximumCount - records.count, 100)
            )
            try append(page.matchResults, to: &records, maximumCount: maximumCount)
        }
        if page.queryCursor != nil, !allowsTruncatedResults {
            throw CKError(.limitExceeded)
        }
        return records
    }

    private func append(
        _ results: [(CKRecord.ID, Result<CKRecord, Error>)],
        to records: inout [CKRecord],
        maximumCount: Int
    ) throws {
        for (_, result) in results {
            guard records.count < maximumCount else { return }
            records.append(try result.get())
        }
    }

    private func failureOutcome(operation: String, error: Error) -> RuntimeReceiptRemoteOutcome {
        let nsError = error as NSError
        var detail = "\(ConnectorRedactor.redact(nsError.domain)) \(nsError.code)"
        var retryAfterSeconds: TimeInterval?
        if let cloudKitError = error as? CKError {
            detail += " code \(cloudKitCodeName(cloudKitError.code))"
            if let retryAfter = nsError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
                detail += " retryAfter \(Int(retryAfter.rounded()))s"
                retryAfterSeconds = retryAfter
            }
        }
        return RuntimeReceiptRemoteOutcome(
            isAvailable: isCloudKitAvailable(error),
            succeeded: false,
            errorMessage: "CloudKit runtime receipt \(operation) failed (\(detail)).",
            retryAfterSeconds: retryAfterSeconds
        )
    }

    private func cloudKitCodeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .resultsTruncated: "resultsTruncated"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .tooManyParticipants: "tooManyParticipants"
        case .alreadyShared: "alreadyShared"
        case .participantAlreadyInvited: "participantAlreadyInvited"
        case .referenceViolation: "referenceViolation"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .participantMayNeedVerification: "participantMayNeedVerification"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        @unknown default: String(describing: code)
        }
    }

    private func isCloudKitAvailable(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return true }
        return switch error.code {
        case .notAuthenticated, .permissionFailure, .badContainer, .badDatabase,
             .zoneNotFound, .missingEntitlement:
            false
        default:
            true
        }
    }
}
