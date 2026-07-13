import ContextPanelCore

public enum CompanionCloudKitNotificationPolicy {
    public static func accepts(subscriptionID: String?, recordName: String?) -> Bool {
        subscriptionID == CompanionRemoteSync.cloudKitSubscriptionID
            && recordName == CompanionRemoteSync.cloudKitRecordName
    }
}
