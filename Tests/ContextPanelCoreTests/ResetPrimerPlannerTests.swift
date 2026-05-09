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
