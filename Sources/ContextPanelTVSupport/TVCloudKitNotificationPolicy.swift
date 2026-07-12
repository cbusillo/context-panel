import Foundation

public struct TVCloudKitNotificationMetadata: Equatable, Sendable {
    public let subscriptionID: String?
    public let containerIdentifier: String?
    public let subscriptionOwnerRecordName: String?

    public init(
        subscriptionID: String?,
        containerIdentifier: String?,
        subscriptionOwnerRecordName: String?
    ) {
        self.subscriptionID = subscriptionID
        self.containerIdentifier = containerIdentifier
        self.subscriptionOwnerRecordName = subscriptionOwnerRecordName
    }
}

public enum TVCloudKitNotificationPolicy {
    public static func accepts(
        _ metadata: TVCloudKitNotificationMetadata,
        expectedSubscriptionID: String,
        expectedContainerIdentifier: String,
        currentUserRecordName: String?
    ) -> Bool {
        guard metadata.subscriptionID == expectedSubscriptionID else { return false }
        if let containerIdentifier = metadata.containerIdentifier,
           containerIdentifier != expectedContainerIdentifier {
            return false
        }
        if let subscriptionOwnerRecordName = metadata.subscriptionOwnerRecordName {
            return subscriptionOwnerRecordName == currentUserRecordName
        }
        return true
    }
}
