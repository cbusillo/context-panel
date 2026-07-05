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

@Test func refreshFailureCategoryClassifiesProviderAuthAndOAuthFailures() {
    #expect(RefreshFailureCategory(errorMessage: nil) == .none)
    #expect(RefreshFailureCategory(
        errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage. Sign in again from Every Code or Codex, then refresh Context Panel."
    ) == .providerAuthorization)
    #expect(RefreshFailureCategory(
        errorMessage: "Google Antigravity OAuth refresh failed with invalid_client. The OAuth client was not found. Sign in again from Settings to refresh the OAuth client session."
    ) == .oauthInvalidClient)
    #expect(RefreshFailureCategory(
        errorMessage: "Google Antigravity OAuth session has expired. Sign in again from Settings."
    ) == .oauthExpired)
    #expect(RefreshFailureCategory(
        errorMessage: "Google Antigravity credentials are in an unexpected format. Sign in again from Settings."
    ) == .credentialFormat)
    #expect(RefreshFailureCategory(
        errorMessage: "Google Antigravity is connected, but Google Code Assist rejected quota access for this app or account."
    ) == .providerAuthorization)
    #expect(RefreshFailureCategory(
        errorMessage: "Provider returned no usage records for this account."
    ) == .unknown)
    #expect(RefreshFailureCategory(
        errorMessage: "Provider request failed with HTTP status code 429."
    ) == .httpFailure)
}

@Test func googleKeychainInteractionErrorsUseReconnectGuidance() {
    let report = StoredProviderReport(
        provider: .google,
        accountID: "google-antigravity",
        accountName: "Antigravity",
        generatedAt: Date(timeIntervalSince1970: 100),
        status: .failure,
        errorMessage: "Google Antigravity keychain read failed: user interaction is not allowed, status -25308."
    )

    #expect(report.userFacingErrorMessage?.contains("Keychain approval") == true)
    #expect(report.userFacingErrorMessage?.contains("Click Refresh") == true)
    #expect(report.userFacingErrorMessage?.contains("for Google") == true)
    #expect(report.userFacingErrorMessage?.contains("Always Allow") == true)
    #expect(report.userFacingErrorMessage?.contains("\"gemini\"") == true)
    #expect(report.userFacingErrorMessage?.contains("-25308") == false)
}

@Test func googleAntigravityAccessTokenExpiryUsesForegroundRefreshGuidance() {
    let report = StoredProviderReport(
        provider: .google,
        accountID: "google-antigravity",
        accountName: "Antigravity",
        generatedAt: Date(timeIntervalSince1970: 100),
        status: .failure,
        errorMessage: "Google Antigravity access token has expired. Open Antigravity so it can refresh its Google session, then refresh Google in Context Panel."
    )

    #expect(report.userFacingErrorMessage?.contains("access token expired") == true)
    #expect(report.userFacingErrorMessage?.contains("Open Antigravity") == true)
    #expect(report.userFacingErrorMessage?.contains("refresh Google in Context Panel") == true)
    #expect(report.userFacingErrorMessage?.contains("Sign in again") == false)
    #expect(report.userFacingErrorMessage?.contains("Reconnect") == false)
}

@Test func googleCodeAssistRejectionUsesAccountCheckGuidance() {
    let report = StoredProviderReport(
        provider: .google,
        accountID: "google-antigravity",
        accountName: "Antigravity",
        generatedAt: Date(timeIntervalSince1970: 100),
        status: .failure,
        errorMessage: "Google Antigravity is connected, but Google Code Assist rejected quota access for this app or account."
    )

    #expect(report.userFacingErrorMessage?.contains("Code Assist rejected quota access") == true)
    #expect(report.userFacingErrorMessage?.contains("Antigravity or Google account") == true)
    #expect(report.userFacingErrorMessage?.contains("refresh Google in Context Panel") == true)
    #expect(report.userFacingErrorMessage?.contains("OAuth") == false)
    #expect(report.userFacingErrorMessage?.contains("Reconnect") == false)
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
                errorMessage: "Google Antigravity credentials are in an unexpected format."
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
                errorMessage: "Google Antigravity credentials are in an unexpected format."
            )
        ]),
        savedAt: second
    )

    let current = try #require(store.loadCurrent().snapshot)
    #expect(current.snapshot.limits.contains { $0.provider == .google && $0.accountID == otherAccountID })
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
                errorMessage: "Google Antigravity is not connected."
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

@Test func snapshotRefreshServiceMigratesGoogleCredentialsBeforeRefreshingMigratedAccount() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let credentials = Data(#"{"accessToken":"old-google-access","refreshToken":"google-refresh","expiresAt":"2099-01-01T00:00:00Z","scopes":["https://www.googleapis.com/auth/cloud-platform"]}"#.utf8)
    let credentialStore = InMemoryProviderCredentialStore(storage: ["gemini-code-assist-default": credentials])
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

    #expect(try credentialStore.load(accountID: "google-antigravity-default") == credentials)
    #expect(accountDocument.accounts.contains { $0.id == "google-antigravity-default" && $0.connectorKind == .googleAntigravityQuota })
    #expect(accountDocument.accounts.contains { $0.displayName == "Antigravity" })
    #expect(!accountDocument.accounts.contains { $0.id == "gemini-code-assist-default" })
}

@Test func snapshotRefreshServiceSkipsGoogleAntigravityInBackgroundRefreshes() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 240)
    let googleAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "google-antigravity-default")
    try primary.save(StoredUsageSnapshot(savedAt: previousAt, refreshResult: ConnectorRefreshResult(
        generatedAt: previousAt,
        reports: [ProviderConnectorReport(
            provider: .google,
            accountID: googleAccountID,
            configuredAccountID: "google-antigravity-default",
            accountName: "Antigravity",
            generatedAt: previousAt,
            limits: [UsageLimit(
                provider: .google,
                accountID: googleAccountID,
                configuredAccountID: "google-antigravity-default",
                accountName: "Antigravity",
                label: "Gemini 3.1 Pro High 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 7,
                limit: 100,
                resetsAt: previousAt.addingTimeInterval(3_600)
            )]
        )]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        allowsExternalGoogleKeychain: false,
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
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
    #expect(current.reports.first?.provider == .google)
    #expect(current.reports.first?.status == .healthy)
    #expect(current.reports.first?.errorMessage == nil)
    #expect(current.snapshot.limits.first?.provider == .google)
    #expect(current.snapshot.limits.first?.used == 7)
}

@Test func snapshotRefreshServicePreservesLegacyGoogleAntigravityDefaultsWhenBackgroundSkipsGoogle() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 240)
    let legacyAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "gemini-code-assist-default")
    try primary.save(StoredUsageSnapshot(savedAt: previousAt, refreshResult: ConnectorRefreshResult(
        generatedAt: previousAt,
        reports: [ProviderConnectorReport(
            provider: .google,
            accountID: legacyAccountID,
            configuredAccountID: "gemini-code-assist-default",
            accountName: "Gemini",
            generatedAt: previousAt,
            limits: [UsageLimit(
                provider: .google,
                accountID: legacyAccountID,
                configuredAccountID: "gemini-code-assist-default",
                accountName: "Gemini",
                label: "Gemini 3.1 Pro High 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 7,
                limit: 100,
                resetsAt: previousAt.addingTimeInterval(3_600)
            )]
        )]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        allowsExternalGoogleKeychain: false,
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "google-antigravity-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity"
        )]
    ))

    _ = try await service.refresh(now: savedAt)
    let current = try #require(primary.loadCurrent().snapshot)

    #expect(current.reports.first?.configuredAccountID == "google-antigravity-default")
    #expect(current.reports.first?.accountID == ConnectorRedactor.localAccountID(provider: .google, stableID: "google-antigravity-default"))
    #expect(current.reports.first?.status == .healthy)
    #expect(current.snapshot.limits.first?.configuredAccountID == "google-antigravity-default")
    #expect(current.snapshot.limits.first?.accountID == ConnectorRedactor.localAccountID(provider: .google, stableID: "google-antigravity-default"))
    #expect(current.snapshot.limits.first?.used == 7)
}

@Test func snapshotRefreshServiceCollapsesLegacyAndMigratedGoogleAntigravityWhenBackgroundSkipsGoogle() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 240)
    let legacyAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "gemini-code-assist-default")
    let migratedAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "google-antigravity-default")
    try primary.save(StoredUsageSnapshot(savedAt: previousAt, refreshResult: ConnectorRefreshResult(
        generatedAt: previousAt,
        reports: [
            ProviderConnectorReport(
                provider: .google,
                accountID: legacyAccountID,
                configuredAccountID: "gemini-code-assist-default",
                accountName: "Gemini",
                generatedAt: previousAt,
                limits: [UsageLimit(
                    provider: .google,
                    accountID: legacyAccountID,
                    configuredAccountID: "gemini-code-assist-default",
                    accountName: "Gemini",
                    label: "Legacy Gemini Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: 7,
                    limit: 100,
                    resetsAt: previousAt.addingTimeInterval(3_600)
                )]
            ),
            ProviderConnectorReport(
                provider: .google,
                accountID: migratedAccountID,
                configuredAccountID: "google-antigravity-default",
                accountName: "Antigravity",
                generatedAt: previousAt,
                limits: [UsageLimit(
                    provider: .google,
                    accountID: migratedAccountID,
                    configuredAccountID: "google-antigravity-default",
                    accountName: "Antigravity",
                    label: "Migrated Gemini Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: 5,
                    limit: 100,
                    resetsAt: previousAt.addingTimeInterval(3_600)
                )]
            ),
        ]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        allowsExternalGoogleKeychain: false,
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
    try AccountConfigurationStore(configurationURL: accountURL).save(AccountConfigurationDocument(
        updatedAt: savedAt,
        accounts: [LocalProviderAccountConfiguration(
            id: "google-antigravity-default",
            provider: .google,
            connectorKind: .googleAntigravityQuota,
            displayName: "Antigravity"
        )]
    ))

    _ = try await service.refresh(now: savedAt)
    let current = try #require(primary.loadCurrent().snapshot)

    #expect(current.reports.filter { $0.provider == .google }.count == 1)
    #expect(current.reports.first?.configuredAccountID == "google-antigravity-default")
    #expect(current.reports.first?.accountID == migratedAccountID)
    #expect(current.snapshot.limits.map(\.configuredAccountID) == ["google-antigravity-default", "google-antigravity-default"])
    #expect(current.snapshot.limits.map(\.accountID) == [migratedAccountID, migratedAccountID])
    #expect(current.snapshot.limits.map(\.label) == ["Migrated Gemini Weekly", "Legacy Gemini Weekly"])
}

@Test func snapshotRefreshServicePreservesFailureOnlyGoogleAntigravityReportWhenBackgroundSkipsGoogle() async throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let primary = JSONSnapshotStore(rootDirectory: try temporaryDirectory())
    let previousAt = Date(timeIntervalSince1970: 240)
    let googleAccountID = ConnectorRedactor.localAccountID(provider: .google, stableID: "google-antigravity-default")
    try primary.save(StoredUsageSnapshot(savedAt: previousAt, refreshResult: ConnectorRefreshResult(
        generatedAt: previousAt,
        reports: [ProviderConnectorReport(
            provider: .google,
            accountID: googleAccountID,
            configuredAccountID: "google-antigravity-default",
            accountName: "Antigravity",
            generatedAt: previousAt,
            limits: [],
            status: .failure,
            errorMessage: "Google Antigravity quota needs macOS Keychain approval."
        )]
    )))
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: primary),
        allowsExternalGoogleKeychain: false,
        promptCacheTelemetryReader: { _ in [] }
    )
    let savedAt = Date(timeIntervalSince1970: 300)
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
    #expect(outcome.refreshResult.reports.first?.status == .failure)
    #expect(outcome.refreshResult.reports.first?.errorMessage?.contains("Keychain approval") == true)
    #expect(current.reports.first?.provider == .google)
    #expect(current.reports.first?.status == .failure)
    #expect(current.reports.first?.errorMessage?.contains("Keychain approval") == true)
    #expect(current.snapshot.limits.isEmpty)
}

@Test func snapshotRefreshServiceDoesNotOverwriteExistingMigratedGoogleCredentials() throws {
    let accountURL = try temporaryDirectory().appending(path: "accounts.json")
    let oldCredentials = Data(#"{"accessToken":"old-google-access","refreshToken":"old-refresh","expiresAt":"2099-01-01T00:00:00Z","scopes":["https://www.googleapis.com/auth/cloud-platform"]}"#.utf8)
    let newCredentials = Data(#"{"accessToken":"new-google-access","refreshToken":"new-refresh","expiresAt":"2099-01-01T00:00:00Z","scopes":["https://www.googleapis.com/auth/cloud-platform"]}"#.utf8)
    let credentialStore = InMemoryProviderCredentialStore(storage: [
        "gemini-code-assist-default": oldCredentials,
        "google-antigravity-default": newCredentials,
    ])
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: accountURL),
        stores: SnapshotRefreshStores(primary: JSONSnapshotStore(rootDirectory: try temporaryDirectory())),
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

    _ = service.loadConfiguredAccounts(now: savedAt)

    #expect(try credentialStore.load(accountID: "google-antigravity-default") == newCredentials)
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

@Test func refreshAttentionSummaryUsesGoogleKeychainGuidance() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "google-antigravity",
            accountName: "Antigravity",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: "Keychain access failed with status -25308. User interaction is not allowed."
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededTitle == "Google refresh needed")
    #expect(summary.refreshNeededDetail.contains("Google · Antigravity needs attention:"))
    #expect(summary.refreshNeededDetail.contains("Refresh for Google"))
    #expect(summary.refreshNeededDetail.contains("Always Allow"))
    #expect(summary.refreshNeededDetail.contains("Reconnect") == false)
    #expect(summary.refreshNeededDetail.contains("-25308") == false)
}

@Test func refreshAttentionSummaryUsesGoogleAntigravityTokenGuidance() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "google-antigravity",
            accountName: "Antigravity",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: "Google Antigravity access token has expired. Open Antigravity so it can refresh its Google session, then refresh Google in Context Panel."
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededDetail.contains("Google Antigravity access token expired") == true)
    #expect(summary.refreshNeededDetail.contains("Open Antigravity") == true)
    #expect(summary.refreshNeededDetail.contains("refresh Google in Context Panel") == true)
    #expect(summary.refreshNeededDetail.contains("Reconnect") == false)
}

@Test func refreshAttentionSummaryUsesGoogleCodeAssistGuidance() throws {
    let savedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [StoredProviderReport(
            provider: .google,
            accountID: "google-antigravity",
            accountName: "Antigravity",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: "Google Antigravity is connected, but Google Code Assist rejected quota access for this app or account."
        )]
    )
    let policy = SnapshotStoreStalenessPolicy(maximumAge: 5 * 60)

    let summary = try #require(policy.refreshAttentionSummary(for: stored, now: savedAt.addingTimeInterval(10)))

    #expect(summary.refreshNeededDetail.contains("Code Assist rejected quota access") == true)
    #expect(summary.refreshNeededDetail.contains("Antigravity or Google account") == true)
    #expect(summary.refreshNeededDetail.contains("refresh Google in Context Panel") == true)
    #expect(summary.refreshNeededDetail.contains("OAuth") == false)
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

    #expect(decision == .skippedNoReports)
    #expect(resetStateStore.load().records.count == 1)
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
    FileManager.default.createFile(atPath: lockURL.path, contents: Data())
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
        lock: SnapshotRefreshLock(lockURL: lockURL, staleAfter: 60)
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

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) {
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
