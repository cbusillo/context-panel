import Foundation

public struct BackgroundRefreshSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var isEnabled: Bool
    public var intervalMinutes: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case intervalMinutes
    }

    public init(isEnabled: Bool = true, intervalMinutes: Int = 5) {
        schemaVersion = 1
        self.isEnabled = isEnabled
        self.intervalMinutes = Self.clampedInterval(minutes: intervalMinutes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        intervalMinutes = Self.clampedInterval(minutes: try container.decode(Int.self, forKey: .intervalMinutes))
    }

    public static var defaultSettings: BackgroundRefreshSettings {
        BackgroundRefreshSettings()
    }

    public var intervalSeconds: Int {
        intervalMinutes * 60
    }

    public mutating func setIntervalMinutes(_ minutes: Int) {
        intervalMinutes = Self.clampedInterval(minutes: minutes)
    }

    private static func clampedInterval(minutes: Int) -> Int {
        min(max(minutes, 5), 60)
    }
}

public struct BackgroundRefreshSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: settingsURL.path)
    }

    public func load() -> BackgroundRefreshSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> BackgroundRefreshSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try Self.makeDecoder().decode(
                BackgroundRefreshSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else { return nil }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: BackgroundRefreshSettings) throws {
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
