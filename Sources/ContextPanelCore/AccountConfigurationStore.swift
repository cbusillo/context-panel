import Foundation

public enum AccountConnectorKind: String, Codable, Equatable, Sendable {
    case codexRateLimits
    case geminiCodeAssist
    case claudeLocalStatus
}

public struct LocalProviderAccountConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let connectorKind: AccountConnectorKind
    public var displayName: String
    public var isEnabled: Bool
    public var authPath: String?
    public var commandPath: String?
    public var statsPath: String?
    public var oauthClientIDEnvironmentName: String?
    public var oauthClientSecretEnvironmentName: String?

    public init(
        id: String,
        provider: Provider,
        connectorKind: AccountConnectorKind,
        displayName: String,
        isEnabled: Bool = true,
        authPath: String? = nil,
        commandPath: String? = nil,
        statsPath: String? = nil,
        oauthClientIDEnvironmentName: String? = nil,
        oauthClientSecretEnvironmentName: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.connectorKind = connectorKind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.authPath = authPath
        self.commandPath = commandPath
        self.statsPath = statsPath
        self.oauthClientIDEnvironmentName = oauthClientIDEnvironmentName
        self.oauthClientSecretEnvironmentName = oauthClientSecretEnvironmentName
    }
}

public struct AccountConfigurationDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var updatedAt: Date
    public var accounts: [LocalProviderAccountConfiguration]

    public init(updatedAt: Date, accounts: [LocalProviderAccountConfiguration]) {
        schemaVersion = 1
        self.updatedAt = updatedAt
        self.accounts = accounts
    }
}

public struct AccountConfigurationLoadResult: Equatable, Sendable {
    public let document: AccountConfigurationDocument
    public let status: UsageStatus
    public let errorMessage: String?

    public init(document: AccountConfigurationDocument, status: UsageStatus, errorMessage: String? = nil) {
        self.document = document
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }
}

public struct AccountConfigurationStore: Sendable {
    public let configurationURL: URL

    public init(configurationURL: URL) {
        self.configurationURL = configurationURL
    }

    public func load(now: Date = Date()) -> AccountConfigurationLoadResult {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return AccountConfigurationLoadResult(document: Self.defaultDocument(now: now), status: .unknown)
        }

        do {
            let document = try Self.makeDecoder().decode(
                AccountConfigurationDocument.self,
                from: try Data(contentsOf: configurationURL)
            )
            guard document.schemaVersion == 1 else {
                throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
            }
            return AccountConfigurationLoadResult(document: document, status: .healthy)
        } catch {
            return AccountConfigurationLoadResult(
                document: Self.defaultDocument(now: now),
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    public func save(_ document: AccountConfigurationDocument) throws {
        let directory = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(document)
        try data.write(to: configurationURL, options: [.atomic])
    }

    public static func defaultDocument(now: Date = Date()) -> AccountConfigurationDocument {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AccountConfigurationDocument(updatedAt: now, accounts: [
            LocalProviderAccountConfiguration(
                id: "openai-codex-default",
                provider: .openAI,
                connectorKind: .codexRateLimits,
                displayName: "Codex",
                authPath: "\(home)/.codex/auth.json"
            ),
            LocalProviderAccountConfiguration(
                id: "claude-local-default",
                provider: .anthropic,
                connectorKind: .claudeLocalStatus,
                displayName: "Claude",
                commandPath: "claude",
                statsPath: "\(home)/.claude/stats-cache.json"
            ),
            LocalProviderAccountConfiguration(
                id: "gemini-code-assist-default",
                provider: .google,
                connectorKind: .geminiCodeAssist,
                displayName: "Gemini",
                isEnabled: false,
                authPath: "\(home)/.gemini/oauth_creds.json",
                oauthClientIDEnvironmentName: "GEMINI_OAUTH_CLIENT_ID",
                oauthClientSecretEnvironmentName: "GEMINI_OAUTH_CLIENT_SECRET"
            ),
        ])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AccountConnectorFactory {
    public static func connectors(
        from document: AccountConfigurationDocument,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        geminiMetadataFileLoader: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
        },
        geminiMetadataFileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
        }
    ) -> [any ProviderConnector] {
        document.accounts.compactMap { account in
            guard account.isEnabled else { return nil }
            switch account.connectorKind {
            case .codexRateLimits:
                guard let authPath = account.authPath else { return nil }
                return CodexRateLimitConnector(accounts: [CodexAccountConfiguration(
                    authPath: authPath,
                    accountName: account.displayName
                )])
            case .geminiCodeAssist:
                guard let authPath = account.authPath else { return nil }
                let configuredMetadata = geminiMetadata(account: account, environment: environment)
                let discoveredMetadata = GeminiOAuthClientMetadataDiscovery.discover(
                    environment: environment,
                    fileLoader: geminiMetadataFileLoader,
                    fileExists: geminiMetadataFileExists
                )
                guard let metadata = configuredMetadata ?? discoveredMetadata else { return nil }
                return GeminiCodeAssistConnector(accounts: [GeminiAccountConfiguration(
                    authPath: authPath,
                    accountName: account.displayName,
                    clientID: metadata.clientID,
                    clientSecret: metadata.clientSecret
                )])
            case .claudeLocalStatus:
                return ClaudeLocalStatusConnector(accounts: [ClaudeAccountConfiguration(
                    accountName: account.displayName,
                    claudeBinary: account.commandPath ?? "claude",
                    statsPath: account.statsPath
                )])
            }
        }
    }

    private static func geminiMetadata(
        account: LocalProviderAccountConfiguration,
        environment: [String: String]
    ) -> GeminiOAuthClientMetadata? {
        guard
            let clientIDName = account.oauthClientIDEnvironmentName,
            let clientSecretName = account.oauthClientSecretEnvironmentName,
            let clientID = environment[clientIDName], !clientID.isEmpty,
            let clientSecret = environment[clientSecretName], !clientSecret.isEmpty
        else { return nil }
        return GeminiOAuthClientMetadata(clientID: clientID, clientSecret: clientSecret)
    }
}
