import Foundation

public enum AccountConnectorKind: String, Codable, Equatable, Sendable {
    case codexRateLimits
    case geminiCodeAssist
    case claudeLocalStatus
    case claudeOAuthUsage
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
    public var rateLimitSnapshotPath: String?
    public var usageBlocksPath: String?
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
        rateLimitSnapshotPath: String? = nil,
        usageBlocksPath: String? = nil,
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
        self.rateLimitSnapshotPath = rateLimitSnapshotPath
        self.usageBlocksPath = usageBlocksPath
        self.oauthClientIDEnvironmentName = oauthClientIDEnvironmentName
        self.oauthClientSecretEnvironmentName = oauthClientSecretEnvironmentName
    }

    public var effectiveAuthPath: String? {
        switch connectorKind {
        case .codexRateLimits:
            return authPath
        case .geminiCodeAssist:
            return authPath
        case .claudeLocalStatus:
            return rateLimitSnapshotPath ?? ContextPanelLocations.claudeStatuslineCacheURL().path
        case .claudeOAuthUsage:
            return nil
        }
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
    public let fallbackConfigurationURL: URL?

    public init(configurationURL: URL, fallbackConfigurationURL: URL? = nil) {
        self.configurationURL = configurationURL
        self.fallbackConfigurationURL = fallbackConfigurationURL
    }

    public func load(now: Date = Date()) -> AccountConfigurationLoadResult {
        let loadURL = FileManager.default.fileExists(atPath: configurationURL.path)
            ? configurationURL
            : fallbackConfigurationURL
        guard let loadURL, FileManager.default.fileExists(atPath: loadURL.path) else {
            return AccountConfigurationLoadResult(document: Self.defaultDocument(now: now), status: .unknown)
        }

        do {
            let document = try Self.makeDecoder().decode(
                AccountConfigurationDocument.self,
                from: try Data(contentsOf: loadURL)
            )
            guard document.schemaVersion == 1 else {
                throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
            }
            let migratedDocument = Self.migratedDocument(document, now: now)
            if loadURL != configurationURL || migratedDocument != document {
                try? save(migratedDocument)
            }
            return AccountConfigurationLoadResult(document: migratedDocument, status: .healthy)
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
        let home = ContextPanelLocations.realUserHomeDirectory().path
        return AccountConfigurationDocument(updatedAt: now, accounts: [
            LocalProviderAccountConfiguration(
                id: "openai-code-default",
                provider: .openAI,
                connectorKind: .codexRateLimits,
                displayName: "Every Code",
                authPath: "\(home)/.code/auth_accounts.json"
            ),
            LocalProviderAccountConfiguration(
                id: "openai-codex-default",
                provider: .openAI,
                connectorKind: .codexRateLimits,
                displayName: "Codex",
                isEnabled: false,
                authPath: "\(home)/.codex/auth.json"
            ),
            LocalProviderAccountConfiguration(
                id: "claude-oauth-default",
                provider: .anthropic,
                connectorKind: .claudeOAuthUsage,
                displayName: "Claude"
            ),
            LocalProviderAccountConfiguration(
                id: "gemini-code-assist-default",
                provider: .google,
                connectorKind: .geminiCodeAssist,
                displayName: "Gemini",
                isEnabled: true,
                authPath: "\(home)/.gemini/oauth_creds.json",
                oauthClientIDEnvironmentName: "GEMINI_OAUTH_CLIENT_ID",
                oauthClientSecretEnvironmentName: "GEMINI_OAUTH_CLIENT_SECRET"
            ),
        ])
    }

    private static func migratedDocument(_ document: AccountConfigurationDocument, now: Date) -> AccountConfigurationDocument {
        var document = document
        var changed = false
        document.accounts = document.accounts.map { account in
            guard account.id == "claude-local-default", account.connectorKind == .claudeLocalStatus else {
                return account
            }
            changed = true
            return LocalProviderAccountConfiguration(
                id: "claude-oauth-default",
                provider: .anthropic,
                connectorKind: .claudeOAuthUsage,
                displayName: account.displayName.isEmpty ? "Claude" : account.displayName,
                isEnabled: account.isEnabled
            )
        }
        if changed {
            document.updatedAt = now
        }
        return document
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
        bookmarkStore: SecureFileBookmarkStore? = nil,
        credentialStore: (any ProviderCredentialStoring)? = nil,
        requiresBookmarkedAuthFiles: Bool = ContextPanelLocations.isRunningInAppSandbox,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        useBundledGeminiMetadataFallback: Bool = true,
        geminiMetadataFileLoader: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
        },
        geminiMetadataFileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
        },
        geminiMetadataDirectoryLister: @escaping @Sendable (String) -> [String] = { path in
            let expanded = NSString(string: path).expandingTildeInPath
            return (try? FileManager.default.contentsOfDirectory(atPath: expanded).map { "\(expanded)/\($0)" }) ?? []
        },
        antigravityCredentialSource: AntigravityKeychainCredentialSource? = AntigravityKeychainCredentialSource()
    ) -> [any ProviderConnector] {
        return document.accounts.compactMap { account -> (any ProviderConnector)? in
            guard account.isEnabled else { return nil }
            switch account.connectorKind {
            case .codexRateLimits:
                guard let authPath = account.authPath else { return nil }
                let authFileLoader = makeAuthFileLoader(
                    accountID: account.id,
                    bookmarkStore: bookmarkStore,
                    credentialStore: credentialStore,
                    requiresBookmarkedAuthFiles: requiresBookmarkedAuthFiles
                )
                return CodexRateLimitConnector(
                    accounts: [CodexAccountConfiguration(
                        configuredAccountID: account.id,
                        authPath: authPath,
                        accountName: codexAccountName(for: authPath, fallback: account.displayName)
                    )],
                    fileLoader: authFileLoader
                )
            case .geminiCodeAssist:
                guard let authPath = account.authPath else { return nil }
                let authFileLoader = makeAuthFileLoader(
                    accountID: account.id,
                    bookmarkStore: bookmarkStore,
                    credentialStore: credentialStore,
                    requiresBookmarkedAuthFiles: requiresBookmarkedAuthFiles
                )
                let configuredMetadata = geminiMetadata(account: account, environment: environment)
                let configuredMetadataValue: GeminiOAuthClientMetadata?
                switch configuredMetadata {
                case .complete(let metadata):
                    configuredMetadataValue = metadata
                case .missing, .partial:
                    configuredMetadataValue = nil
                }
                let cachedMetadataValue = geminiCachedMetadata(accountID: account.id, credentialStore: credentialStore)
                let discoveredMetadata = GeminiOAuthClientMetadataDiscovery.discover(
                    environment: environment,
                    commandPath: account.commandPath,
                    useBundledFallback: useBundledGeminiMetadataFallback,
                    fileLoader: geminiMetadataFileLoader,
                    fileExists: geminiMetadataFileExists,
                    directoryLister: geminiMetadataDirectoryLister
                )
                let metadata = configuredMetadataValue
                    ?? cachedMetadataValue
                    ?? discoveredMetadata
                    ?? (antigravityCredentialSource?.hasCredentials() == true ? GeminiOAuthClientMetadata(clientID: "", clientSecret: "") : nil)
                guard let metadata else {
                    let expanded = NSString(string: authPath).expandingTildeInPath
                    return FailingProviderConnector(
                        provider: .google,
                        accountID: ConnectorRedactor.localAccountID(provider: .google, path: expanded),
                        accountName: account.displayName,
                        message: "Google OAuth client metadata could not be found. Reinstall Gemini CLI, sign into Antigravity, or configure Gemini OAuth client metadata."
                    )
                }
                return GeminiCodeAssistConnector(
                    accounts: [GeminiAccountConfiguration(
                        authPath: authPath,
                        accountName: account.displayName,
                        clientID: metadata.clientID,
                        clientSecret: metadata.clientSecret
                    )],
                    fileLoader: authFileLoader,
                    credentialStore: credentialStore,
                    credentialAccountID: account.id,
                    antigravityCredentialSource: antigravityCredentialSource
                )
            case .claudeLocalStatus:
                return ClaudeLocalStatusConnector(accounts: [ClaudeAccountConfiguration(
                    accountName: account.displayName,
                    statsPath: nil,
                    rateLimitSnapshotPath: account.rateLimitSnapshotPath,
                    usageBlocksPath: account.usageBlocksPath
                )])
            case .claudeOAuthUsage:
                let effectiveCredentialStore: any ProviderCredentialStoring = credentialStore ?? ProviderCredentialStore()
                return ClaudeOAuthUsageConnector(
                    accounts: [ClaudeOAuthAccountConfiguration(
                        accountID: account.id,
                        accountName: account.displayName
                    )],
                    credentialStore: effectiveCredentialStore
                )
            }
        }
    }

    private static func makeAuthFileLoader(
        accountID: String,
        bookmarkStore: SecureFileBookmarkStore?,
        credentialStore: (any ProviderCredentialLoading)?,
        requiresBookmarkedAuthFiles: Bool
    ) -> @Sendable (String) throws -> Data {
        { path in
            let expanded = NSString(string: path).expandingTildeInPath
            if let credentialStore {
                do {
                    if let data = try credentialStore.load(accountID: accountID) {
                        return data
                    }
                } catch {
                    // Keychain cache failures should not block the original user-authorized file path.
                }
            }
            if let store = bookmarkStore, store.hasBookmark(for: expanded) {
                do {
                    if let data = try store.readData(for: expanded) {
                        return data
                    }
                } catch {
                    if requiresBookmarkedAuthFiles {
                        throw CocoaError(.fileReadNoPermission)
                    }
                }
            }
            if requiresBookmarkedAuthFiles {
                throw CocoaError(.fileReadNoPermission)
            }
            return try Data(contentsOf: URL(fileURLWithPath: expanded))
        }
    }

    private static func geminiCachedMetadata(
        accountID: String,
        credentialStore: (any ProviderCredentialLoading)?
    ) -> GeminiOAuthClientMetadata? {
        guard let credentialStore else { return nil }
        let metadataAccountID = GeminiOAuthClientMetadata.credentialAccountID(for: accountID)
        guard let data = try? credentialStore.load(accountID: metadataAccountID) else { return nil }
        return try? JSONDecoder().decode(GeminiOAuthClientMetadata.self, from: data)
    }

    private static func geminiMetadata(
        account: LocalProviderAccountConfiguration,
        environment: [String: String]
    ) -> ConfiguredGeminiMetadata {
        guard
            let clientIDName = account.oauthClientIDEnvironmentName,
            let clientSecretName = account.oauthClientSecretEnvironmentName
        else { return .missing }
        let clientID = environment[clientIDName]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clientSecret = environment[clientSecretName]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clientID.isEmpty && clientSecret.isEmpty { return .missing }
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return .partial }
        return .complete(GeminiOAuthClientMetadata(clientID: clientID, clientSecret: clientSecret))
    }

    private static func codexAccountName(for authPath: String, fallback: String) -> String {
        let expanded = NSString(string: authPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if url.deletingLastPathComponent().lastPathComponent == ".code" {
            return "Every Code"
        }
        if url.deletingLastPathComponent().lastPathComponent == ".codex" {
            return "Codex"
        }
        return fallback
    }
}

private enum ConfiguredGeminiMetadata: Equatable {
    case missing
    case partial
    case complete(GeminiOAuthClientMetadata)
}
