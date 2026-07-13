import CloudKit
@testable import ContextPanelCloudKitSync
import ContextPanelCore
import Testing

@Test func companionCloudKitSubscriptionUsesProductionSafeRecordTypeQuery() throws {
    let subscription = CompanionCloudKitSubscriptionFactory.make()

    #expect(subscription.subscriptionID == CompanionRemoteSync.cloudKitSubscriptionID)
    #expect(subscription.subscriptionID != CompanionRemoteSync.cloudKitLegacySubscriptionID)
    #expect(subscription.recordType == CompanionRemoteSync.cloudKitRecordType)
    let comparison = try #require(subscription.predicate as? NSComparisonPredicate)
    #expect(comparison.leftExpression.keyPath == CompanionRemoteSync.snapshotSchemaVersionFieldName)
    #expect(comparison.predicateOperatorType == .greaterThan)
    let minimumVersion = try #require(comparison.rightExpression.constantValue as? NSNumber)
    #expect(minimumVersion.intValue == 0)
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
    #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
}

@Test func companionCloudKitNotificationPolicyRejectsLegacyAndPresentationUpdates() {
    #expect(CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
        recordName: CompanionRemoteSync.cloudKitRecordName
    ))
    #expect(!CompanionCloudKitNotificationPolicy.accepts(
        subscriptionID: CompanionRemoteSync.cloudKitLegacySubscriptionID,
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
