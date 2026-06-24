import CloudKit
import ContextPanelCore
import Foundation

public enum CompanionCloudKitSyncStoreFactory {
    public static func make(containerIdentifier: String = ContextPanelLocations.iCloudContainerID) -> CompanionRemoteSyncStore {
        let client = CompanionCloudKitClient(containerIdentifier: containerIdentifier)
        return CompanionRemoteSyncStore(
            saveDocument: { document in await client.save(document) },
            loadDocument: { now in await client.load(now: now) },
            registerForUpdates: { await client.registerSubscription() }
        )
    }
}

private actor CompanionCloudKitClient {
    private let containerIdentifier: String

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
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
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "publish", error: error)
            )
        }

        do {
            let record = try await privateDatabase.record(for: recordID)
            try verifyReadableRecord(record, expectedDocument: document, expectedPayload: payload)
            return CompanionRemoteSyncOutcome(succeeded: true)
        } catch {
            return CompanionRemoteSyncOutcome(
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "verify publish", error: error)
            )
        }
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
                outcome: CompanionRemoteSyncOutcome(succeeded: true)
            )
        } catch let error as CKError where error.code == .unknownItem {
            return CompanionRemoteSyncLoadResult(
                result: CompanionSyncLoadResult(document: nil, status: .unknown),
                outcome: CompanionRemoteSyncOutcome(
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
                    isAvailable: isCloudKitAvailable(error),
                    succeeded: false,
                    errorMessage: diagnosticMessage(operation: "load", error: error)
                )
            )
        }
    }

    func registerSubscription() async -> CompanionRemoteSyncOutcome {
        do {
            let subscription = CKQuerySubscription(
                recordType: CompanionRemoteSync.cloudKitRecordType,
                predicate: NSPredicate(format: "TRUEPREDICATE"),
                subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
                options: [.firesOnRecordCreation, .firesOnRecordUpdate]
            )
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await privateDatabase.save(subscription)
            return CompanionRemoteSyncOutcome(succeeded: true)
        } catch {
            return CompanionRemoteSyncOutcome(
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
        CKRecord.ID(recordName: CompanionRemoteSync.cloudKitRecordName)
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

    private func decodeDocument(from record: CKRecord) throws -> CompanionSyncDocument {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync record is missing payload data.")
        }
        return try CompanionSyncPayloadCodec.decode(payload)
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

    private func verifyReadableRecord(
        _ record: CKRecord,
        expectedDocument: CompanionSyncDocument,
        expectedPayload: Data
    ) throws {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync record is missing payload data.")
        }
        guard payload != expectedPayload else {
            _ = try CompanionSyncPayloadCodec.decode(payload)
            return
        }

        let document = try CompanionSyncPayloadCodec.decode(payload)
        guard document.snapshot.generatedAt > expectedDocument.snapshot.generatedAt
            || (document.snapshot.generatedAt == expectedDocument.snapshot.generatedAt
                && document.snapshot.publishedAt > expectedDocument.snapshot.publishedAt)
        else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync record is older than the published document.")
        }
    }

    private func diagnosticMessage(operation: String, error: Error) -> String {
        let nsError = error as NSError
        return "CloudKit companion sync \(operation) failed (\(ConnectorRedactor.redact(nsError.domain)) \(nsError.code))."
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
