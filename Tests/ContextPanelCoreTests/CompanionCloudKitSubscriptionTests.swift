import CloudKit
@testable import ContextPanelCloudKitSync
import ContextPanelCore
import Testing

@Test func companionCloudKitSubscriptionUsesPromotedProductionQuery() throws {
    let subscription = CompanionCloudKitSubscriptionFactory.make()

    #expect(subscription.subscriptionID == CompanionRemoteSync.cloudKitSubscriptionID)
    #expect(subscription.subscriptionID == "companion-sync-updates-v3")
    #expect(CompanionRemoteSync.cloudKitRecordName == "current-v2")
    #expect(CompanionRemoteSync.cloudKitLegacyRecordNames == ["current"])
    #expect(CompanionRemoteSync.cloudKitRetiredSubscriptionIDs == [
        "companion-sync-updates",
        "companion-sync-updates-v2",
    ])
    #expect(subscription.recordType == CompanionRemoteSync.cloudKitRecordType)
    let comparison = try #require(subscription.predicate as? NSComparisonPredicate)
    #expect(comparison.leftExpression.keyPath == "recordID")
    #expect(comparison.predicateOperatorType == .equalTo)
    let recordID = try #require(comparison.rightExpression.constantValue as? CKRecord.ID)
    #expect(recordID.recordName == CompanionRemoteSync.cloudKitRecordName)
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
    #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
}

@Test func companionCloudKitNotificationPolicyRejectsRetiredAndPresentationUpdates() {
    #expect(CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitRetiredSubscriptionIDs[0],
        recordName: CompanionRemoteSync.cloudKitRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitPresentationRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitLegacyRecordNames[0]
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

    #expect(await recorder.events == [
        "fetch",
        "delete:companion-sync-updates",
        "delete:companion-sync-updates-v2",
    ])
}

@Test func companionCloudKitSubscriptionRegistrarCreatesMissingSubscription() async throws {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(recorder: recorder, currentSubscriptionExists: false)

    try await registrar.register()

    #expect(await recorder.events == [
        "fetch",
        "save",
        "delete:companion-sync-updates",
        "delete:companion-sync-updates-v2",
    ])
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
        deleteError: .failed
    )

    try await registrar.register()

    #expect(await recorder.events == [
        "fetch",
        "delete:companion-sync-updates",
        "delete:companion-sync-updates-v2",
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
        ]
    )
    record[CompanionRemoteSync.payloadFieldName] = try CompanionSyncPayloadCodec.encode(remoteDocument) as CKRecordValue
    let incomingDocument = cloudKitDocument(
        generatedAt: incomingDate,
        accounts: [("OpenAI A", "openai-a", 30)]
    )

    let pendingSave = try CompanionCloudKitRecordBuilder(recordID: recordID).makeRecord(
        incomingDocument: incomingDocument,
        existingRecord: record
    )
    let mergedDocument = try CompanionSyncPayloadCodec.decode(pendingSave.payload)

    #expect(pendingSave.record === record)
    #expect(mergedDocument.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(mergedDocument.snapshot.limits.first { $0.accountName == "OpenAI A" }?.used == 30)
    #expect(mergedDocument.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
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

    let merged = CompanionCloudKitDocumentSet.merged([current, legacy])

    #expect(merged?.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(merged?.snapshot.limits.first { $0.accountName == "OpenAI A" }?.used == 30)
    #expect(merged?.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
}

private enum CompanionCloudKitSubscriptionTestError: Error {
    case failed
}

private func cloudKitDocument(
    generatedAt: Date,
    accounts: [(name: String, id: String, used: Int)]
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
            errorMessage: nil
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
    deleteError: CompanionCloudKitSubscriptionTestError? = nil
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
        retiredSubscriptionIDs: CompanionRemoteSync.cloudKitRetiredSubscriptionIDs
    )
}
