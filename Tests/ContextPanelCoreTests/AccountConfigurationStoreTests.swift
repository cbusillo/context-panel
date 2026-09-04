import Foundation
import Testing

@testable import ContextPanelCore

@Test func accountConfigurationStoreReturnsDefaultsWhenMissing() throws {
    let store = AccountConfigurationStore(configurationURL: try temporaryDirectory().appending(path: "accounts.json"))

    let result = store.load(now: Date(timeIntervalSince1970: 0))

    #expect(result.status == .unknown)
    #expect(result.document.accounts.count == 4)
    #expect(!result.document.accounts.contains { $0.effectiveCodexClient == .everyCode })
    #expect(result.document.accounts.contains { $0.id == "openai-codex-default" && $0.displayName == "Codex" && $0.isEnabled && $0.codexClient == .codex })
    #expect(result.document.accounts.contains { $0.id == "openai-codex-lab-default" && $0.displayName == "Codex Lab" && !$0.isEnabled && $0.codexClient == .codexLab })
    #expect(result.document.accounts.contains { $0.connectorKind == .googleAntigravityQuota && $0.isEnabled })
    #expect(result.document.accounts.contains { $0.connectorKind == .claudeOAuthUsage && $0.effectiveAuthPath == nil })
}

@Test func localProviderAccountConfigurationMatchesReportsByConfiguredAccountID() throws {
    let account = LocalProviderAccountConfiguration(
        id: "openai-code-default",
        provider: .openAI,
        connectorKind: .codexRateLimits,
        displayName: "Every Code",
        authPath: "/tmp/code-auth.json"
    )
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:user-a"),
        configuredAccountID: "openai-code-default",
        accountName: "Every Code",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .failure,
        errorMessage: nil
    )

    #expect(account.matchesProviderReport(report))
}

@Test func localProviderAccountConfigurationMatchesGoogleReportsByStableID() throws {
    let account = LocalProviderAccountConfiguration(
        id: "google-antigravity-default",
        provider: .google,
        connectorKind: .googleAntigravityQuota,
        displayName: "Antigravity"
    )
    let report = StoredProviderReport(
        provider: .google,
        accountID: ConnectorRedactor.localAccountID(provider: .google, stableID: "google-antigravity-default"),
        accountName: "Antigravity",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .stale,
        errorMessage: nil
    )

    #expect(account.matchesProviderReport(report))
}

@Test func localProviderAccountConfigurationDoesNotMatchProviderWideReportFromAnotherAccount() throws {
    let account = LocalProviderAccountConfiguration(
        id: "google-antigravity-default",
        provider: .google,
        connectorKind: .googleAntigravityQuota,
        displayName: "Antigravity"
    )
    let report = StoredProviderReport(
        provider: .google,
        accountID: ConnectorRedactor.localAccountID(provider: .google, path: "/tmp/gemini-b.json"),
        accountName: "Other Google",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .failure,
        errorMessage: nil
    )

    #expect(!account.matchesProviderReport(report))
}

@Test func localProviderAccountConfigurationUsesConfiguredAccountIDAsAuthoritative() throws {
    let account = LocalProviderAccountConfiguration(
        id: "openai-code-default",
        provider: .openAI,
        connectorKind: .codexRateLimits,
        displayName: "Every Code",
        authPath: "/tmp/code-auth.json"
    )
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: "openai-code-default",
        configuredAccountID: "openai-codex-default",
        accountName: "Codex",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .failure,
        errorMessage: nil
    )

    #expect(!account.matchesProviderReport(report))
}

@Test func localProviderAccountConfigurationMatchesClaudeOAuthReportsByRedactedStableID() throws {
    let account = LocalProviderAccountConfiguration(
        id: "claude-oauth-default",
        provider: .anthropic,
        connectorKind: .claudeOAuthUsage,
        displayName: "Claude"
    )
    let report = StoredProviderReport(
        provider: .anthropic,
        accountID: ConnectorRedactor.localAccountID(provider: .anthropic, stableID: "claude-oauth-default"),
        accountName: "Claude",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .failure,
        errorMessage: nil
    )

    #expect(account.matchesProviderReport(report))
}

@Test func accountConfigurationStorePreservesCustomAccountsWithoutAddingDefaults() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(configurationURL: url)
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI A",
            authPath: "/tmp/codex-a.json"
        )
    ])

    try store.save(document)
    let result = store.load()

    #expect(result.status == .healthy)
    #expect(result.document == document)
}

@Test(arguments: [true, false])
func accountConfigurationStoreAddsDisabledClientChoicesWithoutRepointingLegacyAccount(legacyEnabled: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let legacy = LocalProviderAccountConfiguration(
        id: "openai-code-default",
        provider: .openAI,
        connectorKind: .codexRateLimits,
        displayName: "My retained account",
        isEnabled: legacyEnabled,
        authPath: "/Users/example/.code-work/auth_accounts.json"
    )
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [legacy])
    try store.save(document)

    let migrated = store.load(now: Date(timeIntervalSince1970: 20))
    let preserved = try #require(migrated.document.accounts.first { $0.id == legacy.id })

    #expect(migrated.status == .healthy)
    #expect(migrated.document.schemaVersion == 1)
    #expect(migrated.document.updatedAt == Date(timeIntervalSince1970: 20))
    // Credential keys use the configured ID; bookmark keys use the auth path.
    #expect(preserved == legacy)
    #expect(preserved.providerReportAccountIDs == legacy.providerReportAccountIDs)
    #expect(preserved.codexClient == nil)
    #expect(migrated.document.accounts.map(\.id) == ["openai-code-default", "openai-codex-default", "openai-codex-lab-default"])
    #expect(migrated.document.accounts.dropFirst().allSatisfy { !$0.isEnabled })
    #expect(migrated.document.accounts.dropFirst().map(\.effectiveCodexClient) == [.codex, .codexLab])

    let savedBytes = try Data(contentsOf: store.configurationURL)
    let reloaded = store.load(now: Date(timeIntervalSince1970: 30))

    #expect(reloaded.document == migrated.document)
    #expect(try Data(contentsOf: store.configurationURL) == savedBytes)
    #expect(Set(reloaded.document.accounts.map(\.id)).count == 3)
}

@Test func accountConfigurationStorePreservesExistingDisabledAndCustomClientChoices() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-code-default", provider: .openAI, connectorKind: .codexRateLimits,
            displayName: "Every Code", authPath: "/Users/example/.code/auth_accounts.json"
        ),
        LocalProviderAccountConfiguration(
            id: "openai-codex-default", provider: .openAI, connectorKind: .codexRateLimits,
            displayName: "Disabled Codex", isEnabled: false, authPath: "/Users/example/.codex/auth.json"
        ),
        LocalProviderAccountConfiguration(
            id: "custom-lab", provider: .openAI, connectorKind: .codexRateLimits,
            displayName: "Work Lab", isEnabled: false, authPath: "/Users/example/work-login/auth.json", codexClient: .codexLab
        ),
    ])
    try store.save(document)

    let result = store.load(now: Date(timeIntervalSince1970: 20))

    #expect(result.status == .healthy)
    #expect(result.document == document)
    #expect(!result.document.accounts.contains { $0.id == "openai-codex-lab-default" })
}

@Test(arguments: [
    ("custom-every-code", "/Users/example/.code/auth_accounts.json"),
    ("openai-code-default", "/Users/example/custom/auth_accounts.json"),
    ("openai-code-default", "/Users/example/.codex-lab/auth_accounts.json"),
])
func accountConfigurationStoreOnlyAddsChoicesForRecognizedLegacyDefault(id: String, authPath: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: id, provider: .openAI, connectorKind: .codexRateLimits,
            displayName: "Custom account", authPath: authPath
        ),
    ])
    try store.save(document)

    #expect(store.load(now: Date(timeIntervalSince1970: 20)).document == document)
}

@Test func accountConfigurationStoreMigratesClaudeLocalStatusToOAuth() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(configurationURL: url)
    let legacyJSON = #"""
    {
      "schemaVersion": 1,
      "updatedAt": "1970-01-01T00:00:10Z",
      "accounts": [
        {
          "id": "claude-local-default",
          "provider": "anthropic",
          "connectorKind": "claudeLocalStatus",
          "displayName": "Claude",
          "isEnabled": true,
          "rateLimitSnapshotPath": "/tmp/statusline-cache.json"
        },
        {
          "id": "claude-custom-local",
          "provider": "anthropic",
          "connectorKind": "claudeLocalStatus",
          "displayName": "Claude Local",
          "isEnabled": true,
          "rateLimitSnapshotPath": "/tmp/custom-statusline-cache.json"
        }
      ]
    }
    """#
    try Data(legacyJSON.utf8).write(to: url)
    let result = store.load(now: Date(timeIntervalSince1970: 20))

    #expect(result.status == .healthy)
    #expect(result.document.updatedAt == Date(timeIntervalSince1970: 20))
    #expect(result.document.accounts.contains { $0.id == "claude-oauth-default" && $0.connectorKind == .claudeOAuthUsage })
    #expect(!result.document.accounts.contains { $0.id == "claude-local-default" })
    #expect(result.document.accounts.contains { $0.id == "claude-custom-local" && $0.connectorKind == .claudeOAuthUsage })
}

@Test func accountConfigurationStoreMigratesRetiredGeminiDefaultToAntigravity() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(configurationURL: url)
    let legacyJSON = """
    {
      "schemaVersion": 1,
      "updatedAt": "1970-01-01T00:00:10Z",
      "accounts": [
        {
          "id": "gemini-code-assist-default",
          "provider": "google",
          "connectorKind": "geminiCodeAssist",
          "displayName": "Gemini",
          "isEnabled": true,
          "authPath": "/Users/example/.gemini/oauth_creds.json",
          "commandPath": "/opt/homebrew/bin/gemini"
        },
        {
          "id": "google-custom",
          "provider": "google",
          "connectorKind": "googleAntigravityQuota",
          "displayName": "Other Google",
          "isEnabled": false
        }
      ]
    }
    """
    let legacyData = try #require(legacyJSON.data(using: .utf8))
    try legacyData.write(to: url)
    let result = store.load(now: Date(timeIntervalSince1970: 20))

    let migrated = try #require(result.document.accounts.first { $0.id == "google-antigravity-default" })
    #expect(result.status == .healthy)
    #expect(result.document.updatedAt == Date(timeIntervalSince1970: 20))
    #expect(migrated.provider == .google)
    #expect(migrated.connectorKind == .googleAntigravityQuota)
    #expect(migrated.displayName == "Antigravity")
    #expect(migrated.authPath == nil)
    #expect(migrated.commandPath == nil)
    #expect(!result.document.accounts.contains { $0.id == "gemini-code-assist-default" })
    #expect(result.document.accounts.contains { $0.id == "google-custom" && !$0.isEnabled })

    let savedJSON = try String(contentsOf: url, encoding: .utf8)
    #expect(savedJSON.contains("googleAntigravityQuota"))
    #expect(!savedJSON.contains("geminiCodeAssist"))
}

@Test func accountConfigurationStoreNormalizesLegacyGoogleConnectorRawValue() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(configurationURL: url)
    let legacyJSON = """
    {
      "schemaVersion": 1,
      "updatedAt": "1970-01-01T00:00:10Z",
      "accounts": [
        {
          "id": "google-antigravity-default",
          "provider": "google",
          "connectorKind": "geminiCodeAssist",
          "displayName": "Antigravity",
          "isEnabled": true
        }
      ]
    }
    """
    let legacyData = try #require(legacyJSON.data(using: .utf8))
    try legacyData.write(to: url)

    let result = store.load(now: Date(timeIntervalSince1970: 20))

    let account = try #require(result.document.accounts.first)
    #expect(result.status == .healthy)
    #expect(result.document.updatedAt == Date(timeIntervalSince1970: 10))
    #expect(account.id == "google-antigravity-default")
    #expect(account.connectorKind == .googleAntigravityQuota)

    let savedJSON = try String(contentsOf: url, encoding: .utf8)
    #expect(savedJSON.contains("googleAntigravityQuota"))
    #expect(!savedJSON.contains("geminiCodeAssist"))
}

@Test func accountConfigurationStorePreservesCustomNameWhenMigratingRetiredGeminiDefault() throws {
    let store = AccountConfigurationStore(configurationURL: try temporaryDirectory().appending(path: "accounts.json"))
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini-code-assist-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Work Google"
        ),
    ])

    try store.save(document)
    let result = store.load(now: Date(timeIntervalSince1970: 20))

    let migrated = try #require(result.document.accounts.first { $0.id == "google-antigravity-default" })
    #expect(migrated.displayName == "Work Google")
}

@Test func accountConfigurationStoreLoadsFallbackWhenPrimaryIsMissing() throws {
    let primaryURL = try temporaryDirectory().appending(path: "group/accounts.json")
    let fallbackURL = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(
        configurationURL: primaryURL,
        fallbackConfigurationURL: fallbackURL
    )
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI A",
            authPath: "/tmp/codex-a.json"
        )
    ])

    try AccountConfigurationStore(configurationURL: fallbackURL).save(document)

    let result = store.load()
    #expect(result.status == .healthy)
    #expect(result.document.accounts.contains(document.accounts[0]))
    #expect(!result.document.accounts.contains { $0.id == "openai-code-default" })
    #expect(AccountConfigurationStore(configurationURL: primaryURL).load().document.accounts.contains(document.accounts[0]))
}

@Test func accountConfigurationStorePrefersPrimaryOverFallback() throws {
    let primaryURL = try temporaryDirectory().appending(path: "group/accounts.json")
    let fallbackURL = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(
        configurationURL: primaryURL,
        fallbackConfigurationURL: fallbackURL
    )
    let primary = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 20), accounts: [
        LocalProviderAccountConfiguration(
            id: "primary",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Primary",
            authPath: "/tmp/primary.json"
        )
    ])
    let fallback = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: "fallback",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Fallback",
            authPath: "/tmp/fallback.json"
        )
    ])

    try AccountConfigurationStore(configurationURL: primaryURL).save(primary)
    try AccountConfigurationStore(configurationURL: fallbackURL).save(fallback)

    let result = store.load()
    #expect(result.status == .healthy)
    #expect(result.document.accounts.contains(primary.accounts[0]))
    #expect(!result.document.accounts.contains(fallback.accounts[0]))
    #expect(!result.document.accounts.contains { $0.id == "openai-code-default" })
}

@Test func accountConnectorFactoryCreatesLiveProviderConnectors() async throws {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: "/tmp/codex.json"
        ),
        LocalProviderAccountConfiguration(
            id: "google",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity"
        ),
        LocalProviderAccountConfiguration(
            id: "claude-local",
            provider: .anthropic,
            connectorKind: .claudeOAuthUsage,
            displayName: "Claude",
            isEnabled: true
        ),
    ])

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        credentialStore: InMemoryProviderCredentialStore(storage: [:]),
        googleAntigravitySnapshotLoader: GoogleAntigravityStatusLineSnapshotStore(
            snapshotURL: try temporaryDirectory()
                .appending(path: "Provider Inputs", directoryHint: .isDirectory)
                .appending(path: "missing-antigravity.json")
        )
    )
    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(connectors.count == 3)
    #expect(Set(connectors.map(\.provider)) == [.openAI, .google, .anthropic])
    #expect(connectors.contains { $0 is GoogleAntigravityQuotaConnector })
    #expect(connectors.contains { $0 is ClaudeOAuthUsageConnector })
    #expect(result.reports.contains { report in
        report.provider == .anthropic
            && report.status == .failure
            && report.errorMessage == "Claude is not connected. Sign in to Claude from Settings."
    })
    #expect(result.reports.contains { report in
        report.provider == .google
            && report.status == .unknown
            && report.errorMessage?.contains("bridge setup is required") == true
    })
}

@Test func accountConnectorFactoryUsesAntigravitySnapshotInsteadOfAppCredentialStoreForGoogle() async throws {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "google-antigravity-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity"
        ),
    ])
    let snapshotStore = GoogleAntigravityStatusLineSnapshotStore(
        snapshotURL: try temporaryDirectory().appending(path: "antigravity-status-line.json")
    )
    try snapshotStore.save(GoogleAntigravityStatusLineSnapshot(
        observedAt: Date(timeIntervalSince1970: 0),
        buckets: [GoogleAntigravityStatusLineBucket(
            id: "gemini-weekly",
            remainingFraction: 0.8,
            resetsAt: Date(timeIntervalSince1970: 3_600)
        )]
    ))
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        credentialStore: InMemoryProviderCredentialStore(storage: [:]),
        googleAntigravitySnapshotLoader: snapshotStore,
        requiresBookmarkedAuthFiles: false
    )

    let report = try #require(await ProviderConnectorRuntime(connectors: connectors)
        .refreshAll(now: Date(timeIntervalSince1970: 0))
        .reports
        .first { $0.provider == .google })

    #expect(report.status == .healthy)
    #expect(report.limits.map(\.used) == [20])
    #expect(report.errorMessage == nil)
}

@Test func accountConnectorFactoryUsesOneActiveAntigravityAccountForSingletonBridge() async throws {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "google-antigravity-primary",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity Primary"
        ),
        LocalProviderAccountConfiguration(
            id: "google-antigravity-secondary",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity Secondary"
        ),
    ])
    let snapshotStore = GoogleAntigravityStatusLineSnapshotStore(
        snapshotURL: try temporaryDirectory().appending(path: "antigravity-status-line.json")
    )
    try snapshotStore.save(GoogleAntigravityStatusLineSnapshot(
        observedAt: Date(timeIntervalSince1970: 0),
        buckets: [GoogleAntigravityStatusLineBucket(
            id: "gemini-weekly",
            remainingFraction: 0.8,
            resetsAt: Date(timeIntervalSince1970: 3_600)
        )]
    ))

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        googleAntigravitySnapshotLoader: snapshotStore,
        requiresBookmarkedAuthFiles: false
    )
    let reports = await ProviderConnectorRuntime(connectors: connectors)
        .refreshAll(now: Date(timeIntervalSince1970: 0))
        .reports

    #expect(connectors.count == 1)
    #expect(reports.map(\.configuredAccountID) == ["google-antigravity-primary"])
    #expect(reports.map(\.accountName) == ["Antigravity Primary"])
}

@Test func sandboxedAuthLoaderRequiresSecurityScopedBookmark() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: "/tmp/context-panel-missing-bookmark.json"
        )
    ])
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        requiresBookmarkedAuthFiles: true
    )

    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.snapshot.limits.isEmpty)
    #expect(result.reports[0].errorMessage?.contains("permission") == true)
}

@Test func sandboxedAuthLoaderRejectsUnreadableStoredBookmark() async throws {
    let root = try temporaryDirectory()
    let authURL = root.appending(path: "auth_accounts.json")
    let bookmarkStore = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))
    try Data(#"{}"#.utf8).write(to: authURL)
    try bookmarkStore.createAndStoreBookmark(for: authURL, path: authURL.path)
    try FileManager.default.removeItem(at: authURL)
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: authURL.path
        )
    ])
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        bookmarkStore: bookmarkStore,
        requiresBookmarkedAuthFiles: true
    )

    let result = await ProviderConnectorRuntime(connectors: connectors)
        .refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.snapshot.limits.isEmpty)
    #expect(result.reports[0].errorMessage?.contains("permission") == true)
}

@Test func sandboxedAuthLoaderPrefersImportedCredentialStore() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: "/tmp/context-panel-missing-bookmark.json"
        )
    ])
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        credentialStore: InMemoryProviderCredentialStore(storage: ["codex": Data(#"{}"#.utf8)]),
        requiresBookmarkedAuthFiles: true
    )

    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].errorMessage?.contains("permission") != true)
    #expect(result.reports[0].errorMessage?.contains("token auth") == true)
}

@Test func sandboxedAuthLoaderFallsBackWhenCredentialStoreThrows() async throws {
    let authURL = try temporaryDirectory().appending(path: "auth_accounts.json")
    try Data(#"{}"#.utf8).write(to: authURL)
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: authURL.path
        )
    ])
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        credentialStore: ThrowingProviderCredentialStore(),
        requiresBookmarkedAuthFiles: false
    )

    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].errorMessage?.contains("Keychain") != true)
    #expect(result.reports[0].errorMessage?.contains("token auth") == true)
}

@Test func authLoaderCanReadDirectlyWhenBookmarksAreOptional() async throws {
    let authURL = try temporaryDirectory().appending(path: "codex.json")
    try Data(#"{}"#.utf8).write(to: authURL)
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: authURL.path
        )
    ])
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        requiresBookmarkedAuthFiles: false
    )

    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].errorMessage?.contains("permission") != true)
    #expect(result.reports[0].errorMessage?.contains("token auth") == true)
}

@Test func localAccountConfigurationUsesConfiguredCodexAuthPathWithoutProbing() throws {
    let authURL = try temporaryDirectory().appending(path: "auth_accounts.json")
    let account = LocalProviderAccountConfiguration(
        id: "codex",
        provider: .openAI,
        connectorKind: .codexRateLimits,
        displayName: "Codex",
        authPath: authURL.path
    )

    #expect(account.effectiveAuthPath == authURL.path)
}

@Test func defaultAccountPathsUseConfiguredClientHomes() throws {
    let document = AccountConfigurationStore.defaultDocument(now: Date(timeIntervalSince1970: 0))

    let lab = try #require(document.accounts.first { $0.id == "openai-codex-lab-default" })
    let codex = try #require(document.accounts.first { $0.id == "openai-codex-default" })
    let google = try #require(document.accounts.first { $0.id == "google-antigravity-default" })

    #expect(lab.authPath == CodexClient.codexLab.homeDirectory().appending(path: "auth_accounts.json").path)
    #expect(codex.authPath == CodexClient.codex.homeDirectory().appending(path: "auth.json").path)
    #expect(lab.isEnabled == false)
    #expect(codex.isEnabled)
    #expect(google.authPath == nil)
    #expect(google.effectiveAuthPath == nil)
    #expect(google.displayName == "Antigravity")
}

@Test func accountConfigurationStoreReportsCorruptFilesAsFailure() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    try Data("nope".utf8).write(to: url)

    let result = AccountConfigurationStore(configurationURL: url).load(now: Date(timeIntervalSince1970: 0))

    #expect(result.status == .failure)
    #expect(result.document.accounts.count == 4)
    #expect(result.errorMessage?.isEmpty == false)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-account-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct ThrowingProviderCredentialStore: ProviderCredentialStoring {
    func load(accountID: String) throws -> Data? {
        throw ProviderCredentialStore.StoreError.unhandledStatus(errSecInteractionNotAllowed)
    }

    func save(_ data: Data, accountID: String) throws {
        throw ProviderCredentialStore.StoreError.unhandledStatus(errSecInteractionNotAllowed)
    }
}
