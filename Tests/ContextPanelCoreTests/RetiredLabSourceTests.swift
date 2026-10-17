import Foundation
import Testing
@testable import ContextPanelCore

@Test(arguments: [true, false])
func retiredLabConfigurationKeepsRecordsButCannotCollect(explicitClient: Bool) throws {
    let account = LocalProviderAccountConfiguration(
        id: "retained-lab", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Historical", authPath: "/example/.codex-lab/auth.json",
        codexClient: explicitClient ? .codexLab : nil,
        codexQuotaPath: "/example/.codex-lab/sessions")
    let decoded = try JSONDecoder().decode(LocalProviderAccountConfiguration.self, from: JSONEncoder().encode(account))
    #expect(decoded == account)
    #expect(decoded.isRetiredSource)
    #expect(decoded.promptCacheDirectory == nil)
    let document = AccountConfigurationDocument(updatedAt: .distantPast, accounts: [decoded])
    #expect(document.accounts == [account])
    #expect(document.settingsAccounts.isEmpty)
    #expect(AccountConnectorFactory.connectors(from: document).isEmpty)
}

@Test(arguments: [true, false])
func retiredLabMirrorDoesNotReadOrCopySource(explicitClient: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: explicitClient ? "custom/sessions" : ".codex-lab/sessions")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let original = Data("private source contents".utf8)
    let file = source.appending(path: "session.jsonl")
    try original.write(to: file)
    let destination = root.appending(path: "mirror")
    let clients: [String: CodexClient] = explicitClient ? [ContextPanelLocations.normalizedPath(source.path): .codexLab] : [:]
    let result = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [source], sourceClients: clients, destination: destination)
    #expect(result.copied == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    #expect(try Data(contentsOf: file) == original)
}
