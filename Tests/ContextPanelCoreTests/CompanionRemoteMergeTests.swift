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
    #expect(widget.refreshAttentionSummary?.providers == [.openAI])
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

private struct CompanionRemoteTestAccount {
    let name: String
    let accountID: String
    let used: Int?
    let generatedAt: Date
    let status: UsageStatus
    let labels: [String]
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
    labels: [String] = ["Weekly"]
) -> CompanionRemoteTestAccount {
    CompanionRemoteTestAccount(
        name: name,
        accountID: accountID,
        used: used,
        generatedAt: generatedAt,
        status: status,
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
                statusOverride: account.status
            )
        }
    }
    let reports = accounts.map { account in
        StoredProviderReport(
            provider: .openAI,
            accountID: account.accountID,
            configuredAccountID: "openai-code-default",
            accountName: account.name,
            generatedAt: account.generatedAt,
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
