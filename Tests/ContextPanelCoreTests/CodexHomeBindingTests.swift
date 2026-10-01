import Foundation
import Testing
@testable import ContextPanelCore

@Test func codexHomeBindingUsesSeparateLoginsDespiteSharedSessions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let homes = [root.appending(path: ".codex"), root.appending(path: ".codex-accounts/account-one"), root.appending(path: ".codex-accounts/account-two")]
    let shared = root.appending(path: "shared-sessions")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    var accounts: [LocalProviderAccountConfiguration] = []
    for (index, home) in homes.enumerated() {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Deliberately not parseable credentials: binding must inspect metadata only.
        try Data([0xff]).write(to: home.appending(path: "auth.json"))
        try FileManager.default.createSymbolicLink(at: home.appending(path: "sessions"), withDestinationURL: shared)
        let original = LocalProviderAccountConfiguration(id: "fixture-\(index)", provider: .openAI,
            connectorKind: .codexRateLimits, displayName: "Account \(index)",
            codexQuotaPath: shared.path)
        let bound = try CodexHomeBinding.bind(account: original, home: home, siblings: accounts)
        #expect(bound.id == original.id)
        #expect(bound.displayName == original.displayName)
        #expect(bound.codexQuotaPath == nil)
        #expect(bound.effectiveAuthPath == home.appending(path: "auth.json").path)
        #expect(bound.effectiveCodexClient == .codex)
        accounts.append(bound)
    }
    #expect(Set(accounts.compactMap(\.effectiveAuthPath)).count == homes.count)
    #expect(throws: CodexHomeBindingError.self) {
        try CodexHomeBinding.bind(account: accounts[1], home: homes[0], siblings: accounts)
    }
    #expect(throws: CodexHomeBindingError.self) {
        try CodexHomeBinding.bind(account: accounts[0], home: root.appending(path: "missing"), siblings: accounts)
    }
    #expect(CodexClient.inferred(fromAuthPath: homes[1].appending(path: "auth.json").path) == .codex)
}
