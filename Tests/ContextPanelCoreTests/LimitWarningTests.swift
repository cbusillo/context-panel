import Foundation
import Testing

@testable import ContextPanelCore

private let warningNow = Date(timeIntervalSinceReferenceDate: 900_100_000)

@Test func limitWarningSettingsStoreRoundTripsAndClampsThreshold() throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    var settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 99, playsSound: false)

    try store.save(settings)

    #expect(store.load().isEnabled == true)
    #expect(store.load().thresholdPercentRemaining == 75)
    #expect(store.load().playsSound == false)

    settings.setThresholdPercentRemaining(-4)
    try store.save(settings)

    #expect(store.load().thresholdPercentRemaining == 1)
}

@Test func limitWarningEvaluatorWarnsWhenMainLimitFallsBelowThreshold() throws {
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .anthropic, accountID: "claude", label: "Claude 5-hour", used: 91, limit: 100),
    ])

    let result = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: .empty,
        snapshot: snapshot,
        now: warningNow
    )

    #expect(result.events.map(\.laneID) == ["anthropic:fiveHour"])
    #expect(result.events.first?.title == "Anthropic 5-hour is low")
    #expect(result.events.first?.remaining == 9)
    #expect(result.state.record(for: "anthropic:fiveHour") != nil)
}

@Test func limitWarningEvaluatorIgnoresDisabledUnknownAndNonMainLimits() {
    let disabled = LimitWarningEvaluator.evaluate(
        settings: LimitWarningSettings(isEnabled: false, thresholdPercentRemaining: 10),
        state: LimitWarningState(records: [LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.05,
            resetIdentity: nil
        )]),
        snapshot: UsageSnapshot(generatedAt: warningNow, limits: [
            warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
        ]),
        now: warningNow
    )
    #expect(disabled.events.isEmpty)
    #expect(disabled.state.records.isEmpty)

    let enabled = LimitWarningEvaluator.evaluate(
        settings: LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10),
        state: .empty,
        snapshot: UsageSnapshot(generatedAt: warningNow, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "codex",
                accountName: "Codex",
                label: "Requests",
                unit: .requests,
                used: 95,
                limit: 100
            ),
            UsageLimit(
                provider: .google,
                accountID: "gemini",
                accountName: "Gemini",
                label: "Gemini 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: nil,
                limit: nil
            ),
        ]),
        now: warningNow
    )

    #expect(enabled.events.isEmpty)
    #expect(enabled.state.records.isEmpty)
}

@Test func limitWarningEvaluatorSuppressesDuplicatesUntilThresholdOrResetChanges() throws {
    let resetAt = warningNow.addingTimeInterval(60 * 60)
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(
            provider: .openAI,
            accountID: "codex",
            label: "Codex 5-hour",
            used: 92,
            limit: 100,
            resetsAt: resetAt
        ),
    ])

    let first = LimitWarningEvaluator.evaluate(settings: settings, state: .empty, snapshot: snapshot, now: warningNow)
    let duplicate = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: first.state,
        snapshot: snapshot,
        now: warningNow.addingTimeInterval(60)
    )
    let changedThreshold = LimitWarningEvaluator.evaluate(
        settings: LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 15),
        state: first.state,
        snapshot: snapshot,
        now: warningNow.addingTimeInterval(120)
    )
    let nextReset = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(180), limits: [
        warningLimit(
            provider: .openAI,
            accountID: "codex",
            label: "Codex 5-hour",
            used: 92,
            limit: 100,
            resetsAt: resetAt.addingTimeInterval(5 * 3_600)
        ),
    ])
    let changedReset = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: first.state,
        snapshot: nextReset,
        now: warningNow.addingTimeInterval(180)
    )

    #expect(first.events.count == 1)
    #expect(duplicate.events.isEmpty)
    #expect(changedThreshold.events.count == 1)
    #expect(changedReset.events.count == 1)
}

@Test func limitWarningEvaluatorClearsStateAfterRecovery() throws {
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let lowSnapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ])
    let low = LimitWarningEvaluator.evaluate(settings: settings, state: .empty, snapshot: lowSnapshot, now: warningNow)
    let recoveredSnapshot = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(60), limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 80, limit: 100),
    ])

    let recovered = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: low.state,
        snapshot: recoveredSnapshot,
        now: warningNow.addingTimeInterval(60)
    )

    #expect(recovered.events.isEmpty)
    #expect(recovered.state.record(for: "openai:fiveHour") == nil)
}

@Test func limitWarningStateStoreKeepsNewestRecordPerLane() throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LimitWarningStateStore(stateURL: directory.appending(path: "warning-state.json"))

    try store.save(LimitWarningState(records: [
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.08,
            resetIdentity: nil
        ),
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 15,
            lastNotifiedAt: warningNow.addingTimeInterval(60),
            lastCapacityRatio: 0.07,
            resetIdentity: nil
        ),
    ]))

    let loaded = store.load()

    #expect(loaded.records.count == 1)
    #expect(loaded.record(for: "openai:fiveHour")?.lastThresholdPercentRemaining == 15)
}

private func warningLimit(
    provider: Provider,
    accountID: String,
    label: String,
    used: Int,
    limit: Int,
    resetsAt: Date? = nil
) -> UsageLimit {
    UsageLimit(
        provider: provider,
        accountID: accountID,
        accountName: accountID,
        label: label,
        unit: .requests,
        used: used,
        limit: limit,
        resetsAt: resetsAt,
        lastUpdatedAt: warningNow
    )
}

private func temporaryWarningDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-warning-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
