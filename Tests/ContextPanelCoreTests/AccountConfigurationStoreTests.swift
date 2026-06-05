import Foundation
import Testing

@testable import ContextPanelCore

@Test func accountConfigurationStoreReturnsDefaultsWhenMissing() throws {
    let store = AccountConfigurationStore(configurationURL: try temporaryDirectory().appending(path: "accounts.json"))

    let result = store.load(now: Date(timeIntervalSince1970: 0))

    #expect(result.status == .unknown)
    #expect(result.document.accounts.count == 4)
    #expect(result.document.accounts.contains { $0.id == "openai-code-default" && $0.displayName == "Every Code" && $0.isEnabled })
    #expect(result.document.accounts.contains { $0.id == "openai-codex-default" && $0.displayName == "Codex" && !$0.isEnabled })
    #expect(result.document.accounts.contains { $0.connectorKind == .geminiCodeAssist && $0.isEnabled })
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

@Test func localProviderAccountConfigurationMatchesLocalConnectorReportsByResolvedPath() throws {
    let authPath = "/tmp/gemini-oauth.json"
    let account = LocalProviderAccountConfiguration(
        id: "gemini-default",
        provider: .google,
        connectorKind: .geminiCodeAssist,
        displayName: "Gemini",
        authPath: authPath
    )
    let report = StoredProviderReport(
        provider: .google,
        accountID: ConnectorRedactor.localAccountID(provider: .google, path: authPath),
        accountName: "Gemini",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .stale,
        errorMessage: nil
    )

    #expect(account.matchesProviderReport(report))
}

@Test func localProviderAccountConfigurationMatchesExpandedLocalConnectorPaths() throws {
    let expandedPath = "\(ContextPanelLocations.realUserHomeDirectory().path)/.gemini/oauth_creds.json"
    let account = LocalProviderAccountConfiguration(
        id: "gemini-default",
        provider: .google,
        connectorKind: .geminiCodeAssist,
        displayName: "Gemini",
        authPath: "~/.gemini/oauth_creds.json"
    )
    let report = StoredProviderReport(
        provider: .google,
        accountID: ConnectorRedactor.localAccountID(provider: .google, path: expandedPath),
        accountName: "Gemini",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .failure,
        errorMessage: nil
    )

    #expect(account.matchesProviderReport(report))
}

@Test func localProviderAccountConfigurationDoesNotMatchProviderWideReportFromAnotherAccount() throws {
    let account = LocalProviderAccountConfiguration(
        id: "gemini-default",
        provider: .google,
        connectorKind: .geminiCodeAssist,
        displayName: "Gemini",
        authPath: "/tmp/gemini-a.json"
    )
    let report = StoredProviderReport(
        provider: .google,
        accountID: ConnectorRedactor.localAccountID(provider: .google, path: "/tmp/gemini-b.json"),
        accountName: "Other Gemini",
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

@Test func localProviderAccountConfigurationMatchesClaudeLocalStatusReportsByEffectivePath() throws {
    let account = LocalProviderAccountConfiguration(
        id: "claude-local-default",
        provider: .anthropic,
        connectorKind: .claudeLocalStatus,
        displayName: "Claude"
    )
    let report = StoredProviderReport(
        provider: .anthropic,
        accountID: ConnectorRedactor.localAccountID(
            provider: .anthropic,
            path: ContextPanelLocations.claudeStatuslineCacheURL().path
        ),
        accountName: "Claude",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .stale,
        errorMessage: nil
    )

    #expect(account.matchesProviderReport(report))
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

@Test func accountConfigurationStoreMigratesDefaultClaudeLocalStatusToOAuth() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    let store = AccountConfigurationStore(configurationURL: url)
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 10), accounts: [
        LocalProviderAccountConfiguration(
            id: "claude-local-default",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude",
            rateLimitSnapshotPath: "/tmp/statusline-cache.json"
        ),
        LocalProviderAccountConfiguration(
            id: "claude-custom-local",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude Local",
            rateLimitSnapshotPath: "/tmp/custom-statusline-cache.json"
        ),
    ])

    try store.save(document)
    let result = store.load(now: Date(timeIntervalSince1970: 20))

    #expect(result.status == .healthy)
    #expect(result.document.updatedAt == Date(timeIntervalSince1970: 20))
    #expect(result.document.accounts.contains { $0.id == "claude-oauth-default" && $0.connectorKind == .claudeOAuthUsage })
    #expect(!result.document.accounts.contains { $0.id == "claude-local-default" })
    #expect(result.document.accounts.contains { $0.id == "claude-custom-local" && $0.connectorKind == .claudeLocalStatus })
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

@Test func accountConnectorFactorySkipsDisabledAndRequiresGeminiMetadata() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "codex",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            authPath: "/tmp/codex.json"
        ),
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json",
            oauthClientIDEnvironmentName: "GEMINI_ID",
            oauthClientSecretEnvironmentName: "GEMINI_SECRET"
        ),
        LocalProviderAccountConfiguration(
            id: "claude-disabled",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude",
            isEnabled: false
        ),
    ])

    let withoutGeminiMetadata = AccountConnectorFactory.connectors(
        from: document,
        environment: [:],
        geminiMetadataFileLoader: { _ in "" },
        geminiMetadataFileExists: { _ in false },
        antigravityCredentialSource: nil
    )
    let missingMetadataResult = await ProviderConnectorRuntime(connectors: withoutGeminiMetadata).refreshAll(now: Date(timeIntervalSince1970: 0))
    let withGeminiEnvironment = AccountConnectorFactory.connectors(from: document, environment: [
        "GEMINI_ID": "client",
        "GEMINI_SECRET": "secret",
    ])

    #expect(withoutGeminiMetadata.count == 2)
    #expect(Set(withoutGeminiMetadata.map(\.provider)) == [.openAI, .google])
    #expect(missingMetadataResult.reports.contains { $0.provider == .google && $0.status == .failure })
    #expect(withGeminiEnvironment.count == 2)
    #expect(Set(withGeminiEnvironment.map(\.provider)) == [.openAI, .google])
}

@Test func accountConnectorFactoryRequiresGeminiMetadataWhenAntigravityCredentialIsMissing() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json",
            oauthClientIDEnvironmentName: "GEMINI_ID",
            oauthClientSecretEnvironmentName: "GEMINI_SECRET"
        ),
    ])

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: [:],
        useBundledGeminiMetadataFallback: false,
        geminiMetadataFileLoader: { _ in "" },
        geminiMetadataFileExists: { _ in false },
        antigravityCredentialSource: AntigravityKeychainCredentialSource(
            credentialLoader: InMemoryProviderCredentialStore(storage: [:])
        )
    )
    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(connectors.count == 1)
    #expect(result.reports.count == 1)
    #expect(result.reports[0].provider == .google)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("Google OAuth client metadata") == true)
}

@Test func accountConnectorFactoryAllowsMissingGeminiMetadataWhenAntigravityCredentialExists() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json",
            oauthClientIDEnvironmentName: "GEMINI_ID",
            oauthClientSecretEnvironmentName: "GEMINI_SECRET"
        ),
    ])
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"access-secret","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: [:],
        useBundledGeminiMetadataFallback: false,
        geminiMetadataFileLoader: { _ in "" },
        geminiMetadataFileExists: { _ in false },
        antigravityCredentialSource: AntigravityKeychainCredentialSource(
            credentialLoader: InMemoryProviderCredentialStore(storage: [
                AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
            ])
        )
    )

    #expect(connectors.count == 1)
    #expect(connectors[0].provider == .google)
}

@Test func accountConnectorFactoryAllowsMissingGeminiMetadataWhenAntigravityCredentialIsUnreadable() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/missing-gemini.json",
            oauthClientIDEnvironmentName: "GEMINI_ID",
            oauthClientSecretEnvironmentName: "GEMINI_SECRET"
        ),
    ])

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: [:],
        useBundledGeminiMetadataFallback: false,
        geminiMetadataFileLoader: { _ in "" },
        geminiMetadataFileExists: { _ in false },
        geminiMetadataDirectoryLister: { _ in [] },
        antigravityCredentialSource: AntigravityKeychainCredentialSource(
            credentialLoader: ThrowingProviderCredentialStore()
        )
    )
    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(connectors.count == 1)
    #expect(result.reports.count == 1)
    #expect(result.reports[0].provider == .google)
    #expect(result.reports[0].status == .unknown)
    #expect(result.reports[0].limits.isEmpty)
    #expect(result.reports[0].errorMessage?.contains("Open Antigravity") == true)
    #expect(result.reports[0].errorMessage?.contains("OAuth client metadata") != true)
}

@Test func accountConnectorFactoryDisablesLegacyGeminiFallbackForForegroundOnlyAntigravityRefresh() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Google",
            authPath: "/tmp/gemini.json"
        ),
    ])

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: [
            "GEMINI_OAUTH_CLIENT_ID": "legacy-client",
            "GEMINI_OAUTH_CLIENT_SECRET": "legacy-secret",
        ],
        geminiMetadataFileExists: { _ in false },
        antigravityCredentialSource: nil,
        allowsLegacyGeminiOAuth: false
    )
    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(connectors.count == 1)
    #expect(result.reports.count == 1)
    #expect(result.reports[0].provider == .google)
    #expect(result.reports[0].status == .unknown)
    #expect(result.reports[0].limits.isEmpty)
    #expect(result.reports[0].errorMessage?.contains("foreground refresh") == true)
}

@Test func accountConnectorFactoryFallsBackToGeminiDiscoveryForPartialMetadataEnvironment() async {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json",
            oauthClientIDEnvironmentName: "GEMINI_ID",
            oauthClientSecretEnvironmentName: "GEMINI_SECRET"
        ),
    ])

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: ["GEMINI_ID": "client"],
        useBundledGeminiMetadataFallback: false,
        geminiMetadataFileLoader: { _ in #"var OAUTH_CLIENT_ID = "discovered"; var OAUTH_CLIENT_SECRET = "secret";"# },
        geminiMetadataFileExists: { _ in true },
        geminiMetadataDirectoryLister: { _ in [] },
        antigravityCredentialSource: nil
    )

    #expect(connectors.count == 1)
    #expect(connectors[0].provider == .google)
}

@Test func accountConnectorFactoryCanDiscoverGeminiMetadataFromInstalledCLI() {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json"
        )
    ])

    let source = #"""
    var OAUTH_CLIENT_ID = "client-id.apps.googleusercontent.com";
    var OAUTH_CLIENT_SECRET = "client-secret";
    """#
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: ["GEMINI_CLI_BUNDLE_PATH": "/tmp/gemini-bundle.js"],
        geminiMetadataFileLoader: { _ in source },
        geminiMetadataFileExists: { _ in true },
        geminiMetadataDirectoryLister: { _ in [] },
        antigravityCredentialSource: nil
    )

    #expect(connectors.count == 1)
    #expect(connectors[0].provider == .google)
}

@Test func accountConnectorFactoryUsesGeminiCommandPathForMetadataDiscovery() {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json",
            commandPath: "/Users/test/.local/bin/gemini"
        )
    ])

    let source = #"""
    var OAUTH_CLIENT_ID = "client-id.apps.googleusercontent.com";
    var OAUTH_CLIENT_SECRET = "client-secret";
    """#
    let connectors = AccountConnectorFactory.connectors(
        from: document,
        environment: [:],
        useBundledGeminiMetadataFallback: false,
        geminiMetadataFileLoader: { _ in source },
        geminiMetadataFileExists: { path in
            path == "/Users/test/.local/bin/gemini"
                || path == "/Users/test/.local/bin/chunk.js"
        },
        geminiMetadataDirectoryLister: { root in
            root == "/Users/test/.local/bin" ? ["\(root)/chunk.js"] : []
        },
        antigravityCredentialSource: nil
    )

    #expect(connectors.count == 1)
    #expect(connectors[0].provider == .google)
}

@Test func accountConnectorFactoryUsesCachedGeminiMetadataInSandbox() {
    let document = AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 0), accounts: [
        LocalProviderAccountConfiguration(
            id: "gemini",
            provider: .google,
            connectorKind: .geminiCodeAssist,
            displayName: "Gemini",
            authPath: "/tmp/gemini.json"
        )
    ])
    let metadata = GeminiOAuthClientMetadata(clientID: "cached-client", clientSecret: "cached-secret")
    let credentialStore = InMemoryProviderCredentialStore(storage: [
        GeminiOAuthClientMetadata.credentialAccountID(for: "gemini"): try! JSONEncoder().encode(metadata),
    ])

    let connectors = AccountConnectorFactory.connectors(
        from: document,
        credentialStore: credentialStore,
        requiresBookmarkedAuthFiles: true,
        environment: [:],
        useBundledGeminiMetadataFallback: false,
        geminiMetadataFileExists: { _ in false },
        geminiMetadataDirectoryLister: { _ in [] },
        antigravityCredentialSource: nil
    )

    #expect(connectors.count == 1)
    #expect(connectors[0].provider == .google)
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

@Test func defaultAccountPathsUseRealUserHome() throws {
    let document = AccountConfigurationStore.defaultDocument(now: Date(timeIntervalSince1970: 0))
    let expectedHome = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })

    let code = try #require(document.accounts.first { $0.id == "openai-code-default" })
    let codex = try #require(document.accounts.first { $0.id == "openai-codex-default" })
    let gemini = try #require(document.accounts.first { $0.id == "gemini-code-assist-default" })

    #expect(code.authPath == "\(expectedHome)/.code/auth_accounts.json")
    #expect(codex.authPath == "\(expectedHome)/.codex/auth.json")
    #expect(codex.isEnabled == false)
    #expect(gemini.authPath == "\(expectedHome)/.gemini/oauth_creds.json")
    #expect(code.authPath?.contains("/Library/Containers/") == false)
    #expect(codex.authPath?.contains("/Library/Containers/") == false)
    #expect(gemini.authPath?.contains("/Library/Containers/") == false)
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
