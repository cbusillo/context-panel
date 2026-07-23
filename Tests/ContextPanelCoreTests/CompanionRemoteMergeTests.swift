import Foundation
import Testing

@testable import ContextPanelCore

@Test func companionRemoteMergePreservesUnreportedOpenAIAccounts() {
    let remoteDate = Date(timeIntervalSince1970: 10_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: remoteDate),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: incomingDate),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(merged.snapshot.limits.first { $0.accountName == "OpenAI A" }?.used == 30)
    #expect(merged.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
    #expect(merged.snapshot.providerStatuses.map(\.accountName) == ["OpenAI A", "OpenAI B"])
}

@Test func companionRemoteMergeKeepsHealthyAccountsWhenAnotherMacLacksOpenAIAuth() {
    let remoteDate = Date(timeIntervalSince1970: 20_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: remoteDate),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(
                name: "Every Code",
                accountID: "missing-auth-file",
                used: nil,
                generatedAt: incomingDate,
                status: .failure
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(merged.snapshot.providerStatuses.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(!merged.snapshot.providerStatuses.contains { $0.status == .failure })
}

@Test func companionRemoteFirstPublishKeepsSavedLimitWithoutSharingFreshFailure() throws {
    let lastGoodDate = Date(timeIntervalSince1970: 25_000)
    let publishDate = lastGoodDate.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 60)
    let incoming = companionRemoteDocument(
        generatedAt: publishDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: publishDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: publishDate),
            companionRemoteAccount(
                name: "Every Code",
                accountID: "openai-saved",
                used: 7,
                generatedAt: lastGoodDate,
                status: .failure,
                statusGeneratedAt: publishDate,
                limitStatus: .healthy
            ),
        ]
    )

    let published = incoming.mergingForRemotePublish(existing: nil)
    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: published, status: published.companionStatus),
        now: publishDate
    )

    #expect(published.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B", "Every Code"])
    #expect(published.snapshot.providerStatuses.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(!published.snapshot.providerStatuses.contains { $0.status == .failure })
    #expect(
        published.companionStatus(
            now: publishDate,
            maximumAge: SnapshotFreshness.companionProviderMaximumAge
        ) == .healthy
    )
    #expect(widget.limits.first { $0.accountName == "Every Code" }?.status == .stale)
    #expect(widget.limits.first { $0.accountName == "OpenAI A" }?.status == .healthy)
    #expect(widget.status == .healthy)
    #expect(widget.refreshAttentionSummary == nil)
}

@Test func companionRemoteFirstPublishTreatsOnlySavedUsageAsStaleDespiteFreshFailureAttempt() {
    let lastGoodDate = Date(timeIntervalSince1970: 26_000)
    let publishDate = lastGoodDate.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 60)
    let incoming = companionRemoteDocument(
        generatedAt: publishDate,
        accounts: [
            companionRemoteAccount(
                name: "Every Code",
                accountID: "openai-saved",
                used: 7,
                generatedAt: lastGoodDate,
                status: .failure,
                statusGeneratedAt: publishDate,
                limitStatus: .healthy
            ),
        ]
    )

    let published = incoming.mergingForRemotePublish(existing: nil)
    let effectiveStatus = published.companionStatus(
        now: publishDate,
        maximumAge: SnapshotFreshness.companionProviderMaximumAge
    )
    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: published, status: effectiveStatus),
        now: publishDate
    )

    #expect(published.snapshot.generatedAt == publishDate)
    #expect(effectiveStatus == .stale)
    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.message == "Showing saved usage from your Mac.")
    #expect(widget.refreshAttentionSummary == nil)
}

@Test func companionRemoteFirstPublishDropsStatusOnlyFailureWhenProviderHasUsage() {
    let publishDate = Date(timeIntervalSince1970: 27_000)
    let incoming = companionRemoteDocument(
        generatedAt: publishDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: publishDate),
            companionRemoteAccount(
                name: "Every Code",
                accountID: "missing-auth-file",
                used: nil,
                generatedAt: publishDate,
                status: .failure
            ),
        ]
    )

    let published = incoming.mergingForRemotePublish(existing: nil)

    #expect(published.snapshot.limits.map(\.accountName) == ["OpenAI A"])
    #expect(published.snapshot.providerStatuses.map(\.accountName) == ["OpenAI A"])
    #expect(published.companionStatus == .healthy)
}

@Test func companionRemoteFirstPublishKeepsFailureWhenProviderHasNoUsage() {
    let publishDate = Date(timeIntervalSince1970: 28_000)
    let incoming = companionRemoteDocument(
        generatedAt: publishDate,
        accounts: [
            companionRemoteAccount(
                name: "Every Code",
                accountID: "missing-auth-file",
                used: nil,
                generatedAt: publishDate,
                status: .failure
            ),
        ]
    )

    let published = incoming.mergingForRemotePublish(existing: nil)

    #expect(published.snapshot.limits.isEmpty)
    #expect(published.snapshot.providerStatuses.map(\.status) == [.failure])
    #expect(published.companionStatus == .failure)
}

@Test func companionRemoteMergeDoesNotLetFailedCollectorReplaceHealthySameAccount() {
    let remoteDate = Date(timeIntervalSince1970: 30_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: nil,
                generatedAt: incomingDate,
                status: .failure
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.count == 1)
    #expect(merged.snapshot.limits[0].used == 20)
    #expect(merged.snapshot.providerStatuses.count == 1)
    #expect(merged.snapshot.providerStatuses[0].status == .healthy)
    #expect(merged.snapshot.providerStatuses[0].generatedAt == remoteDate)
}

@Test func companionRemoteMergeReplacesAllWindowsForTouchedHealthyAccount() {
    let remoteDate = Date(timeIntervalSince1970: 40_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 20,
                generatedAt: remoteDate,
                labels: ["Weekly", "Five hour"]
            ),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: incomingDate,
                labels: ["Weekly"]
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.map(\.label) == ["Weekly"])
    #expect(merged.snapshot.limits[0].used == 30)
}

@Test func companionRemoteMergeKeepsNewerRemoteAccountWhenOlderMacPublishesLater() {
    let incomingDate = Date(timeIntervalSince1970: 50_000)
    let remoteDate = incomingDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 40, generatedAt: remoteDate),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: incomingDate),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.count == 1)
    #expect(merged.snapshot.limits[0].used == 40)
    #expect(merged.snapshot.providerStatuses[0].generatedAt == remoteDate)
}

@Test func companionRemoteMergeDoesNotAdvancePreservedAccountWithDocumentTimestamp() {
    let firstObservation = Date(timeIntervalSince1970: 55_000)
    let remoteObservation = firstObservation.addingTimeInterval(60)
    let incomingDocumentDate = remoteObservation.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteObservation,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: remoteObservation
            ),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDocumentDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: incomingDocumentDate
            ),
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 20,
                generatedAt: firstObservation
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.first { $0.accountName == "OpenAI A" }?.used == 30)
    #expect(merged.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
    #expect(merged.snapshot.providerStatuses.first { $0.accountName == "OpenAI B" }?.generatedAt == remoteObservation)
}

@Test func companionPresentationAgesPreservedAccountWithoutAgingFreshSibling() throws {
    let remoteDate = Date(timeIntervalSince1970: 56_000)
    let incomingDate = remoteDate.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: remoteDate),
        ],
        burnRate: 10
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: incomingDate),
        ],
        burnRate: 20
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)
    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: merged, status: .healthy),
        now: incomingDate
    )

    #expect(widget.limits.first { $0.accountName == "OpenAI A" }?.status == .healthy)
    #expect(widget.limits.first { $0.accountName == "OpenAI B" }?.status == .stale)
    let weekly = try #require(widget.usageSnapshot.mainLimitSummaries.first { $0.id == "openai:weekly" })
    #expect(weekly.liveLimits.map(\.accountName) == ["OpenAI A"])
    #expect(widget.observedBurnRates["openai:weekly"] == nil)
    #expect(widget.status == .healthy)
    #expect(widget.refreshAttentionSummary == nil)
}

@Test func companionRemoteMergePreservesDistinctSavedAccountWhenFreshSiblingArrives() {
    let savedDate = Date(timeIntervalSince1970: 56_500)
    let freshDate = savedDate.addingTimeInterval(SnapshotFreshness.companionProviderMaximumAge + 60)
    let existing = companionRemoteDocument(
        generatedAt: savedDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: savedDate,
                status: .stale
            ),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: freshDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: freshDate),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: existing)

    #expect(merged.snapshot.limits.map(\.accountName) == ["OpenAI B", "OpenAI A"])
    #expect(merged.snapshot.limits.first { $0.accountName == "OpenAI B" }?.used == 40)
}

@Test func companionRemoteMergeEqualObservationChoosesSameAccountInEitherOrder() {
    let observedAt = Date(timeIntervalSince1970: 56_750)
    let first = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: observedAt),
        ]
    )
    let second = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: observedAt),
        ]
    )

    let firstThenSecond = second.mergingForRemotePublish(existing: first)
    let secondThenFirst = first.mergingForRemotePublish(existing: second)

    #expect(firstThenSecond.snapshot == secondThenFirst.snapshot)
}

@Test func companionRemoteMergeRejectsFailedRepublishAuthorityAndBurnRate() {
    let observationDate = Date(timeIntervalSince1970: 56_800)
    let failureDate = observationDate.addingTimeInterval(60)
    let healthy = companionRemoteDocument(
        generatedAt: observationDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 20,
                generatedAt: observationDate
            ),
        ],
        burnRate: 10
    )
    let failedRepublish = companionRemoteDocument(
        generatedAt: failureDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: observationDate,
                status: .failure,
                statusGeneratedAt: failureDate,
                limitStatus: .healthy
            ),
        ],
        burnRate: 99
    )

    let merged = failedRepublish.mergingForRemotePublish(existing: healthy)

    #expect(merged.snapshot.limits[0].used == 20)
    #expect(merged.snapshot.providerStatuses[0].status == .healthy)
    #expect(merged.snapshot.providerStatuses[0].generatedAt == observationDate)
    #expect(merged.observedBurnRates["openai:weekly"]?.unitsPerHour == 10)
}

@Test func companionRemoteMergeEqualDocumentsAreDeterministicInEitherOrder() {
    let observedAt = Date(timeIntervalSince1970: 56_900)
    var secondPreferences = WidgetDisplayPreferences.defaultPreferences
    secondPreferences.moveMainLimits(fromOffsets: IndexSet(integer: 6), toOffset: 0)
    let first = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: observedAt),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: observedAt),
        ],
        promptAccounts: [
            companionRemotePromptAccount(name: "OpenAI A", accountID: "openai-a", observedAt: observedAt),
        ],
        burnRate: 10
    )
    let second = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 45, generatedAt: observedAt),
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: observedAt),
        ],
        promptAccounts: [
            companionRemotePromptAccount(name: "OpenAI Alpha", accountID: "openai-a", observedAt: observedAt),
        ],
        burnRate: 20,
        widgetDisplayPreferences: secondPreferences,
        fastModeForecastSettings: FastModeForecastSettings(
            defaultStandardBurnRateUnitsPerHour: 5,
            fastModeMultiplier: 4,
            reserveUnits: 12,
            minimumSafeHours: 3
        )
    )

    let firstThenSecond = second.mergingForRemotePublish(existing: first)
    let secondThenFirst = first.mergingForRemotePublish(existing: second)

    #expect(firstThenSecond == secondThenFirst)
}

@Test func companionPresentationTreatsTimestampLessPollingAccountAsSaved() throws {
    let now = Date(timeIntervalSince1970: 56_950)
    let freshLimit = UsageLimit(
        provider: .openAI,
        accountID: "openai-a",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI A",
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 20,
        limit: 100,
        lastUpdatedAt: now,
        freshnessMode: .polling
    )
    let timestampLessLimit = UsageLimit(
        provider: .openAI,
        accountID: "openai-b",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI B",
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 40,
        limit: 100,
        lastUpdatedAt: nil,
        freshnessMode: .polling
    )
    let document = CompanionSyncDocument(
        storedSnapshot: StoredUsageSnapshot(
            savedAt: now,
            snapshot: UsageSnapshot(generatedAt: now, limits: [freshLimit, timestampLessLimit]),
            reports: [
                StoredProviderReport(
                    provider: .openAI,
                    accountID: "openai-a",
                    configuredAccountID: "openai-code-default",
                    accountName: "OpenAI A",
                    generatedAt: now,
                    status: .healthy,
                    errorMessage: nil
                ),
            ]
        ),
        publishedAt: now,
        observedBurnRates: [
            "openai:weekly": ObservedBurnRate(
                limitID: "openai:weekly",
                unitsPerHour: 10,
                observedDurationHours: 2,
                sampleCount: 3
            ),
        ]
    )
    let status = document.companionStatus(
        now: now,
        maximumAge: SnapshotFreshness.companionProviderMaximumAge
    )
    let widget = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: document, status: status),
        now: now
    )

    #expect(status == .healthy)
    #expect(widget.limits.first { $0.accountName == "OpenAI A" }?.status == .healthy)
    #expect(widget.limits.first { $0.accountName == "OpenAI B" }?.status == .stale)
    let weekly = try #require(widget.usageSnapshot.mainLimitSummaries.first { $0.id == "openai:weekly" })
    #expect(weekly.liveLimits.map(\.accountName) == ["OpenAI A"])
    #expect(widget.observedBurnRates["openai:weekly"] == nil)
}

@Test func companionRemoteMergePrefersHealthyIncomingOverNewerFailedExistingAccount() {
    let healthyDate = Date(timeIntervalSince1970: 57_000)
    let failureDate = healthyDate.addingTimeInterval(60)
    let existing = companionRemoteDocument(
        generatedAt: failureDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: nil,
                generatedAt: failureDate,
                status: .failure
            ),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: healthyDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: healthyDate
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: existing)

    #expect(merged.snapshot.limits.count == 1)
    #expect(merged.snapshot.limits[0].used == 30)
    #expect(merged.snapshot.providerStatuses[0].status == .healthy)
    #expect(merged.snapshot.providerStatuses[0].generatedAt == healthyDate)
}

@Test func companionRemoteMergeDropsExistingMissingAuthLaneWhenHealthyAccountsArrive() {
    let failureDate = Date(timeIntervalSince1970: 59_000)
    let healthyDate = failureDate.addingTimeInterval(60)
    let existing = companionRemoteDocument(
        generatedAt: failureDate,
        accounts: [
            companionRemoteAccount(
                name: "Every Code",
                accountID: "missing-auth-file",
                used: nil,
                generatedAt: failureDate,
                status: .failure
            ),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: healthyDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: healthyDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: healthyDate),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: existing)

    #expect(merged.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(merged.snapshot.providerStatuses.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(!merged.snapshot.providerStatuses.contains { $0.status == .failure })
}

@Test func companionRemoteMergeUnionsPromptCacheAccounts() {
    let remoteDate = Date(timeIntervalSince1970: 60_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [],
        promptAccounts: [
            companionRemotePromptAccount(name: "OpenAI A", accountID: "openai-a", observedAt: remoteDate),
        ]
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [],
        promptAccounts: [
            companionRemotePromptAccount(name: "OpenAI B", accountID: "openai-b", observedAt: incomingDate),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.promptCacheSummaries.map(\.accountName) == ["OpenAI A", "OpenAI B"])
}

@Test func companionRemoteMergeKeepsFullPoolBurnRateWhenIncomingMacHasSubset() {
    let remoteDate = Date(timeIntervalSince1970: 65_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: remoteDate),
        ],
        burnRate: 10
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: incomingDate),
        ],
        burnRate: 20
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.observedBurnRates["openai:weekly"]?.unitsPerHour == 10)
}

@Test func companionRemoteMergeDropsBurnRateWhenNeitherMacCoversMergedPool() {
    let remoteDate = Date(timeIntervalSince1970: 67_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
        ],
        burnRate: 10
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 30, generatedAt: incomingDate),
        ],
        burnRate: 20
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.observedBurnRates["openai:weekly"] == nil)
}

@Test func companionRemoteMergeUsesIncomingBurnRateWhenAllAccountsReplaceTheirWindows() {
    let remoteDate = Date(timeIntervalSince1970: 69_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: remoteDate),
        ],
        burnRate: 10
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: incomingDate),
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 50,
                generatedAt: incomingDate,
                labels: ["Five hour"]
            ),
        ],
        burnRate: 20
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.filter { $0.label == "Weekly" }.map(\.accountName) == ["OpenAI A"])
    #expect(merged.observedBurnRates["openai:weekly"]?.unitsPerHour == 20)
}

@Test func companionRemoteMergeKeepsRateCoveringTheMergedWindowPool() {
    let remoteDate = Date(timeIntervalSince1970: 71_000)
    let incomingDate = remoteDate.addingTimeInterval(120)
    let staleIncomingDate = remoteDate.addingTimeInterval(-60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
            companionRemoteAccount(name: "OpenAI B", accountID: "openai-b", used: 40, generatedAt: remoteDate),
        ],
        burnRate: 10
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 30, generatedAt: incomingDate),
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 50,
                generatedAt: staleIncomingDate,
                labels: ["Five hour"]
            ),
        ],
        burnRate: 20
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits.filter { $0.label == "Weekly" }.map(\.accountName) == ["OpenAI A", "OpenAI B"])
    #expect(merged.observedBurnRates["openai:weekly"]?.unitsPerHour == 10)
}

@Test func companionRemoteMergeKeepsRateFromTheLiveWindowPool() {
    let remoteDate = Date(timeIntervalSince1970: 72_000)
    let incomingDate = remoteDate.addingTimeInterval(60)
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [
            companionRemoteAccount(name: "OpenAI A", accountID: "openai-a", used: 20, generatedAt: remoteDate),
        ],
        burnRate: 10
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: incomingDate,
                status: .stale
            ),
        ],
        burnRate: 20
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.snapshot.limits[0].status == .healthy)
    #expect(merged.observedBurnRates["openai:weekly"]?.unitsPerHour == 10)
}

@Test func companionRemoteMergeKeepsSettingsFromTheFresherDocument() {
    let incomingDate = Date(timeIntervalSince1970: 73_000)
    let remoteDate = incomingDate.addingTimeInterval(60)
    var remotePreferences = WidgetDisplayPreferences.defaultPreferences
    remotePreferences.moveMainLimits(fromOffsets: IndexSet(integer: 6), toOffset: 0)
    let remoteSettings = FastModeForecastSettings(
        defaultStandardBurnRateUnitsPerHour: 5,
        fastModeMultiplier: 4,
        reserveUnits: 12,
        minimumSafeHours: 3
    )
    let remote = companionRemoteDocument(
        generatedAt: remoteDate,
        accounts: [],
        widgetDisplayPreferences: remotePreferences,
        fastModeForecastSettings: remoteSettings
    )
    let incoming = companionRemoteDocument(
        generatedAt: incomingDate,
        accounts: []
    )

    let merged = incoming.mergingForRemotePublish(existing: remote)

    #expect(merged.widgetDisplayPreferences == remotePreferences)
    #expect(merged.fastModeForecastSettings == remoteSettings)
}

@Test func companionRemoteRetentionKeepsAccountMissingFromOneMacBeforeBoundary() {
    let observedAt = Date(timeIntervalSince1970: 1_000_000)
    let now = observedAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge - 1)
    let remote = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: observedAt
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: observedAt)
    let incoming = companionRemoteDocument(generatedAt: now, accounts: [])

    let merged = incoming.mergingForRemotePublish(existing: remote, now: now)

    #expect(merged.snapshot.limits.map(\.accountName) == ["OpenAI B"])
    #expect(merged.snapshot.providerStatuses.map(\.accountName) == ["OpenAI B"])
    #expect(merged.accountRetentionStates == nil)
}

@Test func companionRemoteRetentionExpiresAtExactBoundaryAcrossAccountState() {
    let observedAt = Date(timeIntervalSince1970: 1_100_000)
    let now = observedAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let remote = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: observedAt
            ),
        ],
        promptAccounts: [
            companionRemotePromptAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                observedAt: observedAt
            ),
        ],
        burnRate: 10
    ).mergingForRemotePublish(existing: nil, now: observedAt)
    let incoming = companionRemoteDocument(generatedAt: now, accounts: [])

    let merged = incoming.mergingForRemotePublish(existing: remote, now: now)

    #expect(merged.snapshot.limits.isEmpty)
    #expect(merged.snapshot.providerStatuses.isEmpty)
    #expect(merged.snapshot.promptCacheSummaries.isEmpty)
    #expect(merged.observedBurnRates.isEmpty)
    #expect(merged.accountRetentionStates == nil)
    #expect(merged.companionStatus == .unknown)
}

@Test func companionRemoteRetentionRemovesOnlyAccountsAbsentPastBoundary() {
    let now = Date(timeIntervalSince1970: 4_000_000)
    let expiredObservation = now.addingTimeInterval(-SnapshotFreshness.companionAccountRetentionAge - 1)
    let remote = companionRemoteDocument(
        generatedAt: expiredObservation,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: expiredObservation
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: expiredObservation)
    let incoming = companionRemoteDocument(
        generatedAt: now,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: now
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote, now: now)

    #expect(merged.snapshot.limits.map(\.accountName) == ["OpenAI A"])
    #expect(merged.snapshot.providerStatuses.map(\.accountName) == ["OpenAI A"])
    #expect(merged.accountRetentionStates == nil)
}

@Test func companionRemoteRetentionIgnoresClockSkewedDocumentEnvelope() {
    let now = Date(timeIntervalSince1970: 5_000_000)
    let remoteObservation = now.addingTimeInterval(-60)
    let skewedEnvelope = now.addingTimeInterval(40 * 24 * 60 * 60)
    let remote = companionRemoteDocument(
        generatedAt: remoteObservation,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: remoteObservation
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: remoteObservation)
    let incoming = companionRemoteDocument(
        generatedAt: skewedEnvelope,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: now
            ),
        ]
    )

    let merged = incoming.mergingForRemotePublish(existing: remote, now: now)

    #expect(Set(merged.snapshot.limits.map(\.accountName)) == ["OpenAI A", "OpenAI B"])
    #expect(merged.accountRetentionStates == nil)
}

@Test func companionRemoteRetentionIsDeterministicInEitherMergeOrder() {
    let now = Date(timeIntervalSince1970: 6_000_000)
    let expiredObservation = now.addingTimeInterval(-SnapshotFreshness.companionAccountRetentionAge)
    let first = companionRemoteDocument(
        generatedAt: now,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 30,
                generatedAt: now
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: now)
    let second = companionRemoteDocument(
        generatedAt: now,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI B",
                accountID: "openai-b",
                used: 40,
                generatedAt: expiredObservation
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: expiredObservation)

    let firstThenSecond = second.mergingForRemotePublish(existing: first, now: now)
    let secondThenFirst = first.mergingForRemotePublish(existing: second, now: now)

    #expect(firstThenSecond == secondThenFirst)
    #expect(firstThenSecond.snapshot.limits.map(\.accountName) == ["OpenAI A"])
}

@Test func companionRemoteRetentionFailureAttemptDoesNotRefreshAnchor() {
    let observedAt = Date(timeIntervalSince1970: 7_000_000)
    let now = observedAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let healthy = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 20,
                generatedAt: observedAt
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: observedAt)
    let failedRepublish = companionRemoteDocument(
        generatedAt: now,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 20,
                generatedAt: observedAt,
                status: .failure,
                statusGeneratedAt: now,
                limitStatus: .healthy
            ),
        ]
    )

    let merged = failedRepublish.mergingForRemotePublish(existing: healthy, now: now)

    #expect(merged.snapshot.limits.isEmpty)
    #expect(merged.snapshot.providerStatuses.isEmpty)
    #expect(merged.accountRetentionStates == nil)
}

@Test func companionRemoteRetentionAllowsFreshAccountToReappear() {
    let observedAt = Date(timeIntervalSince1970: 8_000_000)
    let expiry = observedAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let remote = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 20,
                generatedAt: observedAt
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: observedAt)
    let retired = companionRemoteDocument(
        generatedAt: expiry,
        accounts: []
    ).mergingForRemotePublish(existing: remote, now: expiry)
    let refreshedAt = expiry.addingTimeInterval(1)
    let fresh = companionRemoteDocument(
        generatedAt: refreshedAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 35,
                generatedAt: refreshedAt
            ),
        ]
    )

    let restored = fresh.mergingForRemotePublish(existing: retired, now: refreshedAt)

    #expect(restored.snapshot.limits.map(\.used) == [35])
    #expect(restored.snapshot.providerStatuses.map(\.status) == [.healthy])
    #expect(restored.accountRetentionStates == nil)
}

@Test func companionRemoteRetentionPersistsGraceForUnanchoredFailureLane() {
    let firstFailureAt = Date(timeIntervalSince1970: 9_000_000)
    let expiry = firstFailureAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let firstFailure = companionRemoteDocument(
        generatedAt: firstFailureAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: nil,
                generatedAt: firstFailureAt,
                status: .failure
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: firstFailureAt)
    let repeatedFailure = companionRemoteDocument(
        generatedAt: expiry,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: nil,
                generatedAt: expiry,
                status: .failure
            ),
        ]
    )

    let expired = repeatedFailure.mergingForRemotePublish(existing: firstFailure, now: expiry)

    #expect(firstFailure.accountRetentionStates?.first?.firstIncompleteObservationAt == firstFailureAt)
    #expect(expired.snapshot.providerStatuses.isEmpty)
    #expect(expired.accountRetentionStates == nil)
}

@Test func companionRemoteRetentionCompleteObservationBeatsNewerIncompleteGrace() {
    let completeAt = Date(timeIntervalSince1970: 9_500_000)
    let failureAt = completeAt.addingTimeInterval(10 * 24 * 60 * 60)
    let now = completeAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let complete = companionRemoteDocument(
        generatedAt: completeAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: 20,
                generatedAt: completeAt
            ),
        ]
    )
    let incomplete = companionRemoteDocument(
        generatedAt: failureAt,
        accounts: [
            companionRemoteAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                used: nil,
                generatedAt: failureAt,
                status: .failure
            ),
        ]
    ).mergingForRemotePublish(existing: nil, now: failureAt)

    let completeThenIncomplete = incomplete.mergingForRemotePublish(existing: complete, now: now)
    let incompleteThenComplete = complete.mergingForRemotePublish(existing: incomplete, now: now)

    #expect(completeThenIncomplete.snapshot.limits.isEmpty)
    #expect(incompleteThenComplete.snapshot.limits.isEmpty)
    #expect(completeThenIncomplete == incompleteThenComplete)
}

@Test func companionRemoteRetentionExpiresOrphanedPromptSummaryAtBoundary() {
    let observedAt = Date(timeIntervalSince1970: 10_000_000)
    let now = observedAt.addingTimeInterval(SnapshotFreshness.companionAccountRetentionAge)
    let document = companionRemoteDocument(
        generatedAt: observedAt,
        accounts: [],
        promptAccounts: [
            companionRemotePromptAccount(
                name: "OpenAI A",
                accountID: "openai-a",
                observedAt: observedAt
            ),
        ]
    )

    let retained = document.mergingForRemotePublish(existing: nil, now: now)

    #expect(retained.snapshot.promptCacheSummaries.isEmpty)
}

private struct CompanionRemoteTestAccount {
    let name: String
    let accountID: String
    let used: Int?
    let generatedAt: Date
    let status: UsageStatus
    let statusGeneratedAt: Date
    let limitStatus: UsageStatus
    let labels: [String]
}

private extension CompanionSyncDocument {
    func mergingForRemotePublish(existing: CompanionSyncDocument?) -> CompanionSyncDocument {
        mergingForRemotePublish(
            existing: existing,
            now: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct CompanionRemoteTestPromptAccount {
    let name: String
    let accountID: String
    let observedAt: Date
}

private func companionRemoteAccount(
    name: String,
    accountID: String,
    used: Int?,
    generatedAt: Date,
    status: UsageStatus = .healthy,
    statusGeneratedAt: Date? = nil,
    limitStatus: UsageStatus? = nil,
    labels: [String] = ["Weekly"]
) -> CompanionRemoteTestAccount {
    CompanionRemoteTestAccount(
        name: name,
        accountID: accountID,
        used: used,
        generatedAt: generatedAt,
        status: status,
        statusGeneratedAt: statusGeneratedAt ?? generatedAt,
        limitStatus: limitStatus ?? status,
        labels: labels
    )
}

private func companionRemotePromptAccount(
    name: String,
    accountID: String,
    observedAt: Date
) -> CompanionRemoteTestPromptAccount {
    CompanionRemoteTestPromptAccount(name: name, accountID: accountID, observedAt: observedAt)
}

private func companionRemoteDocument(
    generatedAt: Date,
    accounts: [CompanionRemoteTestAccount],
    promptAccounts: [CompanionRemoteTestPromptAccount] = [],
    burnRate: Double? = nil,
    widgetDisplayPreferences: WidgetDisplayPreferences = .defaultPreferences,
    fastModeForecastSettings: FastModeForecastSettings = .defaultSettings
) -> CompanionSyncDocument {
    let limits = accounts.flatMap { account in
        guard let used = account.used else { return [UsageLimit]() }
        return account.labels.map { label in
            UsageLimit(
                provider: .openAI,
                accountID: account.accountID,
                configuredAccountID: "openai-code-default",
                accountName: account.name,
                label: label,
                windowLabel: label,
                unit: .percent,
                used: used,
                limit: 100,
                lastUpdatedAt: account.generatedAt,
                statusOverride: account.limitStatus
            )
        }
    }
    let reports = accounts.map { account in
        StoredProviderReport(
            provider: .openAI,
            accountID: account.accountID,
            configuredAccountID: "openai-code-default",
            accountName: account.name,
            generatedAt: account.statusGeneratedAt,
            status: account.status,
            errorMessage: account.status == .failure ? "Authentication unavailable" : nil
        )
    }
    return CompanionSyncDocument(
        storedSnapshot: StoredUsageSnapshot(
            savedAt: generatedAt,
            snapshot: UsageSnapshot(generatedAt: generatedAt, limits: limits),
            reports: reports,
            promptCacheObservations: promptAccounts.map { account in
                PromptCacheObservation(
                    provider: .openAI,
                    accountID: account.accountID,
                    accountName: account.name,
                    observedAt: account.observedAt,
                    windowLabel: "Latest",
                    tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
                )
            }
        ),
        publishedAt: generatedAt,
        widgetDisplayPreferences: widgetDisplayPreferences,
        observedBurnRates: burnRate.map { unitsPerHour in
            [
                "openai:weekly": ObservedBurnRate(
                    limitID: "openai:weekly",
                    unitsPerHour: unitsPerHour,
                    observedDurationHours: 2,
                    sampleCount: 3
                ),
            ]
        } ?? [:],
        fastModeForecastSettings: fastModeForecastSettings
    )
}
