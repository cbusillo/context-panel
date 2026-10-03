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

@Test func aSeparateCodexHomeCannotReadTheMainSharedSessions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let main = root.appending(path: ".codex")
    let other = root.appending(path: ".codex-accounts/fixture")
    try FileManager.default.createDirectory(at: main.appending(path: "sessions"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: other.appending(path: "sessions"), withDestinationURL: main.appending(path: "sessions"))
    var account = LocalProviderAccountConfiguration(id: "local", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Fixture", authPath: other.appending(path: "auth.json").path)
    #expect(CodexHomeBinding.isSharedSessionMismatch(account: account, sessions: main.appending(path: "sessions"), mainHome: main))
    #expect(CodexHomeBinding.isSharedSessionMismatch(account: account, sessions: other.appending(path: "sessions"), mainHome: main))
    #expect(!CodexHomeBinding.isSharedSessionMismatch(account: account, sessions: root.appending(path: "private-sessions"), mainHome: main))
    account.authPath = main.appending(path: "auth.json").path
    #expect(!CodexHomeBinding.isSharedSessionMismatch(account: account, sessions: main.appending(path: "sessions"), mainHome: main))
}

@Test func loadingCurrentHomesRepairsObsoleteClientAndSharedQuotaOverride() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = ContextPanelLocations.realUserHomeDirectory()
    let main = LocalProviderAccountConfiguration(id: "main", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Main", authPath: home.appending(path: ".codex/auth.json").path,
        codexClient: .codexLab)
    let separate = LocalProviderAccountConfiguration(id: "separate", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Separate", authPath: home.appending(path: ".codex-accounts/fixture/auth.json").path,
        codexClient: .codex, codexQuotaPath: home.appending(path: ".codex/sessions").path)
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try store.save(AccountConfigurationDocument(updatedAt: .distantPast, accounts: [main, separate]))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let loaded = store.load(now: now).document
    #expect(loaded.accounts[0].codexClient == .codex)
    #expect(loaded.accounts[0].authPath == main.authPath)
    #expect(loaded.accounts[1].codexQuotaPath == nil)
    #expect(loaded.accounts[1].authPath == separate.authPath)
    #expect(loaded.accounts.map(\.id) == [main.id, separate.id])
    #expect(store.load(now: now).document == loaded)
}

@Test func sharedSessionValidationRejectsAnUnboundOrSiblingHome() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let main = root.appending(path: ".codex")
    let one = root.appending(path: "one")
    let two = root.appending(path: "two")
    let unbound = LocalProviderAccountConfiguration(id: "unbound", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Unbound")
    #expect(CodexHomeBinding.isSharedSessionMismatch(account: unbound, sessions: main.appending(path: "sessions"), mainHome: main))
    #expect(CodexHomeBinding.isSharedSessionMismatch(account: unbound, sessions: main.appending(path: "sessions/2026/10/01"), mainHome: main))
    #expect(!CodexHomeBinding.isSharedSessionMismatch(account: unbound, sessions: main.appending(path: "sessions-separate"), mainHome: main))
    let a = LocalProviderAccountConfiguration(id: "one", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "One", authPath: one.appending(path: "auth.json").path)
    var b = LocalProviderAccountConfiguration(id: "two", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Two", authPath: two.appending(path: "auth.json").path)
    #expect(CodexHomeBinding.isSharedSessionMismatch(account: a, sessions: two.appending(path: "sessions"), siblings: [a,b], mainHome: main))
    #expect(CodexHomeBinding.isSharedSessionMismatch(account: a, sessions: two.appending(path: "sessions/2026/10/01"), siblings: [a,b], mainHome: main))
    #expect(!CodexHomeBinding.isSharedSessionMismatch(account: a, sessions: one.appending(path: "sessions"), siblings: [a,b], mainHome: main))
    b.isEnabled = false
    #expect(!CodexHomeBinding.isSharedSessionMismatch(account: a, sessions: two.appending(path: "sessions"), siblings: [a,b], mainHome: main))
}

@Test func codexHomeCommitDoesNotOverwriteUnreadableConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "accounts.json")
    let original = Data("{not-decodable}".utf8)
    try original.write(to: url)
    let store = AccountConfigurationStore(configurationURL: url)
    let fallbackID = try #require(store.load().document.accounts.first?.id)
    let deletions = BindingDeletionRecorder()
    do {
        _ = try await CodexHomeBinding.commit(accountID: fallbackID, home: root, accountStore: store,
            bookmarkStore: SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json")),
            deleteImportedCredential: { deletions.delete($0) }, lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")))
        Issue.record("Unreadable configuration should reject a home mutation")
    } catch let error as AccountConfigurationMutationError {
        #expect(error.localizedDescription == AccountConfigurationMutationError.unreadableConfiguration.localizedDescription)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(deletions.ids.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bookmarks.json").path))
}

@Test func addingCodexHomeDuringRefreshDoesNotSaveAHalfConnectedAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data([0xff]).write(to: home.appending(path: "auth.json"))
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let original = AccountConfigurationDocument(updatedAt: .distantPast, accounts: [])
    try store.save(original)
    let account = LocalProviderAccountConfiguration(id: "new", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Typed@example.invalid")
    let bookmarksURL = root.appending(path: "bookmarks.json")
    let bookmarks = SecureFileBookmarkStore(storeURL: bookmarksURL)
    let refreshLock = SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock"))
    _ = try await refreshLock.withLock {
        let result = try await CodexHomeBinding.add(account: account, home: home, accountStore: store,
            bookmarkStore: bookmarks, lock: refreshLock)
        #expect(result == nil)
    }
    #expect(store.load().document == original)
    #expect(!FileManager.default.fileExists(atPath: bookmarksURL.path))
    let changed = try #require(try await CodexHomeBinding.add(account: account, home: home,
        accountStore: store, bookmarkStore: bookmarks, lock: refreshLock))
    #expect(changed.accounts.count == 1)
    #expect(changed.accounts.first?.displayName == account.displayName)
    #expect(changed.accounts.first?.authPath == home.appending(path: "auth.json").path)
}

@Test func aSessionsOverrideStillReservesItsSavedCodexHome() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0xff]).write(to: root.appending(path: "auth.json"))
    let first = LocalProviderAccountConfiguration(id: "first", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "First", authPath: root.appending(path: "auth.json").path,
        codexQuotaPath: root.appending(path: "sessions").path)
    let second = LocalProviderAccountConfiguration(id: "second", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Second", authPath: root.appending(path: "auth.json").path)
    #expect(throws: CodexHomeBindingError.self) {
        try CodexHomeBinding.bind(account: second, home: root, siblings: [first, second])
    }
    #expect(throws: CodexHomeBindingError.self) {
        try CodexHomeBinding.usingAuthFile(account: first, siblings: [first, second])
    }
    let restored = try CodexHomeBinding.usingAuthFile(account: first, siblings: [first])
    #expect(restored.codexQuotaPath == nil)
    #expect(restored.authPath == first.authPath)
}
