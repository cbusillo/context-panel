import CloudKit
@testable import ContextPanelCloudKitSync
import ContextPanelCore
import Testing

@Test func companionCloudKitSubscriptionUsesPromotedProductionQuery() throws {
    let subscription = CompanionCloudKitSubscriptionFactory.make()

    #expect(subscription.subscriptionID == CompanionRemoteSync.cloudKitSubscriptionID)
    #expect(subscription.subscriptionID == "companion-sync-updates")
    #expect(CompanionRemoteSync.cloudKitRetiredSubscriptionIDs == ["companion-sync-updates-v2"])
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
        subscriptionID: nil,
        recordName: nil
    ))
}

@Test func companionCloudKitSubscriptionRegistrarReusesCurrentSubscription() async throws {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(recorder: recorder, currentSubscriptionExists: true)

    try await registrar.register()

    #expect(await recorder.events == ["fetch", "delete:companion-sync-updates-v2"])
}

@Test func companionCloudKitSubscriptionRegistrarCreatesMissingSubscription() async throws {
    let recorder = CompanionCloudKitSubscriptionRecorder()
    let registrar = makeRegistrar(recorder: recorder, currentSubscriptionExists: false)

    try await registrar.register()

    #expect(await recorder.events == ["fetch", "save", "delete:companion-sync-updates-v2"])
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

    #expect(await recorder.events == ["fetch", "delete:companion-sync-updates-v2"])
}

private enum CompanionCloudKitSubscriptionTestError: Error {
    case failed
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
