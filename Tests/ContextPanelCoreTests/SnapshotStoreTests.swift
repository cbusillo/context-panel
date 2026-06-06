import Foundation
import Testing

@testable import ContextPanelCore

@Test func jsonSnapshotStoreRoundTripsCurrentSnapshotAndReports() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    let refresh = ConnectorRefreshResult(generatedAt: savedAt, reports: [ProviderConnectorReport(
        provider: .openAI,
        accountID: "local-openai",
        accountName: "OpenAI",
        generatedAt: savedAt,
        limits: [usageLimit(provider: .openAI, accountID: "local-openai", used: 30, savedAt: savedAt)]
    )])

    try store.save(StoredUsageSnapshot(savedAt: savedAt, refreshResult: refresh))

    let result = store.loadCurrent()

    #expect(result.status == .healthy)
    #expect(result.snapshot?.schemaVersion == 1)
    #expect(result.snapshot?.savedAt == savedAt)
    #expect(result.snapshot?.snapshot.limits.count == 1)
    #expect(result.snapshot?.reports.count == 1)
    #expect(result.snapshot?.reports[0].provider == .openAI)
    #expect(FileManager.default.fileExists(atPath: store.currentSnapshotURL.path))
    #expect(store.loadHistory().count == 1)
}

@Test func storedSnapshotsDowngradeSuccessfulReportsWithoutMatchingLimits() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "gemini-local",
            accountName: "Gemini",
            generatedAt: savedAt,
            status: .healthy,
            errorMessage: nil
        )]
    )

    try store.save(stored)

    let loadedReport = try #require(store.loadCurrent().snapshot?.reports.first)
    #expect(loadedReport.status == .unknown)
}

@Test func storedSnapshotsKeepSuccessfulReportsWithMatchingLimits() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [usageLimit(provider: .google, accountID: "gemini-local", used: 25, savedAt: savedAt)]
        ),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "gemini-local",
            accountName: "Gemini",
            generatedAt: savedAt,
            status: .healthy,
            errorMessage: nil
        )]
    )

    try store.save(stored)

    let loadedReport = try #require(store.loadCurrent().snapshot?.reports.first)
    #expect(loadedReport.status == .healthy)
}

@Test func storedSnapshotsKeepLimitedConfiguredReportsWithMatchingLimits() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [usageLimit(
                provider: .google,
                accountID: "antigravity-account",
                configuredAccountID: "gemini-code-assist-default",
                used: 100,
                savedAt: savedAt
            )]
        ),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "antigravity-account",
            configuredAccountID: "gemini-code-assist-default",
            accountName: "Antigravity",
            generatedAt: savedAt,
            status: .limited,
            errorMessage: nil
        )]
    )

    try store.save(stored)

    let loadedReport = try #require(store.loadCurrent().snapshot?.reports.first)
    #expect(loadedReport.status == .limited)
}

@Test func jsonSnapshotStoreFiltersHistoryByProviderAccountAndLimit() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(savedAt: first, snapshot: UsageSnapshot(
        generatedAt: first,
        limits: [usageLimit(provider: .openAI, accountID: "a", used: 10, savedAt: first)]
    )))
    try store.save(StoredUsageSnapshot(savedAt: second, snapshot: UsageSnapshot(
        generatedAt: second,
        limits: [usageLimit(provider: .google, accountID: "b", used: 20, savedAt: second)]
    )))

    #expect(store.loadHistory().map(\.savedAt) == [second, first])
    #expect(store.loadHistory(query: SnapshotStoreQuery(provider: .openAI)).map(\.savedAt) == [first])
    #expect(store.loadHistory(query: SnapshotStoreQuery(accountID: "b")).map(\.savedAt) == [second])
    #expect(store.loadHistory(query: SnapshotStoreQuery(limit: 1)).count == 1)
}

@Test func jsonSnapshotStoreMergesRefreshResultByProviderAccount() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    let initial = ConnectorRefreshResult(generatedAt: first, reports: [
        ProviderConnectorReport(
            provider: .openAI,
            accountID: "openai-a",
            accountName: "OpenAI A",
            generatedAt: first,
            limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 40, savedAt: first)]
        ),
        ProviderConnectorReport(
            provider: .google,
            accountID: "gemini-a",
            accountName: "Gemini A",
            generatedAt: first,
            limits: [usageLimit(provider: .google, accountID: "gemini-a", used: 10, savedAt: first)]
        ),
    ])
    try store.save(StoredUsageSnapshot(savedAt: first, refreshResult: initial))

    let claudeRefresh = ConnectorRefreshResult(generatedAt: second, reports: [
        ProviderConnectorReport(
            provider: .anthropic,
            accountID: "claude-local",
            accountName: "Claude",
            generatedAt: second,
            limits: [usageLimit(provider: .anthropic, accountID: "claude-local", used: 3, savedAt: second)]
        )
    ])

    try store.saveMerged(refreshResult: claudeRefresh, savedAt: second)

    let limits = try #require(store.loadCurrent().snapshot?.snapshot.limits)
    #expect(limits.map(\.provider).contains(.openAI))
    #expect(limits.map(\.provider).contains(.google))
    #expect(limits.map(\.provider).contains(.anthropic))
    #expect(store.loadCurrent().snapshot?.reports.count == 3)
    #expect(store.loadHistory().count == 2)

    let replacement = ConnectorRefreshResult(generatedAt: second, reports: [
        ProviderConnectorReport(
            provider: .openAI,
            accountID: "openai-a",
            accountName: "OpenAI A",
            generatedAt: second,
            limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 80, savedAt: second)]
        )
    ])
    try store.saveMerged(refreshResult: replacement, savedAt: second.addingTimeInterval(1))

    let replaced = try #require(store.loadCurrent().snapshot?.snapshot.limits)
    let openAILimit = try #require(replaced.first { $0.provider == .openAI && $0.accountID == "openai-a" })
    #expect(openAILimit.used == 80)
    #expect(replaced.filter { $0.provider == .openAI && $0.accountID == "openai-a" }.count == 1)
    #expect(replaced.map(\.provider).contains(.google))
    #expect(replaced.map(\.provider).contains(.anthropic))
}

@Test func jsonSnapshotStorePreservesPreviousLimitsWhenRefreshFails() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let accountID = "gemini-a"

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Gemini A",
                generatedAt: first,
                limits: [usageLimit(provider: .google, accountID: accountID, used: 10, savedAt: first)]
            )
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Gemini A",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "permission denied"
            )
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    let limits = current.snapshot.limits.filter { $0.provider == .google && $0.accountID == accountID }
    #expect(limits.count == 1)
    #expect(limits[0].used == 10)
    let report = try #require(current.reports.first { $0.provider == .google && $0.accountID == accountID })
    #expect(report.status == .failure)
    #expect(report.errorMessage?.contains("permission") == true)
}

@Test func jsonSnapshotStoreDropsPreviousGoogleLimitsWhenAccountIsUnavailable() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let accountID = ConnectorRedactor.localAccountID(
        provider: .google,
        stableID: "google-antigravity-default"
    )

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Gemini A",
                generatedAt: first,
                limits: [usageLimit(provider: .google, accountID: accountID, used: 10, savedAt: first)]
            )
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Antigravity",
                generatedAt: second,
                limits: [],
                status: .unknown,
                errorMessage: "Google Antigravity quota is not available yet. Legacy Gemini CLI and Code Assist quota paths have been retired."
            )
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.filter { $0.provider == .google }.isEmpty)
    let report = try #require(current.reports.first { $0.provider == .google })
    #expect(report.accountID == accountID)
    #expect(report.status == .unknown)
}

@Test func jsonSnapshotStorePreservesOtherGoogleAccountsWhenOneAccountIsUnavailable() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let unavailableAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "google-a")
    let healthyAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "google-b")

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: unavailableAccountID,
                accountName: "Google A",
                generatedAt: first,
                limits: [usageLimit(provider: .google, accountID: unavailableAccountID, used: 10, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .google,
                accountID: healthyAccountID,
                accountName: "Google B",
                generatedAt: first,
                limits: [usageLimit(provider: .google, accountID: healthyAccountID, used: 20, savedAt: first)]
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: unavailableAccountID,
                accountName: "Google A",
                generatedAt: second,
                limits: [],
                status: .unknown,
                errorMessage: "Google Antigravity did not report model quota availability."
            ),
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.map(\.accountID) == [healthyAccountID])
    #expect(current.reports.contains { $0.accountID == unavailableAccountID && $0.status == .unknown })
    #expect(current.reports.contains { $0.accountID == healthyAccountID && $0.status == .healthy })
}

@Test func jsonSnapshotStoreDropsPreviousLimitsWhenForegroundRequiredReportHasNoData() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let accountID = "gemini-a"

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Gemini A",
                generatedAt: first,
                limits: [usageLimit(provider: .google, accountID: accountID, used: 0, savedAt: first)]
            )
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Gemini A",
                generatedAt: second,
                limits: [],
                status: .unknown,
                errorMessage: "foreground refresh required"
            )
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.filter { $0.provider == .google && $0.accountID == accountID }.isEmpty)
    let report = try #require(current.reports.first { $0.provider == .google && $0.accountID == accountID })
    #expect(report.status == .unknown)
    #expect(report.errorMessage?.contains("foreground refresh") == true)
}

@Test func jsonSnapshotStorePreservesMultiAccountLimitsWhenConnectorFileRefreshFails() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a",
                accountName: "Code A",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 10, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-b",
                accountName: "Code B",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-b", used: 20, savedAt: first)]
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-auth-file",
                accountName: "Code",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "permission denied"
            )
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.map(\.accountID).sorted() == ["openai-a", "openai-b"])
    #expect(current.reports.map(\.accountID) == ["openai-auth-file"])
}

@Test func jsonSnapshotStoreDoesNotPreserveStaleSiblingsWhenProviderPartlySucceeds() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a",
                accountName: "Code A",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 10, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-b",
                accountName: "Code B",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-b", used: 20, savedAt: first)]
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a",
                accountName: "Code A",
                generatedAt: second,
                limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 30, savedAt: second)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-auth-file",
                accountName: "Code",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "permission denied"
            ),
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.map(\.accountID) == ["openai-a"])
    #expect(current.snapshot.limits.first?.used == 30)
}

@Test func jsonSnapshotStorePreservesOnlyFailedAccountLimitWhenSiblingNamesMatch() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a",
                accountName: "Code",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-a", used: 10, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-b",
                accountName: "Code",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-b", used: 20, savedAt: first)]
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a",
                accountName: "Code",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "permission denied"
            ),
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.map(\.accountID) == ["openai-a"])
    #expect(current.snapshot.limits.first?.used == 10)
}

@Test func jsonSnapshotStoreCanDropUnreportedAccountsDuringFullRefresh() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-good",
                accountName: "Code",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-good", used: 20, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-removed",
                accountName: "Code 2",
                generatedAt: first,
                limits: [],
                status: .failure,
                errorMessage: "401"
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-good",
                accountName: "Code",
                generatedAt: second,
                limits: [usageLimit(provider: .openAI, accountID: "openai-good", used: 30, savedAt: second)]
            )
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.map(\.accountID) == ["openai-good"])
    #expect(current.reports.map(\.accountID) == ["openai-good"])
}

@Test func jsonSnapshotStoreReportsMissingCurrentAsUnknown() throws {
    let store = JSONSnapshotStore(rootDirectory: try temporaryDirectory())

    let result = store.loadCurrent()

    #expect(result.snapshot == nil)
    #expect(result.status == .unknown)
}

@Test func jsonSnapshotStoreReportsCorruptCurrentAsFailureWithoutThrowing() throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: root.appending(path: "current-snapshot.json"))

    let result = JSONSnapshotStore(rootDirectory: root).loadCurrent()

    #expect(result.snapshot == nil)
    #expect(result.status == .failure)
    #expect(result.errorMessage?.isEmpty == false)
}

@Test func jsonSnapshotStoreAppliesStalenessPolicy() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let savedAt = Date(timeIntervalSince1970: 100)
    try store.save(StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .google, accountID: "g", used: 20, savedAt: savedAt)]
    )))

    let fresh = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: Date(timeIntervalSince1970: 120))
    let stale = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 60), now: Date(timeIntervalSince1970: 200))

    #expect(fresh.status == .healthy)
    #expect(stale.status == .stale)
}

@Test func jsonSnapshotStoreKeepsProviderFreshnessWhenOnlyPromptCacheChanges() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let providerGeneratedAt = Date(timeIntervalSince1970: 100)
    let promptCacheObservedAt = Date(timeIntervalSince1970: 200)
    try store.save(StoredUsageSnapshot(savedAt: providerGeneratedAt, snapshot: UsageSnapshot(
        generatedAt: providerGeneratedAt,
        limits: [usageLimit(provider: .openAI, accountID: "openai", used: 20, savedAt: providerGeneratedAt)]
    )))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(
            generatedAt: promptCacheObservedAt,
            reports: [],
            promptCacheObservations: [PromptCacheObservation(
                provider: .openAI,
                accountID: "openai-cache",
                accountName: "Every Code · Pro",
                observedAt: promptCacheObservedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 90)
            )]
        ),
        savedAt: promptCacheObservedAt
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.savedAt == promptCacheObservedAt)
    #expect(current.snapshot.generatedAt == providerGeneratedAt)
    #expect(current.promptCacheObservations.count == 1)
    let status = store.loadCurrent(
        policy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        now: promptCacheObservedAt
    )
    #expect(status.status == .stale)
}

@Test func jsonSnapshotStoreAdvancesFreshnessForPromptCacheOnlySnapshots() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let firstObservation = PromptCacheObservation(
        provider: .openAI,
        accountID: "openai-cache",
        accountName: "Every Code · Pro",
        observedAt: first,
        windowLabel: "Last hour",
        tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)
    )
    try store.save(StoredUsageSnapshot(
        savedAt: first,
        snapshot: UsageSnapshot(generatedAt: first, limits: []),
        promptCacheObservations: [firstObservation]
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(
            generatedAt: second,
            reports: [],
            promptCacheObservations: [PromptCacheObservation(
                provider: .openAI,
                accountID: "openai-cache",
                accountName: "Every Code · Pro",
                observedAt: second,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 90)
            )]
        ),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.generatedAt == second)
    let status = store.loadCurrent(
        policy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        now: second
    )
    #expect(status.status == .unknown)
}

@Test func jsonSnapshotStoreRejectsUnsupportedSchema() throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let current = root.appending(path: "current-snapshot.json")
    let json = #"""
    {
      "schemaVersion": 99,
      "savedAt": "1970-01-01T00:00:00Z",
      "snapshot": { "generatedAt": "1970-01-01T00:00:00Z", "limits": [] },
      "reports": []
    }
    """#
    try Data(json.utf8).write(to: current)

    let result = JSONSnapshotStore(rootDirectory: root).loadCurrent()

    #expect(result.status == .failure)
    #expect(result.errorMessage?.contains("Unsupported snapshot schema") == true)
}

@Test func storedProviderReportRedactsErrorMessages() {
    let report = ProviderConnectorReport(
        provider: .openAI,
        accountID: "local",
        accountName: "OpenAI",
        generatedAt: Date(timeIntervalSince1970: 0),
        limits: [],
        status: .failure,
        errorMessage: "failed for user@example.com with bearer sk-secret"
    )

    let stored = StoredProviderReport(report: report)

    #expect(stored.errorMessage?.contains("user@example.com") == false)
    #expect(stored.errorMessage?.contains("sk-secret") == false)
}

@Test func snapshotRefreshServiceDoesNotSaveEmptyRefreshWhenNoAccountsAreEnabled() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "disabled-openai",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            isEnabled: false,
            authPath: "/tmp/missing-auth.json"
        )]
    ))

    let outcome = try await service.refresh(now: savedAt)

    #expect(outcome.savedAt == savedAt)
    #expect(outcome.refreshResult.reports.isEmpty)
    #expect(primary.loadCurrent().snapshot == nil)
    #expect(primary.loadHistory().isEmpty)
}

@Test func snapshotRefreshServiceMirrorsPromptCacheTelemetryBeforeReadingIt() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let callOrder = SnapshotRefreshCallOrderRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryMirror: {
            callOrder.record("mirror")
        },
        promptCacheTelemetryReader: { _ in
            callOrder.record("read")
            return []
        }
    )

    _ = service.promptCacheObservations(now: Date(timeIntervalSince1970: 300))

    #expect(callOrder.values == ["mirror", "read"])
}

@Test func snapshotRefreshServiceMirrorsPromptCacheTelemetryDuringFullRefresh() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let callOrder = SnapshotRefreshCallOrderRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryMirror: {
            callOrder.record("mirror")
        },
        promptCacheTelemetryReader: { _ in
            callOrder.record("read")
            return []
        }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "disabled-openai",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            isEnabled: false,
            authPath: "/tmp/missing-auth.json"
        )]
    ))

    _ = try await service.refresh(now: savedAt)

    #expect(callOrder.values == ["mirror", "read"])
}

@Test func snapshotRefreshServiceMigratesClaudeCredentialsBeforeRefreshingMigratedAccount() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let credentials = Data(#"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.utf8)
    let credentialStore = InMemoryProviderCredentialStore(storage: ["claude-local-default": credentials])
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        credentialStore: credentialStore
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "claude-local-default",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude"
        )]
    ))

    let accountDocument = service.loadConfiguredAccounts(now: savedAt).document
    let connectors = AccountConnectorFactory.connectors(
        from: accountDocument,
        credentialStore: credentialStore,
        requiresBookmarkedAuthFiles: false
    )
    let refreshResult = await ProviderConnectorRuntime(connectors: connectors).refreshAll(now: savedAt)

    #expect(try credentialStore.load(accountID: "claude-oauth-default") == credentials)
    #expect(accountDocument.accounts.contains { $0.id == "claude-oauth-default" && $0.connectorKind == .claudeOAuthUsage })
    #expect(refreshResult.reports.count == 1)
    #expect(refreshResult.reports[0].accountName == "Claude")
    #expect(refreshResult.reports[0].errorMessage != "Claude is not connected. Sign in to Claude from Settings.")
}

@Test func snapshotRefreshRunnerSkipsEmptyRefreshes() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(service: service, lock: nil)
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "disabled-openai",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            isEnabled: false,
            authPath: "/tmp/missing-auth.json"
        )]
    ))

    let decision = try await runner.refresh(now: savedAt)

    #expect(decision == .skippedNoReports)
    #expect(primary.loadCurrent().snapshot == nil)
    #expect(primary.loadHistory().isEmpty)
}

@Test func snapshotRefreshRunnerSavesPromptCacheOnlyRefreshes() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [PromptCacheObservation(
            provider: .openAI,
            accountID: "openai-test-cache",
            accountName: "Every Code · Pro",
            observedAt: Date(timeIntervalSince1970: 250),
            windowLabel: "Last hour",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)
        )] }
    )
    let runner = SnapshotRefreshRunner(service: service, lock: nil)
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "disabled-openai",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI",
            isEnabled: false,
            authPath: "/tmp/missing-auth.json"
        )]
    ))

    let decision = try await runner.refresh(now: savedAt)

    if case let .refreshed(outcome) = decision {
        #expect(outcome.refreshResult.reports.isEmpty)
        #expect(outcome.refreshResult.promptCacheObservations.count == 1)
    } else {
        Issue.record("expected refreshed decision")
    }
    #expect(primary.loadCurrent().snapshot?.promptCacheObservations.count == 1)
    #expect(primary.loadHistory().count == 1)
}

@Test func snapshotRefreshRunnerUpdatesPromptCacheWhenProviderSnapshotIsFresh() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let providerGeneratedAt = Date(timeIntervalSince1970: 1_000)
    let promptCacheObservedAt = Date(timeIntervalSince1970: 1_020)
    try primary.save(StoredUsageSnapshot(savedAt: providerGeneratedAt, snapshot: UsageSnapshot(
        generatedAt: providerGeneratedAt,
        limits: [usageLimit(provider: .openAI, accountID: "openai", used: 10, savedAt: providerGeneratedAt)]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [PromptCacheObservation(
            provider: .openAI,
            accountID: "openai-cache",
            accountName: "Every Code · Pro",
            observedAt: promptCacheObservedAt,
            windowLabel: "Last hour",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 88)
        )] }
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        lock: nil
    )

    let decision = try await runner.refreshIfNeeded(now: promptCacheObservedAt)

    if case .refreshed = decision {
        let current = try #require(primary.loadCurrent().snapshot)
        #expect(current.savedAt == promptCacheObservedAt)
        #expect(current.snapshot.generatedAt == providerGeneratedAt)
        #expect(current.promptCacheObservations.count == 1)
    } else {
        Issue.record("expected prompt-cache-only refresh while provider snapshot remained fresh")
    }
}

@Test func snapshotRefreshRunnerSkipsFreshPromptCacheOnlySnapshotWhenTelemetryIsUnchanged() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let observation = PromptCacheObservation(
        provider: .openAI,
        accountID: "openai-cache",
        accountName: "Every Code · Pro",
        observedAt: savedAt,
        windowLabel: "Last hour",
        tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 88)
    )
    try primary.save(StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        promptCacheObservations: [observation]
    ))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [observation] }
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        lock: nil
    )

    let decision = try await runner.refreshIfNeeded(now: savedAt.addingTimeInterval(30))

    #expect(decision == .skippedFresh)
    #expect(primary.loadHistory().count == 1)
}

@Test func jsonSnapshotStorePrunesOldPromptCacheObservationsWhenMerging() throws {
    let store = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let old = PromptCacheObservation(
        provider: .openAI,
        accountID: "old",
        accountName: "Every Code · Pro",
        observedAt: Date(timeIntervalSince1970: -100),
        windowLabel: "Last hour",
        tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 50)
    )
    let fresh = PromptCacheObservation(
        provider: .openAI,
        accountID: "fresh",
        accountName: "Every Code · Pro",
        observedAt: Date(timeIntervalSince1970: 21_500),
        windowLabel: "Last hour",
        tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 90)
    )
    try store.save(StoredUsageSnapshot(
        savedAt: Date(timeIntervalSince1970: -100),
        snapshot: UsageSnapshot(generatedAt: Date(timeIntervalSince1970: -100), limits: []),
        promptCacheObservations: [old]
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(
            generatedAt: Date(timeIntervalSince1970: 21_600),
            reports: [],
            promptCacheObservations: [fresh]
        ),
        savedAt: Date(timeIntervalSince1970: 21_600)
    )

    #expect(store.loadCurrent().snapshot?.promptCacheObservations.map(\.id) == [fresh.id])
}

@Test func widgetSandboxLocalSnapshotDirectoryUsesProcessApplicationSupport() {
    #expect(ContextPanelLocations.widgetSandboxLocalSnapshotDirectory().path.hasSuffix(
        "Library/Application Support/Context Panel/Snapshots"
    ))
}

@Test func snapshotRefreshRunnerSkipsFreshSnapshots() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 500)
    try primary.save(StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .openAI, accountID: "openai", used: 10, savedAt: savedAt)]
    )))
    let runner = SnapshotRefreshRunner(
        service: service,
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        lock: nil
    )

    let decision = try await runner.refreshIfNeeded(now: savedAt.addingTimeInterval(30))

    #expect(decision == .skippedFresh)
    #expect(primary.loadHistory().count == 1)
}

@Test func snapshotRefreshRunnerSkipsWhenRefreshLockIsHeld() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lockURL.path, contents: Data())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL, staleAfter: 60)
    )

    let decision = try await runner.refresh(now: Date(timeIntervalSince1970: 600))

    #expect(decision == .skippedAlreadyRunning)
    #expect(primary.loadCurrent().snapshot == nil)
}

@Test func snapshotRefreshRunnerRetriesManualSavesUntilLockClears() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lockURL.path, contents: Data())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL, staleAfter: 60)
    )
    let savedAt = Date(timeIntervalSince1970: 800)
    let report = ProviderConnectorReport(
        provider: .anthropic,
        accountID: "claude-local",
        accountName: "Claude",
        generatedAt: savedAt,
        limits: [usageLimit(provider: .anthropic, accountID: "claude-local", used: 20, savedAt: savedAt)],
        status: .healthy
    )

    Task {
        try? await Task.sleep(for: .milliseconds(100))
        try? FileManager.default.removeItem(at: lockURL)
    }

    let decision = try await runner.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: savedAt, reports: [report]),
        savedAt: savedAt,
        retryFor: .seconds(1),
        retryInterval: .milliseconds(20)
    )

    #expect(decision != .skippedAlreadyRunning)
    #expect(primary.loadCurrent().snapshot?.snapshot.limits.first?.accountID == "claude-local")
}

@Test func snapshotRefreshRunnerClearsOrphanedRefreshLock() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"processID":999999}"#.utf8).write(to: lockURL)
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL, staleAfter: 60)
    )
    let savedAt = Date(timeIntervalSince1970: 900)
    let report = ProviderConnectorReport(
        provider: .anthropic,
        accountID: "claude-local",
        accountName: "Claude",
        generatedAt: savedAt,
        limits: [usageLimit(provider: .anthropic, accountID: "claude-local", used: 20, savedAt: savedAt)],
        status: .healthy
    )

    let decision = try await runner.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: savedAt, reports: [report]),
        savedAt: savedAt
    )

    #expect(decision != .skippedAlreadyRunning)
    #expect(primary.loadCurrent().snapshot?.savedAt == savedAt)
    #expect(!FileManager.default.fileExists(atPath: lockURL.path))
}

@Test func snapshotRefreshRunnerSerializesManualSavesWithRefreshLock() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lockURL.path, contents: Data())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL, staleAfter: 60)
    )
    let savedAt = Date(timeIntervalSince1970: 700)
    let report = ProviderConnectorReport(
        provider: .anthropic,
        accountID: "claude-local",
        accountName: "Claude",
        generatedAt: savedAt,
        limits: [usageLimit(provider: .anthropic, accountID: "claude-local", used: 20, savedAt: savedAt)],
        status: .healthy
    )

    let decision = try await runner.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: savedAt, reports: [report]),
        savedAt: savedAt
    )

    #expect(decision == .skippedAlreadyRunning)
    #expect(primary.loadCurrent().snapshot == nil)
}

private func usageLimit(
    provider: Provider,
    accountID: String,
    configuredAccountID: String? = nil,
    used: Int,
    savedAt: Date
) -> UsageLimit {
    UsageLimit(
        provider: provider,
        accountID: accountID,
        configuredAccountID: configuredAccountID,
        accountName: accountID,
        label: "usage",
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: savedAt.addingTimeInterval(3_600),
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class SnapshotRefreshCallOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func record(_ value: String) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}
