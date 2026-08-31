import CloudKit
import ContextPanelCore
import Foundation

public enum CompanionCloudKitSyncStoreFactory {
    public static func make(containerIdentifier: String = ContextPanelLocations.iCloudContainerID) -> CompanionRemoteSyncStore {
        make(
            containerIdentifier: containerIdentifier,
            recordName: CompanionRemoteSync.cloudKitRecordName,
            legacyRecordNames: CompanionRemoteSync.cloudKitLegacyRecordNames,
            storeRole: CompanionRemoteSync.cloudKitStoreRole
        )
    }

    public static func makePresentationPreferences(
        containerIdentifier: String = ContextPanelLocations.iCloudContainerID
    ) -> CompanionPresentationRemoteStore {
        let client = CompanionCloudKitClient(
            containerIdentifier: containerIdentifier,
            recordName: CompanionRemoteSync.cloudKitPresentationRecordName,
            legacyRecordNames: [],
            storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole
        )
        return CompanionPresentationRemoteStore(
            storeRole: CompanionRemoteSync.cloudKitPresentationStoreRole,
            saveDocument: { document in await client.savePresentation(document) },
            loadDocument: { await client.loadPresentation() },
            resolveUserScope: { await client.currentUserScope() }
        )
    }

    private static func make(
        containerIdentifier: String,
        recordName: String,
        legacyRecordNames: [String],
        storeRole: String
    ) -> CompanionRemoteSyncStore {
        let client = CompanionCloudKitClient(
            containerIdentifier: containerIdentifier,
            recordName: recordName,
            legacyRecordNames: legacyRecordNames,
            storeRole: storeRole
        )
        return CompanionRemoteSyncStore(
            storeRole: storeRole,
            saveDocument: { document in await client.save(document, now: Date()) },
            loadDocument: { now in await client.load(now: now) },
            registerForUpdates: { await client.registerSubscription() },
            resolveUserScopeResolution: { await client.currentUserScopeResolution() }
        )
    }
}

enum CompanionCloudKitSubscriptionFactory {
    static func make() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: CompanionRemoteSync.cloudKitRecordType,
            predicate: NSPredicate(
                format: "recordID == %@",
                CKRecord.ID(recordName: CompanionRemoteSync.cloudKitSubscriptionRecordName)
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

enum CompanionCloudKitRecordConflict {
    static func isRetryable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain,
              let code = CKError.Code(rawValue: nsError.code)
        else { return false }
        return code == .serverRecordChanged || code == .constraintViolation
    }

    static func serverRecord(from error: Error) -> CKRecord? {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain,
              nsError.code == CKError.Code.serverRecordChanged.rawValue
        else { return nil }
        return nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
    }
}

struct CompanionCloudKitRecordBuilder {
    let recordID: CKRecord.ID

    func makeRecord(
        incomingDocument: CompanionSyncDocument,
        existingRecord: CKRecord?,
        now: Date,
        userScope: CompanionCloudKitUserScope
    ) throws -> (record: CKRecord, payload: Data, document: CompanionSyncDocument) {
        let existingDocument = try existingRecord
            .map(decodeDocument(from:))
            .map { try scopedDocument($0, userScope: userScope) }
        let document = try scopedDocument(
            incomingDocument,
            userScope: userScope
        ).mergingForRemotePublish(
            existing: existingDocument,
            now: now
        )
        let payload = try CompanionSyncPayloadCodec.encode(document)
        let record = existingRecord ?? CKRecord(
            recordType: CompanionRemoteSync.cloudKitRecordType,
            recordID: recordID
        )
        record[CompanionRemoteSync.payloadFieldName] = payload as CKRecordValue
        record[CompanionRemoteSync.schemaVersionFieldName] = 1 as CKRecordValue
        record[CompanionRemoteSync.documentSchemaVersionFieldName] = document.schemaVersion as CKRecordValue
        record[CompanionRemoteSync.snapshotSchemaVersionFieldName] = document.snapshot.schemaVersion as CKRecordValue
        record[CompanionRemoteSync.generatedAtFieldName] = document.snapshot.generatedAt as CKRecordValue
        record[CompanionRemoteSync.publishedAtFieldName] = document.snapshot.publishedAt as CKRecordValue
        record[CompanionRemoteSync.payloadByteCountFieldName] = payload.count as CKRecordValue
        return (record, payload, document)
    }

    private func decodeDocument(from record: CKRecord) throws -> CompanionSyncDocument {
        guard let payload = record[CompanionRemoteSync.payloadFieldName] as? Data else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync record is missing payload data.")
        }
        return try CompanionSyncPayloadCodec.decode(payload)
    }

    private func scopedDocument(
        _ document: CompanionSyncDocument,
        userScope: CompanionCloudKitUserScope
    ) throws -> CompanionSyncDocument {
        if let existingScope = document.cloudKitUserScope,
           existingScope != userScope {
            throw SnapshotStoreError.corruptStore(
                "CloudKit companion sync document belongs to another user scope."
            )
        }
        return document.bound(to: userScope)
    }
}

enum CompanionCloudKitDocumentSet {
    static func merged(
        _ documents: [CompanionSyncDocument],
        now: Date
    ) -> CompanionSyncDocument? {
        guard let first = documents.first else { return nil }
        var document = first.mergingForRemotePublish(existing: nil, now: now)
        for incoming in documents.dropFirst() {
            document = incoming.mergingForRemotePublish(existing: document, now: now)
        }
        return document
    }
}

private actor CompanionCloudKitClient {
    private static let maximumSaveAttempts = 3

    private let container: CKContainer
    private let recordName: String
    private let legacyRecordNames: [String]
    private let storeRole: String

    init(
        containerIdentifier: String,
        recordName: String,
        legacyRecordNames: [String],
        storeRole: String
    ) {
        container = CKContainer(identifier: containerIdentifier)
        self.recordName = recordName
        self.legacyRecordNames = legacyRecordNames
        self.storeRole = storeRole
    }

    func currentUserScopeResolution() async -> CompanionRemoteUserScopeResolution {
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            return .transientFailure
        }
        switch accountStatus {
        case .available:
            do {
                let recordID = try await container.userRecordID()
                return .resolved(CompanionCloudKitUserScope.derive(
                    containerIdentifier: container.containerIdentifier ?? ContextPanelLocations.iCloudContainerID,
                    userRecordName: recordID.recordName
                ))
            } catch {
                return .transientFailure
            }
        case .noAccount:
            return .unavailable
        case .couldNotDetermine, .restricted, .temporarilyUnavailable:
            return .transientFailure
        @unknown default:
            return .transientFailure
        }
    }

    func currentUserScope() async -> CompanionCloudKitUserScope? {
        await currentUserScopeResolution().userScope
    }

    func save(
        _ document: CompanionSyncDocument,
        now: Date
    ) async -> CompanionRemoteSyncOutcome {
        guard let userScope = await currentUserScope() else {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: false,
                succeeded: false,
                errorMessage: "CloudKit account identity is unavailable."
            )
        }
        let authoritativeSave: (record: CKRecord, payload: Data, document: CompanionSyncDocument)
        do {
            let incomingDocument = try scopedDocument(document, userScope: userScope)
            let legacyDocuments = try await loadDocuments(
                recordNames: legacyRecordNames,
                userScope: userScope
            )
            guard let migrationDocument = CompanionCloudKitDocumentSet.merged(
                legacyDocuments + [incomingDocument],
                now: now
            ) else {
                throw SnapshotStoreError.corruptStore("CloudKit companion sync migration produced no document.")
            }
            authoritativeSave = try await saveMergedRecord(
                migrationDocument,
                recordName: recordName,
                now: now,
                userScope: userScope
            )
            try verifyPublishedRecord(authoritativeSave.record, expectedPayload: authoritativeSave.payload)
            try await verifyCurrentUserScope(userScope)
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "authoritative publish", error: error),
                cloudKitUserScope: userScope
            )
        }

        do {
            for legacyRecordName in legacyRecordNames {
                let wakeSave = try await saveMergedRecord(
                    authoritativeSave.document,
                    recordName: legacyRecordName,
                    now: now,
                    userScope: userScope
                )
                try verifyPublishedRecord(wakeSave.record, expectedPayload: wakeSave.payload)
            }
            try await verifyCurrentUserScope(userScope)
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "wake mirror publish", error: error),
                cloudKitUserScope: userScope
            )
        }

        return CompanionRemoteSyncOutcome(
            storeRole: storeRole,
            succeeded: true,
            cloudKitUserScope: userScope
        )
    }

    func load(now: Date) async -> CompanionRemoteSyncLoadResult {
        guard let userScope = await currentUserScope() else {
            return CompanionRemoteSyncLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .unknown,
                    errorMessage: "CloudKit account identity is unavailable."
                ),
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    isAvailable: false,
                    succeeded: false,
                    errorMessage: "CloudKit account identity is unavailable."
                )
            )
        }
        do {
            let documents = try await loadDocuments(
                recordNames: [recordName] + legacyRecordNames,
                userScope: userScope
            )
            try await verifyCurrentUserScope(userScope)
            guard let document = CompanionCloudKitDocumentSet.merged(documents, now: now) else {
                return CompanionRemoteSyncLoadResult(
                    result: CompanionSyncLoadResult(document: nil, status: .unknown),
                    outcome: CompanionRemoteSyncOutcome(
                        storeRole: storeRole,
                        succeeded: true,
                        missingRecord: true,
                        cloudKitUserScope: userScope
                    )
                )
            }
            let status = document.companionStatus(
                now: now,
                stalenessPolicy: SnapshotStoreStalenessPolicy(
                    maximumAge: SnapshotFreshness.companionProviderMaximumAge
                )
            )
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
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    succeeded: true,
                    cloudKitUserScope: userScope
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
                    errorMessage: diagnosticMessage(operation: "load", error: error),
                    cloudKitUserScope: userScope
                )
            )
        }
    }

    func savePresentation(_ document: CompanionPresentationDocument) async -> CompanionRemoteSyncOutcome {
        guard let userScope = await currentUserScope() else {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: false,
                succeeded: false,
                errorMessage: "CloudKit account identity is unavailable."
            )
        }
        let payload: Data

        do {
            let scopedDocument = try scopedPresentationDocument(document, userScope: userScope)
            payload = try CompanionPresentationPayloadCodec.encode(scopedDocument)
            let record = makePresentationRecord(document: scopedDocument, payload: payload)
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
            try await verifyCurrentUserScope(userScope)
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "presentation publish", error: error),
                cloudKitUserScope: userScope
            )
        }

        return CompanionRemoteSyncOutcome(
            storeRole: storeRole,
            succeeded: true,
            cloudKitUserScope: userScope
        )
    }

    func loadPresentation() async -> CompanionPresentationRemoteLoadResult {
        guard let userScope = await currentUserScope() else {
            return CompanionPresentationRemoteLoadResult(
                document: nil,
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    isAvailable: false,
                    succeeded: false,
                    errorMessage: "CloudKit account identity is unavailable."
                )
            )
        }
        do {
            let record = try await privateDatabase.record(for: recordID)
            let document = try scopedPresentationDocument(
                decodePresentationDocument(from: record),
                userScope: userScope
            )
            try await verifyCurrentUserScope(userScope)
            return CompanionPresentationRemoteLoadResult(
                document: document,
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    succeeded: true,
                    cloudKitUserScope: userScope
                )
            )
        } catch let error as CKError where error.code == .unknownItem {
            return CompanionPresentationRemoteLoadResult(
                document: nil,
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    succeeded: true,
                    missingRecord: true,
                    cloudKitUserScope: userScope
                )
            )
        } catch {
            return CompanionPresentationRemoteLoadResult(
                document: nil,
                outcome: CompanionRemoteSyncOutcome(
                    storeRole: storeRole,
                    isAvailable: isCloudKitAvailable(error),
                    succeeded: false,
                    errorMessage: diagnosticMessage(operation: "presentation load", error: error),
                    cloudKitUserScope: userScope
                )
            )
        }
    }

    func registerSubscription() async -> CompanionRemoteSyncOutcome {
        guard let userScope = await currentUserScope() else {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: false,
                succeeded: false,
                errorMessage: "CloudKit account identity is unavailable."
            )
        }
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
            try await verifyCurrentUserScope(userScope)
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                succeeded: true,
                cloudKitUserScope: userScope
            )
        } catch {
            return CompanionRemoteSyncOutcome(
                storeRole: storeRole,
                isAvailable: isCloudKitAvailable(error),
                succeeded: false,
                errorMessage: diagnosticMessage(operation: "subscribe", error: error),
                cloudKitUserScope: userScope
            )
        }
    }

    private var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName)
    }

    private func saveMergedRecord(
        _ incomingDocument: CompanionSyncDocument,
        recordName targetRecordName: String,
        now: Date,
        userScope: CompanionCloudKitUserScope
    ) async throws -> (record: CKRecord, payload: Data, document: CompanionSyncDocument) {
        let targetRecordID = CKRecord.ID(recordName: targetRecordName)
        var currentRecord = try await loadRecord(recordName: targetRecordName)
        let recordBuilder = CompanionCloudKitRecordBuilder(recordID: targetRecordID)

        for attempt in 0..<Self.maximumSaveAttempts {
            let pendingSave = try recordBuilder.makeRecord(
                incomingDocument: incomingDocument,
                existingRecord: currentRecord,
                now: now,
                userScope: userScope
            )

            do {
                let savedRecord = try await saveRecord(
                    pendingSave.record,
                    recordID: targetRecordID
                )
                return (savedRecord, pendingSave.payload, pendingSave.document)
            } catch {
                guard attempt + 1 < Self.maximumSaveAttempts,
                      CompanionCloudKitRecordConflict.isRetryable(error)
                else { throw error }

                if let serverRecord = CompanionCloudKitRecordConflict.serverRecord(from: error) {
                    currentRecord = serverRecord
                } else {
                    guard let reloadedRecord = try await loadRecord(recordName: targetRecordName) else { throw error }
                    currentRecord = reloadedRecord
                }
            }
        }

        throw SnapshotStoreError.corruptStore("CloudKit companion sync publish exhausted conflict retries.")
    }

    private func loadDocuments(
        recordNames: [String],
        userScope: CompanionCloudKitUserScope
    ) async throws -> [CompanionSyncDocument] {
        var documents: [CompanionSyncDocument] = []
        for recordName in recordNames {
            guard let record = try await loadRecord(recordName: recordName) else { continue }
            documents.append(try scopedDocument(
                decodeDocument(from: record),
                userScope: userScope
            ))
        }
        return documents
    }

    private func loadRecord(recordName: String) async throws -> CKRecord? {
        do {
            return try await privateDatabase.record(for: CKRecord.ID(recordName: recordName))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func saveRecord(_ record: CKRecord, recordID: CKRecord.ID) async throws -> CKRecord {
        let saveResult = try await privateDatabase.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let savedRecordResult = saveResult.saveResults[recordID] else {
            throw SnapshotStoreError.corruptStore("CloudKit companion sync publish did not return the saved record.")
        }
        return try savedRecordResult.get()
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

    private func scopedDocument(
        _ document: CompanionSyncDocument,
        userScope: CompanionCloudKitUserScope
    ) throws -> CompanionSyncDocument {
        if let existingScope = document.cloudKitUserScope,
           existingScope != userScope {
            throw SnapshotStoreError.corruptStore(
                "CloudKit companion sync document belongs to another user scope."
            )
        }
        return document.bound(to: userScope)
    }

    private func scopedPresentationDocument(
        _ document: CompanionPresentationDocument,
        userScope: CompanionCloudKitUserScope
    ) throws -> CompanionPresentationDocument {
        if let existingScope = document.cloudKitUserScope,
           existingScope != userScope {
            throw SnapshotStoreError.corruptStore(
                "CloudKit companion presentation document belongs to another user scope."
            )
        }
        return document.bound(to: userScope)
    }

    private func verifyCurrentUserScope(
        _ expectedScope: CompanionCloudKitUserScope
    ) async throws {
        guard await currentUserScope() == expectedScope else {
            throw SnapshotStoreError.corruptStore(
                "CloudKit account changed during companion synchronization."
            )
        }
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
