import Foundation

/// Identifies the installed executable, independently of synced usage data.
public struct InstalledAppVersion: Equatable, Sendable {
    public let marketingVersion: String?
    public let buildNumber: String?

    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public init(infoDictionary: [String: Any]) {
        marketingVersion = Self.value(infoDictionary["CFBundleShortVersionString"])
        buildNumber = Self.value(infoDictionary["CFBundleVersion"])
    }

    public var displayText: String {
        "Version \(marketingVersion ?? "Unknown") · Build \(buildNumber ?? "Unknown")"
    }

    private static func value(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
