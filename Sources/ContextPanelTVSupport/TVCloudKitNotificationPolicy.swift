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
        guard metadata.containerIdentifier == expectedContainerIdentifier else { return false }
        guard let currentUserRecordName else { return false }
        guard let subscriptionOwnerRecordName = metadata.subscriptionOwnerRecordName else {
            return true
        }
        return subscriptionOwnerRecordName == currentUserRecordName
    }
}
