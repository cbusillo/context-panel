import Foundation

public enum ClaudeStatuslineSetupStatus: String, Codable, Equatable, Sendable {
    case notInstalled
    case notAuthenticated
    case hookMissing
    case waitingForFirstInteractiveResponse
    case cacheHealthy
    case cacheStale
}

public struct ClaudeStatuslineSetupDiagnostic: Codable, Equatable, Sendable {
    public let status: ClaudeStatuslineSetupStatus
    public let statusLineCommand: String?
    public let cacheObservedAt: Date?
    public let cacheAgeSeconds: TimeInterval?

    public init(
        status: ClaudeStatuslineSetupStatus,
        statusLineCommand: String?,
        cacheObservedAt: Date?,
        cacheAgeSeconds: TimeInterval?
    ) {
        self.status = status
        self.statusLineCommand = statusLineCommand
        self.cacheObservedAt = cacheObservedAt
        self.cacheAgeSeconds = cacheAgeSeconds
    }
}

public enum ClaudeStatuslineSettingsError: LocalizedError, Equatable {
    case invalidSettingsJSON
    case invalidStatusLineShape

    public var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON:
            "Claude settings must be a JSON object."
        case .invalidStatusLineShape:
            "Claude statusLine settings must be an object."
        }
    }
}

public enum ClaudeStatuslineSetup {
    public static func defaultSettingsURL(homeDirectory: URL = ContextPanelLocations.realUserHomeDirectory()) -> URL {
        homeDirectory
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    }

    public static func defaultRateLimitCacheURL(homeDirectory: URL = ContextPanelLocations.realUserHomeDirectory()) -> URL {
        if homeDirectory == ContextPanelLocations.realUserHomeDirectory() {
            return ContextPanelLocations.claudeStatuslineCacheURL()
        }
        return homeDirectory
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "ClaudeRateLimits", directoryHint: .isDirectory)
            .appending(path: "statusline-cache.json")
    }

    public static func statusLineCommand(in settingsData: Data?) throws -> String? {
        guard let settingsData, !settingsData.isEmpty else { return nil }
        let settings = try settingsObject(from: settingsData)
        guard let statusLine = settings["statusLine"] else { return nil }
        guard let statusLineObject = statusLine as? [String: Any] else {
            throw ClaudeStatuslineSettingsError.invalidStatusLineShape
        }
        return statusLineObject["command"] as? String
    }

    public static func mergedSettingsData(
        existingData: Data?,
        command: String,
        padding: Int = 0
    ) throws -> Data {
        var settings = try settingsObject(from: existingData)
        settings["statusLine"] = [
            "type": "command",
            "command": command,
            "padding": padding,
        ]
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func diagnostic(
        binaryExists: Bool,
        loggedIn: Bool,
        settingsData: Data?,
        rateLimitSnapshot: ClaudeSubscriptionRateLimitSnapshot?,
        maximumCacheAge: TimeInterval = 30 * 60,
        now: Date = Date()
    ) -> ClaudeStatuslineSetupDiagnostic {
        guard binaryExists else {
            return ClaudeStatuslineSetupDiagnostic(
                status: .notInstalled,
                statusLineCommand: nil,
                cacheObservedAt: nil,
                cacheAgeSeconds: nil
            )
        }

        guard loggedIn else {
            return ClaudeStatuslineSetupDiagnostic(
                status: .notAuthenticated,
                statusLineCommand: try? statusLineCommand(in: settingsData),
                cacheObservedAt: nil,
                cacheAgeSeconds: nil
            )
        }

        let command = try? statusLineCommand(in: settingsData)
        guard command?.isEmpty == false else {
            return ClaudeStatuslineSetupDiagnostic(
                status: .hookMissing,
                statusLineCommand: nil,
                cacheObservedAt: nil,
                cacheAgeSeconds: nil
            )
        }

        guard let rateLimitSnapshot else {
            return ClaudeStatuslineSetupDiagnostic(
                status: .waitingForFirstInteractiveResponse,
                statusLineCommand: command,
                cacheObservedAt: nil,
                cacheAgeSeconds: nil
            )
        }

        let cacheAge = now.timeIntervalSince(rateLimitSnapshot.observedAt)
        return ClaudeStatuslineSetupDiagnostic(
            status: cacheAge <= maximumCacheAge ? .cacheHealthy : .cacheStale,
            statusLineCommand: command,
            cacheObservedAt: rateLimitSnapshot.observedAt,
            cacheAgeSeconds: cacheAge
        )
    }

    private static func settingsObject(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ClaudeStatuslineSettingsError.invalidSettingsJSON
        }
        return dictionary
    }
}
