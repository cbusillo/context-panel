import Foundation
import Darwin
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

@Test func refreshFailureCategoryClassifiesProviderAuthAndOAuthFailures() {
    #expect(RefreshFailureCategory(errorMessage: nil) == .none)
    #expect(RefreshFailureCategory(
        errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage. Sign in again from Every Code or Codex, then refresh Context Panel."
    ) == .providerAuthorization)
    #expect(RefreshFailureCategory(
        errorMessage: "Claude OAuth refresh failed with invalid_client. The OAuth client was not found. Sign in again from Settings."
    ) == .oauthInvalidClient)
    #expect(RefreshFailureCategory(
        errorMessage: "Claude OAuth session has expired. Sign in again from Settings."
    ) == .oauthExpired)
    #expect(RefreshFailureCategory(
        errorMessage: "Claude credentials are in an unexpected format. Sign in again from Settings."
    ) == .credentialFormat)
    #expect(RefreshFailureCategory(
        errorMessage: "Provider rejected quota access for this app or account."
    ) == .providerAuthorization)
    #expect(RefreshFailureCategory(
        errorMessage: "Provider returned no usage records for this account."
    ) == .unknown)
    #expect(RefreshFailureCategory(
        errorMessage: "Provider response body is missing a required field."
    ) == .unknown)
    #expect(RefreshFailureCategory(
        errorMessage: "Provider request failed with HTTP status code 429."
    ) == .httpFailure)
}

@Test func storedProviderReportDistinguishesSavedCredentialsFromReconnectRequired() {
    let generatedAt = Date(timeIntervalSince1970: 100)
    let expired = StoredProviderReport(
        provider: .anthropic,
        accountID: "claude",
        accountName: "Claude",
        generatedAt: generatedAt,
        status: .failure,
        errorMessage: "Claude OAuth session has expired. Sign in again from Settings."
    )
    let transient = StoredProviderReport(
        provider: .anthropic,
        accountID: "claude",
        accountName: "Claude",
        generatedAt: generatedAt,
        status: .failure,
        errorMessage: "Claude usage failed with HTTP status code 500."
    )
    let healthy = StoredProviderReport(
        provider: .anthropic,
        accountID: "claude",
        accountName: "Claude",
        generatedAt: generatedAt,
        status: .healthy,
        errorMessage: nil
    )

    #expect(expired.requiresCredentialReconnect)
    #expect(!transient.requiresCredentialReconnect)
    #expect(!healthy.requiresCredentialReconnect)
}

@Test func googleAntigravityBridgeFailuresDoNotRequestCredentialReconnect() {
    let report = StoredProviderReport(
        provider: .google,
        accountID: "google-antigravity",
        accountName: "Antigravity",
        generatedAt: Date(timeIntervalSince1970: 100),
        status: .failure,
        errorMessage: "Antigravity bridge data could not be read. The last good quota remains available while setup is checked."
    )

    #expect(!report.requiresCredentialReconnect)
    #expect(report.userFacingErrorMessage == report.errorMessage)
}

@Test func reconnectFailuresAreNotCoveredByDifferentAccountsWithSharedConfiguredID() throws {
    let savedAt = Date(timeIntervalSince1970: 100)
    let reports = [
        StoredProviderReport(
            provider: .openAI,
            accountID: "openai-account-limited",
            configuredAccountID: "openai-code-default",
            accountName: "Limited OpenAI",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage."
        ),
        StoredProviderReport(
            provider: .openAI,
            accountID: "openai-account-healthy",
            configuredAccountID: "openai-code-default",
            accountName: "Healthy OpenAI",
            generatedAt: savedAt,
            status: .healthy,
            errorMessage: nil
        ),
    ]

    let failures = reports.reconnectBlockingFailures

    #expect(failures.map(\.accountID) == ["openai-account-limited"])
}

@Test func reconnectFailureIsCoveredByCurrentLimitForSameConfiguredAccount() throws {
    let savedAt = Date(timeIntervalSince1970: 100)
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: "openai-account-failed",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI",
        generatedAt: savedAt,
        status: .failure,
        errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage."
    )
    let limits = [UsageLimit(
        provider: .openAI,
        accountID: "openai-account-failed",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI",
        label: "Codex 5-hour",
        windowLabel: "5-hour",
        unit: .percent,
        used: 12,
        limit: 100,
        resetsAt: savedAt.addingTimeInterval(60),
        lastUpdatedAt: savedAt,
        confidence: .observed
    )]

    #expect([report].reconnectBlockingFailures(coveredBy: limits).isEmpty)
}

@Test func reconnectFailureIsNotCoveredByOlderLimitForSameAccount() throws {
    let previousRefresh = Date(timeIntervalSince1970: 100)
    let failedRefresh = Date(timeIntervalSince1970: 200)
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: "openai-account-failed",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI",
        generatedAt: failedRefresh,
        status: .failure,
        errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage."
    )
    let limits = [UsageLimit(
        provider: .openAI,
        accountID: "openai-account-failed",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI",
        label: "Codex Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 2,
        limit: 100,
        resetsAt: failedRefresh.addingTimeInterval(60),
        lastUpdatedAt: previousRefresh,
        confidence: .observed
    )]

    #expect([report].reconnectBlockingFailures(coveredBy: limits).map(\.accountID) == ["openai-account-failed"])
}

@Test func reconnectFailureIsNotCoveredByDifferentLimitAccountWithSharedConfiguredID() throws {
    let savedAt = Date(timeIntervalSince1970: 100)
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: "openai-account-failed",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI",
        generatedAt: savedAt,
        status: .failure,
        errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage."
    )
    let limits = [UsageLimit(
        provider: .openAI,
        accountID: "openai-account-healthy",
        configuredAccountID: "openai-code-default",
        accountName: "OpenAI",
        label: "Codex 5-hour",
        windowLabel: "5-hour",
        unit: .percent,
        used: 12,
        limit: 100,
        resetsAt: savedAt.addingTimeInterval(60),
        lastUpdatedAt: savedAt,
        confidence: .observed
    )]

    #expect([report].reconnectBlockingFailures(coveredBy: limits).map(\.accountID) == ["openai-account-failed"])
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
    #expect(store.loadHistory(query: SnapshotStoreQuery(since: second)).map(\.savedAt) == [second])
    #expect(store.loadHistory(query: SnapshotStoreQuery(limit: 1)).count == 1)
    #expect(store.historyCount() == 2)
}

@Test func jsonSnapshotStoreCountsHistoryFilesWithoutDecodingThem() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    try FileManager.default.createDirectory(at: store.historyDirectoryURL, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: store.historyDirectoryURL.appending(path: "invalid.json"))
    try Data("ignored".utf8).write(to: store.historyDirectoryURL.appending(path: "notes.txt"))

    #expect(store.historyCount() == 1)
    #expect(store.loadHistory().isEmpty)
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
    #expect(limits[0].status == .stale)
    let report = try #require(current.reports.first { $0.provider == .google && $0.accountID == accountID })
    #expect(report.status == .failure)
    #expect(report.errorMessage?.contains("permission") == true)
    #expect(current.reports.reconnectBlockingFailures(coveredBy: current.snapshot.limits).map(\.accountID) == [accountID])
}

@Test func jsonSnapshotStoreKeepsPreservedStaleAGYLimitStaleAfterScheduledReset() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let observedAt = Date(timeIntervalSince1970: 100)
    let failedAt = Date(timeIntervalSince1970: 120)
    let resetAt = Date(timeIntervalSince1970: 150)
    let accountID = "google-antigravity"
    let limit = UsageLimit(
        id: "google:local:agy:gemini-5h",
        provider: .google,
        accountID: accountID,
        accountName: "Antigravity",
        label: "Gemini 5-hour",
        windowLabel: "5-hour",
        modelLabel: "Gemini",
        unit: .percent,
        used: 80,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: observedAt,
        confidence: .observed
    )

    try store.save(StoredUsageSnapshot(
        savedAt: observedAt,
        refreshResult: ConnectorRefreshResult(generatedAt: observedAt, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Antigravity",
                generatedAt: observedAt,
                limits: [limit]
            )
        ])
    ))
    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: failedAt, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Antigravity",
                generatedAt: failedAt,
                limits: [],
                status: .failure,
                errorMessage: "bridge unavailable"
            )
        ]),
        savedAt: failedAt
    )

    let stored = try #require(store.loadCurrent().snapshot?.snapshot.limits.first)
    let presented = stored.presented(at: resetAt.addingTimeInterval(1))
    #expect(stored.status == .stale)
    #expect(stored.freshnessMode == .polling)
    #expect(presented == stored)
    #expect(presented.used == 80)
    #expect(presented.presentationAssumption == nil)
}

@Test func jsonSnapshotStoreDoesNotPreserveOldGoogleLimitsWhenNewAccountIDFails() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let oldAccountID = "google-legacy-account"
    let newAccountID = ConnectorRedactor.localAccountID(
        provider: .google,
        stableID: "google-antigravity-default"
    )

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: oldAccountID,
                configuredAccountID: "gemini-code-assist-default",
                accountName: "Legacy Google",
                generatedAt: first,
                limits: [usageLimit(
                    provider: .google,
                    accountID: oldAccountID,
                    configuredAccountID: "gemini-code-assist-default",
                    used: 10,
                    savedAt: first
                )]
            )
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: newAccountID,
                configuredAccountID: "google-antigravity-default",
                accountName: "Antigravity",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "Antigravity bridge data could not be read."
            )
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.filter { $0.provider == .google }.isEmpty)
    #expect(!current.reports.contains { $0.accountID == oldAccountID })
    #expect(current.reports.contains { $0.accountID == newAccountID && $0.status == .failure })
}

@Test func jsonSnapshotStorePreservesUnrelatedNilConfiguredGoogleLimitsWhenDefaultAccountFails() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let otherAccountID = "google-other-account"
    let newAccountID = ConnectorRedactor.localAccountID(
        provider: .google,
        stableID: "google-antigravity-default"
    )

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: otherAccountID,
                accountName: "Other Google",
                generatedAt: first,
                limits: [usageLimit(provider: .google, accountID: otherAccountID, used: 10, savedAt: first)]
            )
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: newAccountID,
                configuredAccountID: "google-antigravity-default",
                accountName: "Antigravity",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "Antigravity bridge data could not be read."
            )
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.contains {
        $0.provider == .google && $0.accountID == otherAccountID && $0.status == .stale
    })
    #expect(current.reports.contains { $0.provider == .google && $0.accountID == otherAccountID })
    #expect(current.reports.contains { $0.accountID == newAccountID && $0.status == .failure })
}

@Test func jsonSnapshotStoreDropsRetiredNilConfiguredGeminiLimitsWhenDefaultAccountFails() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let oldAccountID = "google-retired-gemini-account"
    let newAccountID = ConnectorRedactor.localAccountID(
        provider: .google,
        stableID: "google-antigravity-default"
    )

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: oldAccountID,
                accountName: "Gemini",
                generatedAt: first,
                limits: [UsageLimit(
                    provider: .google,
                    accountID: oldAccountID,
                    accountName: "Gemini",
                    label: "gemini-2.5-pro",
                    modelLabel: "gemini-2.5-pro",
                    unit: .percent,
                    used: 10,
                    limit: 100,
                    resetsAt: first.addingTimeInterval(3_600),
                    lastUpdatedAt: first,
                    confidence: .observed
                )]
            )
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: newAccountID,
                configuredAccountID: "google-antigravity-default",
                accountName: "Antigravity",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "Antigravity bridge setup is required."
            )
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.filter { $0.provider == .google }.isEmpty)
    #expect(!current.reports.contains { $0.accountID == oldAccountID })
    #expect(current.reports.contains { $0.accountID == newAccountID && $0.status == .failure })
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
                errorMessage: "Antigravity bridge setup is required."
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
                errorMessage: "The Antigravity bridge is active, but AGY did not report active quota buckets."
            ),
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.map(\.accountID) == [healthyAccountID])
    #expect(current.reports.contains { $0.accountID == unavailableAccountID && $0.status == .unknown })
    #expect(current.reports.contains { $0.accountID == healthyAccountID && $0.status == .healthy })
}

@Test func jsonSnapshotStoreDropsPreviousLimitsWhenSetupRequiredReportHasNoData() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let accountID = "google-antigravity"

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: accountID,
                accountName: "Antigravity",
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
                accountName: "Antigravity",
                generatedAt: second,
                limits: [],
                status: .unknown,
                errorMessage: "Antigravity bridge setup is required."
            )
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.filter { $0.provider == .google && $0.accountID == accountID }.isEmpty)
    let report = try #require(current.reports.first { $0.provider == .google && $0.accountID == accountID })
    #expect(report.status == .unknown)
    #expect(report.errorMessage?.contains("bridge setup is required") == true)
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
    #expect(current.snapshot.limits.allSatisfy { $0.status == .stale })
    #expect(current.reports.map(\.accountID) == ["openai-auth-file"])
}

@Test func jsonSnapshotStoreMarksOnlyFailedOpenAIAccountStaleDuringPartialRefresh() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-available",
                accountName: "Available",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-available", used: 1, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-failed",
                accountName: "Failed",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-failed", used: 2, savedAt: first)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-limited",
                accountName: "Limited",
                generatedAt: first,
                limits: [usageLimit(provider: .openAI, accountID: "openai-limited", used: 100, savedAt: first)]
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-available",
                accountName: "Available",
                generatedAt: second,
                limits: [usageLimit(provider: .openAI, accountID: "openai-available", used: 1, savedAt: second)]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-failed",
                accountName: "Failed",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage."
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-limited",
                accountName: "Limited",
                generatedAt: second,
                limits: [usageLimit(provider: .openAI, accountID: "openai-limited", used: 100, savedAt: second)]
            ),
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    let available = try #require(current.snapshot.limits.first { $0.accountID == "openai-available" })
    let failed = try #require(current.snapshot.limits.first { $0.accountID == "openai-failed" })
    let limited = try #require(current.snapshot.limits.first { $0.accountID == "openai-limited" })
    #expect(available.status == .healthy)
    #expect(available.lastUpdatedAt == second)
    #expect(failed.status == .stale)
    #expect(failed.used == 2)
    #expect(failed.lastUpdatedAt == first)
    #expect(!failed.isLiveCapacityBucket(at: second))
    #expect(limited.status == .limited)
    #expect(limited.lastUpdatedAt == second)
    #expect(current.reports.reconnectBlockingFailures(coveredBy: current.snapshot.limits).map(\.accountID) == ["openai-failed"])
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

@Test func jsonSnapshotStoreScopesConnectorFileFailureToConfiguredAccount() throws {
    let root = try temporaryDirectory()
    let store = JSONSnapshotStore(rootDirectory: root)
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    try store.save(StoredUsageSnapshot(
        savedAt: first,
        refreshResult: ConnectorRefreshResult(generatedAt: first, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a-1",
                configuredAccountID: "openai-config-a",
                accountName: "A1",
                generatedAt: first,
                limits: [usageLimit(
                    provider: .openAI,
                    accountID: "openai-a-1",
                    configuredAccountID: "openai-config-a",
                    used: 10,
                    savedAt: first
                )]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-a-2",
                configuredAccountID: "openai-config-a",
                accountName: "A2",
                generatedAt: first,
                limits: [usageLimit(
                    provider: .openAI,
                    accountID: "openai-a-2",
                    configuredAccountID: "openai-config-a",
                    used: 20,
                    savedAt: first
                )]
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-b",
                configuredAccountID: "openai-config-b",
                accountName: "B",
                generatedAt: first,
                limits: [usageLimit(
                    provider: .openAI,
                    accountID: "openai-b",
                    configuredAccountID: "openai-config-b",
                    used: 30,
                    savedAt: first
                )]
            ),
        ])
    ))

    try store.saveMerged(
        refreshResult: ConnectorRefreshResult(generatedAt: second, reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-auth-file-a",
                configuredAccountID: "openai-config-a",
                accountName: "A",
                generatedAt: second,
                limits: [],
                status: .failure,
                errorMessage: "permission denied"
            ),
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-b",
                configuredAccountID: "openai-config-b",
                accountName: "B",
                generatedAt: second,
                limits: [usageLimit(
                    provider: .openAI,
                    accountID: "openai-b",
                    configuredAccountID: "openai-config-b",
                    used: 40,
                    savedAt: second
                )]
            ),
        ]),
        savedAt: second,
        preservesUnreportedAccounts: false
    )

    let current = try #require(store.loadCurrent().snapshot)
    let configALimits = current.snapshot.limits.filter { $0.configuredAccountID == "openai-config-a" }
    let configBLimits = current.snapshot.limits.filter { $0.configuredAccountID == "openai-config-b" }
    #expect(configALimits.map(\.accountID).sorted() == ["openai-a-1", "openai-a-2"])
    #expect(configALimits.allSatisfy { $0.status == .stale })
    #expect(configBLimits.map(\.accountID) == ["openai-b"])
    #expect(configBLimits.first?.used == 40)
    #expect(configBLimits.first?.status == .healthy)
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
    #expect(current.snapshot.limits.first?.status == .stale)
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
        errorMessage: "failed for user@example.com with bearer sk-secret at /Users/example/.code/auth.json via https://hooks.example.com/private"
    )

    let stored = StoredProviderReport(report: report)

    #expect(stored.errorMessage?.contains("user@example.com") == false)
    #expect(stored.errorMessage?.contains("sk-secret") == false)
    #expect(stored.errorMessage?.contains("/Users/example/.code/auth.json") == false)
    #expect(stored.errorMessage?.contains("hooks.example.com") == false)
}

@Test func storedProviderReportRoundTripsProviderAccessStateWithoutProviderPayload() throws {
    let reset = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:30:00Z"))
    let report = StoredProviderReport(
        provider: .anthropic,
        accountID: "local-anthropic",
        accountName: "Claude",
        generatedAt: reset.addingTimeInterval(-300),
        status: .limited,
        accessState: ProviderAccessState(kind: .blockedUntilReset, resetsAt: reset),
        errorMessage: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(report)
    let decoded = try JSONDecoder.contextPanelISO8601.decode(StoredProviderReport.self, from: data)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(decoded == report)
    #expect(json.contains("blockedUntilReset"))
    #expect(json.contains("spend") == false)
    #expect(json.contains("disabled_reason") == false)
}

@Test func storedProviderReportDefaultsLegacyAccessStateToUnknown() throws {
    let json = #"""
    {
      "provider": "anthropic",
      "accountID": "local-anthropic",
      "accountName": "Claude",
      "generatedAt": "2026-07-23T19:00:00Z",
      "status": "limited",
      "errorMessage": null
    }
    """#.data(using: .utf8)!

    let decoded = try JSONDecoder.contextPanelISO8601.decode(StoredProviderReport.self, from: json)

    #expect(decoded.accessState == .unknown)
}

@Test func storedProviderReportDemotesAccessStateWhenObservationBecomesStale() {
    let report = StoredProviderReport(
        provider: .anthropic,
        accountID: "local-anthropic",
        accountName: "Claude",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .limited,
        accessState: ProviderAccessState(kind: .paidFallbackActive),
        errorMessage: nil
    )

    #expect(report.withStatus(.stale).accessState == .unknown)
}

@Test func degradedProviderAccessUsesWarningPresentation() {
    let report = StoredProviderReport(
        provider: .anthropic,
        accountID: "local-anthropic",
        accountName: "Claude",
        generatedAt: Date(timeIntervalSince1970: 0),
        status: .limited,
        accessState: ProviderAccessState(kind: .degraded),
        errorMessage: nil
    )

    #expect(report.providerAccessAlert?.status == .close)
}

@Test func storedSnapshotProviderAccessAlertsRespectAgeAndResetStaleness() {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let resetsAt = generatedAt.addingTimeInterval(60)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic-work",
                accountName: "Work Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: resetsAt,
                lastUpdatedAt: generatedAt
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .anthropic,
                accountID: "anthropic-work",
                accountName: "Work Claude",
                generatedAt: generatedAt,
                status: .limited,
                accessState: ProviderAccessState(kind: .blockedUntilReset, resetsAt: resetsAt),
                errorMessage: nil
            ),
        ]
    )

    #expect(stored.providerAccessAlerts(
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 10_000),
        now: generatedAt
    ).count == 1)
    #expect(stored.providerAccessAlerts(
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 10_000),
        now: resetsAt.addingTimeInterval(SnapshotFreshness.resetExpiryRefreshGrace + 1)
    ).isEmpty)
    #expect(stored.providerAccessAlerts(
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        now: generatedAt.addingTimeInterval(120)
    ).isEmpty)
}

@Test func earlierAccountResetDoesNotHideLaterBlockingReset() {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let fiveHourReset = generatedAt.addingTimeInterval(60)
    let weeklyReset = generatedAt.addingTimeInterval(600)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic-work",
                accountName: "Work Claude",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: fiveHourReset,
                lastUpdatedAt: generatedAt
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic-work",
                accountName: "Work Claude",
                label: "Claude weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 100,
                limit: 100,
                resetsAt: weeklyReset,
                lastUpdatedAt: generatedAt
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .anthropic,
                accountID: "anthropic-work",
                accountName: "Work Claude",
                generatedAt: generatedAt,
                status: .limited,
                accessState: ProviderAccessState(kind: .blockedUntilReset, resetsAt: weeklyReset),
                errorMessage: nil
            ),
        ]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 10_000)

    #expect(stored.providerAccessAlerts(
        stalenessPolicy: policy,
        now: fiveHourReset.addingTimeInterval(SnapshotFreshness.resetExpiryRefreshGrace + 1)
    ).count == 1)
    #expect(stored.providerAccessAlerts(
        stalenessPolicy: policy,
        now: weeklyReset.addingTimeInterval(SnapshotFreshness.resetExpiryRefreshGrace + 1)
    ).isEmpty)
}

@Test func providerAccessResetCopyIncludesDateForAnotherDay() throws {
    let now = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let resetsAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-27T12:00:00Z"))
    let report = StoredProviderReport(
        provider: .anthropic,
        accountID: "anthropic-work",
        accountName: "Work Claude",
        generatedAt: now,
        status: .limited,
        accessState: ProviderAccessState(kind: .blockedUntilReset, resetsAt: resetsAt),
        errorMessage: nil
    )
    let alert = try #require(report.providerAccessAlert)

    #expect(alert.resetDisplayText(now: now) == resetsAt.formatted(date: .abbreviated, time: .shortened))
    #expect(alert.resetAccessibilityText(now: now) == resetsAt.formatted(date: .abbreviated, time: .shortened))
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
    #expect(outcome.didSaveSnapshot == false)
    #expect(primary.loadCurrent().snapshot == nil)
    #expect(primary.loadHistory().isEmpty)
}

@Test func snapshotRefreshServiceClearsStoredProviderStateWhenAllAccountsAreDisabled() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let widgetMirror = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 200)
    let savedAt = previousAt.addingTimeInterval(901)
    let previous = StoredUsageSnapshot(
        savedAt: previousAt,
        refreshResult: ConnectorRefreshResult(
            generatedAt: previousAt,
            reports: [ProviderConnectorReport(
                provider: .openAI,
                accountID: "openai-primary",
                accountName: "OpenAI",
                generatedAt: previousAt,
                limits: [usageLimit(
                    provider: .openAI,
                    accountID: "openai-primary",
                    used: 20,
                    savedAt: previousAt
                )],
                status: .healthy
            )]
        )
    )
    try primary.save(previous)
    try widgetMirror.save(previous)
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
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary, mirrors: [widgetMirror]),
        promptCacheTelemetryReader: { _ in [] }
    )

    let outcome = try await service.refresh(now: savedAt)
    let current = try #require(primary.loadCurrent().snapshot)
    let mirrored = try #require(widgetMirror.loadCurrent().snapshot)

    #expect(outcome.didSaveSnapshot == true)
    #expect(outcome.refreshResult.reports.isEmpty)
    #expect(current.savedAt == savedAt)
    #expect(current.snapshot.generatedAt == savedAt)
    #expect(current.snapshot.limits.isEmpty)
    #expect(current.reports.isEmpty)
    #expect(mirrored == current)
    #expect(primary.loadHistory().count == 2)
    #expect(SnapshotStoreStalenessPolicy(maximumAge: 900).status(for: current, now: savedAt) == .unknown)
}

@Test func snapshotRefreshServiceMirrorsSavedSnapshotToWidgetFallbackStore() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let widgetMirror = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary, mirrors: [widgetMirror]),
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    let refreshResult = ConnectorRefreshResult(
        generatedAt: savedAt,
        reports: [ProviderConnectorReport(
            provider: .openAI,
            accountID: "openai-primary",
            accountName: "OpenAI",
            generatedAt: savedAt,
            limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
        )]
    )

    _ = try await service.saveMergedAsync(refreshResult: refreshResult, savedAt: savedAt)

    #expect(primary.loadCurrent().snapshot?.savedAt == savedAt)
    #expect(widgetMirror.loadCurrent().snapshot?.savedAt == savedAt)
    #expect(widgetMirror.loadCurrent().snapshot?.snapshot.limits.count == 1)
}

@Test func snapshotRefreshServiceSyncSaveMirrorsSavedSnapshotToWidgetFallbackStore() throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let widgetMirror = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary, mirrors: [widgetMirror]),
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    let refreshResult = ConnectorRefreshResult(
        generatedAt: savedAt,
        reports: [ProviderConnectorReport(
            provider: .openAI,
            accountID: "openai-primary",
            accountName: "OpenAI",
            generatedAt: savedAt,
            limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
        )]
    )

    _ = try service.saveMerged(refreshResult: refreshResult, savedAt: savedAt)

    #expect(primary.loadCurrent().snapshot?.savedAt == savedAt)
    #expect(widgetMirror.loadCurrent().snapshot?.savedAt == savedAt)
    #expect(widgetMirror.loadCurrent().snapshot?.snapshot.limits.count == 1)
}

@Test func snapshotRefreshServiceMirrorsPromptCacheTelemetryBeforeReadingIt() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let callOrder = SnapshotRefreshCallOrderRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryMirror: { _, _ in
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

@Test func snapshotRefreshServicePassesBookmarkStoreToPromptCacheMirror() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let bookmarkStore = SecureFileBookmarkStore(storeURL: try temporaryDirectory().appending(path: "bookmarks.json"))
    let callOrder = SnapshotRefreshCallOrderRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        bookmarkStore: bookmarkStore,
        promptCacheTelemetryMirror: { store, _ in
            callOrder.record(store == nil ? "missing" : "present")
        },
        promptCacheTelemetryReader: { _ in [] }
    )

    _ = service.promptCacheObservations(now: Date(timeIntervalSince1970: 300))

    #expect(callOrder.values == ["present"])
}

@Test func snapshotRefreshServiceMirrorsPromptCacheFromConfiguredCodexUsageDirectories() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let customRoot = try temporaryDirectory().appending(path: "custom-home", directoryHint: .isDirectory)
    let codeRoot = customRoot.appending(path: ".code-chris", directoryHint: .isDirectory)
    let customAuth = codeRoot.appending(path: "auth_accounts.json")
    try FileManager.default.createDirectory(at: codeRoot, withIntermediateDirectories: true)
    try Data().write(to: customAuth)
    let store = AccountConfigurationStore(configurationURL: accountURL)
    try store.save(AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 100), accounts: [
        LocalProviderAccountConfiguration(
            id: "custom-code",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Custom Code",
            authPath: customAuth.path
        ),
    ]))
    let recorder = SnapshotRefreshSourceRecorder()
    let service = SnapshotRefreshService(
        accountStore: store,
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryMirror: { _, sources in
            recorder.record(sources.map(\.path))
        },
        promptCacheTelemetryReader: { _ in [] }
    )

    _ = service.promptCacheObservations(now: Date(timeIntervalSince1970: 300))

    #expect(recorder.values == [codeRoot.appending(path: "usage", directoryHint: .isDirectory).path])
}

@Test func snapshotRefreshServiceMirrorsPromptCacheTelemetryDuringFullRefresh() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let callOrder = SnapshotRefreshCallOrderRecorder()
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryMirror: { _, _ in
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
    let legacyJSON = #"""
    {
      "schemaVersion": 1,
      "updatedAt": "1970-01-01T00:05:00Z",
      "accounts": [
        {
          "id": "claude-local-default",
          "provider": "anthropic",
          "connectorKind": "claudeLocalStatus",
          "displayName": "Claude",
          "isEnabled": true
        }
      ]
    }
    """#
    try Data(legacyJSON.utf8).write(to: accountURL)

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

@Test func snapshotRefreshServiceMigratesLegacyGoogleAccountWithoutCopyingCredentials() throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let oldCredentials = Data("legacy-google-credential".utf8)
    let credentialStore = InMemoryProviderCredentialStore(storage: ["gemini-code-assist-default": oldCredentials])
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        credentialStore: credentialStore,
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "gemini-code-assist-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Gemini"
        )]
    ))

    let accountDocument = service.loadConfiguredAccounts(now: savedAt).document

    #expect(accountDocument.accounts.contains { account in
        account.id == "google-antigravity-default"
            && account.connectorKind == .googleAntigravityQuota
            && account.displayName == "Antigravity"
    })
    #expect(!accountDocument.accounts.contains { $0.id == "gemini-code-assist-default" })
    #expect(try credentialStore.load(accountID: "gemini-code-assist-default") == oldCredentials)
    #expect(try credentialStore.load(accountID: "google-antigravity-default") == nil)
}

@Test func snapshotRefreshServiceRefreshesGoogleFromStatusLineSnapshot() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let bridgeStore = GoogleAntigravityStatusLineSnapshotStore(
        snapshotURL: try temporaryDirectory().appending(path: "antigravity-status-line.json")
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try bridgeStore.save(GoogleAntigravityStatusLineSnapshot(
        sourceVersion: "1.1.1",
        planTier: "Google AI Pro",
        observedAt: savedAt,
        buckets: [
            GoogleAntigravityStatusLineBucket(
                id: "gemini-3.1-pro-high-5h",
                remainingFraction: 0.93,
                resetsAt: savedAt.addingTimeInterval(3_600)
            ),
            GoogleAntigravityStatusLineBucket(
                id: "claude-sonnet-4.6-weekly",
                remainingFraction: 0.88,
                resetsAt: savedAt.addingTimeInterval(7 * 24 * 3_600)
            ),
        ]
    ))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        googleAntigravitySnapshotLoader: bridgeStore,
        promptCacheTelemetryReader: { _ in [] }
    )
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "google-antigravity-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity"
        )]
    ))

    let outcome = try await service.refresh(now: savedAt)
    let current = try #require(primary.loadCurrent().snapshot)

    #expect(outcome.refreshResult.reports.first?.provider == .google)
    #expect(outcome.refreshResult.reports.first?.status == .healthy)
    #expect(outcome.refreshResult.reports.first?.errorMessage == nil)
    #expect(outcome.refreshResult.snapshot.limits.map(\.label) == [
        "Gemini 3.1 Pro High 5-hour",
        "Claude Sonnet 4.6 Weekly",
    ])
    #expect(current.reports.first?.provider == .google)
    #expect(current.reports.first?.status == .healthy)
    #expect(current.snapshot.limits.map(\.used) == [7, 12])
}

@Test func snapshotRefreshServicePersistsGoogleSetupRequiredStateWhenBridgeIsMissing() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let missingBridgeStore = GoogleAntigravityStatusLineSnapshotStore(
        snapshotURL: try temporaryDirectory()
            .appending(path: "Provider Inputs", directoryHint: .isDirectory)
            .appending(path: "missing-antigravity-status-line.json")
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        googleAntigravitySnapshotLoader: missingBridgeStore,
        promptCacheTelemetryReader: { _ in [] }
    )
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "google-antigravity-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity"
        )]
    ))

    let outcome = try await service.refresh(now: savedAt)
    let current = try #require(primary.loadCurrent().snapshot)

    #expect(outcome.refreshResult.reports.first?.status == .unknown)
    #expect(outcome.refreshResult.reports.first?.errorMessage?.contains("bridge setup is required") == true)
    #expect(current.reports.first?.status == .unknown)
    #expect(current.snapshot.limits.isEmpty)
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

@Test func snapshotRefreshRunnerPublishesAuthoritativeEmptyRefreshAfterDisablingAllAccounts() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 200)
    let savedAt = Date(timeIntervalSince1970: 300)
    try primary.save(StoredUsageSnapshot(
        savedAt: previousAt,
        refreshResult: ConnectorRefreshResult(
            generatedAt: previousAt,
            reports: [ProviderConnectorReport(
                provider: .anthropic,
                accountID: "claude-primary",
                accountName: "Claude",
                generatedAt: previousAt,
                limits: [usageLimit(
                    provider: .anthropic,
                    accountID: "claude-primary",
                    used: 40,
                    savedAt: previousAt
                )],
                status: .healthy
            )]
        )
    ))
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: []
    ))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(service: service, lock: nil)

    let decision = try await runner.refresh(now: savedAt)

    if case let .refreshed(outcome) = decision {
        #expect(outcome.didSaveSnapshot == true)
        #expect(outcome.refreshResult.reports.isEmpty)
        #expect(primary.loadCurrent().snapshot?.snapshot.limits.isEmpty == true)
        #expect(primary.loadCurrent().snapshot?.reports.isEmpty == true)
    } else {
        Issue.record("expected an authoritative empty refresh after disabling all accounts")
    }
}

@Test func snapshotRefreshRunnerRetriesAuthoritativeEmptyPublicationWhenPrimaryIsAlreadyEmpty() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let widgetMirror = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 200)
    let savedAt = Date(timeIntervalSince1970: 300)
    try primary.save(StoredUsageSnapshot(
        savedAt: previousAt,
        snapshot: UsageSnapshot(generatedAt: previousAt, limits: [])
    ))
    try widgetMirror.save(StoredUsageSnapshot(
        savedAt: previousAt,
        snapshot: UsageSnapshot(generatedAt: previousAt, limits: [usageLimit(
            provider: .openAI,
            accountID: "stale-openai",
            used: 20,
            savedAt: previousAt
        )])
    ))
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: []
    ))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary, mirrors: [widgetMirror]),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(service: service, lock: nil)

    let decision = try await runner.refresh(now: savedAt)

    if case .refreshed = decision {
        #expect(primary.loadCurrent().snapshot?.snapshot.generatedAt == savedAt)
        #expect(widgetMirror.loadCurrent().snapshot?.snapshot.limits.isEmpty == true)
        #expect(widgetMirror.loadCurrent().snapshot?.savedAt == savedAt)
    } else {
        Issue.record("expected authoritative empty publication to retry while an empty primary exists")
    }
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

@Test func widgetContainerLocalSnapshotDirectoryTargetsWidgetExtensionContainer() {
    let path = ContextPanelLocations.widgetContainerLocalSnapshotDirectory().path

    #expect(path.contains("Library/Containers/com.shinycomputers.contextpanel.widget/Data"))
    #expect(path.hasSuffix("Library/Application Support/Context Panel/Snapshots"))
}

@Test func snapshotRefreshStoresAppDefaultSkipsWidgetContainerMirrorInSandbox() {
    let stores = SnapshotRefreshStores.appDefault(
        appGroupID: "invalid.test.app-group",
        isRunningInAppSandbox: true
    )

    #expect(stores.mirrors.isEmpty)
}

@Test func snapshotRefreshStoresAppDefaultKeepsWidgetFallbackMirrorOutsideSandbox() {
    let stores = SnapshotRefreshStores.appDefault(
        appGroupID: "invalid.test.app-group",
        isRunningInAppSandbox: false
    )

    #expect(stores.mirrors.count == 1)
    #expect(stores.mirrors.first?.currentSnapshotURL.path.contains(
        "Library/Containers/com.shinycomputers.contextpanel.widget/Data"
    ) == true)
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

@Test func snapshotStalenessPolicyMarksExpiredResetAsStaleAfterGrace() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt)]
    ))
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    #expect(policy.status(for: stored, now: resetAt.addingTimeInterval(9)) == .limited)
    #expect(policy.status(for: stored, now: resetAt.addingTimeInterval(10)) == .stale)
}

@Test func snapshotStoreStalenessPolicyCacheLoadsOnlyOnReload() {
    let initialPolicy = SnapshotStoreStalenessPolicy(maximumAge: 60)
    var loadCount = 0
    let cache = SnapshotStoreStalenessPolicyCache(
        initialPolicy: initialPolicy,
        loadPolicy: {
            loadCount += 1
            return SnapshotStoreStalenessPolicy(maximumAge: 120)
        }
    )

    #expect(loadCount == 0)
    #expect(cache.policy == initialPolicy)

    let reloadedPolicy = cache.reload()

    #expect(loadCount == 1)
    #expect(reloadedPolicy.maximumAge == 120)
    #expect(cache.policy == reloadedPolicy)

    _ = cache.policy.status(for: nil, now: Date(timeIntervalSince1970: 1_000))
    _ = cache.policy.refreshAttentionSummary(for: nil, now: Date(timeIntervalSince1970: 1_000))

    #expect(loadCount == 1)

    cache.reload()

    #expect(loadCount == 2)
}

@Test func snapshotStoreStalenessPolicyCacheAdoptsUpdatedResetStateOnReload() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let now = resetAt.addingTimeInterval(20)
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [
        usageLimit(provider: .google, accountID: "Antigravity", used: 0, savedAt: savedAt, resetsAt: resetAt),
    ])
    let stored = StoredUsageSnapshot(savedAt: resetAt.addingTimeInterval(10), snapshot: staleSnapshot)
    var loadedState: ResetExpiryRefreshState?
    let cache = SnapshotStoreStalenessPolicyCache(
        initialPolicy: SnapshotStoreStalenessPolicy(maximumAge: 5 * 60),
        loadPolicy: {
            SnapshotStoreStalenessPolicy(
                maximumAge: 5 * 60,
                resetExpiryRefreshState: loadedState
            )
        }
    )

    #expect(cache.policy.refreshAttentionSummary(for: stored, now: now) != nil)

    var suppressingState = ResetExpiryRefreshState()
    suppressingState.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )
    loadedState = suppressingState

    #expect(cache.policy.refreshAttentionSummary(for: stored, now: now) != nil)

    cache.reload()

    #expect(cache.policy.refreshAttentionSummary(for: stored, now: now) == nil)
}

@Test func snapshotStalenessPolicyKeepsEventDrivenAGYLimitsFreshWhileIdle() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let now = generatedAt.addingTimeInterval(24 * 3_600)
    let resetAt = now.addingTimeInterval(3_600)
    let limit = UsageLimit(
        id: "google:local:agy:gemini-weekly",
        provider: .google,
        accountID: "local",
        accountName: "Antigravity",
        label: "Gemini Weekly",
        unit: .percent,
        used: 20,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: generatedAt,
        confidence: .observed
    )
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [limit])
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    #expect(policy.status(for: stored, now: now) == .healthy)
    #expect(policy.refreshAttentionSummary(for: stored, now: now) == nil)
    #expect(policy.nextStaleTransitionDate(for: stored.snapshot, now: now) == resetAt.addingTimeInterval(10))
}

@Test func snapshotStalenessPolicyRefreshesElapsedAGYResetWithoutShowingStale() {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = generatedAt.addingTimeInterval(60)
    let now = resetAt.addingTimeInterval(10)
    let limit = UsageLimit(
        id: "google:local:agy:gemini-5h",
        provider: .google,
        accountID: "local",
        accountName: "Antigravity",
        label: "Gemini 5-hour",
        unit: .percent,
        used: 20,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: generatedAt,
        confidence: .observed
    )
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [limit])
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    #expect(policy.status(for: stored, now: now) == .healthy)
    #expect(policy.refreshAttentionSummary(for: stored, now: now) == nil)
    #expect(policy.needsResetRefresh(for: stored, now: now))
}

@Test func snapshotStalenessPolicyStillAgesMixedPolledProviders() {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let now = generatedAt.addingTimeInterval(3_600)
    let agyLimit = UsageLimit(
        id: "google:local:agy:gemini-weekly",
        provider: .google,
        accountID: "local",
        accountName: "Antigravity",
        label: "Gemini Weekly",
        unit: .percent,
        used: 20,
        limit: 100,
        resetsAt: now.addingTimeInterval(3_600),
        lastUpdatedAt: generatedAt,
        confidence: .observed
    )
    let openAILimit = usageLimit(
        provider: .openAI,
        accountID: "openai",
        used: 20,
        savedAt: generatedAt,
        resetsAt: now.addingTimeInterval(3_600)
    )
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [agyLimit, openAILimit])
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    #expect(policy.status(for: stored, now: now) == .stale)
    #expect(policy.refreshAttentionSummary(for: stored, now: now)?.isSnapshotAgeStale == true)
}

@Test func refreshAttentionSummaryNamesSingleExpiredResetProvider() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .google, accountID: "Antigravity", used: 0, savedAt: savedAt, resetsAt: resetAt)]
    ))
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: resetAt.addingTimeInterval(10)))

    #expect(summary.singleProvider == .google)
    #expect(summary.refreshNeededTitle == "Google refresh needed")
    #expect(summary.refreshNeededDetail.contains("Google · Antigravity"))
    #expect(summary.refreshNeededDetail.contains("expired"))
}

@Test func refreshAttentionSummaryUsesGoogleAntigravityBridgeReadGuidance() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let message = "Antigravity bridge data could not be read. The last good quota remains available while setup is checked."
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "google-antigravity",
            accountName: "Antigravity",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: message
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededTitle == "Google refresh needed")
    #expect(summary.refreshNeededDetail.contains("Google · Antigravity needs attention:"))
    #expect(summary.refreshNeededDetail.contains(message))
    #expect(summary.refreshNeededDetail.contains("Reconnect") == false)
}

@Test func refreshAttentionSummaryUsesGoogleAntigravitySetupGuidance() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let message = "Antigravity bridge setup is required. Copy the setup command from Context Panel and paste it into AGY CLI once. With AGY 1.1.1, later Every Code AGY runs publish quota automatically."
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "google-antigravity",
            accountName: "Antigravity",
            generatedAt: savedAt,
            status: .unknown,
            errorMessage: message
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededTitle == "Google refresh needed")
    #expect(summary.refreshNeededDetail.contains(message))
    #expect(summary.refreshNeededDetail.contains("Reconnect") == false)
}

@Test func refreshAttentionSummaryUsesFailureReportMessageWhenAvailable() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "openai-account",
            accountName: "OpenAI",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: "Every Code auth expired."
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededDetail == "OpenAI · OpenAI needs attention: Every Code auth expired.")
}

@Test func refreshAttentionSummaryUsesReconnectFallbackWhenFailureHasNoMessage() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "openai-account",
            accountName: "OpenAI",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: nil
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededDetail == "OpenAI · OpenAI needs attention. Reconnect this account, then refresh.")
}

@Test func refreshAttentionSummaryOmitsSuppressedExpiredResetProvider() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [
        usageLimit(provider: .google, accountID: "Antigravity", used: 0, savedAt: savedAt, resetsAt: resetAt),
    ])
    var state = ResetExpiryRefreshState()
    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )
    let stored = StoredUsageSnapshot(savedAt: resetAt.addingTimeInterval(10), snapshot: staleSnapshot)
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60, resetExpiryRefreshState: state)

    #expect(policy.refreshAttentionSummary(for: stored, now: resetAt.addingTimeInterval(20)) == nil)
}

@Test func refreshAttentionSummaryOmitsExpiredResetAfterRetryExhaustion() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [
        usageLimit(provider: .google, accountID: "Antigravity", used: 0, savedAt: savedAt, resetsAt: resetAt),
    ])
    var state = ResetExpiryRefreshState()
    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )
    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(40)
    )
    let stored = StoredUsageSnapshot(savedAt: resetAt.addingTimeInterval(40), snapshot: staleSnapshot)
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60, resetExpiryRefreshState: state)

    #expect(policy.refreshAttentionSummary(for: stored, now: resetAt.addingTimeInterval(70)) == nil)
}

@Test func snapshotRefreshRunnerRefreshesWhenResetExpired() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let resetStateStore = ResetExpiryRefreshStateStore(stateURL: try temporaryDirectory().appending(path: "reset-state.json"))
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: []
    ))
    try primary.save(StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt)]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        stalenessPolicy: SnapshotStoreStalenessPolicy(maximumAge: 5 * 60),
        resetExpiryRefreshStore: resetStateStore,
        lock: nil
    )

    let decision = try await runner.refreshIfNeeded(now: resetAt.addingTimeInterval(10))

    if case .refreshed = decision {
        #expect(primary.loadCurrent().snapshot?.snapshot.limits.isEmpty == true)
        #expect(resetStateStore.load().records.isEmpty)
    } else {
        Issue.record("expected an authoritative empty refresh to clear expired reset state")
    }
}

@Test func snapshotRefreshRunnerRefreshesElapsedAGYResetWithoutVisibleStaleState() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let resetStateStore = ResetExpiryRefreshStateStore(stateURL: try temporaryDirectory().appending(path: "reset-state.json"))
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let agyLimit = UsageLimit(
        id: "google:local:agy:gemini-5h",
        provider: .google,
        accountID: "local",
        accountName: "Antigravity",
        label: "Gemini 5-hour",
        unit: .percent,
        used: 20,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: []
    ))
    try primary.save(StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [agyLimit])
    ))
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        stalenessPolicy: policy,
        resetExpiryRefreshStore: resetStateStore,
        lock: nil
    )
    let now = resetAt.addingTimeInterval(10)

    #expect(policy.status(for: primary.loadCurrent().snapshot, now: now) == .healthy)
    let decision = try await runner.refreshIfNeeded(now: now)

    if case .refreshed = decision {
        #expect(primary.loadCurrent().snapshot?.snapshot.limits.isEmpty == true)
        #expect(resetStateStore.load().records.isEmpty)
    } else {
        Issue.record("expected AGY state to clear when no accounts remain configured")
    }
}

@Test func resetExpiryRefreshStateSuppressesImmediateRetryForSameExpiredWindow() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [
        usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt),
    ])
    var state = ResetExpiryRefreshState()

    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )

    let suppressedPolicy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60, resetExpiryRefreshState: state)
    let stored = StoredUsageSnapshot(savedAt: resetAt.addingTimeInterval(10), snapshot: staleSnapshot)
    #expect(suppressedPolicy.status(for: stored, now: resetAt.addingTimeInterval(20)) == .limited)
    #expect(suppressedPolicy.status(for: stored, now: resetAt.addingTimeInterval(40)) == .stale)
}

@Test func resetExpiryRefreshStateSchedulesRetryInsteadOfPastResetDeadline() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [
        usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt),
    ])
    var state = ResetExpiryRefreshState()
    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )

    #expect(state.nextRefreshCheckDate(for: staleSnapshot, now: resetAt.addingTimeInterval(20)) == resetAt.addingTimeInterval(40))
}

@Test func resetExpiryRefreshStateKeepsSharedConfiguredAccountsDistinct() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let sharedConfiguredAccountID = "configured-openai-shared"
    let firstAccount = UsageLimit(
        id: "openai:weekly",
        provider: .openAI,
        accountID: "raw-openai-a",
        configuredAccountID: sharedConfiguredAccountID,
        accountName: "Work A",
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 100,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
    let secondAccount = UsageLimit(
        id: "openai:weekly",
        provider: .openAI,
        accountID: "raw-openai-b",
        configuredAccountID: sharedConfiguredAccountID,
        accountName: "Work B",
        label: "Weekly",
        windowLabel: "Weekly",
        unit: .percent,
        used: 100,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [firstAccount, secondAccount])
    var state = ResetExpiryRefreshState()

    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )
    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAt: resetAt.addingTimeInterval(20)
    )

    let firstKey = try #require(ResetExpiryRefreshKey(limit: firstAccount))
    let secondKey = try #require(ResetExpiryRefreshKey(limit: secondAccount))
    let firstRecord = try #require(state.record(for: firstKey))
    let secondRecord = try #require(state.record(for: secondKey))
    #expect(state.records.count == 2)
    #expect(firstRecord.retryCount == 2)
    #expect(secondRecord.retryCount == 2)
    #expect(firstRecord.key.accountID == "raw-openai-a")
    #expect(secondRecord.key.accountID == "raw-openai-b")
}

@Test func resetExpiryRefreshStateDoesNotConsumeRetryForUnattemptedAccount() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let openAIStuck = usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt)
    let googleStuck = usageLimit(provider: .google, accountID: "google", used: 100, savedAt: savedAt, resetsAt: resetAt)
    let staleSnapshot = UsageSnapshot(generatedAt: savedAt, limits: [openAIStuck, googleStuck])
    var state = ResetExpiryRefreshState()
    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAccounts: [ResetExpiryRefreshAccountKey(provider: .openAI, accountID: "openai", configuredAccountID: nil)],
        attemptedAt: resetAt.addingTimeInterval(10)
    )

    state.recordAttempt(
        previousSnapshot: staleSnapshot,
        refreshedSnapshot: staleSnapshot,
        attemptedAccounts: [ResetExpiryRefreshAccountKey(provider: .google, accountID: "google", configuredAccountID: nil)],
        attemptedAt: resetAt.addingTimeInterval(20)
    )

    let openAIKey = try #require(ResetExpiryRefreshKey(limit: openAIStuck))
    let googleKey = try #require(ResetExpiryRefreshKey(limit: googleStuck))
    let openAIRecord = try #require(state.record(for: openAIKey))
    let googleRecord = try #require(state.record(for: googleKey))
    #expect(openAIRecord.retryCount == 1)
    #expect(openAIRecord.nextRetryAt == resetAt.addingTimeInterval(40))
    #expect(googleRecord.retryCount == 1)
    #expect(googleRecord.nextRetryAt == resetAt.addingTimeInterval(50))
}

@Test func snapshotRefreshRunnerDefersResetRetryWhenRefreshLockIsHeld() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let resetStateStore = ResetExpiryRefreshStateStore(stateURL: try temporaryDirectory().appending(path: "reset-state.json"))
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let heldLock = try HeldFileLock(url: lockURL)
    defer { heldLock.release() }
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    try primary.save(StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt)]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        resetExpiryRefreshStore: resetStateStore,
        lock: SnapshotRefreshLock(lockURL: lockURL)
    )
    let now = resetAt.addingTimeInterval(10)

    let decision = try await runner.refresh(now: now)

    #expect(decision == .skippedAlreadyRunning)
    #expect(runner.nextRefreshCheckDate(now: now) == now.addingTimeInterval(30))
}

@Test func resetExpiryRefreshStateClearsWhenResetWindowAdvances() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let resetAt = savedAt.addingTimeInterval(60)
    let previous = UsageSnapshot(generatedAt: savedAt, limits: [
        usageLimit(provider: .openAI, accountID: "openai", used: 100, savedAt: savedAt, resetsAt: resetAt),
    ])
    let refreshed = UsageSnapshot(generatedAt: resetAt.addingTimeInterval(10), limits: [
        usageLimit(
            provider: .openAI,
            accountID: "openai",
            used: 0,
            savedAt: resetAt.addingTimeInterval(10),
            resetsAt: resetAt.addingTimeInterval(3_600)
        ),
    ])
    var state = ResetExpiryRefreshState(records: [ResetExpiryRefreshRecord(
        key: try #require(ResetExpiryRefreshKey(limit: previous.limits[0])),
        attemptedAt: resetAt.addingTimeInterval(10),
        nextRetryAt: resetAt.addingTimeInterval(40),
        retryCount: 1
    )])

    state.recordAttempt(
        previousSnapshot: previous,
        refreshedSnapshot: refreshed,
        attemptedAt: resetAt.addingTimeInterval(10)
    )

    #expect(state.records.isEmpty)
}

@Test func snapshotRefreshRunnerNextRefreshCheckIntervalUsesResetDeadline() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let finishedAt = startedAt.addingTimeInterval(2)
    let resetCheckAt = startedAt.addingTimeInterval(20)

    let interval = SnapshotRefreshRunner.nextRefreshCheckInterval(
        normalInterval: 5 * 60,
        nextCheckDate: resetCheckAt,
        startedAt: startedAt,
        finishedAt: finishedAt
    )

    #expect(interval == 18)
}

@Test func snapshotRefreshRunnerSkipsWhenRefreshLockIsHeld() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let heldLock = try HeldFileLock(url: lockURL)
    defer { heldLock.release() }
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL)
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
    let heldLock = try HeldFileLock(url: lockURL)
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL)
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

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) {
        heldLock.release()
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

@Test func snapshotRefreshRunnerReusesUnlockedRefreshLockFile() async throws {
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
        lock: SnapshotRefreshLock(lockURL: lockURL)
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
    #expect(FileManager.default.fileExists(atPath: lockURL.path))
}

@Test func snapshotRefreshRunnerSerializesManualSavesWithRefreshLock() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let lockURL = try temporaryDirectory().appending(path: "refresh.lock")
    try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let heldLock = try HeldFileLock(url: lockURL)
    defer { heldLock.release() }
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary)
    )
    let runner = SnapshotRefreshRunner(
        service: service,
        lock: SnapshotRefreshLock(lockURL: lockURL)
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

private final class HeldFileLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

private func usageLimit(
    provider: Provider,
    accountID: String,
    configuredAccountID: String? = nil,
    used: Int,
    savedAt: Date,
    resetsAt: Date? = nil
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
        resetsAt: resetsAt ?? savedAt.addingTimeInterval(3_600),
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

private final class SnapshotRefreshSourceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func record(_ values: [String]) {
        lock.withLock {
            storedValues = values
        }
    }
}
