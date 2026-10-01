import Foundation
import Testing
@testable import ContextPanelCore

@Test func accountRemovalPersistsWithoutTouchingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let home = root.appending(path: "home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let auth = home.appending(path: "auth.json")
    let sentinel = Data([0xff, 0x00, 0xfe])
    try sentinel.write(to: auth)
    let removed = LocalProviderAccountConfiguration(id: "removed", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Old source", authPath: auth.path)
    let kept = LocalProviderAccountConfiguration(id: "kept", provider: .anthropic,
        connectorKind: .claudeOAuthUsage, displayName: "Keep")
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try store.save(AccountConfigurationDocument(updatedAt: .distantPast, accounts: [removed, kept]))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let changed = try #require(try await store.removeAccount(id: removed.id,
        lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")), now: now))
    #expect(changed.accounts == [kept])
    #expect(store.load(now: now).document == changed)
    #expect(try Data(contentsOf: auth) == sentinel)
    let rows = AccountCapacity.rows(configuration: changed.accounts,
        snapshot: UsageSnapshot(generatedAt: now, limits: []), reports: [], now: now)
    #expect(rows.map(\.configuredAccountID) == [kept.id])
}

@Test func accountRemovalSurvivesRetiredSourceMigration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codex = try #require(AccountConfigurationStore.defaultDocument(now: now).accounts.first { $0.provider == .openAI })
    let retired = LocalProviderAccountConfiguration(id: "retired", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Retained history", authPath: "/retired/auth.json", codexClient: .everyCode)
    try store.save(AccountConfigurationDocument(updatedAt: now, accounts: [retired, codex]))
    _ = try #require(try await store.removeAccount(id: codex.id,
        lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")), now: now))
    for _ in 0..<2 {
        let document = store.load(now: now).document
        #expect(!document.accounts.contains { $0.id == codex.id })
        #expect(document.accounts.contains { $0.id == retired.id })
        #expect(document.removedAccountIDs.contains(codex.id))
    }
}

@Test func accountRemovalWaitsForRefreshAndCanRemoveAllDefaults() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try store.save(AccountConfigurationStore.defaultDocument(now: now))
    let original = store.load(now: now).document
    let lock = SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock"))
    let first = try #require(original.accounts.first)
    let blocked = try await lock.withLock { try await store.removeAccount(id: first.id, lock: lock, now: now) }
    #expect(blocked != nil)
    #expect(blocked! == nil)
    #expect(store.load(now: now).document == original)
    for account in original.accounts {
        _ = try #require(try await store.removeAccount(id: account.id, lock: lock, now: now))
    }
    #expect(store.load(now: now).document.accounts.isEmpty)
}

@Test func accountRemovalDoesNotReplaceUnreadableSetupWithDefaults() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "accounts.json")
    let broken = Data("unreadable setup".utf8)
    try broken.write(to: file)
    let store = AccountConfigurationStore(configurationURL: file)
    await #expect(throws: AccountConfigurationMutationError.self) {
        try await store.removeAccount(id: "any", lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")))
    }
    #expect(try Data(contentsOf: file) == broken)
}

@Test func codexUnavailableSourceRemainsExplicitWithSavedLogin() {
    var account = LocalProviderAccountConfiguration(id: "local", provider: .openAI,
        connectorKind: .codexRateLimits, displayName: "Local", authPath: "/gone/auth.json")
    #expect(CodexHomeBinding.sourceState(account: account, authFileAvailable: false, hasSavedLogin: true) == .unavailableUsingSavedLogin)
    #expect(CodexHomeBinding.sourceState(account: account, authFileAvailable: false, hasSavedLogin: false) == .unavailable)
    #expect(CodexHomeBinding.sourceState(account: account, authFileAvailable: true, hasSavedLogin: true) == .available)
    account.authPath = nil
    #expect(CodexHomeBinding.sourceState(account: account, authFileAvailable: false, hasSavedLogin: false) == .unconfigured)
    account.codexQuotaPath = "/sessions"
    #expect(CodexHomeBinding.sourceState(account: account, authFileAvailable: false, hasSavedLogin: true) == .sessionHistory)
}
