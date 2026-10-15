import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelApp

private let refreshCommandNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func agentRefreshCommandDispatchAndUsageHaveNoRefreshSideEffects() async throws {
    #expect(await ContextPanelEntryPoint.refreshNowResult(arguments: []) == nil)
    #expect(await ContextPanelEntryPoint.refreshNowResult(arguments: ["--account-snapshot"]) == nil)
    let help = try #require(await ContextPanelEntryPoint.refreshNowResult(arguments: ["--refresh-now", "--help"]))
    #expect(help.exitCode == 0)
    #expect(!help.standardOutput.isEmpty)
    for arguments in [["--storage-root", "/private/secret"], ["--help", "--extra"]] {
        let invalid = await AgentRefreshCommand.run(arguments: arguments, refresh: { _ in
            Issue.record("Invalid arguments must not refresh")
            return .skippedNoReports
        })
        #expect(invalid.exitCode == 64)
        #expect(!String(decoding: invalid.standardError, as: UTF8.self).contains("/private/secret"))
    }
}

@Test func agentRefreshCommandSavesEveryEnabledSourceBeforeReturning() async throws {
    let fixture = try RefreshCommandFixture(accounts: [
        refreshCommandAccount("first", .openAI), refreshCommandAccount("second", .openAI),
        refreshCommandAccount("claude", .anthropic), refreshCommandAccount("google", .google),
        refreshCommandAccount("disabled", .anthropic, enabled: false)
    ])
    defer { fixture.remove() }
    let service = fixture.service { document in
        document.accounts.filter(\.isEnabled).map { RefreshCommandConnector(account: $0) }
    }
    let runner = fixture.runner(service)
    let result = await fixture.run(runner)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let saved = try #require(fixture.snapshots.loadCurrent().snapshot)
    #expect(Set(saved.reports.compactMap(\.configuredAccountID)) == Set(["first", "second", "claude", "google"]))
    #expect(saved.savedAt == refreshCommandNow)
    #expect(!String(decoding: result.standardOutput, as: UTF8.self).contains("private-label"))
    // A forced refresh must still run when the previous snapshot is fresh.
    #expect(await fixture.run(runner).exitCode == 0)
}

@Test func agentRefreshCommandImportsGoogleBridgeWithoutInventingAnObservation() async throws {
    let account = refreshCommandAccount("google", .google)
    let fixture = try RefreshCommandFixture(accounts: [account])
    defer { fixture.remove() }
    let observedAt = refreshCommandNow.addingTimeInterval(-86_400)
    let bridge = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: fixture.root.appending(path: "bridge/quota.json"))
    try bridge.save(GoogleAntigravityStatusLineSnapshot(observedAt: observedAt,
        buckets: [GoogleAntigravityStatusLineBucket(id: "gemini-pro", remainingFraction: 0.6,
            resetsAt: refreshCommandNow.addingTimeInterval(3_600))]))
    // Production connector factory, with only the bridge location replaced by a fixture.
    let service = SnapshotRefreshService(accountStore: fixture.accounts,
        stores: SnapshotRefreshStores(primary: fixture.snapshots), googleAntigravitySnapshotLoader: bridge,
        promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] })
    let result = await fixture.run(fixture.runner(service))
    #expect(result.exitCode == 0)
    let saved = try #require(fixture.snapshots.loadCurrent().snapshot)
    #expect(saved.savedAt == refreshCommandNow)
    #expect(saved.snapshot.limits.first?.lastUpdatedAt == observedAt)
    #expect(saved.snapshot.limits.first?.used == 40)
    #expect(String(decoding: result.standardOutput, as: UTF8.self).contains(observedAt.ISO8601Format()))
}

@Test(arguments: [false, true])
func agentRefreshCommandValidatesBothSourcesOfADeduplicatedAccount(secondFails: Bool) async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("first", .openAI),
        refreshCommandAccount("second", .openAI)])
    defer { fixture.remove() }
    let service = fixture.service { document in
        document.accounts.enumerated().map { index, account in
            RefreshCommandConnector(account: account, failure: secondFails && index == 1 ? .failure : nil,
                logicalAccountID: "same-chatgpt-account")
        }
    }
    let result = await fixture.run(fixture.runner(service))
    #expect(result.exitCode == (secondFails ? 1 : 0))
    #expect(result.standardError.isEmpty == !secondFails)
    let saved = try #require(fixture.snapshots.loadCurrent().snapshot)
    #expect(saved.reports.count == 1)
    #expect(saved.snapshot.limits.count == 1)
}

@Test(arguments: [UsageStatus.failure, .unknown, .stale])
func agentRefreshCommandPartialFailuresAreNonzeroAndPreserveSuccessfulReadings(status: UsageStatus) async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("good", .openAI),
        refreshCommandAccount("bad", .anthropic)])
    defer { fixture.remove() }
    let service = fixture.service { document in
        document.accounts.map { RefreshCommandConnector(account: $0, failure: $0.provider == .anthropic ? status : nil) }
    }
    let result = await fixture.run(fixture.runner(service))
    #expect(result.exitCode == 1)
    #expect(!result.standardOutput.isEmpty)
    let error = String(decoding: result.standardError, as: UTF8.self)
    #expect(error.contains(Provider.anthropic.rawValue))
    #expect(!error.contains("private-label"))
    #expect(!error.contains("/private/secret"))
    #expect(!error.contains("private@example.com"))
    #expect(fixture.snapshots.loadCurrent().snapshot?.snapshot.limits.contains { $0.provider == .openAI } == true)
}

@Test(arguments: [false, true])
func agentRefreshCommandPreservesAccountIdentityAndHonorsRemovals(removingSource: Bool) async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("identified", .openAI),
        refreshCommandAccount("other", .anthropic)])
    defer { fixture.remove() }
    let material = try #require(ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID,
        identifier: "fixture-chatgpt-account", scope: "seat:fixture-seat"))
    let localID = material.localHistoryID(configurationID: "identified")
    let identity = ProviderAccountIdentityKey.generate().identity(for: material).bound(toLocalAccountID: localID)
    let service = fixture.service { document in
        document.accounts.map { account in
            RefreshCommandConnector(account: account, logicalAccountID: account.provider == .openAI ? localID : nil,
                sharedIdentity: account.provider == .openAI ? identity : nil)
        }
    }
    let runner = fixture.runner(service)
    // The ordinary runner's IDs and the command's saved IDs must agree.
    _ = try await runner.refresh(now: refreshCommandNow)
    let before = try #require(fixture.snapshots.loadCurrent().snapshot)
    if removingSource {
        var configuration = fixture.accounts.load(now: refreshCommandNow).document
        let removedID = AccountDisplayMetadata.safeID(.openAI, identity.accountID)
        configuration.pendingRemovedDisplayIDs = [removedID]
        configuration.removedDisplayDates = [removedID: refreshCommandNow]
        try fixture.accounts.save(configuration)
    }
    let result = await fixture.run(runner)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let after = try #require(fixture.snapshots.loadCurrent().snapshot)
    if removingSource {
        #expect(!fixture.accounts.load(now: refreshCommandNow).document.accounts.contains { $0.id == "identified" })
        #expect(after.snapshot.limits.allSatisfy { $0.provider != .openAI })
    } else {
        #expect(after.snapshot.limits.map(\.accountID) == before.snapshot.limits.map(\.accountID))
        #expect(after.reports.first { $0.provider == .openAI }?.sharedAccountIdentity == identity)
    }
}

@Test func agentRefreshCommandMissingSourcesCannotBeHiddenBySuccessfulProviders() async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("good", .openAI),
        refreshCommandAccount("missing", .google)])
    defer { fixture.remove() }
    let service = fixture.service { document in
        [RefreshCommandConnector(account: document.accounts[0])]
    }
    let result = await fixture.run(fixture.runner(service))
    #expect(result.exitCode == 1)
    #expect(String(decoding: result.standardError, as: UTF8.self).contains(Provider.google.rawValue))
}

@Test func agentRefreshCommandMissingGoogleBridgeIsNonzero() async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("google", .google)])
    defer { fixture.remove() }
    let service = SnapshotRefreshService(accountStore: fixture.accounts,
        stores: SnapshotRefreshStores(primary: fixture.snapshots),
        googleAntigravitySnapshotLoader: GoogleAntigravityStatusLineSnapshotStore(snapshotURL: fixture.root.appending(path: "missing.json")),
        promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] })
    let result = await fixture.run(fixture.runner(service))
    #expect(result.exitCode == 1)
    #expect(!result.standardError.isEmpty)
}

@Test func agentRefreshCommandLockContentionAndSaveFailureCannotSucceed() async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("good", .openAI)])
    defer { fixture.remove() }
    let runner = fixture.runner(fixture.service { document in [RefreshCommandConnector(account: document.accounts[0])] })
    let lock = try #require(runner.lock)
    let busy = try #require(try await lock.withLock { await fixture.run(runner) })
    #expect(busy.exitCode == 1)
    #expect(!busy.standardError.isEmpty)
    #expect(fixture.snapshots.loadCurrent().snapshot == nil)
    // Make the snapshot root a file so the real writer fails.
    try Data("blocked".utf8).write(to: fixture.snapshots.rootDirectory)
    let failed = await fixture.run(runner)
    #expect(failed.exitCode == 1)
    #expect(failed.standardOutput.isEmpty)
    #expect(!String(decoding: failed.standardError, as: UTF8.self).contains(fixture.root.path))
}

@Test func agentRefreshCommandWaitsForAnExistingRefreshThenSaves() async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("good", .openAI)])
    defer { fixture.remove() }
    let runner = fixture.runner(fixture.service { document in [RefreshCommandConnector(account: document.accounts[0])] })
    let busy = RefreshCommandBusyOnce()
    let clock = RefreshCommandClock()
    let result = await AgentRefreshCommand.run(arguments: [], accountStore: fixture.accounts,
        now: { clock.read() }, sleep: { clock.advance() }, refresh: { now in
            if await busy.take() { return .skippedAlreadyRunning }
            return try await runner.refresh(now: now)
        })
    #expect(result.exitCode == 0)
    let saved = try #require(fixture.snapshots.loadCurrent().snapshot)
    #expect(saved.savedAt == clock.read())
    #expect(saved.savedAt > refreshCommandNow)
}

private final class RefreshCommandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = refreshCommandNow
    func read() -> Date { lock.withLock { date } }
    func advance() { lock.withLock { date += 60 } }
}

private actor RefreshCommandBusyOnce {
    private var isBusy = true
    func take() -> Bool {
        defer { isBusy = false }
        return isBusy
    }
}

@Test func agentRefreshCommandMissingMalformedAndDisabledSetupDoNotRefresh() async throws {
    let fixture = try RefreshCommandFixture(accounts: [refreshCommandAccount("off", .openAI, enabled: false)])
    defer { fixture.remove() }
    let neverRefresh: @Sendable (Date) async throws -> SnapshotRefreshRunDecision = { _ in
        Issue.record("Invalid or disabled setup must not refresh")
        return .skippedNoReports
    }
    let off = await AgentRefreshCommand.run(arguments: [], accountStore: fixture.accounts, refresh: neverRefresh)
    #expect(off.exitCode == 1)
    try Data("private-secret invalid JSON".utf8).write(to: fixture.accounts.configurationURL)
    let malformed = await AgentRefreshCommand.run(arguments: [], accountStore: fixture.accounts, refresh: neverRefresh)
    #expect(malformed.exitCode == 1)
    #expect(!String(decoding: malformed.standardError, as: UTF8.self).contains("private-secret"))
    try FileManager.default.removeItem(at: fixture.accounts.configurationURL)
    let missing = await AgentRefreshCommand.run(arguments: [], accountStore: fixture.accounts, refresh: neverRefresh)
    #expect(missing.exitCode == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.accounts.configurationURL.path))
}

private func refreshCommandAccount(_ id: String, _ provider: Provider, enabled: Bool = true) -> LocalProviderAccountConfiguration {
    LocalProviderAccountConfiguration(id: id, provider: provider,
        connectorKind: provider == .openAI ? .codexRateLimits : provider == .anthropic ? .claudeOAuthUsage : .googleAntigravityQuota,
        displayName: "private-label", isEnabled: enabled)
}

private struct RefreshCommandConnector: ProviderConnector {
    let account: LocalProviderAccountConfiguration
    var failure: UsageStatus? = nil
    var logicalAccountID: String? = nil
    var sharedIdentity: SharedProviderAccountIdentity? = nil
    var provider: Provider { account.provider }
    func refresh(now: Date) async -> ConnectorRefreshResult {
        let accountID = logicalAccountID ?? account.id
        let limit = UsageLimit(provider: provider, accountID: accountID, configuredAccountID: account.id,
            accountName: account.displayName, label: "Weekly", unit: .percent, used: 20, limit: 100,
            resetsAt: now.addingTimeInterval(86_400), lastUpdatedAt: now)
        return ConnectorRefreshResult(generatedAt: now, reports: [ProviderConnectorReport(provider: provider,
            accountID: accountID, configuredAccountID: account.id, accountName: account.displayName,
            generatedAt: now, limits: failure == nil ? [limit] : [], status: failure,
            errorMessage: failure == nil ? nil : "Read failed at /private/secret for private@example.com",
            sharedAccountIdentity: sharedIdentity)])
    }
}

private struct RefreshCommandFixture: Sendable {
    let root: URL
    let accounts: AccountConfigurationStore
    let snapshots: JSONSnapshotStore
    init(accounts configured: [LocalProviderAccountConfiguration]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "refresh-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        accounts = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
        snapshots = JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots"))
        try accounts.save(AccountConfigurationDocument(updatedAt: refreshCommandNow, accounts: configured))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func service(_ factory: @escaping @Sendable (AccountConfigurationDocument) -> [any ProviderConnector]) -> SnapshotRefreshService {
        SnapshotRefreshService(accountStore: accounts, stores: SnapshotRefreshStores(primary: snapshots),
            connectorFactory: factory, promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] })
    }
    func runner(_ service: SnapshotRefreshService) -> SnapshotRefreshRunner {
        SnapshotRefreshRunner(service: service, resetExpiryRefreshStore: nil,
            lock: SnapshotRefreshLock(lockURL: root.appending(path: "refresh.lock")))
    }
    func run(_ runner: SnapshotRefreshRunner) async -> AgentRefreshCommand.Result {
        await AgentRefreshCommand.run(arguments: [], accountStore: accounts, now: { refreshCommandNow }, sleep: {},
            refresh: { try await runner.refresh(now: $0) })
    }
}
