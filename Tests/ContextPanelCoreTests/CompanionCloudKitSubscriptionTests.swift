import CloudKit
@testable import ContextPanelCloudKitSync
import ContextPanelCore
import Testing

@Test func companionCloudKitSubscriptionUsesProductionSafeRecordTypeQuery() {
    let subscription = CompanionCloudKitSubscriptionFactory.make()

    #expect(subscription.subscriptionID == CompanionRemoteSync.cloudKitSubscriptionID)
    #expect(subscription.recordType == CompanionRemoteSync.cloudKitRecordType)
    #expect(subscription.predicate.predicateFormat == "TRUEPREDICATE")
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
    #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
}
