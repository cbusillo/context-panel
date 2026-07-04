import Foundation
import Testing

@testable import ContextPanelCore
@testable import ContextPanelWidget
@testable import ContextPanelWidgetUI

private let testWidgetLinks = ContextPanelWidgetLinks(
    overview: URL(string: "contextpanel://overview")!,
    reconnect: URL(string: "contextpanel://reconnect")!,
    cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!
)

@Test func widgetKindMatchesSharedReloadIdentity() {
    #expect(ContextPanelWidgetIdentity.kind == "ContextPanelWidget")
}

@Test func companionWidgetKindMatchesSharedReloadIdentity() {
    #expect(ContextPanelCompanionWidgetIdentity.kind == "ContextPanelCompanionWidget")
}

@Test func widgetSnapshotUsesSetupNeededForMissingStore() {
    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: nil, status: .unknown),
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(widget.state == .setupNeeded)
    #expect(widget.status == .unknown)
    #expect(widget.limits.isEmpty)
    #expect(widget.message.contains("Set up"))
}

@Test func widgetSnapshotPreservesStaleCachedLimits() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: savedAt.addingTimeInterval(60)
    )

    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.limits.count == 1)
    #expect(widget.message == "Refresh Context Panel to update data.")
    #expect(widget.hasProviderReconnectIssue == false)
}

@Test func widgetSnapshotNamesSingleProviderForAgeOnlyStaleness() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: savedAt.addingTimeInterval(SnapshotFreshness.widgetMaximumAge + 1)
    )

    #expect(widget.refreshAttentionSummary?.singleProvider == .openAI)
    #expect(widget.widgetProblemText == "OpenAI refresh needed")
}

@Test func widgetSnapshotDoesNotRequestReconnectWhenCurrentLimitCoversFailedReport() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let limit = UsageLimit(
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
    )
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [limit]),
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "openai-account-failed",
            configuredAccountID: "openai-code-default",
            accountName: "OpenAI",
            generatedAt: savedAt,
            status: .failure,
            errorMessage: "Every Code auth for this ChatGPT account is no longer authorized for Codex usage."
        )]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: savedAt.addingTimeInterval(30)
    )

    #expect(widget.hasProviderReconnectIssue == false)
    #expect(widget.message == "Refresh Context Panel to update data.")
    #expect(widget.widgetProblemText != "Reconnect account")
}

@Test func widgetSnapshotProblemTextNamesSingleExpiredResetProvider() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let resetAt = savedAt.addingTimeInterval(60)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(
            provider: .google,
            accountID: "google-antigravity",
            accountName: "Antigravity",
            label: "Gemini Five Hour Limit",
            windowLabel: "5-hour",
            unit: .percent,
            used: 0,
            limit: 100,
            resetsAt: resetAt,
            lastUpdatedAt: savedAt,
            confidence: .observed
        )]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: resetAt.addingTimeInterval(10)
    )

    #expect(widget.refreshAttentionSummary?.singleProvider == .google)
    #expect(widget.widgetProblemText == "Google refresh needed")
    #expect(widget.message.contains("Google · Antigravity"))
}

@Test func widgetSnapshotDefaultStalenessPolicyDoesNotSuppressExpiredResetRefresh() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let resetAt = savedAt.addingTimeInterval(60)
    let limit = UsageLimit(
        provider: .google,
        accountID: "google-antigravity",
        accountName: "Antigravity",
        label: "Gemini Five Hour Limit",
        windowLabel: "5-hour",
        unit: .percent,
        used: 0,
        limit: 100,
        resetsAt: resetAt,
        lastUpdatedAt: savedAt,
        confidence: .observed
    )
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [limit])
    )
    var resetState = ResetExpiryRefreshState()
    resetState.recordAttempt(
        previousSnapshot: stored.snapshot,
        refreshedSnapshot: stored.snapshot,
        attemptedAt: resetAt.addingTimeInterval(10)
    )

    let defaultWidget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: resetAt.addingTimeInterval(20)
    )
    let explicitWidget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: resetAt.addingTimeInterval(20),
        stalenessPolicy: SnapshotStoreStalenessPolicy(
            maximumAge: SnapshotFreshness.widgetMaximumAge,
            resetExpiryRefreshState: resetState
        )
    )

    #expect(defaultWidget.refreshAttentionSummary?.singleProvider == .google)
    #expect(explicitWidget.refreshAttentionSummary == nil)
}

@Test func widgetSnapshotKeepsStaleStatusWhenCachedLimitIsLimited() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 100, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.limits.first?.status == .limited)
    #expect(widget.message == "Refresh Context Panel to update data.")
}

@Test func widgetSnapshotKeepsFailureStatusWhenCachedLimitIsLimited() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 100, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .failure),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .failure)
    #expect(widget.status == .failure)
    #expect(widget.limits.first?.status == .limited)
    #expect(widget.message == "Reconnect account to update data.")
}

@Test func widgetSnapshotUsesProviderFailureDetailForStaleProviderFailures() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
        ),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-account",
                configuredAccountID: "openai-code-default",
                accountName: "OpenAI",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Auth expired"
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.message == "OpenAI · OpenAI needs attention: Auth expired")
    #expect(widget.hasProviderReconnectIssue == true)
}

@Test func widgetSnapshotUsesGoogleAntigravityGuidanceForStaleProviderFailures() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(
                provider: .google,
                accountID: "google-working-account",
                configuredAccountID: "google-other-account",
                accountName: "Antigravity",
                label: "Gemini",
                used: 20,
                limit: 100
            )]
        ),
        reports: [
            StoredProviderReport(
                provider: .google,
                accountID: "google-antigravity-failed",
                configuredAccountID: "google-antigravity",
                accountName: "Antigravity",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Google Antigravity access token has expired. Open Antigravity so it can refresh its Google session, then refresh Google in Context Panel."
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.widgetProblemText == "Reconnect account")
    #expect(widget.message.contains("Google · Antigravity needs attention:"))
    #expect(widget.message.contains("Open Antigravity"))
    #expect(widget.message.contains("refresh Google in Context Panel"))
    #expect(widget.message.contains("Reconnect") == false)
}

@Test func widgetSnapshotUsesReconnectMessageWhenFailureHasWorkingConfiguredSiblingAccount() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-code-default",
                accountName: "Working OpenAI",
                label: "Codex",
                used: 20,
                limit: 100
            )]
        ),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-expired-account",
                configuredAccountID: "openai-code-default",
                accountName: "Expired OpenAI",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Auth expired"
            ),
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-code-default",
                accountName: "Working OpenAI",
                generatedAt: savedAt,
                status: .healthy,
                errorMessage: nil
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.status == .stale)
    #expect(widget.message == "Refresh Context Panel to update data.")
    #expect(widget.hasProviderReconnectIssue == false)
}

@Test func widgetSnapshotUsesProviderFailureDetailWhenFailureHasOnlyDifferentConfiguredSibling() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [UsageLimit(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-other-default",
                accountName: "Working OpenAI",
                label: "Codex",
                used: 20,
                limit: 100
            )]
        ),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-expired-account",
                configuredAccountID: "openai-code-default",
                accountName: "Expired OpenAI",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Auth expired"
            ),
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-other-default",
                accountName: "Working OpenAI",
                generatedAt: savedAt,
                status: .healthy,
                errorMessage: nil
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.message == "OpenAI · Expired OpenAI needs attention: Auth expired")
    #expect(widget.hasProviderReconnectIssue == true)
}

@Test func widgetSnapshotBuildsProviderSummaries() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 85, limit: 100),
            UsageLimit(provider: .google, label: "Gemini", used: 10, limit: 100),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .healthy),
        now: savedAt.addingTimeInterval(60)
    )
    let summaries = Dictionary(uniqueKeysWithValues: widget.providerSummaries.map { ($0.provider, $0) })

    #expect(widget.state == .ready)
    #expect(summaries[.openAI]?.status == .close)
    #expect(summaries[.openAI]?.limitCount == 1)
    #expect(summaries[.openAI]?.tightestLimit?.label == "Codex")
    #expect(summaries[.google]?.status == .healthy)
    #expect(summaries[.anthropic]?.limitCount == 0)
}

@Test func widgetSnapshotUsesSetupCopyWhenProviderAccessIsMissing() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: []),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-code-default",
                configuredAccountID: "openai-code-default",
                accountName: "Every Code",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "The file could not be opened."
            ),
            StoredProviderReport(
                provider: .anthropic,
                accountID: "claude-oauth-default",
                configuredAccountID: nil,
                accountName: "Claude",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Claude is not connected."
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .unknown), now: savedAt)

    #expect(widget.state == .ready)
    #expect(widget.needsProviderConnection)
    #expect(widget.message == "Connect an account to show limits.")
    #expect(widget.tightestHeadline == "Not connected")
    #expect(widget.tightestSubheadline == "No provider data yet")
    #expect(widget.fastModeVerdict == "Connect accounts to track limits")
    #expect(widget.fastModeDetail == "Open the app to connect OpenAI, Claude, or Google.")
    #expect(widget.fastModeResetDetail == "limits appear after setup")
    #expect(widget.widgetProblemText == "Setup needed")
    #expect(widget.widgetProviderSummaryText(provider: .openAI) == "not connected")
}

@Test func widgetSnapshotUsesSetupCopyWhenOnlyAuxiliaryLimitsAreAvailable() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai-code-default",
                configuredAccountID: "openai-code-default",
                accountName: "Every Code",
                label: "Spark daily",
                windowLabel: "Daily",
                used: 12,
                limit: 100
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-code-default",
                configuredAccountID: "openai-code-default",
                accountName: "Every Code",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "The file could not be opened."
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .unknown), now: savedAt)

    #expect(widget.mainLimitSummaries.isEmpty)
    #expect(widget.limits.isEmpty == false)
    #expect(widget.needsProviderConnection)
    #expect(widget.shouldShowMainLimitEmptyRow)
    #expect(widget.message == "Connect an account to show limits.")
    #expect(widget.tightestHeadline == "Not connected")
    #expect(widget.widgetProblemText == "Setup needed")
    #expect(widget.widgetDeepLinkURL(links: testWidgetLinks) == testWidgetLinks.reconnect)
    #expect(widget.widgetProviderSummaryText(provider: .openAI) == "not connected")
}

@Test func widgetSnapshotKeepsMainLimitsVisibleWhenAnotherProviderFails() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-code-default",
                accountName: "Working OpenAI",
                label: "Codex weekly",
                windowLabel: "Weekly",
                used: 20,
                limit: 100
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "openai-working-account",
                configuredAccountID: "openai-code-default",
                accountName: "Working OpenAI",
                generatedAt: savedAt,
                status: .healthy,
                errorMessage: nil
            ),
            StoredProviderReport(
                provider: .anthropic,
                accountID: "claude-oauth-default",
                configuredAccountID: "claude-oauth-default",
                accountName: "Claude",
                generatedAt: savedAt,
                status: .failure,
                errorMessage: "Claude is not connected."
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy), now: savedAt)

    #expect(widget.mainLimitSummaries.map(\.provider) == [.openAI])
    #expect(widget.needsProviderConnection == false)
    #expect(widget.shouldShowMainLimitEmptyRow == false)
    #expect(widget.message == "Usage data is current.")
    #expect(widget.tightestHeadline == "80% left")
    #expect(widget.widgetDeepLinkURL(links: testWidgetLinks) == testWidgetLinks.overview)
    #expect(widget.widgetProviderSummaryText(provider: .openAI) == "1w 80% left")
    #expect(widget.widgetProviderSummaryText(provider: .anthropic) == "setup needed")
}

@Test func widgetSnapshotCarriesPromptCacheTelemetry() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(generatedAt: savedAt, limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100),
        ]),
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "every-code",
                accountName: "Every Code",
                observedAt: savedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
        ]
    )

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .healthy),
        now: savedAt.addingTimeInterval(60)
    )

    #expect(widget.promptCacheObservations.count == 1)
    #expect(widget.promptCacheSummary.tokenWeightedHitRate == 0.9)
    #expect(widget.promptCacheWidgetState == .available)
}

@Test func widgetSnapshotCanRequestPromptCacheAuthorizationForConfiguredCodexAccount() throws {
    let root = try widgetSnapshotTemporaryDirectory()
    let codeDirectory = root.appending(path: ".code-chris", directoryHint: .isDirectory)
    let usageDirectory = codeDirectory.appending(path: "usage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)

    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 100), accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-code-default",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Every Code",
            authPath: codeDirectory.appending(path: "auth_accounts.json").path
        ),
    ]))

    let bookmarkStore = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))

    #expect(WidgetSnapshot.promptCacheWidgetState(
        accountStore: accountStore,
        bookmarkStore: bookmarkStore,
        now: Date(timeIntervalSince1970: 110)
    ) == .needsAuthorization)
}

@Test func widgetSnapshotDoesNotRequestPromptCacheAuthorizationAfterUsageBookmarkIsSaved() throws {
    let root = try widgetSnapshotTemporaryDirectory()
    let codeDirectory = root.appending(path: ".code", directoryHint: .isDirectory)
    let usageDirectory = codeDirectory.appending(path: "usage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)

    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 100), accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-code-default",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Every Code",
            authPath: codeDirectory.appending(path: "auth_accounts.json").path
        ),
    ]))

    let bookmarkStore = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))
    try bookmarkStore.createAndStoreBookmark(
        for: usageDirectory,
        path: ContextPanelLocations.normalizedPath(usageDirectory.path)
    )

    #expect(WidgetSnapshot.promptCacheWidgetState(
        accountStore: accountStore,
        bookmarkStore: bookmarkStore,
        now: Date(timeIntervalSince1970: 110)
    ) == nil)
}

@Test func widgetSnapshotTrustsSavedPromptCacheBookmarkRecordWithoutResolvingIt() throws {
    let root = try widgetSnapshotTemporaryDirectory()
    let codeDirectory = root.appending(path: ".code", directoryHint: .isDirectory)
    let usageDirectory = codeDirectory.appending(path: "usage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)

    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: Date(timeIntervalSince1970: 100), accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-code-default",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Every Code",
            authPath: codeDirectory.appending(path: "auth_accounts.json").path
        ),
    ]))

    let bookmarkStoreURL = root.appending(path: "bookmarks.json")
    let bookmarkPath = ContextPanelLocations.normalizedPath(usageDirectory.path)
    let data = try JSONEncoder().encode([bookmarkPath: "appScoped:AQID"])
    try data.write(to: bookmarkStoreURL, options: .atomic)
    let bookmarkStore = SecureFileBookmarkStore(storeURL: bookmarkStoreURL)

    #expect(bookmarkStore.hasCurrentBookmark(for: bookmarkPath))
    #expect(WidgetSnapshot.promptCacheWidgetState(
        accountStore: accountStore,
        bookmarkStore: bookmarkStore,
        now: Date(timeIntervalSince1970: 110)
    ) == nil)
}

@Test func widgetSnapshotUsesTelemetryAfterPromptCacheAuthorizationOverrideClears() throws {
    let now = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100),
        ]),
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "every-code",
                accountName: "Every Code",
                observedAt: now,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 940)
            ),
        ]
    )
    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .healthy),
        now: now.addingTimeInterval(60),
        promptCacheWidgetState: nil
    )

    #expect(widget.promptCacheWidgetState == .available)
    #expect(widget.promptCacheSummary.latestHitRate == 0.94)
}

@Test func timelineProviderShowsPromptCacheTelemetryAfterUsageBookmarkExists() throws {
    let root = try widgetSnapshotTemporaryDirectory()
    let now = Date(timeIntervalSince1970: 100)
    let codeDirectory = root.appending(path: ".code", directoryHint: .isDirectory)
    let usageDirectory = codeDirectory.appending(path: "usage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)

    let primaryStore = JSONSnapshotStore(rootDirectory: root.appending(path: "snapshots", directoryHint: .isDirectory))
    try primaryStore.save(StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100),
        ]),
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "every-code",
                accountName: "Every Code",
                observedAt: now,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 940)
            ),
        ]
    ))

    let accountStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accountStore.save(AccountConfigurationDocument(updatedAt: now, accounts: [
        LocalProviderAccountConfiguration(
            id: "openai-code-default",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "Every Code",
            authPath: codeDirectory.appending(path: "auth_accounts.json").path
        ),
    ]))

    let bookmarkStore = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))
    try bookmarkStore.createAndStoreBookmark(
        for: usageDirectory,
        path: ContextPanelLocations.normalizedPath(usageDirectory.path)
    )

    let provider = ContextPanelTimelineProvider(
        store: primaryStore,
        containerFallbackStore: JSONSnapshotStore(rootDirectory: root.appending(path: "fallback", directoryHint: .isDirectory)),
        preferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "widget-prefs.json")),
        containerFallbackPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "fallback-widget-prefs.json")),
        forecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json")),
        containerFallbackForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "fallback-forecast.json")),
        accountStore: accountStore,
        bookmarkStore: bookmarkStore
    )

    let entry = provider.entry(date: now.addingTimeInterval(60))

    #expect(entry.snapshot.promptCacheWidgetState == .available)
    #expect(entry.snapshot.promptCacheSummary.latestHitRate == 0.94)
}

@Test func providerSummariesUseTheTightestWindowInsteadOfAverageCapacity() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(provider: .openAI, label: "Weekly", used: 95, limit: 100),
            UsageLimit(provider: .openAI, label: "5-hour", used: 5, limit: 100),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy))
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(abs((openAI?.capacityRatio ?? 0) - 0.05) < 0.0001)
    #expect(openAI?.tightestLimit?.label == "Weekly")
}

@Test func providerSummariesUsePooledMainWindowStatus() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "limited",
                accountName: "Limited OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 100,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "usable",
                accountName: "Usable OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 20,
                limit: 100
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(widget.status == .healthy)
    #expect(openAI?.status == .healthy)
    #expect(openAI?.tightestLimit?.status == .limited)
}

@Test func providerSummariesStillIncludeNonMainLimitPressure() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "usable",
                accountName: "Usable OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 20,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "usable",
                accountName: "Usable OpenAI",
                label: "Image generation",
                unit: .requests,
                used: 10,
                limit: 10,
                statusOverride: .limited
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(widget.status == .limited)
    #expect(openAI?.status == .limited)
    #expect(widget.message == "Usage data is current.")
}

@Test func widgetMessageOmitsCloseLimitPressure() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "close",
                accountName: "Close OpenAI",
                label: "Codex Weekly",
                windowLabel: "Weekly",
                modelLabel: "Codex",
                unit: .percent,
                used: 82,
                limit: 100,
                statusOverride: .close
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(widget.status == .close)
    #expect(openAI?.status == .close)
    #expect(widget.message == "Usage data is current.")
}

@Test func anthropicProviderSummaryUsesMainSummaryWhenNonMainLimitIsUnknown() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude weekly",
                windowLabel: "Weekly",
                modelLabel: "Claude",
                unit: .percent,
                used: 12,
                limit: 100,
                resetsAt: savedAt.addingTimeInterval(6 * 3_600),
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "claude-unknown",
                accountName: "Claude Unknown",
                label: "Claude auxiliary signal",
                modelLabel: "Claude",
                unit: .unknown,
                used: nil,
                limit: nil,
                resetsAt: nil,
                lastUpdatedAt: savedAt,
                confidence: .observed,
                statusOverride: .unknown
            ),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: stored.snapshot.aggregateStatus), now: savedAt)
    let anthropic = widget.providerSummaries.first { $0.provider == .anthropic }

    #expect(widget.status == .unknown)
    #expect(anthropic?.status == .healthy)
    #expect(widget.usageSnapshot.mainLimitSummaries.first { $0.provider == .anthropic }?.status == .healthy)
    #expect(widget.limits.first { $0.label == "Claude auxiliary signal" }?.status == .unknown)
}

@Test func anthropicEstimatedSummaryKeepsResetTextWithoutUsageRatio() {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(3_600)
    let summary = MainLimitSummary(
        provider: .anthropic,
        window: .fiveHour,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "claude",
                accountName: "Claude",
                label: "Claude 5-hour estimate",
                windowLabel: "5-hour estimated",
                modelLabel: "Claude",
                unit: .unknown,
                used: nil,
                limit: nil,
                resetsAt: reset,
                lastUpdatedAt: now,
                confidence: .estimated,
                statusOverride: .healthy
            ),
        ],
        generatedAt: now
    )

    #expect(summary.usageRatio == nil)
    #expect(summary.widgetResetText != nil)
    #expect(summary.widgetResetConfidenceText?.contains("estimated") == true)
}

@Test func resetCountdownRoundsFutureHoursUp() {
    let now = Date(timeIntervalSince1970: 1_000)
    let summary = MainLimitSummary(
        provider: .openAI,
        window: .fiveHour,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 0,
                limit: 100,
                resetsAt: now.addingTimeInterval((5 * 3_600) - 1),
                lastUpdatedAt: now,
                confidence: .official
            ),
        ],
        generatedAt: now
    )

    #expect(summary.resetCountdownText(now: now) == "5h")
}

@Test func resetCountdownKeepsNearlyDayLongWindowsCompact() {
    let now = Date(timeIntervalSince1970: 1_000)
    let summary = MainLimitSummary(
        provider: .openAI,
        window: .daily,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI daily",
                windowLabel: "Daily",
                unit: .percent,
                used: 0,
                limit: 100,
                resetsAt: now.addingTimeInterval((23 * 3_600) + 60),
                lastUpdatedAt: now,
                confidence: .official
            ),
        ],
        generatedAt: now
    )

    #expect(summary.resetCountdownText(now: now) == "24h")
}

@Test func widgetResetTextRoundsFiveHourWindowUp() {
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let reset = now.addingTimeInterval((5 * 3_600) - 1)
    let summary = MainLimitSummary(
        provider: .openAI,
        window: .fiveHour,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 0,
                limit: 100,
                resetsAt: reset,
                lastUpdatedAt: now,
                confidence: .official
            ),
        ],
        generatedAt: now
    )

    #expect(summary.widgetResetText == "5h")
}

@Test func anthropicWidgetSnapshotSurfacesConnectedUnknownOAuthStatusWithoutMainLimit() {
    let now = Date(timeIntervalSince1970: 1000)
    let limits = [
        UsageLimit(
            provider: .anthropic,
            accountID: "claude-acct",
            accountName: "Claude",
            label: "Claude OAuth usage",
            modelLabel: "Claude",
            unit: .unknown,
            used: nil,
            limit: nil,
            resetsAt: nil,
            lastUpdatedAt: now,
            confidence: .observed,
            statusOverride: .unknown
        )
    ]
    let stored = StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: limits))
    let snapshot = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy), now: now)
    #expect(snapshot.status == .unknown)
    #expect(snapshot.limits.contains { $0.provider == .anthropic })
    #expect(snapshot.usageSnapshot.mainLimitSummaries.filter { $0.provider == .anthropic }.isEmpty)

    let healthyLimit = UsageLimit(
        provider: .anthropic,
        accountID: "claude-acct",
        accountName: "Claude",
        label: "Claude weekly",
        windowLabel: "Weekly",
        modelLabel: "Claude",
        unit: .percent,
        used: 25,
        limit: 100,
        resetsAt: nil,
        lastUpdatedAt: now,
        confidence: .observed
    )
    #expect(healthyLimit.status == .healthy)

    let summary = MainLimitSummary(provider: .anthropic, window: .weekly, limits: [healthyLimit])
    #expect(summary.resetsAt == nil)
    #expect(summary.status == .healthy)
}

private func widgetSnapshotTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-widget-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
