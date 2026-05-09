import Foundation

public struct ResetPrimerAccountPreference: Codable, Equatable, Identifiable, Sendable {
    public let accountID: String
    public var provider: Provider
    public var accountName: String
    public var isEnabled: Bool

    public var id: String { accountID }

    public init(accountID: String, provider: Provider, accountName: String, isEnabled: Bool = false) {
        self.accountID = accountID
        self.provider = provider
        self.accountName = accountName
        self.isEnabled = isEnabled
    }
}

public struct ResetPrimerSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var isEnabled: Bool
    public var delayMinutesAfterReset: Int
    public var accountStaggerMinutes: Int
    public var accountPreferences: [ResetPrimerAccountPreference]

    public init(
        isEnabled: Bool = false,
        delayMinutesAfterReset: Int = 5,
        accountStaggerMinutes: Int = 10,
        accountPreferences: [ResetPrimerAccountPreference] = []
    ) {
        precondition(delayMinutesAfterReset >= 0, "delayMinutesAfterReset must not be negative")
        precondition(accountStaggerMinutes >= 0, "accountStaggerMinutes must not be negative")

        schemaVersion = 1
        self.isEnabled = isEnabled
        self.delayMinutesAfterReset = delayMinutesAfterReset
        self.accountStaggerMinutes = accountStaggerMinutes
        self.accountPreferences = Self.normalized(accountPreferences)
    }

    public static var defaultSettings: ResetPrimerSettings {
        ResetPrimerSettings()
    }

    public func preference(for accountID: String) -> ResetPrimerAccountPreference? {
        accountPreferences.first { $0.accountID == accountID }
    }

    public mutating func syncAccounts(_ accounts: [LocalProviderAccountConfiguration]) {
        let existingByID = Dictionary(uniqueKeysWithValues: accountPreferences.map { ($0.accountID, $0) })
        accountPreferences = Self.normalized(accounts.map { account in
            var preference = existingByID[account.id] ?? ResetPrimerAccountPreference(
                accountID: account.id,
                provider: account.provider,
                accountName: account.displayName
            )
            preference.provider = account.provider
            preference.accountName = account.displayName
            if !account.isEnabled {
                preference.isEnabled = false
            }
            return preference
        })
    }

    public mutating func setAccount(_ accountID: String, isEnabled: Bool) {
        guard let index = accountPreferences.firstIndex(where: { $0.accountID == accountID }) else { return }
        accountPreferences[index].isEnabled = isEnabled
    }

    public mutating func setDelayMinutesAfterReset(_ minutes: Int) {
        delayMinutesAfterReset = max(minutes, 0)
    }

    public mutating func setAccountStaggerMinutes(_ minutes: Int) {
        accountStaggerMinutes = max(minutes, 0)
    }

    private static func normalized(_ preferences: [ResetPrimerAccountPreference]) -> [ResetPrimerAccountPreference] {
        Dictionary(grouping: preferences, by: \.accountID)
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider {
                    return lhs.provider.displayName < rhs.provider.displayName
                }
                if lhs.accountName != rhs.accountName {
                    return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
                }
                return lhs.accountID < rhs.accountID
            }
    }
}

public struct ResetPrimerSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: settingsURL.path)
    }

    public func load() -> ResetPrimerSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> ResetPrimerSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try Self.makeDecoder().decode(
                ResetPrimerSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else {
                return nil
            }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: ResetPrimerSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
