import Foundation

public struct TVRetiredProviderBadgeCleanup: Sendable {
    public static let expiryRequestIdentifier = "context-panel-provider-badge-expiry"
    public static let badgesPreferenceKey = "tv-provider-badges-enabled"

    public let providerAlertStateURL: URL

    public init(providerAlertStateURL: URL) {
        self.providerAlertStateURL = providerAlertStateURL
    }

    @discardableResult
    public func perform(
        defaults: UserDefaults,
        fileManager: FileManager = .default,
        removePendingNotificationRequests: ([String]) -> Void
    ) -> Int {
        defaults.removeObject(forKey: Self.badgesPreferenceKey)
        removePendingNotificationRequests([Self.expiryRequestIdentifier])
        try? fileManager.removeItem(at: providerAlertStateURL)
        return 0
    }
}
