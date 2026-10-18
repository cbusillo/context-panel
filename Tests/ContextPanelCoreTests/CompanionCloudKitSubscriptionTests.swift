import CloudKit
@testable import ContextPanelCloudKitSync
import ContextPanelCore
import Testing

@Test func companionCloudKitSubscriptionUsesPromotedProductionWakeQuery() throws {
    let subscription = CompanionCloudKitSubscriptionFactory.make()

    #expect(subscription.subscriptionID == CompanionRemoteSync.cloudKitSubscriptionID)
    #expect(CompanionRemoteSync.cloudKitLegacyRecordNames.contains(CompanionRemoteSync.cloudKitSubscriptionRecordName))
    #expect(subscription.recordType == CompanionRemoteSync.cloudKitRecordType)
    let comparison = try #require(subscription.predicate as? NSComparisonPredicate)
    #expect(comparison.leftExpression.keyPath == "recordID")
    #expect(comparison.predicateOperatorType == .equalTo)
    let recordID = try #require(comparison.rightExpression.constantValue as? CKRecord.ID)
    #expect(recordID.recordName == CompanionRemoteSync.cloudKitSubscriptionRecordName)
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
    #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
}

@Test func companionCloudKitNotificationPolicyRejectsOtherGenerationAndPresentationUpdates() {
    #expect(CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitSubscriptionRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: "companion-sync-updates-v3",
        recordName: CompanionRemoteSync.cloudKitSubscriptionRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitPresentationRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: nil,
        recordName: nil
    ))
}

@Test func companionCloudKitSubscriptionRegistrarReusesCurrentSubscription() async throws {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(recorder: recorder, currentSubscriptionExists: true)

    try await registrar.register()

    #expect(await recorder.events == ["fetch"])
}

@Test func companionCloudKitSubscriptionRegistrarCreatesMissingSubscription() async throws {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(recorder: recorder, currentSubscriptionExists: false)

    try await registrar.register()

    #expect(await recorder.events == ["fetch", "save"])
}

@Test func companionCloudKitSubscriptionRegistrarStopsAfterFetchFailure() async {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(recorder: recorder, fetchError: .failed)

    await #expect(throws: CompanionCloudKitSubscriptionTestError.failed) {
        try await registrar.register()
    }
    #expect(await recorder.events == ["fetch"])
}

@Test func companionCloudKitSubscriptionRegistrarStopsAfterSaveFailure() async {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(
        recorder: recorder,
        currentSubscriptionExists: false,
        saveError: .failed
    )

    await #expect(throws: CompanionCloudKitSubscriptionTestError.failed) {
        try await registrar.register()
    }
    #expect(await recorder.events == ["fetch", "save"])
}

@Test func companionCloudKitSubscriptionRegistrarIgnoresRetiredDeletionFailure() async throws {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(
        recorder: recorder,
        currentSubscriptionExists: true,
        deleteError: .failed,
        retiredSubscriptionIDs: ["legacy-subscription"]
    )

    try await registrar.register()

    #expect(await recorder.events == [
        "fetch",
        "delete:legacy-subscription",
    ])
}

@Test func companionCloudKitRecordConflictExtractsServerRecordForRetry() {
    let record = CKRecord(
        recordType: CompanionRemoteSync.cloudKitRecordType,
        recordID: CKRecord.ID(recordName: CompanionRemoteSync.cloudKitRecordName)
    )
    let error = NSError(
        domain: CKError.errorDomain,
        code: CKError.Code.serverRecordChanged.rawValue,
        userInfo: [CKRecordChangedErrorServerRecordKey: record]
    )

    #expect(CompanionCloudKitRecordConflict.isRetryable(error))
    #expect(CompanionCloudKitRecordConflict.serverRecord(from: error) === record)
}

@Test func companionCloudKitRecordConflictRetriesConcurrentCreate() {
    let error = NSError(
        domain: CKError.errorDomain,
        code: CKError.Code.constraintViolation.rawValue
    )

    #expect(CompanionCloudKitRecordConflict.isRetryable(error))
    #expect(CompanionCloudKitRecordConflict.serverRecord(from: error) == nil)
}

@Test func companionCloudKitRecordConflictRejectsUnrelatedErrors() {
    let error = NSError(
        domain: CKError.errorDomain,
        code: CKError.Code.networkFailure.rawValue
    )

    #expect(!CompanionCloudKitRecordConflict.isRetryable(error))
    #expect(CompanionCloudKitRecordConflict.serverRecord(from: error) == nil)
}

@Test func companionCloudKitRecordBuilderMergesExistingAccountLanes() throws {
    let remoteDate = Date(timeIntervalSince1970: 70_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let recordID = CKRecord.ID(recordName: CompanionRemoteSync.cloudKitRecordName)
    let record = CKRecord(recordType: CompanionRemoteSync.cloudKitRecordType, recordID: recordID)
    let remoteDocument = cloudKitDocument(
        generatedAt: remoteDate,
        accounts: [
            ("OpenAI A", "openai-a", 20),
            ("OpenAI B", "openai-b", 40),
        ],
        verifiedAccountIDs: ["openai-b"]
    )
    record[CompanionRemoteSync.payloadFieldName] = try CompanionSyncPayloadCodec.encode(remoteDocument) as CKRecordValue
    let incomingDocument = cloudKitDocument(
        generatedAt: incomingDate,
        accounts: [("OpenAI A", "openai-a", 30)]
    )

    let pendingSave = try CompanionCloudKitRecordBuilder(recordID: recordID).makeRecord(
        incomingDocument: incomingDocument,
        existingRecord: record,
        now: incomingDate,
        userScope: cloudKitUserScope
    )
    try expectCloudKitRecordFitsProductionSchema(pendingSave.record)
    let mergedDocument = try CompanionSyncPayloadCodec.decode(pendingSave.payload)

    #expect(pendingSave.record === record)
    #expect(pendingSave.document == mergedDocument)
    #expect(Set(mergedDocument.snapshot.limits.map(\.accountName)) == ["OpenAI A", "OpenAI B"])
    #expect(mergedDocument.snapshot.limits.first { $0.accountName == "OpenAI A" }?.used == 30)
    #expect(mergedDocument.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
}

@Test func companionCloudKitRecordBuilderDropsUnverifiedAccountsTheNewPublishNoLongerReports() throws {
    let remoteDate = Date(timeIntervalSince1970: 72_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let recordID = CKRecord.ID(recordName: CompanionRemoteSync.cloudKitRecordName)
    let record = CKRecord(recordType: CompanionRemoteSync.cloudKitRecordType, recordID: recordID)
    let remoteDocument = cloudKitDocument(
        generatedAt: remoteDate,
        accounts: [
            ("OpenAI A", "openai-a", 20),
            ("Codex Lab", "openai-lab", 10),
            ("OpenAI B", "openai-b", 40),
        ],
        verifiedAccountIDs: ["openai-b"]
    )
    record[CompanionRemoteSync.payloadFieldName] = try CompanionSyncPayloadCodec.encode(remoteDocument) as CKRecordValue
    let incomingDocument = cloudKitDocument(
        generatedAt: incomingDate,
        accounts: [("OpenAI A", "openai-a", 30)]
    )

    let pendingSave = try CompanionCloudKitRecordBuilder(recordID: recordID).makeRecord(
        incomingDocument: incomingDocument,
        existingRecord: record,
        now: incomingDate,
        userScope: cloudKitUserScope
    )

    #expect(Set(pendingSave.document.snapshot.limits.map(\.accountName)) == ["OpenAI A", "OpenAI B"])
    #expect(Set(pendingSave.document.snapshot.providerStatuses.map(\.accountName)) == ["OpenAI A", "OpenAI B"])
}

@Test func companionCloudKitRecordBuilderCreatesLegacyWakeMirror() throws {
    let generatedAt = Date(timeIntervalSince1970: 75_000)
    let recordID = CKRecord.ID(recordName: CompanionRemoteSync.cloudKitSubscriptionRecordName)
    let document = cloudKitDocument(
        generatedAt: generatedAt,
        accounts: [("OpenAI A", "openai-a", 25)]
    )

    let pendingSave = try CompanionCloudKitRecordBuilder(recordID: recordID).makeRecord(
        incomingDocument: document,
        existingRecord: nil,
        now: generatedAt,
        userScope: cloudKitUserScope
    )
    let mirroredDocument = try CompanionSyncPayloadCodec.decode(pendingSave.payload)

    #expect(pendingSave.record.recordID.recordName == CompanionRemoteSync.cloudKitSubscriptionRecordName)
    #expect(pendingSave.document == mirroredDocument)
    #expect(mirroredDocument.snapshot.limits.map(\.accountName) == ["OpenAI A"])
}

@Test func companionCloudKitDocumentSetMergesLegacyAndCurrentRecords() {
    let currentDate = Date(timeIntervalSince1970: 80_000)
    let legacyDate = currentDate.addingTimeInterval(60)
    let current = cloudKitDocument(
        generatedAt: currentDate,
        accounts: [
            ("OpenAI A", "openai-a", 20),
            ("OpenAI B", "openai-b", 40),
        ]
    )
    let legacy = cloudKitDocument(
        generatedAt: legacyDate,
        accounts: [("OpenAI A", "openai-a", 30)]
    )

    let merged = CompanionCloudKitDocumentSet.merged([current, legacy], now: legacyDate)

    #expect(merged?.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(merged?.snapshot.limits.first { $0.accountName == "OpenAI A" }?.used == 30)
    #expect(merged?.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
}

@Test func companionCloudKitRecordPathsCompactExpiredAccountsWithoutMirrorResurrection() throws {
    let observedAt = Date(timeIntervalSince1970: 90_000)
    let now = observedAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let recordID = CKRecord.ID(recordName: CompanionRemoteSync.cloudKitRecordName)
    let record = CKRecord(recordType: CompanionRemoteSync.cloudKitRecordType, recordID: recordID)
    let managedDocument = cloudKitDocument(
        generatedAt: observedAt,
        accounts: [("OpenAI B", "openai-b", 40)]
    ).mergingForRemotePublish(existing: nil, now: observedAt)
    record[CompanionRemoteSync.payloadFieldName] = try CompanionSyncPayloadCodec.encode(managedDocument) as CKRecordValue
    let incomingDocument = cloudKitDocument(generatedAt: now, accounts: [])

    let pendingSave = try CompanionCloudKitRecordBuilder(recordID: recordID).makeRecord(
        incomingDocument: incomingDocument,
        existingRecord: record,
        now: now,
        userScope: cloudKitUserScope
    )
    let mergedMirrors = CompanionCloudKitDocumentSet.merged(
        [managedDocument, managedDocument],
        now: now
    )

    #expect(pendingSave.document.snapshot.limits.isEmpty)
    #expect(pendingSave.document.snapshot.providerStatuses.isEmpty)
    #expect(pendingSave.document.accountRetentionStates == nil)
    #expect(mergedMirrors?.snapshot.limits.isEmpty == true)
    #expect(mergedMirrors?.snapshot.providerStatuses.isEmpty == true)
    #expect(mergedMirrors?.accountRetentionStates == nil)
}

private enum CompanionCloudKitSubscriptionTestError: Error {
    case failed
}

private let cloudKitUserScope = CompanionCloudKitUserScope.derive(
    containerIdentifier: ContextPanelLocations.iCloudContainerID,
    userRecordName: "test-user"
)

private let cloudKitIdentityKey = ProviderAccountIdentityKey(keyID: UUID(), secret: Data(repeating: 23, count: 32))!

private func cloudKitDocument(
    generatedAt: Date,
    accounts: [(name: String, id: String, used: Int)],
    verifiedAccountIDs: Set<String> = []
) -> CompanionSyncDocument {
    let limits = accounts.map { account in
        UsageLimit(
            provider: .openAI,
            accountID: account.id,
            configuredAccountID: "openai-code-default",
            accountName: account.name,
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: account.used,
            limit: 100,
            lastUpdatedAt: generatedAt
        )
    }
    let reports = accounts.map { account in
        StoredProviderReport(
            provider: .openAI,
            accountID: account.id,
            configuredAccountID: "openai-code-default",
            accountName: account.name,
            generatedAt: generatedAt,
            status: .healthy,
            errorMessage: nil,
            sharedAccountIdentity: verifiedAccountIDs.contains(account.id)
                ? ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID, identifier: account.id)
                    .map { cloudKitIdentityKey.identity(for: $0).bound(toLocalAccountID: account.id) } : nil
        )
    }
    return CompanionSyncDocument(
        storedSnapshot: StoredUsageSnapshot(
            savedAt: generatedAt,
            snapshot: UsageSnapshot(generatedAt: generatedAt, limits: limits),
            reports: reports
        ),
        publishedAt: generatedAt
    )
}

private actor CompanionCloudKitSubscriptionRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private func makeRegistrar(
    recorder: CompanionCloudKitSubscriptionRecorder,
    currentSubscriptionExists: Bool = true,
    fetchError: CompanionCloudKitSubscriptionTestError? = nil,
    saveError: CompanionCloudKitSubscriptionTestError? = nil,
    deleteError: CompanionCloudKitSubscriptionTestError? = nil,
    retiredSubscriptionIDs: [String] = []
) -> CompanionCloudKitSubscriptionRegistrar {
    CompanionCloudKitSubscriptionRegistrar(
        currentSubscriptionExists: {
            await recorder.record("fetch")
            if let fetchError { throw fetchError }
            return currentSubscriptionExists
        },
        saveCurrentSubscription: {
            await recorder.record("save")
            if let saveError { throw saveError }
        },
        deleteSubscription: { subscriptionID in
            await recorder.record("delete:\(subscriptionID)")
            if let deleteError { throw deleteError }
        },
        retiredSubscriptionIDs: retiredSubscriptionIDs
    )
}

// Compare constructed records with the schema consumed by the Production schema gate.
// Adding a field to both sources remains an intended change; undeployed fields,
// unwritten contract fields and mismatched value types fail.
func expectCloudKitRecordFitsProductionSchema(_ record: CKRecord, identityDigest: String? = nil) throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let data = try Data(contentsOf: root.appending(path: "CloudKit/companion-sync.schema.json"))
    let schema = try JSONDecoder().decode(RecordSchemaContract.self, from: data)
    #expect(schema.containerIdentifier == ContextPanelLocations.iCloudContainerID)
    let declaration = try #require(schema.recordTypes.first { $0.name == record.recordType })
    let encryptedFields = Set(declaration.fields.filter { $0.type == "ENCRYPTED_BYTES" }.map(\.name))
    let plainFields = Set(declaration.fields.map(\.name)).subtracting(encryptedFields)
    #expect(Set(record.allKeys()).subtracting(encryptedFields) == plainFields,
            "Record fields differ from the contract for \(record.recordType)")
    #expect(Set(record.encryptedValues.allKeys()) == encryptedFields,
            "Encrypted fields differ from the contract for \(record.recordType)")
    for field in declaration.fields {
        if field.type == "ENCRYPTED_BYTES" {
            #expect(record.encryptedValues[field.name] is Data, "\(record.recordType).\(field.name) must be encrypted bytes")
        } else {
            #expect(cloudKitValue(record[field.name], hasContractType: field.type),
                    "\(record.recordType).\(field.name) does not hold \(field.type)")
        }
    }
    if let expectedName = declaration.recordName {
        #expect(record.recordID.recordName == expectedName)
    } else if let pattern = declaration.recordNamePattern {
        let digest = try #require(identityDigest)
        #expect(record.recordID.recordName == pattern.replacingOccurrences(of: "<sha256>", with: digest))
    }
}

private func cloudKitValue(_ value: (any CKRecordValueProtocol)?, hasContractType type: String) -> Bool {
    switch type {
    case "BYTES": value is Data
    case "STRING": value is String
    case "TIMESTAMP": value is Date
    case "INT64": (value as? NSNumber).map { !CFNumberIsFloatType($0) } ?? false
    default: false
    }
}

private struct RecordSchemaContract: Decodable {
    let containerIdentifier: String
    let recordTypes: [RecordType]

    struct RecordType: Decodable {
        let name: String
        let recordName: String?
        let recordNamePattern: String?
        let fields: [Field]
    }

    struct Field: Decodable {
        let name: String
        let type: String
    }
}
