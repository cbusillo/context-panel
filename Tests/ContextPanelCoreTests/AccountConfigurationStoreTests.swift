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

@Test func localProviderAccountConfigurationMatchesGoogleReportsByStableID() throws {
    let account = LocalProviderAccountConfiguration(
        id: "google-antigravity-default",
        provider: .google,
        connectorKind: .geminiCodeAssist,
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
        connectorKind: .geminiCodeAssist,
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

@Test func accountConnectorFactorySkipsDisabledAndReportsGoogleUnavailable() async {
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
            connectorKind: .geminiCodeAssist,
            displayName: "Antigravity"
        ),
        LocalProviderAccountConfiguration(
            id: "claude-disabled",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude",
            isEnabled: false
        ),
    ])

    let connectors = AccountConnectorFactory.connectors(from: document)
    let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(connectors.count == 2)
    #expect(Set(connectors.map(\.provider)) == [.openAI, .google])
    #expect(result.reports.contains { report in
        report.provider == .google
            && report.status == .unknown
            && report.errorMessage?.contains("retired") == true
    })
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
    let google = try #require(document.accounts.first { $0.id == "google-antigravity-default" })

    #expect(code.authPath == "\(expectedHome)/.code/auth_accounts.json")
    #expect(codex.authPath == "\(expectedHome)/.codex/auth.json")
    #expect(codex.isEnabled == false)
    #expect(google.authPath == nil)
    #expect(google.effectiveAuthPath == nil)
    #expect(google.displayName == "Antigravity")
    #expect(code.authPath?.contains("/Library/Containers/") == false)
    #expect(codex.authPath?.contains("/Library/Containers/") == false)
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
