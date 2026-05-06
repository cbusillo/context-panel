import Foundation
import Testing

@testable import ContextPanelCore

@Test func accountConfigurationStoreReturnsDefaultsWhenMissing() throws {
    let store = AccountConfigurationStore(configurationURL: try temporaryDirectory().appending(path: "accounts.json"))

    let result = store.load(now: Date(timeIntervalSince1970: 0))

    #expect(result.status == .unknown)
    #expect(result.document.accounts.count == 3)
    #expect(result.document.accounts.contains { $0.connectorKind == .codexRateLimits && $0.isEnabled })
    #expect(result.document.accounts.contains { $0.connectorKind == .geminiCodeAssist && !$0.isEnabled })
}

@Test func accountConfigurationStoreRoundTripsAccounts() throws {
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

@Test func accountConnectorFactorySkipsDisabledAndMissingSecretEnvironment() {
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

    let withoutGeminiEnvironment = AccountConnectorFactory.connectors(from: document, environment: [:])
    let withGeminiEnvironment = AccountConnectorFactory.connectors(from: document, environment: [
        "GEMINI_ID": "client",
        "GEMINI_SECRET": "secret",
    ])

    #expect(withoutGeminiEnvironment.count == 1)
    #expect(withoutGeminiEnvironment[0].provider == .openAI)
    #expect(withGeminiEnvironment.count == 2)
    #expect(Set(withGeminiEnvironment.map(\.provider)) == [.openAI, .google])
}

@Test func accountConfigurationStoreReportsCorruptFilesAsFailure() throws {
    let url = try temporaryDirectory().appending(path: "accounts.json")
    try Data("nope".utf8).write(to: url)

    let result = AccountConfigurationStore(configurationURL: url).load(now: Date(timeIntervalSince1970: 0))

    #expect(result.status == .failure)
    #expect(result.document.accounts.count == 3)
    #expect(result.errorMessage?.isEmpty == false)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-account-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

