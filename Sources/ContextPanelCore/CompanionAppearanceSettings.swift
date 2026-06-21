import Foundation

public enum CompanionVisionOSAppAppearance: String, Codable, CaseIterable, Sendable {
    case dark
    case light
}

public enum CompanionVisionOSWidgetAppearance: String, Codable, CaseIterable, Sendable {
    case matchApp
    case dark
    case light
}

public struct CompanionAppearanceSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var visionOSAppAppearance: CompanionVisionOSAppAppearance
    public var visionOSWidgetAppearance: CompanionVisionOSWidgetAppearance

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case visionOSAppAppearance
        case visionOSWidgetAppearance
    }

    public init(
        visionOSAppAppearance: CompanionVisionOSAppAppearance = .dark,
        visionOSWidgetAppearance: CompanionVisionOSWidgetAppearance = .matchApp
    ) {
        schemaVersion = 1
        self.visionOSAppAppearance = visionOSAppAppearance
        self.visionOSWidgetAppearance = visionOSWidgetAppearance
    }

    public static var defaultSettings: CompanionAppearanceSettings {
        CompanionAppearanceSettings()
    }

    public var resolvedVisionOSWidgetAppearance: CompanionVisionOSAppAppearance {
        switch visionOSWidgetAppearance {
        case .matchApp:
            visionOSAppAppearance
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}

public struct CompanionAppearanceSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public func load() -> CompanionAppearanceSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> CompanionAppearanceSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try Self.makeDecoder().decode(
                CompanionAppearanceSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else { return nil }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: CompanionAppearanceSettings) throws {
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
