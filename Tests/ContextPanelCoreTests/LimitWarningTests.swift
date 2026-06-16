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

@Test func limitWarningSnapshotResolverUsesPersistedMergedSnapshotWhenAvailable() throws {
    let persistedSnapshot = StoredUsageSnapshot(
        savedAt: warningNow,
        snapshot: UsageSnapshot(generatedAt: warningNow, limits: [
            warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
            warningLimit(provider: .anthropic, accountID: "claude", label: "Claude 5-hour", used: 91, limit: 100),
        ])
    )
    let transientSnapshot = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(60), limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ])

    let effective = LimitWarningSnapshotResolver.effectiveSnapshot(
        transientSnapshot: transientSnapshot,
        persistedSnapshot: persistedSnapshot
    )

    #expect(Set(effective.mainLimitSummaries.map(\.id)) == ["openai:fiveHour", "anthropic:fiveHour"])
}

@Test func limitWarningSnapshotResolverFallsBackToTransientSnapshotWhenNoPersistedSnapshotExists() throws {
    let transientSnapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ])

    let effective = LimitWarningSnapshotResolver.effectiveSnapshot(
        transientSnapshot: transientSnapshot,
        persistedSnapshot: nil
    )

    #expect(effective.mainLimitSummaries.map(\.id) == ["openai:fiveHour"])
}

@Test func limitWarningCommitPlanAdvancesStateOnlyAfterDeliveryCommit() throws {
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ])
    let evaluation = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: .empty,
        snapshot: snapshot,
        now: warningNow
    )

    var plan = LimitWarningNotificationCommitPlan(
        currentState: .empty,
        targetState: evaluation.state,
        snapshot: snapshot,
        settings: settings
    )

    #expect(plan.hasPendingChanges)
    #expect(plan.persistedState.records.isEmpty)

    plan.commitDeliveredEvent(for: "openai:fiveHour")

    #expect(plan.persistedState == evaluation.state)
}

@Test func limitWarningCommitPlanPreservesStillLowSuppressionAcrossPartialRefresh() throws {
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let existingState = LimitWarningState(records: [
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.05,
            resetIdentity: nil
        ),
        LimitWarningRecord(
            laneID: "anthropic:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.09,
            resetIdentity: nil
        ),
    ])
    let stillLowPartialSnapshot = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(60), limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ])

    let plan = LimitWarningNotificationCommitPlan(
        currentState: existingState,
        targetState: existingState,
        snapshot: stillLowPartialSnapshot,
        settings: settings
    )

    #expect(plan.hasPendingChanges == false)
    #expect(plan.persistedState == existingState)
}

@Test func limitWarningCommitPlanClearsRecoveredLaneWithoutCommittingNewWarnings() throws {
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let existingState = LimitWarningState(records: [
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.05,
            resetIdentity: nil
        ),
    ])
    let recoveredSnapshot = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(60), limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 80, limit: 100),
    ])
    let recoveredEvaluation = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: existingState,
        snapshot: recoveredSnapshot,
        now: warningNow.addingTimeInterval(60)
    )

    let plan = LimitWarningNotificationCommitPlan(
        currentState: existingState,
        targetState: recoveredEvaluation.state,
        snapshot: recoveredSnapshot,
        settings: settings
    )

    #expect(plan.hasPendingChanges)
    #expect(plan.persistedState.records.isEmpty)
}

@Test func limitWarningCommitPlanSeparatesRecoveredCleanupFromUndeliveredNewWarning() throws {
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let existingState = LimitWarningState(records: [
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.05,
            resetIdentity: nil
        ),
    ])
    let mixedSnapshot = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(60), limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 80, limit: 100),
        warningLimit(provider: .anthropic, accountID: "claude", label: "Claude 5-hour", used: 95, limit: 100),
    ])
    let evaluation = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: existingState,
        snapshot: mixedSnapshot,
        now: warningNow.addingTimeInterval(60)
    )

    var plan = LimitWarningNotificationCommitPlan(
        currentState: existingState,
        targetState: evaluation.state,
        snapshot: mixedSnapshot,
        settings: settings
    )

    #expect(plan.hasPersistedStateChanges)
    #expect(plan.persistedState.records.isEmpty)

    plan.commitDeliveredEvent(for: "anthropic:fiveHour")

    #expect(plan.persistedState == evaluation.state)
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

@Test func limitWarningWebhookSettingsStoreRoundTripsAndClamps() throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))

    try store.save(LimitWarningWebhookSettings(
        isEnabled: true,
        preset: .genericJSON,
        destinationLabel: String(repeating: "A", count: 120),
        mentionText: String(repeating: "B", count: 180),
        timeoutSeconds: 99
    ))

    let loaded = store.load()
    #expect(loaded.isEnabled)
    #expect(loaded.preset == .genericJSON)
    #expect(loaded.destinationLabel.count == 80)
    #expect(loaded.mentionText.count == 120)
    #expect(loaded.timeoutSeconds == 15)
}

@Test func limitWarningWebhookPayloadOmitsSecretsAndFormatsDiscord() throws {
    let event = LimitWarningEvent(
        laneID: "openai:fiveHour",
        provider: .openAI,
        window: .fiveHour,
        thresholdPercentRemaining: 10,
        capacityRatio: 0.04,
        remaining: 4,
        limit: 100,
        resetsAt: warningNow.addingTimeInterval(3_600),
        accountCount: 2
    )
    let settings = LimitWarningWebhookSettings(isEnabled: true, preset: .discord, mentionText: "@here")

    let payload = try LimitWarningWebhookPayloadBuilder.payload(
        for: event,
        settings: settings,
        sentAt: warningNow,
        appVersion: "1.0.test"
    )
    let object = try #require(JSONSerialization.jsonObject(with: payload.data) as? [String: Any])
    let payloadText = String(decoding: payload.data, as: UTF8.self)
    let embeds = try #require(object["embeds"] as? [[String: Any]])
    let embed = try #require(embeds.first)
    let fields = try #require(embed["fields"] as? [[String: Any]])
    let capacityField = try #require(fields.first { $0["name"] as? String == "Capacity" })
    let capacityValue = try #require(capacityField["value"] as? String)
    let resetField = try #require(fields.first { $0["name"] as? String == "Reset" })

    #expect(object["content"] as? String == "@here")
    #expect(embed["title"] as? String == "OpenAI 5-hour is low")
    #expect(embed["description"] as? String == "OpenAI 5-hour capacity is below your 10% warning threshold.")
    #expect(capacityValue == "[----------] 4% left (4/100 points)")
    #expect(resetField["value"] as? String == "<t:\(Int(warningNow.addingTimeInterval(3_600).timeIntervalSince1970)):R>")
    #expect(fields.contains { $0["name"] as? String == "Limit" } == false)
    #expect(payloadText.components(separatedBy: "4% left").count == 2)
    #expect(!payloadText.contains("4 of 100 remaining"))
    #expect(!payloadText.contains("discord.com/api/webhooks"))
    #expect(!payloadText.localizedCaseInsensitiveContains("token"))
}

@Test func limitWarningWebhookDiscordPayloadHandlesMissingAbsoluteCapacity() throws {
    let event = LimitWarningEvent(
        laneID: "openai:fiveHour",
        provider: .openAI,
        window: .fiveHour,
        thresholdPercentRemaining: 10,
        capacityRatio: 0.08,
        remaining: nil,
        limit: nil,
        resetsAt: nil,
        accountCount: 1
    )
    let settings = LimitWarningWebhookSettings(isEnabled: true, preset: .discord)

    let payload = try LimitWarningWebhookPayloadBuilder.payload(
        for: event,
        settings: settings,
        sentAt: warningNow,
        appVersion: "1.0.test"
    )
    let object = try #require(JSONSerialization.jsonObject(with: payload.data) as? [String: Any])
    let embeds = try #require(object["embeds"] as? [[String: Any]])
    let embed = try #require(embeds.first)
    let fields = try #require(embed["fields"] as? [[String: Any]])
    let capacityField = try #require(fields.first { $0["name"] as? String == "Capacity" })
    let capacityValue = try #require(capacityField["value"] as? String)
    let resetField = try #require(fields.first { $0["name"] as? String == "Reset" })

    #expect(object["content"] == nil)
    #expect(capacityValue == "[#---------] 8% left")
    #expect(resetField["value"] as? String == "Unknown")
}

@Test func limitWarningWebhookSecretValidationRequiresHTTPS() {
    #expect(LimitWarningWebhookSecretStore.validatedWebhookURL("http://example.com/hook") == nil)
    #expect(LimitWarningWebhookSecretStore.validatedWebhookURL("not a url") == nil)
    #expect(LimitWarningWebhookSecretStore.validatedWebhookURL("https://example.com/hook") != nil)
}

@Test func limitWarningWebhookDeliveryRetriesAfterFailureUntilSuccess() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .genericJSON))
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10))
    let poster = FakeWebhookPoster(statusCodes: [500, 204])
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: poster,
        appVersion: "1.0.test"
    )
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .anthropic, accountID: "claude", label: "Claude Weekly", used: 93, limit: 100),
    ])

    let failed = await service.deliverIfNeeded(snapshot: snapshot, now: warningNow)
    let succeeded = await service.deliverIfNeeded(snapshot: snapshot, now: warningNow.addingTimeInterval(60))
    let suppressed = await service.deliverIfNeeded(snapshot: snapshot, now: warningNow.addingTimeInterval(120))

    #expect(failed.first?.statusCode == 500)
    #expect(failed.first?.succeeded == false)
    #expect(succeeded.first?.statusCode == 204)
    #expect(succeeded.first?.succeeded == true)
    #expect(suppressed.isEmpty)
    #expect(await poster.postCount == 2)
}

@Test func limitWarningWebhookDeliveryStateKeepsOneLiveRecordPerLaneAndSeparateTestRecord() {
    let older = warningNow
    let newer = warningNow.addingTimeInterval(60)
    let state = LimitWarningWebhookDeliveryState(records: [
        LimitWarningWebhookDeliveryRecord(
            deliveryKey: "primary-webhook:openai:fiveHour:reset-a:10",
            laneID: "openai:fiveHour",
            lastAttemptedAt: older,
            lastSucceededAt: older,
            lastHTTPStatus: 204,
            lastError: nil
        ),
        LimitWarningWebhookDeliveryRecord(
            deliveryKey: "primary-webhook:openai:fiveHour:reset-b:10",
            laneID: "openai:fiveHour",
            lastAttemptedAt: newer,
            lastSucceededAt: nil,
            lastHTTPStatus: 500,
            lastError: "HTTP 500"
        ),
        LimitWarningWebhookDeliveryRecord(
            deliveryKey: "test:123",
            laneID: "test:fiveHour",
            isTest: true,
            lastAttemptedAt: newer.addingTimeInterval(60),
            lastSucceededAt: newer.addingTimeInterval(60),
            lastHTTPStatus: 204,
            lastError: nil
        ),
    ])

    #expect(state.records.count == 2)
    #expect(state.record(for: "primary-webhook:openai:fiveHour:reset-b:10")?.lastHTTPStatus == 500)
    #expect(state.latestRecord?.deliveryKey == "primary-webhook:openai:fiveHour:reset-b:10")
    #expect(state.latestTestRecord?.deliveryKey == "test:123")
}

@Test func limitWarningWebhookDeliveryPrunesMissingLanes() throws {
    var state = LimitWarningWebhookDeliveryState(records: [
        LimitWarningWebhookDeliveryRecord(
            deliveryKey: "primary-webhook:openai:fiveHour:reset:10",
            laneID: "openai:fiveHour",
            lastAttemptedAt: warningNow,
            lastSucceededAt: warningNow,
            lastHTTPStatus: 204,
            lastError: nil
        ),
        LimitWarningWebhookDeliveryRecord(
            deliveryKey: "primary-webhook:anthropic:weekly:reset:10",
            laneID: "anthropic:weekly",
            lastAttemptedAt: warningNow,
            lastSucceededAt: warningNow,
            lastHTTPStatus: 204,
            lastError: nil
        ),
        LimitWarningWebhookDeliveryRecord(
            deliveryKey: "test:123",
            laneID: "test:fiveHour",
            isTest: true,
            lastAttemptedAt: warningNow.addingTimeInterval(1),
            lastSucceededAt: warningNow.addingTimeInterval(1),
            lastHTTPStatus: 204,
            lastError: nil
        ),
    ])

    state.removeRecords(forMissing: ["anthropic:weekly"])

    #expect(state.records.map(\.laneID).sorted() == ["anthropic:weekly", "test:fiveHour"])
    #expect(state.latestTestRecord?.deliveryKey == "test:123")
}

@Test func limitWarningWebhookSendTestWritesSeparateTestStatus() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: false, preset: .discord))
    let poster = FakeWebhookPoster(statusCodes: [204])
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: poster,
        appVersion: "1.0.test"
    )

    let result = await service.sendTest(now: warningNow)
    let state = stateStore.load()

    #expect(result.succeeded == true)
    #expect(state.latestRecord == nil)
    #expect(state.latestTestRecord?.succeeded == true)
}

@Test func limitWarningWebhookDeliveryUsesConfiguredWarningThreshold() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .genericJSON))
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 25))
    let poster = FakeWebhookPoster(statusCodes: [204])
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: poster,
        appVersion: "1.0.test"
    )
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 80, limit: 100),
    ])

    let result = await service.deliverIfNeeded(snapshot: snapshot, now: warningNow)

    #expect(result.first?.succeeded == true)
    #expect(await poster.postCount == 1)
}

@Test func limitWarningPendingNotificationQueueKeepsNewestPerLaneAndRemovesDelivered() throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LimitWarningPendingNotificationStore(
        queueURL: directory.appending(path: "limit-warning-pending-notifications.json")
    )
    let older = LimitWarningPendingNotification(
        event: warningEvent(laneID: "openai:weekly", capacityRatio: 0.10),
        queuedAt: warningNow,
        playsSound: true
    )
    let newer = LimitWarningPendingNotification(
        event: warningEvent(laneID: "openai:weekly", capacityRatio: 0.05),
        queuedAt: warningNow.addingTimeInterval(60),
        playsSound: false
    )
    let anthropic = LimitWarningPendingNotification(
        event: warningEvent(laneID: "anthropic:weekly", provider: .anthropic, capacityRatio: 0.08),
        queuedAt: warningNow.addingTimeInterval(30),
        playsSound: true
    )

    try store.append([older, anthropic, newer])
    var loaded = store.load()

    #expect(loaded.notifications.map(\.id) == ["anthropic:weekly", "openai:weekly"])
    #expect(loaded.notifications.first { $0.id == "openai:weekly" }?.event.capacityRatio == 0.05)
    #expect(loaded.notifications.first { $0.id == "openai:weekly" }?.playsSound == false)

    loaded.remove(ids: ["openai:weekly"])
    try store.save(loaded)

    #expect(store.load().notifications.map(\.id) == ["anthropic:weekly"])
}

@Test func limitWarningNotificationPresentationUsesStableLaneIdentifierAndContent() {
    let event = warningEvent(laneID: "openai:weekly", capacityRatio: 0.09)
    let notification = LimitWarningPendingNotification(
        event: event,
        queuedAt: warningNow,
        playsSound: true
    )

    let presentation = notification.presentation

    #expect(presentation.identifier == "context-panel-limit-warning-openai:weekly")
    #expect(presentation.title == event.title)
    #expect(presentation.body == event.body)
    #expect(presentation.playsSound == true)
}

@Test func limitWarningPendingNotificationQueueRemovesOnlyExactDeliveredNotification() {
    let queued = LimitWarningPendingNotification(
        event: warningEvent(laneID: "openai:weekly", capacityRatio: 0.05),
        queuedAt: warningNow.addingTimeInterval(60),
        playsSound: false
    )
    let staleDelivered = LimitWarningPendingNotification(
        event: warningEvent(laneID: "openai:weekly", capacityRatio: 0.10),
        queuedAt: warningNow,
        playsSound: true
    )
    var queue = LimitWarningPendingNotificationQueue(notifications: [queued])

    queue.remove([staleDelivered])
    #expect(queue.notifications == [queued])

    queue.remove([queued])
    #expect(queue.notifications.isEmpty)
}

@Test func limitWarningRecordMatchesDeliveredPendingNotificationOnlyForSameWarning() {
    let event = warningEvent(laneID: "openai:weekly", capacityRatio: 0.09)
    let notification = LimitWarningPendingNotification(
        event: event,
        queuedAt: warningNow,
        playsSound: true
    )
    let deliveredRecord = LimitWarningRecord(
        laneID: notification.id,
        lastThresholdPercentRemaining: event.thresholdPercentRemaining,
        lastNotifiedAt: warningNow.addingTimeInterval(1),
        lastCapacityRatio: event.capacityRatio,
        resetIdentity: event.resetIdentity
    )

    #expect(deliveredRecord.matchesDeliveredNotification(notification))

    let sameWarningIdentityWithDifferentCapacity = LimitWarningPendingNotification(
        event: warningEvent(laneID: "openai:weekly", capacityRatio: 0.06),
        queuedAt: warningNow,
        playsSound: true
    )
    #expect(deliveredRecord.matchesDeliveredNotification(sameWarningIdentityWithDifferentCapacity))

    let olderRecord = LimitWarningRecord(
        laneID: notification.id,
        lastThresholdPercentRemaining: event.thresholdPercentRemaining,
        lastNotifiedAt: warningNow.addingTimeInterval(-1),
        lastCapacityRatio: event.capacityRatio,
        resetIdentity: event.resetIdentity
    )
    let differentThresholdRecord = LimitWarningRecord(
        laneID: notification.id,
        lastThresholdPercentRemaining: event.thresholdPercentRemaining + 5,
        lastNotifiedAt: warningNow.addingTimeInterval(1),
        lastCapacityRatio: event.capacityRatio,
        resetIdentity: event.resetIdentity
    )

    #expect(olderRecord.matchesDeliveredNotification(notification))
    #expect(!differentThresholdRecord.matchesDeliveredNotification(notification))
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

private func warningEvent(
    laneID: String,
    provider: Provider = .openAI,
    window: MainLimitWindow = .weekly,
    capacityRatio: Double
) -> LimitWarningEvent {
    LimitWarningEvent(
        laneID: laneID,
        provider: provider,
        window: window,
        thresholdPercentRemaining: 10,
        capacityRatio: capacityRatio,
        remaining: Int((capacityRatio * 100).rounded()),
        limit: 100,
        resetsAt: warningNow.addingTimeInterval(3_600),
        accountCount: 1
    )
}

private func temporaryWarningDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-warning-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct StaticWebhookSecretStore: LimitWarningWebhookSecretLoading {
    let url: URL?

    func loadWebhookURL() throws -> URL? {
        url
    }
}

private actor FakeWebhookPoster: LimitWarningWebhookPosting {
    private var statusCodes: [Int]
    private(set) var postCount = 0

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    func post(payload: LimitWarningWebhookPayload, to url: URL, timeoutSeconds: Double) async throws -> Int {
        postCount += 1
        return statusCodes.isEmpty ? 204 : statusCodes.removeFirst()
    }
}
