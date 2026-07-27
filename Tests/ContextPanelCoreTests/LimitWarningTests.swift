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

@Test func limitWarningEvaluationTreatsAssumedAGYResetAsRecoveredCapacity() throws {
    let resetAt = warningNow.addingTimeInterval(60)
    let settings = LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10)
    let rawSnapshot = UsageSnapshot(generatedAt: warningNow, limits: [UsageLimit(
        id: "google:local:agy:gemini-5h",
        provider: .google,
        accountID: "local",
        accountName: "Antigravity",
        label: "Gemini 5-hour",
        windowLabel: "5-hour",
        modelLabel: "Gemini",
        unit: .percent,
        used: 95,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: warningNow,
        confidence: .observed
    )])
    let low = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: .empty,
        snapshot: rawSnapshot,
        now: warningNow
    )

    let assumedReset = LimitWarningEvaluator.evaluate(
        settings: settings,
        state: low.state,
        snapshot: rawSnapshot.presented(at: resetAt.addingTimeInterval(1)),
        now: resetAt.addingTimeInterval(1)
    )

    #expect(low.events.count == 1)
    #expect(assumedReset.events.isEmpty)
    #expect(assumedReset.state.record(for: "google:fiveHour") == nil)
    #expect(rawSnapshot.limits.first?.used == 95)
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

@Test func limitWarningCommitPlanPrunesLanesMissingFromAuthoritativeSnapshot() {
    let existingState = LimitWarningState(records: [
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.05,
            resetIdentity: nil
        ),
    ])

    let plan = LimitWarningNotificationCommitPlan(
        currentState: existingState,
        targetState: .empty,
        snapshot: UsageSnapshot(generatedAt: warningNow, limits: []),
        settings: LimitWarningSettings(isEnabled: true)
    )

    #expect(plan.hasPersistedStateChanges)
    #expect(plan.persistedState.records.isEmpty)
}

@Test func limitWarningCommitPlanPreservesUnrepresentedLanesForPendingDelivery() {
    let existingState = LimitWarningState(records: [
        LimitWarningRecord(
            laneID: "openai:fiveHour",
            lastThresholdPercentRemaining: 10,
            lastNotifiedAt: warningNow,
            lastCapacityRatio: 0.05,
            resetIdentity: nil
        ),
    ])

    let plan = LimitWarningNotificationCommitPlan(
        currentState: existingState,
        targetState: existingState,
        snapshot: UsageSnapshot(generatedAt: warningNow, limits: []),
        settings: LimitWarningSettings(isEnabled: true),
        prunesMissingLanes: false
    )

    #expect(!plan.hasPersistedStateChanges)
    #expect(plan.persistedState == existingState)
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
        settings: settings,
        prunesMissingLanes: false
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

@Test func limitWarningWebhookSecretValidationRejectsLocalAndPrivateDestinations() {
    let rejectedURLs = [
        "https://localhost/hook",
        "https://service.local/hook",
        "https://internal/hook",
        "https://127.0.0.1/hook",
        "https://127.1/hook",
        "https://10.0.0.1/hook",
        "https://100.64.0.1/hook",
        "https://172.16.0.1/hook",
        "https://192.168.1.1/hook",
        "https://169.254.169.254/latest/meta-data",
        "https://[::1]/hook",
        "https://[fd00::1]/hook",
        "https://[fe80::1]/hook",
        "https://[::ffff:127.0.0.1]/hook",
        "https://metadata.google.internal/computeMetadata/v1",
        "https://user:password@example.com/hook",
    ]

    for value in rejectedURLs {
        #expect(LimitWarningWebhookSecretStore.validatedWebhookURL(value) == nil)
    }
    #expect(LimitWarningWebhookSecretStore.validatedWebhookURL("https://discord.com/api/webhooks/example") != nil)
    #expect(LimitWarningWebhookSecretStore.validatedWebhookURL("https://8.8.8.8/hook") != nil)
}

@Test func limitWarningWebhookRedirectPolicyAllowsOnlyBodyPreservingSameOriginHTTPS() {
    let source = URL(string: "https://hooks.example.com/path")!

    #expect(LimitWarningWebhookURLPolicy.allowsRedirect(
        statusCode: 307,
        from: source,
        to: URL(string: "https://hooks.example.com/updated")!
    ))
    #expect(!LimitWarningWebhookURLPolicy.allowsRedirect(
        statusCode: 302,
        from: source,
        to: URL(string: "https://hooks.example.com/updated")!
    ))
    #expect(!LimitWarningWebhookURLPolicy.allowsRedirect(
        statusCode: 307,
        from: source,
        to: URL(string: "https://other.example.com/updated")!
    ))
    #expect(!LimitWarningWebhookURLPolicy.allowsRedirect(
        statusCode: 307,
        from: source,
        to: URL(string: "https://127.0.0.1/internal")!
    ))
    #expect(!LimitWarningWebhookURLPolicy.allowsRedirect(
        statusCode: 307,
        from: source,
        to: URL(string: "http://hooks.example.com/updated")!
    ))
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
    let failedSnapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(
            provider: .anthropic,
            accountID: "claude",
            label: "Claude Weekly",
            used: 93,
            limit: 100,
            resetsAt: warningNow.addingTimeInterval(20 * 60)
        ),
    ])
    let retrySnapshot = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(11 * 60), limits: [
        warningLimit(
            provider: .anthropic,
            accountID: "claude",
            label: "Claude Weekly",
            used: 93,
            limit: 100,
            resetsAt: warningNow.addingTimeInterval(31 * 60)
        ),
    ])

    let failed = await service.deliverIfNeeded(snapshot: failedSnapshot, now: failedSnapshot.generatedAt)
    let succeeded = await service.deliverIfNeeded(snapshot: retrySnapshot, now: retrySnapshot.generatedAt)
    let suppressed = await service.deliverIfNeeded(
        snapshot: retrySnapshot,
        now: retrySnapshot.generatedAt.addingTimeInterval(60)
    )

    #expect(failed.first?.statusCode == 500)
    #expect(failed.first?.succeeded == false)
    #expect(succeeded.first?.statusCode == 204)
    #expect(succeeded.first?.succeeded == true)
    #expect(suppressed.isEmpty)
    #expect(await poster.postCount == 2)
}

@Test func limitWarningWebhookDeliverySuppressesResetDriftUntilCapacityRecovers() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .discord))
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 15))
    let poster = FakeWebhookPoster(statusCodes: [204, 204])
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: poster,
        appVersion: "1.0.test"
    )
    let firstLow = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(
            provider: .anthropic,
            accountID: "claude",
            label: "Claude 5-hour",
            used: 100,
            limit: 100,
            resetsAt: warningNow.addingTimeInterval(20 * 60)
        ),
    ])
    let driftingLow = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(11 * 60), limits: [
        warningLimit(
            provider: .anthropic,
            accountID: "claude",
            label: "Claude 5-hour",
            used: 100,
            limit: 100,
            resetsAt: warningNow.addingTimeInterval(31 * 60)
        ),
    ])
    let recovered = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(16 * 60), limits: [
        warningLimit(
            provider: .anthropic,
            accountID: "claude",
            label: "Claude 5-hour",
            used: 80,
            limit: 100,
            resetsAt: warningNow.addingTimeInterval(36 * 60)
        ),
    ])
    let nextLow = UsageSnapshot(generatedAt: warningNow.addingTimeInterval(21 * 60), limits: [
        warningLimit(
            provider: .anthropic,
            accountID: "claude",
            label: "Claude 5-hour",
            used: 100,
            limit: 100,
            resetsAt: warningNow.addingTimeInterval(41 * 60)
        ),
    ])

    let firstResult = await service.deliverIfNeeded(snapshot: firstLow, now: firstLow.generatedAt)
    let driftingResult = await service.deliverIfNeeded(snapshot: driftingLow, now: driftingLow.generatedAt)
    let recoveredResult = await service.deliverIfNeeded(snapshot: recovered, now: recovered.generatedAt)

    #expect(firstResult.first?.succeeded == true)
    #expect(driftingResult.isEmpty)
    #expect(recoveredResult.isEmpty)
    #expect(stateStore.load().latestRecord == nil)

    let nextLowResult = await service.deliverIfNeeded(snapshot: nextLow, now: nextLow.generatedAt)

    #expect(nextLowResult.first?.succeeded == true)
    #expect(await poster.postCount == 2)
}

@Test func limitWarningWebhookDeliveryRedactsThrownErrorDetails() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .genericJSON))
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10))
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: ThrowingWebhookPoster(),
        appVersion: "1.0.test"
    )
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .anthropic, accountID: "claude", label: "Claude Weekly", used: 93, limit: 100),
    ])

    let result = await service.deliverIfNeeded(snapshot: snapshot, now: warningNow)
    let storedError = stateStore.load().latestRecord?.lastError

    #expect(result.first?.succeeded == false)
    #expect(result.first?.errorMessage?.contains("/Users/example/.code/auth.json") == false)
    #expect(result.first?.errorMessage?.contains("hooks.example.com") == false)
    #expect(storedError?.contains("/Users/example/.code/auth.json") == false)
    #expect(storedError?.contains("hooks.example.com") == false)
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

@Test func limitWarningWebhookDeliveryPrunesInactiveLanes() throws {
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

    state.retainLiveRecords(for: ["anthropic:weekly"])

    #expect(state.records.map(\.laneID).sorted() == ["anthropic:weekly", "test:fiveHour"])
    #expect(state.latestTestRecord?.deliveryKey == "test:123")
}

@Test func limitWarningWebhookDeliveryPrunesInactiveLanesBeforeEligibilityGuards() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    let staleRecord = LimitWarningWebhookDeliveryRecord(
        deliveryKey: "primary-webhook:openai:fiveHour:no-reset:10",
        laneID: "openai:fiveHour",
        lastAttemptedAt: warningNow,
        lastSucceededAt: warningNow,
        lastHTTPStatus: 204,
        lastError: nil
    )
    let emptySnapshot = UsageSnapshot(generatedAt: warningNow, limits: [])

    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: false, preset: .genericJSON))
    try stateStore.save(LimitWarningWebhookDeliveryState(records: [staleRecord]))
    let disabledService = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: FakeWebhookPoster(statusCodes: []),
        appVersion: "1.0.test"
    )

    #expect(await disabledService.deliverIfNeeded(snapshot: emptySnapshot, now: warningNow).isEmpty)
    #expect(stateStore.load().records.isEmpty)

    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .genericJSON))
    try stateStore.save(LimitWarningWebhookDeliveryState(records: [staleRecord]))
    let missingSecretService = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: nil),
        poster: FakeWebhookPoster(statusCodes: []),
        appVersion: "1.0.test"
    )

    #expect(await missingSecretService.deliverIfNeeded(snapshot: emptySnapshot, now: warningNow).isEmpty)
    #expect(stateStore.load().records.isEmpty)
}

@Test func limitWarningWebhookDeliverySerializesConcurrentStateWriters() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .genericJSON))
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10))
    try stateStore.save(LimitWarningWebhookDeliveryState(records: [LimitWarningWebhookDeliveryRecord(
        deliveryKey: "primary-webhook:google:stale:no-reset:10",
        laneID: "google:stale",
        lastAttemptedAt: warningNow,
        lastSucceededAt: warningNow,
        lastHTTPStatus: 204,
        lastError: nil
    )]))
    let poster = GatedWebhookPoster()
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: poster,
        appVersion: "1.0.test",
        lockWaitDuration: .seconds(2),
        lockRetryInterval: .milliseconds(5)
    )
    let snapshot = UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ])
    let liveDelivery = Task {
        await service.deliverIfNeeded(snapshot: snapshot, now: warningNow)
    }
    guard await poster.waitUntilFirstPostStarts() else {
        liveDelivery.cancel()
        await poster.releaseFirstPost()
        Issue.record("live webhook POST did not start before the test deadline")
        return
    }
    let testDelivery = Task {
        await service.sendTest(now: warningNow.addingTimeInterval(1))
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(await poster.postCount == 1)
    await poster.releaseFirstPost()
    let liveResults = await liveDelivery.value
    let testResult = await testDelivery.value
    let state = stateStore.load()

    #expect(liveResults.first?.succeeded == true)
    #expect(testResult.succeeded == true)
    #expect(await poster.postCount == 2)
    #expect(!state.records.contains(where: { $0.laneID == "google:stale" }))
    #expect(state.latestRecord != nil)
    #expect(state.latestTestRecord != nil)
}

@Test func limitWarningWebhookDeliverySummaryRequiresWholeBatchSuccess() throws {
    let summary = try #require(LimitWarningWebhookDeliverySummary(results: [
        LimitWarningWebhookDeliveryResult(
            attempted: true,
            succeeded: true,
            statusCode: 204,
            errorMessage: nil
        ),
        LimitWarningWebhookDeliveryResult(
            attempted: true,
            succeeded: false,
            statusCode: 500,
            errorMessage: "HTTP 500"
        ),
    ]))

    #expect(summary.succeeded == false)
    #expect(summary.eventCount == 2)
    #expect(summary.lastHTTPStatus == 500)
    #expect(summary.errorMessage == "HTTP 500")
    #expect(LimitWarningWebhookDeliverySummary(results: []) == nil)
}

@Test func limitWarningWebhookConfigurationResetWaitsForInFlightDelivery() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: true, preset: .genericJSON))
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 10))
    let poster = GatedWebhookPoster()
    let service = LimitWarningWebhookDeliveryService(
        warningSettingsStore: warningSettingsStore,
        settingsStore: settingsStore,
        stateStore: stateStore,
        secretStore: StaticWebhookSecretStore(url: URL(string: "https://example.com/hook")),
        poster: poster,
        lockWaitDuration: .seconds(2),
        lockRetryInterval: .milliseconds(5)
    )
    let delivery = Task { await service.deliverIfNeeded(snapshot: UsageSnapshot(generatedAt: warningNow, limits: [
        warningLimit(provider: .openAI, accountID: "codex", label: "Codex 5-hour", used: 95, limit: 100),
    ]), now: warningNow) }
    #expect(await poster.waitUntilFirstPostStarts())
    let reset = Task { try await service.updateConfiguration {} }
    await poster.releaseFirstPost()
    _ = await delivery.value
    try await reset.value
    #expect(stateStore.load().records.isEmpty)
}

@Test func limitWarningWebhookSendTestWritesSeparateTestStatus() async throws {
    let directory = try temporaryWarningDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = LimitWarningWebhookSettingsStore(settingsURL: directory.appending(path: "webhook-settings.json"))
    let warningSettingsStore = LimitWarningSettingsStore(settingsURL: directory.appending(path: "warning-settings.json"))
    let stateStore = LimitWarningWebhookDeliveryStateStore(stateURL: directory.appending(path: "webhook-state.json"))
    try settingsStore.save(LimitWarningWebhookSettings(isEnabled: false, preset: .discord))
    let poster = FakeWebhookPoster(statusCodes: [204, 204])
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
    let suppressed = await service.deliverIfNeeded(
        snapshot: snapshot,
        now: warningNow.addingTimeInterval(60)
    )
    try warningSettingsStore.save(LimitWarningSettings(isEnabled: true, thresholdPercentRemaining: 30))
    let changedThreshold = await service.deliverIfNeeded(
        snapshot: snapshot,
        now: warningNow.addingTimeInterval(120)
    )

    #expect(result.first?.succeeded == true)
    #expect(suppressed.isEmpty)
    #expect(changedThreshold.first?.succeeded == true)
    #expect(await poster.postCount == 2)
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

@Test func limitWarningPendingNotificationQueuePrunesMissingLanes() {
    var queue = LimitWarningPendingNotificationQueue(notifications: [
        LimitWarningPendingNotification(
            event: warningEvent(laneID: "openai:weekly", capacityRatio: 0.05),
            queuedAt: warningNow,
            playsSound: true
        ),
        LimitWarningPendingNotification(
            event: warningEvent(laneID: "anthropic:weekly", provider: .anthropic, capacityRatio: 0.08),
            queuedAt: warningNow,
            playsSound: true
        ),
    ])

    queue.removeNotifications(forMissing: ["anthropic:weekly"])

    #expect(queue.notifications.map(\.id) == ["anthropic:weekly"])
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

private actor GatedWebhookPoster: LimitWarningWebhookPosting {
    private var firstPostStarted = false
    private var firstPostReleased = false
    private(set) var postCount = 0

    func post(payload: LimitWarningWebhookPayload, to url: URL, timeoutSeconds: Double) async throws -> Int {
        postCount += 1
        if postCount == 1 {
            firstPostStarted = true
            while !firstPostReleased {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return 204
    }

    func waitUntilFirstPostStarts() async -> Bool {
        for _ in 0..<200 {
            if firstPostStarted { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return firstPostStarted
    }

    func releaseFirstPost() {
        firstPostReleased = true
    }
}

private struct ThrowingWebhookPoster: LimitWarningWebhookPosting {
    func post(payload: LimitWarningWebhookPayload, to url: URL, timeoutSeconds: Double) async throws -> Int {
        throw NSError(
            domain: "WebhookTest",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "failed at /Users/example/.code/auth.json via https://hooks.example.com/private",
            ]
        )
    }
}
