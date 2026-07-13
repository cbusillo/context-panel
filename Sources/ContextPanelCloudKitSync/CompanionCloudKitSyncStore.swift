import CloudKit
import ContextPanelCore
import Foundation

public enum CompanionCloudKitSyncStoreFactory {
    public static func make(containerIdentifier: String = ContextPanelLocations.iCloudContainerID) -> CompanionRemoteSyncStore {
        make(
            containerIdentifier: containerIdentifier,
            recordName: CompanionRemoteSync.cloudKitRecordName,
            storeRole: CompanionRemoteSync.cloudKitStoreRole
        )
    }

    public static func makePresentationPreferences(
        containerIdentifier: String = ContextPanelLocations.iCloudContainerID
    ) -> CompanionPresentationRemoteStore {
        let client = CompanionCloudKitClient(
            containerIdentifier: containerIdentifier,
            recordName: CompanionRemoteSync.cloudKitPresentationRecordName,
            storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole
        )
        return CompanionPresentationRemoteStore(
            storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole,
            saveDocument: { document in await client.savePresentation(document) },
            loadDocument: { await client.loadPresentation() }
        )
    }

    private static func make(
        containerIdentifier: String,
        recordName: String,
        storeRole: String
    ) -> CompanionRemoteSyncStore {
        let client = CompanionCloudKitClient(
            containerIdentifier: containerIdentifier,
            recordName: recordName,
            storeRole: storeRole
        )
        return CompanionRemoteSyncStore(
            storeRole: storeRole,
            saveDocument: { document in await client.save(document) },
            loadDocument: { now in await client.load(now: now) },
            registerForUpdates: { await client.registerSubscription() }
        )
    }
}

enum CompanionCloudKitSubscriptionFactory {
    static func make() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: CompanionRemoteSync.cloudKitRecordType,
            predicate: NSPredicate(
                format: "recordID == %@",
                CKRecord.ID(recordName: CompanionRemoteSync.cloudKitRecordName)
            ),
            subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }
}

struct CompanionCloudKitSubscriptionRegistrar {
    let currentSubscriptionExists: () async throws -> Bool
    let saveCurrentSubscription: () async throws -> Void
    let deleteSubscription: (String) async throws -> Void
    let retiredSubscriptionIDs: [String]

    func register() async throws {
        if try await !currentSubscriptionExists() {
            try await saveCurrentSubscription()
        }
        for subscriptionID in retiredSubscriptionIDs {
            try? await deleteSubscription(subscriptionID)
        }
    }
}

private actor CompanionCloudKitClient {
    private let containerIdentifier: String
    private let recordName: String
    private let storeRole: String

    init(containerIdentifier: String, recordName: String, storeRole: String) {
        self.containerIdentifier = containerIdentifier
        self.recordName = recordName
        self.storeRole = storeRole
    }

    func save(_ document: CompanionSyncDocument) async -> CompanionRemoteSyncOutcome {
        let payload: Data

        do {
            payload = try CompanionSyncPayloadCodec.encode(document)
            let record = makeRecord(document: document, payload: payload)
            let saveResult = try await privateDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys
            )

            guard let savedRecordResult = saveResult.saveResults[recordID] else {
                throw SnapshotStoreError.corruptStore("CloudKit companion sync publish did not return the saved record.")
            }
            let savedRecord = try savedRecordResult.get()
            try verifyPublishedRecord(savedRecord, expectedPayload: payload)
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "publish", error: error)
            )
        }

        return CompanionRemoteSyncOutcome(storeRole: storeRole, succeeded: true)
    }

    func load(now: Date) async -> CompanionRemoteSyncLoadResult {
        do {
            let record = try await privateDatabase.record(for: recordID)
            let document = try decodeDocument(from: record)
            let status = now.timeIntervalSince(document.snapshot.generatedAt) > SnapshotFreshness.companionProviderMaximumAge
                ? UsageStatus.stale
                : document.companionStatus
            let result = CompanionSyncLoadResult(
                document: document,
                status: status,
                transportMetadata: CompanionSyncTransportMetadata(
                    source: .cloudKit,
                    receivedAt: now,
                    mirroredAt: nil,
                    deliveryStatus: .healthy
                )
            )
            return CompanionRemoteSyncLoadResult(
                result: result,
                outcome: CompanionRemoteSyncOutcome(storeRole: storeRole, succeeded: true)
            )
        } catch let error as CKError where error.code == .unknownItem {
            return CompanionRemoteSyncLoadResult(
                result: CompanionSyncLoadResult(document: nil, status: .unknown),
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    succeeded: true,
                    missingRecord: true
                )
            )
        } catch {
            return CompanionRemoteSyncLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: diagnosticMessage(operation: "load", error: error)
                ),
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    isAvailable: isCloudKitAvailable(error),
                    succeeded: false,
                    errorMessage: diagnosticMessage(operation: "load", error: error)
                )
            )
        }
    }

    func savePresentation(_ document: CompanionPresentationDocument) async -> CompanionRemoteSyncOutcome {
        let payload: Data

        do {
            payload = try CompanionPresentationPayloadCodec.encode(document)
            let record = makePresentationRecord(document: document, payload: payload)
            let saveResult = try await privateDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys
            )

            guard let savedRecordResult = saveResult.saveResults[recordID] else {
                throw SnapshotStoreError.corruptStore("CloudKit companion presentation publish did not return the saved record.")
            }
            let savedRecord = try savedRecordResult.get()
            try verifyPublishedPresentationRecord(savedRecord, expectedPayload: payload)
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "presentation publish", error: error)
            )
        }

        return CompanionRemoteSyncOutcome(storeRole: storeRole, succeeded: true)
    }

    func loadPresentation() async -> CompanionPresentationRemoteLoadResult {
        do {
            let record = try await privateDatabase.record(for: recordID)
            let document = try decodePresentationDocument(from: record)
            return CompanionPresentationRemoteLoadResult(
                document: document,
                outcome: CompanionRemoteSyncOutcome(storeRole: storeRole, succeeded: true)
            )
        } catch let error as CKError where error.code == .unknownItem {
            return CompanionPresentationRemoteLoadResult(
                document: nil,
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    succeeded: true,
                    missingRecord: true
                )
            )
        } catch {
            return CompanionPresentationRemoteLoadResult(
                document: nil,
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    isAvailable: isCloudKitAvailable(error),
                    succeeded: false,
                    errorMessage: diagnosticMessage(operation: "presentation load", error: error)
                )
            )
        }
    }

    func registerSubscription() async -> CompanionRemoteSyncOutcome {
        do {
            let database = privateDatabase
            let registrar = CompanionCloudKitSubscriptionRegistrar(
                currentSubscriptionExists: {
                    do {
                        _ = try await database.subscription(
                            for: CompanionRemoteSync.cloudKitSubscriptionID
                        )
                        return true
                    } catch let error as CKError where error.code == .unknownItem {
                        return false
                    }
                },
                saveCurrentSubscription: {
                    _ = try await database.save(
                        CompanionCloudKitSubscriptionFactory.make()
                    )
                },
                deleteSubscription: { subscriptionID in
                    _ = try await database.deleteSubscription(withID: subscriptionID)
                },
                retiredSubscriptionIDs: CompanionRemoteSync.cloudKitRetiredSubscriptionIDs
            )
            try await registrar.register()
            return CompanionRemoteSyncOutcome(storeRole: storeRole, succeeded: true)
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "subscribe", error: error)
            )
        }
    }

    private var privateDatabase: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName)
    }

    private func makeRecord(document: CompanionSyncDocument, payload: Data) -> CKRecord {
        let record = CKRecord(recordType: CompanionRemoteSync.cloudKitRecordType, recordID: recordID)
        record[CompanionRemoteSync.payloadFieldName] = payload as CKRecordValue
        record[CompanionRemoteSync.schemaVersionFieldName] = 1 as CKRecordValue
        record[CompanionRemoteSync.documentSchemaVersionFieldName] = document.schemaVersion as CKRecordValue
        record[CompanionRemoteSync.snapshotSchemaVersionFieldName] = document.snapshot.schemaVersion as CKRecordValue
        record[CompanionRemoteSync.generatedAtFieldName] = document.snapshot.generatedAt as CKRecordValue
        record[CompanionRemoteSync.publishedAtFieldName] = document.snapshot.publishedAt as CKRecordValue
        record[CompanionRemoteSync.payloadByteCountFieldName] = payload.count as CKRecordValue
        return record
    }

    private func makePresentationRecord(
        document: CompanionPresentationDocument,
        payload: Data
    ) -> CKRecord {
        let record = CKRecord(recordType: CompanionRemoteSync.cloudKitRecordType, recordID: recordID)
        record[CompanionRemoteSync.payloadFieldName] = payload as CKRecordValue
        record[CompanionRemoteSync.schemaVersionFieldName] = 1 as CKRecordValue
        record[CompanionRemoteSync.documentSchemaVersionFieldName] = document.schemaVersion as CKRecordValue
        record[CompanionRemoteSync.snapshotSchemaVersionFieldName] = 0 as CKRecordValue
        record[CompanionRemoteSync.generatedAtFieldName] = document.updatedAt as CKRecordValue
        record[CompanionRemoteSync.publishedAtFieldName] = document.updatedAt as CKRecordValue
        record[CompanionRemoteSync.payloadByteCountFieldName] = payload.count as CKRecordValue
        return record
    }

    private func decodeDocument(from record: CKRecord) throws -> CompanionSyncDocument {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync record is missing payload data.")
        }
        return try CompanionSyncPayloadCodec.decode(payload)
    }

    private func decodePresentationDocument(from record: CKRecord) throws -> CompanionPresentationDocument {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion presentation record is missing payload data.")
        }
        return try CompanionPresentationPayloadCodec.decode(payload)
    }

    private func verifyPublishedRecord(_ record: CKRecord, expectedPayload: Data) throws {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync record is missing payload data.")
        }
        guard payload == expectedPayload else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync publish returned a different payload.")
        }
        _ = try CompanionSyncPayloadCodec.decode(payload)
    }

    private func verifyPublishedPresentationRecord(_ record: CKRecord, expectedPayload: Data) throws {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion presentation record is missing payload data.")
        }
        guard payload == expectedPayload else {
            throw SnapshotStoreError.corruptStore("CloudKit companion presentation publish returned a different payload.")
        }
        _ = try CompanionPresentationPayloadCodec.decode(payload)
    }

    private func diagnosticMessage(operation: String, error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(ConnectorRedactor.redact(nsError.domain)) \(nsError.code)"]
        if let ckError = error as? CKError {
            parts.append("code \(cloudKitCodeName(ckError.code))")
            parts.append(contentsOf: cloudKitDiagnosticDetails(for: ckError))
        }
        return "CloudKit companion sync \(operation) failed (\(parts.joined(separator: "; ")))."
    }

    private func cloudKitDiagnosticDetails(for error: CKError) -> [String] {
        var details: [String] = []
        let nsError = error as NSError
        if let retryAfter = nsError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            details.append("retryAfter \(Int(retryAfter.rounded()))s")
        }
        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           !partialErrors.isEmpty {
            let summaries = partialErrors.prefix(3).map { key, partialError in
                "\(safeDiagnosticFragment(String(describing: key))): \(errorSummary(partialError))"
            }
            details.append("partialErrors \(summaries.joined(separator: ", "))")
        }
        details.append(contentsOf: cloudKitUserInfoSummaries(from: nsError))
        return details
    }

    private func cloudKitUserInfoSummaries(from error: NSError) -> [String] {
        let ignoredKeys: Set<String> = [
            CKErrorRetryAfterKey,
            CKPartialErrorsByItemIDKey,
            NSUnderlyingErrorKey,
        ]
        let summaries = error.userInfo.compactMap { key, value -> String? in
            let keyString = String(describing: key)
            guard !ignoredKeys.contains(keyString),
                  let summary = diagnosticUserInfoValue(value) else {
                return nil
            }
            return "\(safeDiagnosticKey(keyString)) \(summary)"
        }
        return Array(summaries.sorted().prefix(3))
    }

    private func diagnosticUserInfoValue(_ value: Any) -> String? {
        switch value {
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func safeDiagnosticKey(_ value: String) -> String {
        value.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
        }
    }

    private func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        if let ckError = error as? CKError {
            return "\(ConnectorRedactor.redact(nsError.domain)) \(nsError.code) code \(cloudKitCodeName(ckError.code))"
        }
        return "\(ConnectorRedactor.redact(nsError.domain)) \(nsError.code)"
    }

    private func safeDiagnosticFragment(_ value: String) -> String {
        let redacted = ConnectorRedactor.redact(value.replacingOccurrences(of: "\n", with: " "))
        if redacted.count <= 180 {
            return redacted
        }
        return String(redacted.prefix(177)) + "..."
    }

    private func cloudKitCodeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .resultsTruncated: return "resultsTruncated"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .participantAlreadyInvited: return "participantAlreadyInvited"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        @unknown default: return String(describing: code)
        }
    }

    private func isCloudKitAvailable(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return true }
        switch error.code {
        case .notAuthenticated, .permissionFailure, .badContainer, .badDatabase, .zoneNotFound:
            return false
        default:
            return true
        }
    }
}
