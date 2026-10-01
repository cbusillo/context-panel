import Foundation
import Testing
@testable import ContextPanelCore

private final class BindingDeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deleted: [String] = []
    func delete(_ id: String) { lock.withLock { deleted.append(id) } }
    var ids: [String] { lock.withLock { deleted } }
}

@Test func codexHomeBindingDoesNotMutateDuringRefreshAndCommitsAfterLockRelease() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "current-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("placeholder".utf8).write(to: home.appending(path: "auth.json"))
    let account = LocalProviderAccountConfiguration(id: "fixture", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Local", authPath: "/old/source/auth.json")
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let original = AccountConfigurationDocument(updatedAt: .distantPast, accounts: [account])
    try store.save(original)
    let bookmarkStore = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))
    let refreshLock = SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock"))
    let deletions = BindingDeletionRecorder()
    let blocked = try await refreshLock.withLock {
        try await CodexHomeBinding.commit(accountID: account.id, home: home, accountStore: store,
            bookmarkStore: bookmarkStore, deleteImportedCredential: { deletions.delete($0) }, lock: refreshLock)
    }
    #expect(blocked != nil)
    #expect(blocked! == nil)
    #expect(deletions.ids.isEmpty)
    #expect(store.load().document == original)
    let changed = try #require(try await CodexHomeBinding.commit(accountID: account.id, home: home,
        accountStore: store, bookmarkStore: bookmarkStore,
        deleteImportedCredential: { deletions.delete($0) }, lock: refreshLock,
        now: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(deletions.ids == [account.id])
    #expect(changed.accounts.first?.effectiveAuthPath == home.appending(path: "auth.json").path)
    #expect(store.load().document == changed)
    #expect(bookmarkStore.canReadBookmark(for: home.appending(path: "auth.json").path))
}

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
