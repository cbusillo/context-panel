import Foundation

public struct CompanionRefreshSettings: Codable, Equatable, Sendable {
    public static let allowedIntervalMinutes = [5, 10, 15, 30, 60]
    public static let minimumWidgetIntervalMinutes = 15

    public let schemaVersion: Int
    public var intervalMinutes: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case intervalMinutes
    }

    public init(intervalMinutes: Int = 5) {
        schemaVersion = 1
        self.intervalMinutes = Self.clampedInterval(minutes: intervalMinutes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        intervalMinutes = Self.clampedInterval(minutes: try container.decode(Int.self, forKey: .intervalMinutes))
    }

    public static var defaultSettings: CompanionRefreshSettings {
        CompanionRefreshSettings()
    }

    public var intervalSeconds: Int {
        intervalMinutes * 60
    }

    public var interval: TimeInterval {
        TimeInterval(intervalSeconds)
    }

    public var widgetIntervalSeconds: Int {
        max(intervalMinutes, Self.minimumWidgetIntervalMinutes) * 60
    }

    public var widgetInterval: TimeInterval {
        TimeInterval(widgetIntervalSeconds)
    }

    public mutating func setIntervalMinutes(_ minutes: Int) {
        intervalMinutes = Self.clampedInterval(minutes: minutes)
    }

    private static func clampedInterval(minutes: Int) -> Int {
        allowedIntervalMinutes.min(by: { abs($0 - minutes) < abs($1 - minutes) }) ?? 5
    }
}

public struct CompanionRefreshSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public func load() -> CompanionRefreshSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> CompanionRefreshSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try Self.makeDecoder().decode(
                CompanionRefreshSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else { return nil }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: CompanionRefreshSettings) throws {
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
