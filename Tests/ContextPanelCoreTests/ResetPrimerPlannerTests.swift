import Foundation
import Testing

@testable import ContextPanelCore

private let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

@Test func resetPrimerPlannerReturnsNoCandidatesWhenGlobalSettingIsOff() {
    let resetAt = now.addingTimeInterval(-60)
    let settings = ResetPrimerSettings(
        isEnabled: false,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
    )

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerSchedulesDueAndUpcomingWindowsFromSettings() throws {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 5,
        accountStaggerMinutes: 10,
        accountPreferences: [
            preference(accountID: "openai-a", provider: .openAI),
            preference(accountID: "openai-b", provider: .openAI),
        ]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            limit(accountID: "openai-b", accountName: "OpenAI B", provider: .openAI, resetAt: resetAt),
            limit(accountID: "openai-a", accountName: "OpenAI A", provider: .openAI, resetAt: resetAt),
        ]
    )

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now)

    #expect(plan.due.map(\.accountID) == ["openai-a"])
    #expect(plan.upcoming.map(\.accountID) == ["openai-b"])
    #expect(plan.due.first?.scheduledAt == resetAt.addingTimeInterval(5 * 60))
    #expect(plan.upcoming.first?.scheduledAt == resetAt.addingTimeInterval(15 * 60))
}

@Test func resetPrimerPlannerMatchesResolvedLimitsToConfiguredAccountID() throws {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-code-default", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            limit(
                accountID: "openai-resolved-a",
                configuredAccountID: "openai-code-default",
                accountName: "first@example.com · pro",
                provider: .openAI,
                resetAt: resetAt
            ),
            limit(
                accountID: "openai-resolved-b",
                configuredAccountID: "openai-code-default",
                accountName: "second@example.com · pro",
                provider: .openAI,
                resetAt: resetAt.addingTimeInterval(30 * 60)
            ),
        ]
    )

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now)

    #expect(plan.due.map(\.accountID) == ["openai-code-default"])
    #expect(plan.due.map(\.configuredAccountID) == ["openai-code-default"])
    #expect(plan.due.map(\.resolvedAccountID) == ["openai-resolved-a"])
    #expect(plan.upcoming.map(\.accountID) == ["openai-code-default"])
    #expect(plan.upcoming.map(\.configuredAccountID) == ["openai-code-default"])
    #expect(plan.upcoming.map(\.resolvedAccountID) == ["openai-resolved-b"])
}

@Test func resetPrimerExecutorCanUseResolvedAccountWhenConfiguredAliasIsMissing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let command = directory.appending(path: "code")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "configured-openai", provider: .openAI)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "resolved-openai",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Resolved OpenAI",
            commandPath: command.path
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(
                accountID: "resolved-openai",
                configuredAccountID: "configured-openai",
                provider: .openAI,
                resetAt: resetAt
            )]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { _, _, _ in
            Issue.record("Code primer should not run a process without a proven cheap account-selectable command")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.skipped])
    #expect(results.first?.candidate.configuredAccountID == "configured-openai")
    #expect(results.first?.candidate.resolvedAccountID == "resolved-openai")
    #expect(results.first?.errorMessage == "Reset priming is not supported for this provider")
}

@Test func resetPrimerExecutorPrefersCurrentResolvedAccountOverConfiguredAlias() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let currentCommand = directory.appending(path: "current-code")
    let legacyCommand = directory.appending(path: "legacy-code")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: currentCommand)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: currentCommand.path)
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "configured-openai", provider: .openAI)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "configured-openai",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Legacy OpenAI",
            isEnabled: true,
            commandPath: legacyCommand.path
        ),
        LocalProviderAccountConfiguration(
            id: "resolved-openai-current",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Current OpenAI",
            isEnabled: true,
            commandPath: currentCommand.path
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(
                accountID: "resolved-openai-current",
                configuredAccountID: "configured-openai",
                provider: .openAI,
                resetAt: resetAt
            )]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { commandURL, _, _ in
            Issue.record("Primer command should not run until a provider supplies primer arguments: \(commandURL.path)")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.skipped])
    #expect(results.first?.errorMessage == "Reset priming is not supported for this provider")
}

@Test func resetPrimerPlannerKeepsRunStateCompatibleWhenConfiguredAliasAppears() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "configured-openai", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(
            accountID: "resolved-openai",
            configuredAccountID: "configured-openai",
            provider: .openAI,
            resetAt: resetAt
        )]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: ResetPrimerRunKey(
                provider: .openAI,
                accountID: "resolved-openai",
                resetAt: resetAt
            ),
            accountName: "Resolved OpenAI",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerKeepsLogicalRunStateWhenResolvedAccountChanges() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "configured-openai", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(
            accountID: "resolved-openai-v2",
            configuredAccountID: "configured-openai",
            provider: .openAI,
            resetAt: resetAt
        )]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: ResetPrimerRunKey(
                provider: .openAI,
                accountID: "configured-openai",
                resetAt: resetAt
            ),
            accountName: "Configured OpenAI",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerKeepsRunStateWhenCurrentSnapshotLosesConfiguredAlias() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "resolved-openai-v2", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(
            accountID: "resolved-openai-v2",
            provider: .openAI,
            resetAt: resetAt
        )]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: ResetPrimerRunKey(
                provider: .openAI,
                accountID: "configured-openai",
                resetAt: resetAt
            ),
            resolvedAccountIDs: ["resolved-openai-v1", "resolved-openai-v2"],
            accountName: "Configured OpenAI",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerKeepsLegacyRunStateWhenCurrentSnapshotLosesConfiguredAlias() throws {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "resolved-openai-v1", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(
            accountID: "resolved-openai-v1",
            provider: .openAI,
            resetAt: resetAt
        )]
    )
    let legacyJSON = """
    {
      "schemaVersion" : 1,
      "records" : [
        {
          "key" : {
            "provider" : "openai",
            "accountID" : "resolved-openai-v1",
            "resetAt" : "\(ISO8601DateFormatter().string(from: resetAt))"
          },
          "accountName" : "Resolved OpenAI",
          "scheduledAt" : "\(ISO8601DateFormatter().string(from: resetAt))",
          "status" : "completed",
          "updatedAt" : "\(ISO8601DateFormatter().string(from: now))"
        }
      ]
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(ResetPrimerRunState.self, from: Data(legacyJSON.utf8))

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(state.records.first?.resolvedAccountIDs == ["resolved-openai-v1"])
    #expect(plan.isEmpty)
}

@Test func resetPrimerRunStateUpsertPreservesHistoricalResolvedAccountIDs() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let candidate = ResetPrimerCandidate(
        key: ResetPrimerRunKey(provider: .openAI, accountID: "configured-openai", resetAt: resetAt),
        configuredAccountID: "configured-openai",
        resolvedAccountID: "resolved-openai-v2",
        resolvedAccountIDs: ["resolved-openai-v2"],
        accountName: "Configured OpenAI",
        windowLabel: "Weekly",
        scheduledAt: resetAt,
        sourceLimitIDs: ["resolved-openai-v2:weekly"]
    )
    var state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: ResetPrimerRunKey(provider: .openAI, accountID: "configured-openai", resetAt: resetAt),
            resolvedAccountIDs: ["resolved-openai-v1"],
            accountName: "Configured OpenAI",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    state.upsert(ResetPrimerRunRecord(
        key: candidate.key,
        resolvedAccountIDs: candidate.resolvedAccountIDs,
        accountName: candidate.accountName,
        scheduledAt: candidate.scheduledAt,
        status: .completed,
        updatedAt: now.addingTimeInterval(60)
    ), for: candidate)

    #expect(state.records.count == 1)
    #expect(state.records.first?.resolvedAccountIDs == ["resolved-openai-v1", "resolved-openai-v2"])
}

@Test func resetPrimerPlannerDoesNotMatchLegacyRunStateByDisplayNameAlone() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "configured-openai", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(
            accountID: "resolved-openai-current",
            configuredAccountID: "configured-openai",
            accountName: "Shared Account Name",
            provider: .openAI,
            resetAt: resetAt
        )]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: ResetPrimerRunKey(
                provider: .openAI,
                accountID: "different-resolved-openai",
                resetAt: resetAt
            ),
            accountName: "Shared Account Name",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.due.map(\.accountID) == ["configured-openai"])
}

@Test func usageSnapshotRecommendsOpenAIWeeklyAccountWithEarliestFutureReset() throws {
    let laterReset = now.addingTimeInterval(3 * 3_600)
    let earlierReset = now.addingTimeInterval(90 * 60)
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            limit(
                accountID: "openai-later",
                configuredAccountID: "openai-code-default",
                accountName: "later@example.com · pro",
                provider: .openAI,
                windowLabel: "Weekly",
                resetAt: laterReset
            ),
            limit(
                accountID: "openai-earlier",
                configuredAccountID: "openai-code-default",
                accountName: "earlier@example.com · pro",
                provider: .openAI,
                windowLabel: "Weekly",
                resetAt: earlierReset
            ),
            limit(
                accountID: "openai-past",
                configuredAccountID: "openai-code-default",
                accountName: "past@example.com · pro",
                provider: .openAI,
                windowLabel: "Weekly",
                resetAt: now.addingTimeInterval(-10 * 60)
            ),
        ]
    )

    let recommendation = try #require(snapshot.nextAccountToUse(provider: .openAI, window: .weekly))

    #expect(recommendation.accountID == "openai-earlier")
    #expect(recommendation.configuredAccountID == "openai-code-default")
    #expect(recommendation.resetsAt == earlierReset)
}

@Test func resetPrimerPlannerStaggersSameAccountIDsAcrossProviders() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountStaggerMinutes: 10,
        accountPreferences: [
            preference(accountID: "default", provider: .anthropic),
            preference(accountID: "default", provider: .openAI),
        ]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            limit(accountID: "default", accountName: "Claude", provider: .anthropic, resetAt: resetAt),
            limit(accountID: "default", accountName: "OpenAI", provider: .openAI, resetAt: resetAt),
        ]
    )

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now)

    #expect(plan.due.map(\.provider) == [.anthropic, .openAI])
    #expect(plan.due.map(\.scheduledAt) == [
        resetAt,
        resetAt.addingTimeInterval(10 * 60),
    ])
}

@Test func resetPrimerPlannerGroupsModelBucketsByAccountWindowAndReset() throws {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            limit(
                id: "openai-a:weekly:sonnet",
                accountID: "openai-a",
                provider: .openAI,
                label: "Model A weekly",
                windowLabel: "Weekly",
                modelLabel: "Model A",
                resetAt: resetAt
            ),
            limit(
                id: "openai-a:weekly:opus",
                accountID: "openai-a",
                provider: .openAI,
                label: "Model B weekly",
                windowLabel: "Weekly",
                modelLabel: "Model B",
                resetAt: resetAt
            ),
        ]
    )

    let candidate = try #require(ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now).due.first)

    #expect(candidate.windowLabel == "Weekly")
    #expect(candidate.sourceLimitIDs == ["openai-a:weekly:opus", "openai-a:weekly:sonnet"])
}

@Test func resetPrimerPlannerSkipsDisabledAccounts() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [
            ResetPrimerAccountPreference(
                accountID: "openai-a",
                provider: .openAI,
                accountName: "OpenAI A",
                isEnabled: false
            ),
        ]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
    )

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerSkipsDegradedLimits() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [
            preference(accountID: "failure", provider: .openAI),
            preference(accountID: "stale", provider: .openAI),
            preference(accountID: "unknown", provider: .openAI),
        ]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            limit(accountID: "failure", provider: .openAI, resetAt: resetAt, statusOverride: .failure),
            limit(accountID: "stale", provider: .openAI, resetAt: resetAt, statusOverride: .stale),
            limit(accountID: "unknown", provider: .openAI, resetAt: resetAt, statusOverride: .unknown),
        ]
    )

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerDoesNotRepeatCompletedRunsForTheSameReset() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let key = ResetPrimerRunKey(
        provider: .openAI,
        accountID: "openai-a",
        windowLabel: "Weekly",
        resetAt: resetAt
    )
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(accountID: "openai-a", provider: .openAI, windowLabel: "Weekly", resetAt: resetAt)]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: key,
            accountName: "OpenAI A",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerDoesNotRepeatCompletedRunsWhenWindowCopyChanges() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let key = ResetPrimerRunKey(
        provider: .openAI,
        accountID: "openai-a",
        windowLabel: "Weekly",
        resetAt: resetAt
    )
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(accountID: "openai-a", provider: .openAI, windowLabel: "7-day pool", resetAt: resetAt)]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: key,
            accountName: "OpenAI A",
            scheduledAt: resetAt,
            status: .completed,
            updatedAt: now
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.isEmpty)
}

@Test func resetPrimerPlannerRetriesFailedRunsForTheSameReset() {
    let resetAt = now.addingTimeInterval(-10 * 60)
    let key = ResetPrimerRunKey(
        provider: .openAI,
        accountID: "openai-a",
        windowLabel: "Weekly",
        resetAt: resetAt
    )
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    )
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(accountID: "openai-a", provider: .openAI, windowLabel: "Weekly", resetAt: resetAt)]
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: key,
            accountName: "OpenAI A",
            scheduledAt: resetAt,
            status: .failed,
            updatedAt: now,
            errorMessage: "failed with sk-secret"
        )
    ])

    let plan = ResetPrimerPlanner.plan(settings: settings, snapshot: snapshot, state: state, now: now)

    #expect(plan.due.map(\.accountID) == ["openai-a"])
}

@Test func resetPrimerRunStateKeepsNewestDuplicateRecordAndRedactsErrors() {
    let key = ResetPrimerRunKey(
        provider: .openAI,
        accountID: "openai-a",
        windowLabel: "Weekly",
        resetAt: now
    )

    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: key,
            accountName: "Old OpenAI",
            scheduledAt: now,
            status: .completed,
            updatedAt: now
        ),
        ResetPrimerRunRecord(
            key: key,
            accountName: "OpenAI A",
            scheduledAt: now,
            status: .failed,
            updatedAt: now.addingTimeInterval(60),
            errorMessage: "failed for user@example.com with bearer sk-secret"
        ),
    ])

    #expect(state.records.count == 1)
    #expect(state.records.first?.status == .failed)
    #expect(state.records.first?.errorMessage?.contains("user@example.com") == false)
    #expect(state.records.first?.errorMessage?.contains("sk-secret") == false)
}

@Test func resetPrimerRunStateStoreRoundTripsState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ResetPrimerRunStateStore(
        stateURL: directory.appending(path: "reset-primer-runs.json")
    )
    let state = ResetPrimerRunState(records: [
        ResetPrimerRunRecord(
            key: ResetPrimerRunKey(
                provider: .google,
                accountID: "gemini-a",
                windowLabel: "Daily",
                resetAt: now
            ),
            accountName: "Gemini A",
            scheduledAt: now.addingTimeInterval(60),
            status: .completed,
            updatedAt: now.addingTimeInterval(120)
        )
    ])

    try store.save(state)

    #expect(store.exists)
    #expect(store.load() == state)
}

@Test func resetPrimerPlanServiceLoadsSharedStoresAndMarksCandidates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    ))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )

    let firstPlan = service.plan(now: now)
    let candidate = try #require(firstPlan.due.first)
    try service.mark(
        candidate,
        status: .failed,
        now: now.addingTimeInterval(60),
        errorMessage: "failed for user@example.com with bearer sk-secret"
    )

    #expect(service.plan(now: now.addingTimeInterval(120)).due.map(\.accountID) == ["openai-a"])
    #expect(stateStore.load().record(for: candidate.key)?.status == .failed)
    #expect(stateStore.load().record(for: candidate.key)?.errorMessage?.contains("sk-secret") == false)
}

@Test func resetPrimerExecutorSkipsCodePrimerUntilCheapAccountSelectableCommandExists() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let command = directory.appending(path: "code")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Code",
            commandPath: command.path
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { url, arguments, timeout in
            _ = url
            _ = arguments
            _ = timeout
            Issue.record("Code primer should not run a process without a proven cheap account-selectable command")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.skipped])
    #expect(results.first?.errorMessage == "Reset priming is not supported for this provider")
    let candidate = try #require(results.first?.candidate)
    #expect(stateStore.load().record(for: candidate.key)?.status == .skipped)
    #expect(service.plan(now: now.addingTimeInterval(60)).isEmpty)
}

@Test func resetPrimerExecutorHandlesDuplicateConfiguredAccountIDs() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Code A"
        ),
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Code A Duplicate"
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { _, _, _ in
            Issue.record("Code primer should not run a process without a proven cheap account-selectable command")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.skipped])
    #expect(results.first?.errorMessage == "No primer command is configured" || results.first?.errorMessage == "Reset priming is not supported for this provider")
}

@Test func resetPrimerExecutorSurfacesRunStateSaveFailures() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let blockedStateDirectory = directory.appending(path: "reset-primer-runs", directoryHint: .isDirectory)
    let stateStore = ResetPrimerRunStateStore(stateURL: blockedStateDirectory.appending(path: "state.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let command = directory.appending(path: "primer")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: blockedStateDirectory)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Code",
            commandPath: command.path
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { _, _, _ in
            Issue.record("Primer command should not run when run state cannot be saved")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.failed])
    #expect(results.first?.errorMessage?.contains("Reset primer state could not be saved") == true)
}

@Test func resetPrimerExecutorSkipsMissingCommandAndDoesNotRepeatSkippedRun() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "openai-a", provider: .openAI)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Code",
            commandPath: directory.appending(path: "missing-code").path
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(accountID: "openai-a", provider: .openAI, resetAt: resetAt)]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { _, _, _ in
            Issue.record("Missing command should not run a process")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.skipped])
    let candidate = try #require(results.first?.candidate)
    #expect(stateStore.load().record(for: candidate.key)?.status == .skipped)
    #expect(service.plan(now: now.addingTimeInterval(60)).isEmpty)
}

@Test func resetPrimerExecutorSkipsUnsupportedProviderPrimer() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = ResetPrimerSettingsStore(settingsURL: directory.appending(path: "reset-primer-settings.json"))
    let stateStore = ResetPrimerRunStateStore(stateURL: directory.appending(path: "reset-primer-runs.json"))
    let snapshotStore = JSONSnapshotStore(rootDirectory: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
    let accountStore = AccountConfigurationStore(configurationURL: directory.appending(path: "accounts.json"))
    let command = directory.appending(path: "claude")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    let resetAt = now.addingTimeInterval(-10 * 60)
    try settingsStore.save(ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 0,
        accountPreferences: [preference(accountID: "claude-a", provider: .anthropic)]
    ))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "claude-a",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude",
            commandPath: command.path
        ),
    ]))
    try snapshotStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(
            generatedAt: now,
            limits: [limit(accountID: "claude-a", provider: .anthropic, resetAt: resetAt)]
        )
    ))
    let service = ResetPrimerPlanService(
        settingsStore: settingsStore,
        stateStore: stateStore,
        snapshotStore: snapshotStore
    )
    let executor = ResetPrimerExecutor(
        planService: service,
        accountStore: accountStore,
        processRunner: { _, _, _ in
            Issue.record("Unsupported primer provider should not run a process")
            return 0
        }
    )

    let results = await executor.runDue(now: now)

    #expect(results.map(\.status) == [.skipped])
    #expect(results.first?.errorMessage == "Reset priming is not supported for this provider")
}

private func preference(accountID: String, provider: Provider) -> ResetPrimerAccountPreference {
    ResetPrimerAccountPreference(
        accountID: accountID,
        provider: provider,
        accountName: accountID.capitalized,
        isEnabled: true
    )
}

private func limit(
    id: String? = nil,
    accountID: String,
    configuredAccountID: String? = nil,
    accountName: String? = nil,
    provider: Provider,
    label: String = "Usage",
    windowLabel: String? = "Weekly",
    modelLabel: String? = nil,
    resetAt: Date,
    statusOverride: UsageStatus? = nil
) -> UsageLimit {
    UsageLimit(
        id: id,
        provider: provider,
        accountID: accountID,
        configuredAccountID: configuredAccountID,
        accountName: accountName ?? accountID.capitalized,
        label: label,
        windowLabel: windowLabel,
        modelLabel: modelLabel,
        unit: .percent,
        used: 50,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: now,
        confidence: .observed,
        statusOverride: statusOverride
    )
}
