import Foundation

/// The local client supplying credentials and telemetry, not a separate provider.
public enum CodexClient: String, Codable, Equatable, Sendable {
    case codex
    case codexLab
    // Decode existing configurations and historical records only. Never collect this source.
    case everyCode

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .codexLab: "Codex Lab"
        case .everyCode: "Every Code"
        }
    }

    public var telemetryFolderName: String { self == .codex ? "sessions" : "usage" }

    public static func inferred(fromAuthPath path: String?) -> CodexClient? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let home = url.deletingLastPathComponent().lastPathComponent
        if home == ".codex-lab" || home.hasPrefix(".codex-lab-") { return .codexLab }
        if home == ".codex" || home.hasPrefix(".codex-") { return .codex }
        if home == ".code" || home.hasPrefix(".code-") { return .everyCode }
        return nil
    }

    public func homeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = ContextPanelLocations.realUserHomeDirectory()
    ) -> URL {
        let key: String
        let folder: String
        switch self {
        case .codex: (key, folder) = ("CODEX_HOME", ".codex")
        case .codexLab: (key, folder) = ("CODEX_LAB_HOME", ".codex-lab")
        case .everyCode: (key, folder) = ("CODE_HOME", ".code")
        }
        if let path = environment[key], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return userHome.appending(path: folder, directoryHint: .isDirectory)
    }
}

public extension LocalProviderAccountConfiguration {
    var isRetiredSource: Bool { effectiveCodexClient == .everyCode }

    var supportsPromptCacheTelemetry: Bool { promptCacheDirectory != nil }

    var effectiveCodexClient: CodexClient? {
        guard connectorKind == .codexRateLimits else { return nil }
        return codexClient ?? CodexClient.inferred(fromAuthPath: authPath)
    }

    var promptCacheDirectory: URL? {
        guard let client = effectiveCodexClient, client != .everyCode, let path = effectiveAuthPath else { return nil }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .deletingLastPathComponent()
            .appending(path: client.telemetryFolderName, directoryHint: .isDirectory)
    }
}

public extension AccountConfigurationDocument {
    /// Presentation only: keep the complete stored document when saving settings.
    var settingsAccounts: [LocalProviderAccountConfiguration] {
        let available = accounts.filter { !$0.isRetiredSource }
        return available.filter { $0.effectiveCodexClient == .codexLab }
            + available.filter { $0.effectiveCodexClient != .codexLab }
    }
}
