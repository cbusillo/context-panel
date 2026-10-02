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
    public var accountAliases: [String: String]?
    /// User-selected, account-specific session folder. Nil retains the auth-file adapter.
    public var codexQuotaPath: String?
    /// Independent of collection. Missing values preserve older setup until edited.
    public var showInWidgets: Bool?
    public var useLast: Bool?
    public var restorationRequestedAt: Date?

    public init(
        id: String,
        provider: Provider,
        connectorKind: AccountConnectorKind,
        displayName: String,
        isEnabled: Bool = true,
        authPath: String? = nil,
        commandPath: String? = nil,
        codexClient: CodexClient? = nil,
        accountAliases: [String: String]? = nil,
        codexQuotaPath: String? = nil,
        showInWidgets: Bool? = nil,
        useLast: Bool? = nil,
        restorationRequestedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.connectorKind = connectorKind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.authPath = authPath
        self.commandPath = commandPath
        self.codexClient = codexClient
        self.accountAliases = accountAliases
        self.codexQuotaPath = codexQuotaPath
        self.showInWidgets = showInWidgets
        self.useLast = useLast
        self.restorationRequestedAt = restorationRequestedAt
    }

    public var effectiveAuthPath: String? {
        switch connectorKind {
        case .codexRateLimits:
            if codexQuotaPath != nil { return nil }
            guard let authPath, !authPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
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
            if codexQuotaPath != nil {
                return [ConnectorRedactor.localAccountID(provider: provider, stableID: id)]
            }
            guard let authPath = effectiveAuthPath else { return [] }
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

    func soleProviderReportAccountID(in reports: [StoredProviderReport]) -> String? {
        let members = Set(reports.filter { matchesProviderReport($0) }.map(\.accountID))
        return members.count == 1 ? members.first : nil
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
    public var removedAccountIDs: [String]
    public var removedDisplayIDs: [String]?
    public var pendingRemovedDisplayIDs: [String]?
    public var removalUserScope: CompanionCloudKitUserScope?
    public var publisherID: String?
    public var membershipIdentityVersion: Int?
    public var removedDisplayDates: [String: Date]?
    public var restoredDisplayDates: [String: Date]?

    public init(updatedAt: Date, accounts: [LocalProviderAccountConfiguration], removedAccountIDs: [String] = [], removedDisplayIDs: [String]? = nil, pendingRemovedDisplayIDs: [String]? = nil, removalUserScope: CompanionCloudKitUserScope? = nil, publisherID: String? = nil, membershipIdentityVersion: Int? = nil, removedDisplayDates: [String: Date]? = nil, restoredDisplayDates: [String: Date]? = nil) {
        schemaVersion = 1
        self.updatedAt = updatedAt
        self.accounts = accounts
        self.removedAccountIDs = removedAccountIDs
        self.removedDisplayIDs = removedDisplayIDs
        self.pendingRemovedDisplayIDs = pendingRemovedDisplayIDs
        self.removalUserScope = removalUserScope
        self.publisherID = publisherID
        self.membershipIdentityVersion = membershipIdentityVersion
        self.removedDisplayDates = removedDisplayDates
        self.restoredDisplayDates = restoredDisplayDates
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, updatedAt, accounts, removedAccountIDs, removedDisplayIDs, pendingRemovedDisplayIDs, removalUserScope, publisherID, membershipIdentityVersion, removedDisplayDates, restoredDisplayDates }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        accounts = try container.decode([LocalProviderAccountConfiguration].self, forKey: .accounts)
        removedAccountIDs = try container.decodeIfPresent([String].self, forKey: .removedAccountIDs) ?? []
        removedDisplayIDs = try container.decodeIfPresent([String].self, forKey: .removedDisplayIDs)
        pendingRemovedDisplayIDs = try container.decodeIfPresent([String].self, forKey: .pendingRemovedDisplayIDs)
        removalUserScope = try container.decodeIfPresent(CompanionCloudKitUserScope.self, forKey: .removalUserScope)
        publisherID = try container.decodeIfPresent(String.self, forKey: .publisherID)
        membershipIdentityVersion = try container.decodeIfPresent(Int.self, forKey: .membershipIdentityVersion)
        removedDisplayDates = try container.decodeIfPresent([String: Date].self, forKey: .removedDisplayDates)
        restoredDisplayDates = try container.decodeIfPresent([String: Date].self, forKey: .restoredDisplayDates)
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

public enum AccountConfigurationMutationError: LocalizedError {
    case unreadableConfiguration
    public var errorDescription: String? { "Account setup could not be read. Restore it before removing an account." }
}

public struct AccountConfigurationStore: Sendable {
    public let configurationURL: URL
    public let fallbackConfigurationURL: URL?

    public init(configurationURL: URL, fallbackConfigurationURL: URL? = nil) {
        self.configurationURL = configurationURL
        self.fallbackConfigurationURL = fallbackConfigurationURL
    }

    public func load(now: Date = Date()) -> AccountConfigurationLoadResult {
        var result: AccountConfigurationLoadResult?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: configurationURL, options: [], error: &coordinatorError) { _ in
            result = loadCoordinated(now: now)
        }
        return result ?? AccountConfigurationLoadResult(document: Self.defaultDocument(now: now), status: .failure,
            errorMessage: coordinatorError?.localizedDescription ?? "Account setup could not be coordinated.")
    }

    private func loadCoordinated(now: Date) -> AccountConfigurationLoadResult {
        let loadURL = FileManager.default.fileExists(atPath: configurationURL.path)
            ? configurationURL
            : fallbackConfigurationURL
        guard let loadURL, FileManager.default.fileExists(atPath: loadURL.path) else {
            var document = Self.defaultDocument(now: now)
            document.publisherID = UUID().uuidString.lowercased()
            document.membershipIdentityVersion = 1
            do { try save(document) }
            catch { return AccountConfigurationLoadResult(document: Self.defaultDocument(now: now), status: .failure, errorMessage: error.localizedDescription) }
            return AccountConfigurationLoadResult(document: document, status: .unknown)
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
                do { try save(migratedDocument) }
                catch { return AccountConfigurationLoadResult(document: document, status: .failure, errorMessage: error.localizedDescription) }
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

    /// Removes panel membership only. No credential store, bookmark store or provider home is accessed.
    public func removeAccount(
        id: String, lock: SnapshotRefreshLock = .appDefault(), now: Date = Date(),
        storedSnapshot: StoredUsageSnapshot? = nil, userScope: CompanionCloudKitUserScope? = nil
    ) async throws -> AccountConfigurationDocument? {
        try await lock.withLock {
            let result = load(now: now)
            guard result.status != .failure else { throw AccountConfigurationMutationError.unreadableConfiguration }
            var document = result.document
            guard let account = document.accounts.first(where: { $0.id == id }) else { return document }
            if let userScope, let previousScope = document.removalUserScope, previousScope != userScope {
                document.removedDisplayIDs = []
                document.removedDisplayDates = [:]
            document.restoredDisplayDates = [:]
            }
            if let userScope { document.removalUserScope = userScope }
            var removed = Set<String>()
            let verified = storedSnapshot?.reports.filter { account.matchesProviderReport($0) && $0.sharedAccountIdentity != nil
                && (userScope == nil || $0.sharedAccountIdentity?.userScope == nil || $0.sharedAccountIdentity?.userScope == userScope) } ?? []
            if verified.isEmpty && !(storedSnapshot?.reports.contains(where: { account.matchesProviderReport($0) }) ?? false) { removed.insert(AccountDisplayMetadata.companionConfigurationID(account, publisherID: document.publisherID)) }
            for report in verified {
                if let identity = report.sharedAccountIdentity { removed.insert(AccountDisplayMetadata.safeID(report.provider, identity.accountID)) }
            }
            let membershipSnapshot = storedSnapshot ?? StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: [])
            do {
                for entry in AccountDisplayMetadata.companion(configuration: [account], stored: membershipSnapshot, now: now, publisherID: document.publisherID) {
                    removed.insert(entry.id)
                }
            }
            if userScope == nil {
                document.pendingRemovedDisplayIDs = Array(Set(document.pendingRemovedDisplayIDs ?? []).union(removed)).sorted()
            } else {
                document.removedDisplayIDs = Array(Set(document.removedDisplayIDs ?? []).union(document.pendingRemovedDisplayIDs ?? []).union(removed)).sorted()
                document.pendingRemovedDisplayIDs = nil
            }
            for key in removed { document.removedDisplayDates = (document.removedDisplayDates ?? [:]).merging([key: now]) { max($0, $1) } }
            document.accounts.removeAll { $0.id == id }
            if !document.removedAccountIDs.contains(id) { document.removedAccountIDs.append(id) }
            document.updatedAt = now
            try save(document)
            return document
        }
    }

    /// Called under the refresh lock, before reading provider credentials.
    public func applyGlobalRemovals(_ ids: [String], storedSnapshot: StoredUsageSnapshot?, now: Date, userScope: CompanionCloudKitUserScope? = nil) throws {
        let result = load(now: now)
        guard result.status != .failure else { return }
        var document = result.document
        let changedScope = userScope != nil && document.removalUserScope != nil && document.removalUserScope != userScope
        if changedScope { document.removedDisplayDates = [:]; document.restoredDisplayDates = [:] }
        let existing = changedScope ? [] : document.removedDisplayIDs ?? []
        let membershipSnapshot = storedSnapshot ?? StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: [])
        for account in document.accounts {
            guard let requested = account.restorationRequestedAt else { continue }
            for report in membershipSnapshot.reports where account.matchesProviderReport(report) && report.status != .failure {
                guard let identity = report.sharedAccountIdentity,
                      identity.userScope == nil || identity.userScope == userScope,
                      membershipSnapshot.snapshot.limits.contains(where: { $0.provider == report.provider && $0.accountID == report.accountID }) else { continue }
                let key = AccountDisplayMetadata.safeID(report.provider, identity.accountID)
                document.restoredDisplayDates = (document.restoredDisplayDates ?? [:]).merging([key: requested]) { max($0, $1) }
            }
        }
        let removed = Set(existing).union(document.pendingRemovedDisplayIDs ?? []).union(ids).filter { key in
            guard let restored = document.restoredDisplayDates?[key] else { return true }
            return (document.removedDisplayDates?[key] ?? Date(timeIntervalSince1970: 0)) >= restored
        }
        guard !removed.isEmpty || changedScope || document != result.document else { return }
        if let userScope { document.removalUserScope = userScope }
        let rows = AccountDisplayMetadata.companion(configuration: document.accounts, stored: membershipSnapshot, now: now, publisherID: document.publisherID)
        let deleted = document.accounts.filter { account in
            if removed.contains(AccountDisplayMetadata.companionConfigurationID(account, publisherID: document.publisherID)) { return true }
            let reports = membershipSnapshot.reports.filter { account.matchesProviderReport($0) }
            if !reports.isEmpty {
                return reports.allSatisfy { report in
                    guard let identity = report.sharedAccountIdentity,
                          identity.userScope == nil || identity.userScope == userScope else { return false }
                    return removed.contains(AccountDisplayMetadata.safeID(report.provider, identity.accountID))
                }
            }
            let accountRows = rows.filter { $0.configurationID == AccountDisplayMetadata.companionConfigurationID(account, publisherID: document.publisherID) }
            return !accountRows.isEmpty && accountRows.allSatisfy { removed.contains($0.id) }
        }
        document.accounts.removeAll { account in deleted.contains { $0.id == account.id } }
        document.removedAccountIDs = Array(Set(document.removedAccountIDs).union(deleted.map(\.id))).sorted()
        document.removedDisplayIDs = removed.sorted()
        if userScope != nil { document.pendingRemovedDisplayIDs = nil }
        if result.status == .unknown && deleted.isEmpty { return }
        if document != result.document { document.updatedAt = now; try save(document) }
    }

    public func receiveSharedAccountIntents(_ shared: CompanionSyncDocument, scope: CompanionCloudKitUserScope, now: Date) throws {
        let result = load(now: now)
        guard result.status != .failure, shared.cloudKitUserScope == scope else { return }
        var document = result.document
        if let previous = document.removalUserScope, previous != scope {
            document.removedDisplayIDs = []
            document.removedDisplayDates = [:]
            document.restoredDisplayDates = [:]
        }
        document.removalUserScope = scope
        document.removedDisplayDates = (document.removedDisplayDates ?? [:]).merging(shared.accountRemovalDates ?? [:]) { max($0, $1) }
        document.restoredDisplayDates = (document.restoredDisplayDates ?? [:]).merging(shared.accountRestorationDates ?? [:]) { max($0, $1) }
        let restored = Set((document.restoredDisplayDates ?? [:]).compactMap { key, date -> String? in
            date > (document.removedDisplayDates?[key] ?? Date(timeIntervalSince1970: 0)) ? key : nil
        })
        document.removedDisplayIDs = (document.removedDisplayIDs ?? []).filter { !restored.contains($0) }
        document.pendingRemovedDisplayIDs = document.pendingRemovedDisplayIDs?.filter { !restored.contains($0) }
        if document != result.document { document.updatedAt = now; try save(document) }
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
        for index in document.accounts.indices where document.accounts[index].connectorKind == .codexRateLimits {
            let account = document.accounts[index]
            if let path = account.codexQuotaPath,
               CodexHomeBinding.isSharedSessionMismatch(account: account,
                   sessions: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath), siblings: document.accounts) {
                document.accounts[index].codexQuotaPath = nil
                changed = true
            }
            if account.codexClient == .codexLab, let authPath = account.authPath {
                let home = URL(fileURLWithPath: NSString(string: authPath).expandingTildeInPath)
                    .deletingLastPathComponent().standardizedFileURL
                let currentMain = ContextPanelLocations.realUserHomeDirectory().appending(path: ".codex").standardizedFileURL
                let accountHomes = ContextPanelLocations.realUserHomeDirectory().appending(path: ".codex-accounts").standardizedFileURL
                if home.path == currentMain.path || home.deletingLastPathComponent().path == accountHomes.path {
                    document.accounts[index].codexClient = .codex
                    changed = true
                }
            }
        }
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
        let hasRetiredSource = document.accounts.contains { $0.isRetiredSource }
        for index in document.accounts.indices where document.accounts[index].isRetiredSource && document.accounts[index].isEnabled {
            document.accounts[index].isEnabled = false
            changed = true
        }
        for var account in defaultDocument(now: now).accounts where hasRetiredSource && account.connectorKind == .codexRateLimits {
            guard !document.removedAccountIDs.contains(account.id) else { continue }
            guard !document.accounts.contains(where: {
                $0.id == account.id || $0.effectiveCodexClient == account.effectiveCodexClient
            }) else { continue }
            account.isEnabled = false
            document.accounts.append(account)
            changed = true
        }
        if document.publisherID == nil && document.accounts.contains(where: { $0.isSharedDefaultMembership }) {
            document.publisherID = UUID().uuidString.lowercased()
            // Retire only old anonymous setup placeholders, never an observed login.
            let empty = StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: [])
            let legacyPlaceholders = AccountDisplayMetadata.companion(configuration: document.accounts.filter { $0.isSharedDefaultMembership }, stored: empty, now: now)
            document.removedDisplayIDs = Array(Set(document.globalRemovedDisplayIDs).union(legacyPlaceholders.map(\.id))).sorted()
        }
        if document.publisherID != nil && document.membershipIdentityVersion != 1 {
            let legacy = document.accounts.filter(\.isSharedDefaultMembership).flatMap { AccountDisplayMetadata.legacyUnidentifiedDisplayIDs($0) }
            document.removedDisplayIDs = Array(Set(document.globalRemovedDisplayIDs).union(legacy)).sorted()
            document.membershipIdentityVersion = 1
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
        requiresBookmarkedAuthFiles: Bool = ContextPanelLocations.isRunningInAppSandbox,
        identityResolver: ProviderAccountIdentityResolver? = nil
    ) -> [any ProviderConnector] {
        var hasGoogleAntigravityConnector = false
        return document.accounts.compactMap { account -> (any ProviderConnector)? in
            guard account.isEnabled, !account.isRetiredSource else { return nil }
            switch account.connectorKind {
            case .codexRateLimits:
                if account.codexQuotaPath != nil {
                    return makeSessionQuotaConnector(account: account, document: document,
                        bookmarkStore: bookmarkStore, requiresBookmark: requiresBookmarkedAuthFiles)
                }
                guard let authPath = account.effectiveAuthPath else { return nil }
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
                            : account.displayName,
                        accountAliases: account.accountAliases ?? [:]
                    )],
                    identityResolver: identityResolver,
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
                    credentialStore: effectiveCredentialStore,
                    identityResolver: identityResolver,
                    identityMaterialStore: identityResolver == nil ? nil : ProviderAccountIdentityMaterialStore(store: ProviderCredentialStore(service: "Context Panel account identity bindings"))
                )
            }
        }
    }

    private static func makeSessionQuotaConnector(
        account: LocalProviderAccountConfiguration,
        document: AccountConfigurationDocument,
        bookmarkStore: SecureFileBookmarkStore?,
        requiresBookmark: Bool
    ) -> CodexSessionQuotaConnector {
        CodexSessionQuotaConnector(account: account) { now in
            let path = NSString(string: account.codexQuotaPath ?? "").expandingTildeInPath
            let read: (URL) throws -> CodexSessionQuotaObservation? = { root in
                guard !CodexHomeBinding.isSharedSessionMismatch(account: account, sessions: root, siblings: document.accounts) else {
                    throw CodexSessionQuotaError.sharedDirectory
                }
                let canonical = root.resolvingSymlinksInPath().standardizedFileURL
                for sibling in document.accounts where sibling.isEnabled && sibling.id != account.id {
                    guard let siblingPath = sibling.codexQuotaPath else { continue }
                    let expanded = NSString(string: siblingPath).expandingTildeInPath
                    let resolved: URL? = try? bookmarkStore?.withResolvedURL(for: expanded) { $0 }
                    let siblingRoot = resolved ?? URL(fileURLWithPath: expanded)
                    if siblingRoot.resolvingSymlinksInPath().standardizedFileURL == canonical {
                        throw CodexSessionQuotaError.sharedDirectory
                    }
                }
                return try CodexSessionQuotaReader.read(rootDirectory: root, now: now)
            }
            if let bookmarkStore, bookmarkStore.hasCurrentBookmark(for: path) {
                // Preserve a nil observation separately from a missing bookmark.
                var observation: CodexSessionQuotaObservation?
                let accessed: Bool? = try bookmarkStore.withResolvedURL(for: path) { root in
                    observation = try read(root)
                    return true
                }
                guard accessed == true else { throw CocoaError(.fileReadNoPermission) }
                return observation
            }
            guard !requiresBookmark else { throw CocoaError(.fileReadNoPermission) }
            return try read(URL(fileURLWithPath: path))
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

public extension AccountConfigurationDocument {
    var globalRemovedDisplayIDs: [String] {
        // Historical local removals are not new global deletion decisions.
        Array(Set(removedDisplayIDs ?? []).union(pendingRemovedDisplayIDs ?? [])).sorted()
    }
}

public extension LocalProviderAccountConfiguration {
    var isSharedDefaultMembership: Bool {
        AccountConfigurationStore.defaultDocument(now: .distantPast).accounts.contains { $0.id == id }
    }
}
