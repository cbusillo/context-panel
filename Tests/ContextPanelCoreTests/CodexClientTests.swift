import Foundation
import Darwin
import Testing

@testable import ContextPanelCore

@Test func codexClientInfersDistinctClientHomesAndPrioritizesLabPrefix() {
    let cases: [(String?, CodexClient?)] = [
        ("/Users/example/.codex/auth.json", .codex),
        ("/Users/example/.codex-work/auth_accounts.json", .codex),
        ("/Users/example/.codex-lab/auth_accounts.json", .codexLab),
        ("/Users/example/.codex-lab-work/auth.json", .codexLab),
        ("/Users/example/.code/auth_accounts.json", .everyCode),
        ("/Users/example/.code-work/auth.json", .everyCode),
        ("/Users/example/arbitrary/auth.json", nil),
        (nil, nil),
    ]

    for (path, expected) in cases {
        #expect(CodexClient.inferred(fromAuthPath: path) == expected)
    }
}

@Test func codexClientHomesHonorOnlyTheirOwnAbsoluteEnvironmentOverrides() {
    let userHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = [
        "CODEX_HOME": "/Volumes/work/Codex",
        "CODEX_LAB_HOME": "/Volumes/work/Lab",
        "CODE_HOME": "/Volumes/work/Legacy",
        "HOME": "/sandbox/container",
    ]

    #expect(CodexClient.codex.homeDirectory(environment: environment, userHome: userHome).path == "/Volumes/work/Codex")
    #expect(CodexClient.codexLab.homeDirectory(environment: environment, userHome: userHome).path == "/Volumes/work/Lab")
    #expect(CodexClient.everyCode.homeDirectory(environment: environment, userHome: userHome).path == "/Volumes/work/Legacy")

    let cases: [(CodexClient, String, String)] = [
        (.codex, "CODEX_HOME", ".codex"),
        (.codexLab, "CODEX_LAB_HOME", ".codex-lab"),
        (.everyCode, "CODE_HOME", ".code"),
    ]
    for (client, key, folder) in cases {
        for overrides in [[:], ["HOME": "/sandbox/container"], [key: "relative/path"], [key: "~/custom"], [key: ""]] {
            #expect(client.homeDirectory(environment: overrides, userHome: userHome).path == "/Users/example/\(folder)")
        }
    }
    #expect(CodexClient.codexLab.homeDirectory(environment: ["CODEX_HOME": "/Volumes/work/Codex"], userHome: userHome).path == "/Users/example/.codex-lab")
}

@Test func explicitCodexClientMetadataSelectsTelemetryAtArbitraryAuthPaths() throws {
    let cases: [(CodexClient, String)] = [(.codex, "sessions"), (.codexLab, "sessions")]
    for (client, folder) in cases {
        let account = LocalProviderAccountConfiguration(
            id: "custom", provider: .openAI, connectorKind: .codexRateLimits,
            displayName: "Custom", authPath: "/Volumes/work/client-login/auth.json", codexClient: client
        )

        #expect(account.effectiveCodexClient == client)
        #expect(account.promptCacheDirectory?.path == "/Volumes/work/client-login/\(folder)")
        #expect(try JSONDecoder().decode(LocalProviderAccountConfiguration.self, from: JSONEncoder().encode(account)) == account)
    }
}

@Test func explicitCodexClientMetadataOverridesPathInference() {
    let account = LocalProviderAccountConfiguration(
        id: "custom", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Custom", authPath: "/Users/example/.codex/auth.json", codexClient: .codexLab
    )

    #expect(account.effectiveCodexClient == .codexLab)
    #expect(account.promptCacheDirectory?.path == "/Users/example/.codex/sessions")
}

@Test func legacyConfigurationDecodesWithoutClientMetadataAndInfersTelemetry() throws {
    let data = Data(#"""
    {"id":"legacy","provider":"openai","connectorKind":"codexRateLimits","displayName":"Legacy","isEnabled":false,"authPath":"/Users/example/.codex-lab-work/auth_accounts.json"}
    """#.utf8)

    let account = try JSONDecoder().decode(LocalProviderAccountConfiguration.self, from: data)

    #expect(account.codexClient == nil)
    #expect(account.effectiveCodexClient == .codexLab)
    #expect(account.promptCacheDirectory?.path == "/Users/example/.codex-lab-work/sessions")
    #expect(!account.isEnabled)
}

@Test func codexClientTelemetryRequiresKnownSourceAndAuthPath() {
    let unknown = LocalProviderAccountConfiguration(
        id: "unknown", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Unknown", authPath: "/Volumes/custom/auth.json"
    )
    var missingPath = unknown
    missingPath.codexClient = .codex
    missingPath.authPath = nil
    let claude = LocalProviderAccountConfiguration(
        id: "claude", provider: .anthropic, connectorKind: .claudeOAuthUsage,
        displayName: "Claude", authPath: "/Users/example/.codex/auth.json", codexClient: .codex
    )

    #expect(unknown.effectiveCodexClient == nil)
    #expect(unknown.promptCacheDirectory == nil)
    #expect(!unknown.supportsPromptCacheTelemetry)
    #expect(missingPath.promptCacheDirectory == nil)
    #expect(claude.effectiveCodexClient == nil)
    #expect(claude.promptCacheDirectory == nil)
}

@Test func codexClientDefaultHomesUseLoginHomeOutsideSandboxContainer() throws {
    let user = try #require(getpwuid(getuid()))
    let home = URL(fileURLWithPath: String(cString: user.pointee.pw_dir))
    for (client, folder) in [(CodexClient.codex, ".codex"), (.codexLab, ".codex-lab"), (.everyCode, ".code")] {
        let actual = client.homeDirectory(environment: ["HOME": "/sandbox/Library/Containers/example"])
        #expect(actual == home.appending(path: folder, directoryHint: .isDirectory))
        #expect(!actual.path.contains("/Library/Containers/"))
    }
}

@Test func retiredClientRemainsDecodableButHasNoTelemetrySource() throws {
    let account = LocalProviderAccountConfiguration(
        id: "retained", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Old account", authPath: "/Users/example/custom/auth.json", codexClient: .everyCode
    )
    let decoded = try JSONDecoder().decode(LocalProviderAccountConfiguration.self, from: JSONEncoder().encode(account))
    #expect(decoded == account)
    #expect(decoded.isRetiredSource)
    #expect(decoded.promptCacheDirectory == nil)
    #expect(!decoded.supportsPromptCacheTelemetry)
    #expect(ContextPanelLocations.promptCacheUsageDirectory(forAuthPath: "/Users/example/.code/auth.json") == nil)
}

@Test func codexClientExplicitModernMetadataAtLegacyPathStaysActive() {
    for client in [CodexClient.codex, .codexLab] {
        let account = LocalProviderAccountConfiguration(
            id: "openai-code-default", provider: .openAI, connectorKind: .codexRateLimits,
            displayName: "Repointed", authPath: "/Users/example/.code/auth.json", codexClient: client
        )
        #expect(!account.isRetiredSource)
        #expect(account.promptCacheDirectory != nil)
    }
}

@Test func settingsAccountsHideRetiredSourcesAndPutAllLabAccountsFirstStably() {
    func account(_ id: String, _ client: CodexClient) -> LocalProviderAccountConfiguration {
        LocalProviderAccountConfiguration(id: id, provider: .openAI, connectorKind: .codexRateLimits,
                                         displayName: id, codexClient: client)
    }
    let document = AccountConfigurationDocument(updatedAt: .distantPast, accounts: [
        account("codex", .codex), account("old", .everyCode), account("lab-work", .codexLab),
        account("codex-work", .codex), account("lab", .codexLab),
    ])
    #expect(document.settingsAccounts.map(\.id) == ["lab-work", "lab", "codex", "codex-work"])
    #expect(document.accounts.map(\.id) == ["codex", "old", "lab-work", "codex-work", "lab"])
}
