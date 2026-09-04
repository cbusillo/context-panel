import Foundation

public enum AccountConnectorKind: String, Codable, Equatable, Sendable {
    case codexRateLimits
    case googleAntigravityQuota
    case claudeOAuthUsage

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.codexRateLimits.rawValue:
            self = .codexRateLimits
        case "geminiCodeAssist", Self.googleAntigravityQuota.rawValue:
            self = .googleAntigravityQuota
        case "claudeLocalStatus", Self.claudeOAuthUsage.rawValue:
            self = .claudeOAuthUsage
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown account connector kind: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct LocalProviderAccountConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let connectorKind: AccountConnectorKind
    public var displayName: String
    public var isEnabled: Bool
    public var authPath: String?
    public var commandPath: String?
    public var codexClient: CodexClient?

    public init(
        id: String,
        provider: Provider,
        connectorKind: AccountConnectorKind,
        displayName: String,
        isEnabled: Bool = true,
        authPath: String? = nil,
        commandPath: String? = nil,
        codexClient: CodexClient? = nil
    ) {
        self.id = id
        self.provider = provider
        self.connectorKind = connectorKind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.authPath = authPath
        self.commandPath = commandPath
        self.codexClient = codexClient
    }

    public var effectiveAuthPath: String? {
        switch connectorKind {
        case .codexRateLimits:
            return authPath
        case .googleAntigravityQuota:
            return nil
        case .claudeOAuthUsage:
            return nil
        }
    }
}

public extension LocalProviderAccountConfiguration {
    var providerReportAccountIDs: [String] {
        switch connectorKind {
        case .codexRateLimits:
            guard let authPath else { return [] }
            return Self.localAccountIDs(provider: provider, path: authPath)
        case .googleAntigravityQuota:
            return [ConnectorRedactor.localAccountID(provider: provider, stableID: id)]
        case .claudeOAuthUsage:
            return [ConnectorRedactor.localAccountID(provider: provider, stableID: id)]
        }
    }

    func matchesProviderReport(_ report: StoredProviderReport) -> Bool {
        guard report.provider == provider else { return false }
        if let configuredAccountID = report.configuredAccountID {
            return configuredAccountID == id
        }
        return report.accountID == id || providerReportAccountIDs.contains(report.accountID)
    }

    private static func localAccountIDs(provider: Provider, path: String) -> [String] {
        var ids = [ConnectorRedactor.localAccountID(provider: provider, path: path)]
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath != path {
            ids.append(ConnectorRedactor.localAccountID(provider: provider, path: expandedPath))
        }
        return ids
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
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
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
            let data = try Data(contentsOf: loadURL)
            let document = try Self.makeDecoder().decode(
                AccountConfigurationDocument.self,
                from: data
            )
            guard document.schemaVersion == 1 else {
                throw SnapshotStoreError.unsupportedSchema(version: document.schemaVersion)
            }
            let migratedDocument = Self.migratedDocument(document, now: now)
            if loadURL != configurationURL || migratedDocument != document || Self.containsLegacyConnectorRawValue(data) {
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
        return AccountConfigurationDocument(updatedAt: now, accounts: [
            LocalProviderAccountConfiguration(
                id: "openai-codex-default",
                provider: .openAI,
                connectorKind: .codexRateLimits,
                displayName: "Codex",
                authPath: CodexClient.codex.homeDirectory().appending(path: "auth.json").path,
                codexClient: .codex
            ),
            LocalProviderAccountConfiguration(
                id: "openai-codex-lab-default",
                provider: .openAI,
                connectorKind: .codexRateLimits,
                displayName: "Codex Lab",
                isEnabled: false,
                authPath: CodexClient.codexLab.homeDirectory().appending(path: "auth_accounts.json").path,
                codexClient: .codexLab
            ),
            LocalProviderAccountConfiguration(
                id: "claude-oauth-default",
                provider: .anthropic,
                connectorKind: .claudeOAuthUsage,
                displayName: "Claude"
            ),
            LocalProviderAccountConfiguration(
                id: "google-antigravity-default",
                provider: .google,
                connectorKind: .googleAntigravityQuota,
                displayName: "Antigravity",
                isEnabled: true
            ),
        ])
    }

    private static func migratedDocument(_ document: AccountConfigurationDocument, now: Date) -> AccountConfigurationDocument {
        let originalDocument = document
        var document = ClaudeAccountMigration.migrateAccountConfiguration(document, now: now)
        var changed = document != originalDocument
        document.accounts = document.accounts.map { account in
            if account.id == GoogleAccountMigration.oldAccountID, account.connectorKind == .googleAntigravityQuota {
                changed = true
                return LocalProviderAccountConfiguration(
                    id: GoogleAccountMigration.newAccountID,
                    provider: .google,
                    connectorKind: .googleAntigravityQuota,
                    displayName: GoogleAccountMigration.migratedDisplayName(from: account.displayName),
                    isEnabled: account.isEnabled
                )
            }
            return account
        }
        // Add setup choices without repointing existing bookmarks/Keychain keys,
        // enabling an account the user turned off, or discarding historical IDs.
        let hasLegacyDefault = document.accounts.contains {
            $0.id == "openai-code-default" && $0.effectiveCodexClient == .everyCode
        }
        for var account in defaultDocument(now: now).accounts where hasLegacyDefault && account.connectorKind == .codexRateLimits {
            guard !document.accounts.contains(where: {
                $0.id == account.id || $0.effectiveCodexClient == account.effectiveCodexClient
            }) else { continue }
            account.isEnabled = false
            document.accounts.append(account)
            changed = true
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

    private static func containsLegacyConnectorRawValue(_ data: Data) -> Bool {
        guard let contents = String(data: data, encoding: .utf8) else { return false }
        return contents.contains("\"geminiCodeAssist\"") || contents.contains("\"claudeLocalStatus\"")
    }
}

public enum AccountConnectorFactory {
    public static func connectors(
        from document: AccountConfigurationDocument,
        bookmarkStore: SecureFileBookmarkStore? = nil,
        credentialStore: (any ProviderCredentialStoring)? = nil,
        googleAntigravitySnapshotLoader: (any GoogleAntigravityQuotaSnapshotLoading)? = nil,
        requiresBookmarkedAuthFiles: Bool = ContextPanelLocations.isRunningInAppSandbox
    ) -> [any ProviderConnector] {
        var hasGoogleAntigravityConnector = false
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
                        accountName: account.displayName.isEmpty
                            ? (account.effectiveCodexClient?.displayName ?? "OpenAI")
                            : account.displayName
                    )],
                    fileLoader: authFileLoader
                )
            case .googleAntigravityQuota:
                guard !hasGoogleAntigravityConnector else { return nil }
                hasGoogleAntigravityConnector = true
                let snapshotLoader: any GoogleAntigravityQuotaSnapshotLoading
                if let googleAntigravitySnapshotLoader {
                    snapshotLoader = googleAntigravitySnapshotLoader
                } else if let snapshotURL = ContextPanelLocations.googleAntigravityStatusLineSnapshotURL() {
                    snapshotLoader = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
                } else {
                    snapshotLoader = UnavailableGoogleAntigravitySnapshotLoader()
                }
                return GoogleAntigravityQuotaConnector(
                    accounts: [GoogleAntigravityAccountConfiguration(
                        accountID: account.id,
                        accountName: account.displayName
                    )],
                    snapshotLoader: snapshotLoader
                )
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

}

private struct UnavailableGoogleAntigravitySnapshotLoader: GoogleAntigravityQuotaSnapshotLoading {
    func load() throws -> GoogleAntigravityStatusLineSnapshot? {
        throw GoogleAntigravityStatusLineStoreError.unavailable
    }
}
