import Darwin
import Foundation
import Testing

@testable import ContextPanelCore

@Test func codexConnectorRefreshesMultipleAccountsIntoNormalizedLimits() async throws {
    let authA = #"{"tokens":{"access_token":"token-secret-a","account_id":"account-a"}}"#.data(using: .utf8)!
    let authB = #"{"tokens":{"access_token":"token-secret-b","account_id":"account-b"}}"#.data(using: .utf8)!
    let usage = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 50, "limit_window_seconds": 18000, "reset_at": 1788393600 },
        "secondary_window": { "used_percent": 25, "limit_window_seconds": 604800, "reset_at": 1788998400 }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let connector = CodexRateLimitConnector(
        accounts: [
            CodexAccountConfiguration(authPath: "/tmp/openai-a.json", accountName: "OpenAI A"),
            CodexAccountConfiguration(authPath: "/tmp/openai-b.json", accountName: "OpenAI B"),
        ],
        httpClient: http,
        fileLoader: { path in
            path.contains("openai-a") ? authA : authB
        }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 2)
    #expect(result.snapshot.limits.count == 4)
    #expect(Set(result.snapshot.limits.map(\.accountName)) == ["OpenAI A", "OpenAI B"])
    #expect(Set(result.reports.map(\.accountID)).count == 2)
    #expect(result.snapshot.limits.allSatisfy { $0.provider == .openAI && $0.unit == .percent })
    #expect(result.snapshot.limits.contains { $0.used == 50 && $0.windowLabel == "5-hour" })
    #expect(http.requests.count == 2)
    #expect(http.requests.map { $0.headers["ChatGPT-Account-Id"] } == ["account-a", "account-b"])
}

@Test func codexResetCreditsUseOnlySiblingGETDetailsEndpoint() async throws {
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 4, applicable: 2)),
        ConnectorHTTPResponse(statusCode: 200, data: codexResetDetails(available: 2, expiries: [
            "2027-02-01T00:00:00Z", "2027-02-02T00:00:00Z",
        ])),
    ])

    let result = await codexResetConnector(http: http).refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
    let summary = try #require(result.reports.first?.resetCredits)

    #expect((summary.availableCount, summary.coverage) == (2, .complete))
    #expect(http.requests.map(\.method) == ["GET", "GET"])
    #expect(http.requests.allSatisfy { $0.body == nil })
    #expect(http.requests.map(\.url.absoluteString) == [
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    ])
    #expect(http.requests.contains { $0.url.path.contains("/usage/") } == false)
}

@Test func codexResetCreditsIgnoreApplicableZeroForAvailableInventory() async throws {
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 4, applicable: 0)),
        ConnectorHTTPResponse(statusCode: 200, data: codexResetDetails(available: 4, expiries: [
            "2027-02-01T00:00:00Z",
            "2027-02-02T00:00:00Z",
            "2027-02-03T00:00:00Z",
            "2027-02-04T00:00:00Z",
        ])),
    ])

    let result = await codexResetConnector(http: http).refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
    let summary = try #require(result.reports.first?.resetCredits)

    #expect((summary.availableCount, summary.coverage) == (4, .complete))
    #expect(http.requests.map(\.url.absoluteString) == [
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    ])
}

@Test func codexResetCreditsSkipDetailsForAuthoritativeAvailableZero() async throws {
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(
        statusCode: 200,
        data: codexResetUsage(available: 0, applicable: 4)
    )])

    let result = await codexResetConnector(http: http).refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
    let summary = try #require(result.reports.first?.resetCredits)

    #expect(summary == ProviderResetCreditSummary(
        availableCount: 0,
        observedAt: Date(timeIntervalSince1970: 1_800_000_000),
        coverage: .countOnly
    ))
    #expect(http.requests.map(\.url.absoluteString) == ["https://chatgpt.com/backend-api/wham/usage"])
}

@Test func codexResetCreditDetailsFailureKeepsSuccessfulUsageCountOnly() async throws {
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 1)),
        ConnectorHTTPResponse(statusCode: 503, data: Data()),
    ])

    let result = await codexResetConnector(http: http).refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
    let report = try #require(result.reports.first)
    let summary = try #require(report.resetCredits)

    #expect((report.status, report.limits.count, report.errorMessage) == (.healthy, 1, nil))
    #expect((summary.availableCount, summary.coverage, summary.earliestKnownExpiry) == (1, .countOnly, nil))
}

@Test func codexResetCreditDetailsAuthorizationFailureKeepsSuccessfulUsageCountOnly() async throws {
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 1)),
        ConnectorHTTPResponse(statusCode: 401, data: Data()),
    ])

    let report = try #require(await codexResetConnector(http: http)
        .refresh(now: Date(timeIntervalSince1970: 1_800_000_000)).reports.first)

    #expect(report.status == .healthy)
    #expect((report.resetCredits?.availableCount, report.resetCredits?.coverage) == (1, .countOnly))
}

@Test func codexMalformedResetCreditDetailsKeepSuccessfulUsageCountOnly() async throws {
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 1)),
        ConnectorHTTPResponse(statusCode: 200, data: Data(#"{"data":{"credits":[]}}"#.utf8)),
    ])

    let report = try #require(await codexResetConnector(http: http)
        .refresh(now: Date(timeIntervalSince1970: 1_800_000_000)).reports.first)

    #expect(report.status == .healthy)
    #expect((report.resetCredits?.availableCount, report.resetCredits?.coverage) == (1, .countOnly))
}

@Test func codexResetCreditDetailsMissingRequiredCountKeepSuccessfulUsageCountOnly() async throws {
    let details = Data(#"{"credits":[{"id":"discard-me","reset_type":"codex_rate_limits","status":"available","granted_at":"2027-01-01T00:00:00Z","expires_at":"2027-02-01T00:00:00Z"}]}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 1)),
        ConnectorHTTPResponse(statusCode: 200, data: details),
    ])

    let report = try #require(await codexResetConnector(http: http)
        .refresh(now: Date(timeIntervalSince1970: 1_800_000_000)).reports.first)

    #expect(report.status == .healthy)
    #expect((report.resetCredits?.availableCount, report.resetCredits?.coverage) == (1, .countOnly))
}

@Test func codexResetCreditsUseCodexAPISiblingGETDetailsEndpoint() async throws {
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: codexResetUsage(available: 1)),
        ConnectorHTTPResponse(statusCode: 200, data: codexResetDetails(
            available: 1,
            expiries: ["2027-02-01T00:00:00Z"]
        )),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(
            authPath: "/tmp/openai.json",
            accountName: "OpenAI",
            endpoint: URL(string: "https://example.test/api/codex/usage")!
        )],
        httpClient: http,
        fileLoader: { _ in Data(#"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.utf8) }
    )

    let report = try #require(await connector.refresh(
        now: Date(timeIntervalSince1970: 1_800_000_000)
    ).reports.first)

    #expect((report.resetCredits?.availableCount, report.resetCredits?.coverage) == (1, .complete))
    #expect(http.requests.map(\.url.absoluteString) == [
        "https://example.test/api/codex/usage",
        "https://example.test/api/codex/rate-limit-reset-credits",
    ])
}

@Test func codexUsageDecodeFailureKeepsFreshResetCountStaleSafe() async throws {
    let usage = Data(#"{"rate_limit":"malformed","rate_limit_reset_credits":{"available_count":1}}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 200, data: codexResetDetails(expiries: ["2027-02-01T00:00:00Z"])),
    ])
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let report = try #require(await codexResetConnector(http: http).refresh(now: now).reports.first)
    let summary = try #require(report.resetCredits)

    #expect(report.status == .failure)
    #expect((summary.availableCount, summary.observedAt) == (1, now))
    #expect((summary.coverage, summary.earliestKnownExpiry) == (.countOnly, nil))
}

@Test func providerRuntimeDeduplicatesSameProviderAccountID() async throws {
    let auth = #"{"tokens":{"access_token":"token-secret","account_id":"same-account"}}"#.data(using: .utf8)!
    let usage = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 50, "limit_window_seconds": 18000, "reset_at": 1788393600 },
        "secondary_window": { "used_percent": 99, "limit_window_seconds": 604800, "reset_at": 1788998400 }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 200, data: usage),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [
            CodexAccountConfiguration(authPath: "/tmp/openai-a.json", accountName: "OpenAI A"),
            CodexAccountConfiguration(authPath: "/tmp/openai-b.json", accountName: "OpenAI B"),
        ],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await ProviderConnectorRuntime(connectors: [connector]).refreshAll(now: Date(timeIntervalSince1970: 0))

    #expect(http.requests.count == 2)
    #expect(result.reports.count == 1)
    #expect(result.snapshot.limits.count == 2)
    #expect(result.snapshot.limits.map(\.accountName) == ["OpenAI A", "OpenAI A"])
}

@Test func providerRuntimeSelectsFreshestResetCreditsWithoutCollapsingSiblings() async throws {
    let older = resetCreditSummary(count: 3, observedAt: 100, coverage: .complete, expiry: 500)
    let newer = resetCreditSummary(count: 1, observedAt: 200, coverage: .partial, expiry: 400)
    let primary = resetCreditReport(accountID: "same-account", summary: older, hasLimit: true)
    let aliasFailure = resetCreditReport(accountID: "same-account", summary: newer, status: .failure)
    let sibling = resetCreditReport(accountID: "sibling-account", summary: resetCreditSummary(count: 7, observedAt: 200))

    let forward = await ProviderConnectorRuntime(connectors: [
        StubConnector(provider: .openAI, report: primary),
        StubConnector(provider: .openAI, report: aliasFailure),
        StubConnector(provider: .openAI, report: sibling),
    ]).refreshAll(now: Date(timeIntervalSince1970: 200))
    let reverse = await ProviderConnectorRuntime(connectors: [
        StubConnector(provider: .openAI, report: sibling),
        StubConnector(provider: .openAI, report: aliasFailure),
        StubConnector(provider: .openAI, report: primary),
    ]).refreshAll(now: Date(timeIntervalSince1970: 200))
    let forwardPrimary = try #require(forward.reports.first { $0.accountID == "same-account" })
    let reversePrimary = try #require(reverse.reports.first { $0.accountID == "same-account" })

    #expect((forward.reports.count, reverse.reports.count) == (2, 2))
    #expect((forwardPrimary.status, reversePrimary.status) == (.healthy, .healthy))
    #expect((forwardPrimary.limits.count, reversePrimary.limits.count) == (1, 1))
    #expect((forwardPrimary.resetCredits, reversePrimary.resetCredits) == (newer, newer))
    #expect(forward.reports.first { $0.accountID == "sibling-account" }?.resetCredits?.availableCount == 7)
    #expect(reverse.reports.first { $0.accountID == "sibling-account" }?.resetCredits?.availableCount == 7)
}

@Test func providerRuntimePrefersLowerEqualTimeResetCountRegardlessOfConnectorOrder() async throws {
    let positive = resetCreditReport(
        accountID: "same-account",
        summary: resetCreditSummary(count: 2, observedAt: 200, coverage: .complete, expiry: 500),
        hasLimit: true
    )
    let explicitZero = resetCreditReport(
        accountID: "same-account",
        summary: resetCreditSummary(count: 0, observedAt: 200),
        hasLimit: true
    )

    let forward = await ProviderConnectorRuntime(connectors: [
        StubConnector(provider: .openAI, report: positive),
        StubConnector(provider: .openAI, report: explicitZero),
    ]).refreshAll(now: Date(timeIntervalSince1970: 200))
    let reverse = await ProviderConnectorRuntime(connectors: [
        StubConnector(provider: .openAI, report: explicitZero),
        StubConnector(provider: .openAI, report: positive),
    ]).refreshAll(now: Date(timeIntervalSince1970: 200))
    let forwardSummary = try #require(forward.reports.first?.resetCredits)
    let reverseSummary = try #require(reverse.reports.first?.resetCredits)

    #expect(forwardSummary == reverseSummary)
    #expect((forwardSummary.availableCount, forwardSummary.coverage) == (0, .countOnly))
}

@Test func providerRuntimePreservesConfiguredAccountIDWhenDeduplicatingFallbackReports() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let failingFallback = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "Configured OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed"
    ))
    let resolvedReport = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "Resolved OpenAI",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "Resolved OpenAI",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))

    let result = await ProviderConnectorRuntime(connectors: [failingFallback, resolvedReport]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.reports[0].accountName == "Resolved OpenAI")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai"])
}

@Test func providerRuntimeBackfillsConfiguredAccountIDWhenAliasReportArrivesSecond() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let resolvedReport = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "Resolved OpenAI",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "Resolved OpenAI",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))
    let aliasReport = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "Configured OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed"
    ))

    let result = await ProviderConnectorRuntime(connectors: [resolvedReport, aliasReport]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai"])
}

@Test func providerRuntimeBackfillsConfiguredAccountIDWhenPlaceholderArrivesFirst() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let placeholder = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "Configured OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed"
    ))
    let resolvedReport = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "Resolved OpenAI",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "Resolved OpenAI",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))

    let result = await ProviderConnectorRuntime(connectors: [placeholder, resolvedReport]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai"])
}

@Test func providerRuntimeKeepsRicherAccountNameWhenSuccessfulPlaceholderReplacesEmptyReport() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let richEmptyReport = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "info@example.com · pro",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed before live usage arrived"
    ))
    let placeholderSuccess = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "OpenAI",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "OpenAI",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))

    let result = await ProviderConnectorRuntime(connectors: [richEmptyReport, placeholderSuccess]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.reports[0].accountName == "info@example.com · pro")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai"])
    #expect(result.snapshot.limits.map(\.accountName) == ["info@example.com · pro"])
}

@Test func providerRuntimeBackfillsConfiguredAccountIDWhenDuplicateReportsAreEmpty() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let unconfiguredFailure = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "Resolved OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed before alias was known"
    ))
    let configuredFailure = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "Configured OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed after alias was known"
    ))

    let result = await ProviderConnectorRuntime(connectors: [unconfiguredFailure, configuredFailure]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.reports[0].accountName == "Configured OpenAI")
    #expect(result.reports[0].status == .failure)
}

@Test func providerRuntimeKeepsRicherAccountNameWhenDuplicateReportHasPlaceholderName() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let unconfiguredFailure = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "info@example.com · pro",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed before alias was known"
    ))
    let configuredFailure = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed after alias was known"
    ))

    let result = await ProviderConnectorRuntime(connectors: [unconfiguredFailure, configuredFailure]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.reports[0].accountName == "info@example.com · pro")
}

@Test func providerRuntimeKeepsRicherAccountNameWhenSuccessfulReportArrivesFirst() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let resolvedReport = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "info@example.com · pro",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "info@example.com · pro",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))
    let configuredFailure = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "OpenAI",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed after alias was known"
    ))

    let result = await ProviderConnectorRuntime(connectors: [resolvedReport, configuredFailure]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.reports[0].accountName == "info@example.com · pro")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai"])
}

@Test func providerRuntimePropagatesRicherMergedAccountNameToLimits() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let placeholderSuccess = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        accountName: "OpenAI",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "OpenAI",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))
    let richConfiguredFailure = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai",
        accountName: "info@example.com · pro",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed after rich alias was known"
    ))

    let result = await ProviderConnectorRuntime(connectors: [placeholderSuccess, richConfiguredFailure]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai")
    #expect(result.reports[0].accountName == "info@example.com · pro")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai"])
    #expect(result.snapshot.limits.map(\.accountName) == ["info@example.com · pro"])
}

@Test func providerRuntimeUsesOneConfiguredAccountIDWhenDuplicateReportsDisagree() async throws {
    let generatedAt = Date(timeIntervalSince1970: 10)
    let resolvedAccountID = ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:resolved")
    let firstAlias = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai-a",
        accountName: "OpenAI A",
        generatedAt: generatedAt,
        limits: [],
        status: .failure,
        errorMessage: "failed before live usage arrived"
    ))
    let secondAliasSuccess = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: resolvedAccountID,
        configuredAccountID: "configured-openai-b",
        accountName: "OpenAI B",
        generatedAt: generatedAt,
        limits: [UsageLimit(
            provider: .openAI,
            accountID: resolvedAccountID,
            accountName: "OpenAI B",
            label: "Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 25,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(3_600)
        )]
    ))

    let result = await ProviderConnectorRuntime(connectors: [firstAlias, secondAliasSuccess]).refreshAll(now: generatedAt)

    #expect(result.reports.count == 1)
    #expect(result.reports[0].configuredAccountID == "configured-openai-a")
    #expect(result.snapshot.limits.map(\.configuredAccountID) == ["configured-openai-a"])
}

@Test func codexConnectorReadsAuthAccountsFile() async throws {
    let firstIDToken = jwtPayload(email: "first@example.com", name: "First Person", accountID: "account-a", planType: "pro")
    let secondIDToken = jwtPayload(email: "second@example.com", name: "Second Person", accountID: "account-b", planType: "pro")
    let authAccountsJSON = #"""
    {
      "version": 1,
      "active_account_id": "local-account-a",
      "accounts": [
        {
          "id": "local-account-a",
          "mode": "chatgpt",
          "label": "first@example.com",
          "tokens": {
            "access_token": "token-secret-a",
            "account_id": "account-a",
            "id_token": "__FIRST_ID_TOKEN__",
            "refresh_token": "refresh-secret-a"
          }
        },
        {
          "id": "local-account-b",
          "mode": "chatgpt",
          "label": "second@example.com",
          "tokens": {
            "access_token": "token-secret-b",
            "account_id": "account-b",
            "id_token": "__SECOND_ID_TOKEN__",
            "refresh_token": "refresh-secret-b"
          }
        }
      ]
    }
    """#
    let authAccounts = authAccountsJSON
        .replacingOccurrences(of: "__FIRST_ID_TOKEN__", with: firstIDToken)
        .replacingOccurrences(of: "__SECOND_ID_TOKEN__", with: secondIDToken)
        .data(using: .utf8)!
    let usageTemplate = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 1, "limit_window_seconds": 18000, "reset_at": 1788393600 },
        "secondary_window": { "used_percent": 2, "limit_window_seconds": 604800, "reset_at": 1788998400 }
      },
      "rate_limit_reset_credits": {
        "available_count": __AVAILABLE_COUNT__,
        "applicable_available_count": 0
      }
    }
    """#
    let firstUsage = Data(usageTemplate.replacingOccurrences(of: "__AVAILABLE_COUNT__", with: "2").utf8)
    let secondUsage = Data(usageTemplate.replacingOccurrences(of: "__AVAILABLE_COUNT__", with: "3").utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: firstUsage),
        ConnectorHTTPResponse(statusCode: 200, data: codexResetDetails(
            available: 2,
            expiries: ["2027-02-01T00:00:00Z", "2027-02-02T00:00:00Z"]
        )),
        ConnectorHTTPResponse(statusCode: 200, data: secondUsage),
        ConnectorHTTPResponse(statusCode: 503, data: Data()),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/auth_accounts.json", accountName: "OpenAI Code")],
        httpClient: http,
        fileLoader: { _ in authAccounts }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 2)
    #expect(result.snapshot.limits.count == 4)
    #expect(result.reports.map(\.accountName) == ["first@example.com · pro", "second@example.com · pro"])
    #expect(result.reports.allSatisfy { $0.configuredAccountID == nil })
    #expect(result.snapshot.limits.map(\.accountName) == [
        "first@example.com · pro",
        "first@example.com · pro",
        "second@example.com · pro",
        "second@example.com · pro",
    ])
    #expect(result.snapshot.limits.allSatisfy { $0.configuredAccountID == nil })
    #expect(result.reports.map { $0.resetCredits?.availableCount } == [2, 3])
    #expect(result.reports.map { $0.resetCredits?.coverage } == [.complete, .countOnly])
    #expect(http.requests.map { $0.headers["ChatGPT-Account-Id"] } == [
        "account-a", "account-a", "account-b", "account-b",
    ])
    #expect(Set(result.reports.map(\.accountID)).count == 2)
}

@Test func codexConnectorCarriesConfiguredAccountIDForResolvedAuthAccounts() async throws {
    let firstIDToken = jwtPayload(email: "first@example.com", name: "First Person", accountID: "account-a", planType: "pro")
    let secondIDToken = jwtPayload(email: "second@example.com", name: "Second Person", accountID: "account-b", planType: "pro")
    let authAccountsJSON = #"""
    {
      "version": 1,
      "accounts": [
        {
          "id": "local-account-a",
          "mode": "chatgpt",
          "tokens": {
            "access_token": "token-secret-a",
            "account_id": "account-a",
            "id_token": "__FIRST_ID_TOKEN__"
          }
        },
        {
          "id": "local-account-b",
          "mode": "chatgpt",
          "tokens": {
            "access_token": "token-secret-b",
            "account_id": "account-b",
            "id_token": "__SECOND_ID_TOKEN__"
          }
        }
      ]
    }
    """#
    let authAccounts = authAccountsJSON
        .replacingOccurrences(of: "__FIRST_ID_TOKEN__", with: firstIDToken)
        .replacingOccurrences(of: "__SECOND_ID_TOKEN__", with: secondIDToken)
        .data(using: .utf8)!
    let usage = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 1, "limit_window_seconds": 18000, "reset_at": 1788393600 },
        "secondary_window": { "used_percent": 2, "limit_window_seconds": 604800, "reset_at": 1788998400 }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 200, data: usage),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(
            configuredAccountID: "openai-code-default",
            authPath: "/tmp/auth_accounts.json",
            accountName: "Code"
        )],
        httpClient: http,
        fileLoader: { _ in authAccounts }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 2)
    #expect(result.reports.allSatisfy { $0.configuredAccountID == "openai-code-default" })
    #expect(result.snapshot.limits.allSatisfy { $0.configuredAccountID == "openai-code-default" })
    #expect(Set(result.reports.map(\.accountID)).count == 2)
}

@Test func codexConnectorPrefersIDTokenAccountIDWhenAuthAccountIDIsStale() async throws {
    let idToken = jwtPayload(
        email: "info@example.com",
        name: "Info Account",
        accountID: "fresh-account",
        planType: "pro"
    )
    let auth = #"""
    {
      "tokens": {
        "access_token": "token-secret",
        "account_id": "stale-account",
        "id_token": "__ID_TOKEN__"
      }
    }
    """#
        .replacingOccurrences(of: "__ID_TOKEN__", with: idToken)
        .data(using: .utf8)!
    let usage = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 5, "limit_window_seconds": 18000, "reset_at": 1788393600 },
        "secondary_window": { "used_percent": 10, "limit_window_seconds": 604800, "reset_at": 1788998400 }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(
            configuredAccountID: "openai-code-default",
            authPath: "/tmp/auth.json",
            accountName: "Code"
        )],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 1)
    #expect(http.requests.map { $0.headers["ChatGPT-Account-Id"] } == ["fresh-account"])
    #expect(result.reports[0].accountID == ConnectorRedactor.localAccountID(provider: .openAI, stableID: "chatgpt:fresh-account"))
    #expect(result.snapshot.limits.allSatisfy { $0.configuredAccountID == "openai-code-default" })
}

@Test func codexConnectorFiltersAdditionalModelLimitsAgainstChatGPTModels() async throws {
    let auth = #"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.data(using: .utf8)!
    let usage = codexUsageWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
        ("GPT-5.5 Thinking", "gpt-5-5-thinking", 2),
    ])
    let models = #"""
    {
      "models": [
        { "slug": "gpt-5-5-thinking", "title": "GPT-5.5 Thinking" }
      ]
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(http.requests.map { $0.url.path } == ["/backend-api/wham/usage", "/backend-api/models"])
    #expect(result.snapshot.limits.map(\.label) == ["Codex 5-hour", "GPT-5.5 Thinking 5-hour"])
}

@Test func codexConnectorKeepsCodexVariantWhenChatGPTModelsExposeStandaloneFamily() async throws {
    let auth = #"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.data(using: .utf8)!
    let usage = codexUsageWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
        ("GPT-5.2-Codex-Legacy", "codex_legacy", 2),
    ])
    let models = #"""
    {
      "models": [
        { "slug": "gpt-5-3", "title": "GPT-5.3" }
      ]
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(http.requests.map { $0.url.path } == ["/backend-api/wham/usage", "/backend-api/models"])
    #expect(result.snapshot.limits.map(\.label) == ["Codex 5-hour", "GPT-5.3-Codex-Spark 5-hour"])
}

@Test func codexConnectorKeepsAdditionalModelLimitsWhenAvailabilityFetchFails() async throws {
    let auth = #"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.data(using: .utf8)!
    let usage = codexUsageWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
    ])
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 500, data: Data()),
    ])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(http.requests.map { $0.url.path } == ["/backend-api/wham/usage", "/backend-api/models"])
    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.map(\.label) == ["Codex 5-hour", "GPT-5.3-Codex-Spark 5-hour"])
}

@Test func codexConnectorSkipsModelAvailabilityFetchWithoutAdditionalLimits() async throws {
    let auth = #"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.data(using: .utf8)!
    let usage = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 5, "limit_window_seconds": 18000, "reset_at": 1788393600 }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(http.requests.map { $0.url.path } == ["/backend-api/wham/usage"])
    #expect(result.snapshot.limits.map(\.label) == ["Codex 5-hour"])
}

@Test func codexTokenIdentityExtractsEmailNamePlanAndAccountID() {
    let token = jwtPayload(
        email: "person@example.com",
        name: "Person Name",
        accountID: "chatgpt-account",
        planType: "pro"
    )

    let identity = CodexTokenIdentity.extract(fromIDToken: token)

    #expect(identity.email == "person@example.com")
    #expect(identity.name == "Person Name")
    #expect(identity.chatGPTAccountID == "chatgpt-account")
    #expect(identity.planType == "pro")
}

@Test func codexConnectorRedactsHTTPFailures() async {
    let auth = #"{"tokens":{"access_token":"token-secret"}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 500, data: Data("secret body".utf8))])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date())

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("HTTP 500") == true)
    #expect(result.reports[0].errorMessage?.contains("raw body redacted") == true)
    #expect(result.reports[0].errorMessage?.contains("secret body") == false)
    #expect(result.snapshot.limits.isEmpty)
}

@Test func connectorSafeErrorDescriptionRedactsSecretsURLsAndLocalPaths() {
    let message = "failed for user@example.com with bearer sk-secret-token at /Users/example/.code/auth.json via https://hooks.example.com/private"

    let redacted = ConnectorRedactor.safeErrorDescription(message)

    #expect(!redacted.contains("user@example.com"))
    #expect(!redacted.contains("sk-secret-token"))
    #expect(!redacted.contains("/Users/example/.code/auth.json"))
    #expect(!redacted.contains("hooks.example.com"))
    #expect(redacted.contains("[local path]"))
    #expect(redacted.contains("[url redacted]"))
}

@Test func connectorSafeErrorDescriptionRedactsCompleteAuthorizationCredentials() {
    let cases: [(message: String, marker: String, secrets: [String])] = [
        ("Bearer abc~def+/==", "bearer [redacted]", ["abc~def+/=="]),
        ("Basic c3RhbmRhbG9uZTpwYXNzd29yZA==", "basic [redacted]", ["c3RhbmRhbG9uZTpwYXNzd29yZA=="]),
        ("Authorization: Basic dXNlcjpwYXNz", "authorization=[redacted]", ["dXNlcjpwYXNz"]),
        (
            "Cookie: session=secret-value; secondary=secret-two",
            "Cookie=[redacted]",
            ["secret-value", "secret-two"]
        )
    ]

    for testCase in cases {
        let redacted = ConnectorRedactor.safeErrorDescription(testCase.message)

        #expect(redacted.contains(testCase.marker))
        for secret in testCase.secrets {
            #expect(!redacted.contains(secret))
        }
    }
}

@Test func connectorSafeErrorDescriptionRedactsControlObfuscatedCredentials() {
    let cases: [(message: String, secrets: [String])] = [
        ("Be\u{200D}arer abc\u{0007}def", ["abc", "def"]),
        ("Ba\u{200B}sic dXNl\u{0085}cjpwYXNz", ["dXNl", "cjpwYXNz"]),
        ("Author\u{009D}ization: Basic dXNl\u{0009}cjpwYXNz", ["dXNl", "cjpwYXNz"]),
        ("Coo\u{009D}kie: session=secret-value", ["secret-value"])
    ]

    for testCase in cases {
        let redacted = ConnectorRedactor.safeErrorDescription(testCase.message)

        for secret in testCase.secrets {
            #expect(!redacted.contains(secret))
        }
        #expect(!redacted.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format
        })
    }
}

@Test func codexConnectorReportsAccountReauthWhenUsageIsUnauthorizedWithoutRefreshToken() async {
    let auth = #"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 401, data: Data("secret body".utf8))])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date())

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("cannot be refreshed") == true)
    #expect(result.reports[0].errorMessage?.contains("Sign in again") == true)
    #expect(result.reports[0].errorMessage?.contains("secret body") == false)
    #expect(http.requests.count == 1)
}

@Test func codexConnectorReportsAccountReauthWhenUsageIsUnauthorizedWithRefreshToken() async {
    let auth = #"{"tokens":{"access_token":"token-secret","refresh_token":"refresh-secret","account_id":"account-a"}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 401, data: Data("secret body".utf8))])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date())

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("Every Code auth") == true)
    #expect(result.reports[0].errorMessage?.contains("Sign in again") == true)
    #expect(result.reports[0].errorMessage?.contains("secret body") == false)
    #expect(http.requests.count == 1)
}

@Test func googleAntigravityBridgePersistsOnlySanitizedQuotaFields() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
    let payload = #"""
    {
      "version": "1.1.1",
      "plan_tier": "Google AI Ultra",
      "email": "sensitive-email@example.com",
      "cwd": "/Users/sensitive/workspace",
      "conversation_id": "sensitive-conversation-id",
      "transcript_path": "/Users/sensitive/transcript.jsonl",
      "access_token": "sensitive-access-token",
      "quota": {
        "gemini-3.1-pro-high-5h": {
          "remaining_fraction": 0.75,
          "reset_in_seconds": 3600,
          "request_id": "sensitive-request-id"
        },
        "claude-sonnet-4.6-weekly": {
          "remaining_fraction": 0.9,
          "reset_time": "2027-01-16T09:00:00Z"
        },
        "gpt-oss-120b-weekly": {
          "remaining_fraction": 0.2,
          "disabled": true
        }
      }
    }
    """#.data(using: .utf8)!

    let result = try GoogleAntigravityStatusLineBridge.ingest(
        data: payload,
        observedAt: observedAt,
        store: store
    )
    let loadedSnapshot = try store.load()
    let snapshot = try #require(loadedSnapshot)
    let persisted = try String(contentsOf: snapshotURL, encoding: .utf8)
    let filePermissions = try #require(
        FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.posixPermissions] as? NSNumber
    )
    let directoryPermissions = try #require(
        FileManager.default.attributesOfItem(atPath: snapshotURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    )

    #expect(result == .saved(snapshot))
    #expect(snapshot.sourceVersion == "1.1.1")
    #expect(snapshot.planTier == "Google AI Ultra")
    #expect(snapshot.observedAt == observedAt)
    #expect(snapshot.buckets.map(\.id) == [
        "claude-sonnet-4.6-weekly",
        "gemini-3.1-pro-high-5h",
        "gpt-oss-120b-weekly",
    ])
    #expect(snapshot.buckets.last?.isDisabled == true)
    #expect(snapshot.buckets[1].resetsAt == observedAt.addingTimeInterval(3_600))
    #expect(filePermissions.intValue & 0o7777 == 0o600)
    #expect(directoryPermissions.intValue & 0o7777 == 0o700)
    for sensitiveValue in [
        "sensitive-email@example.com",
        "/Users/sensitive/workspace",
        "sensitive-conversation-id",
        "/Users/sensitive/transcript.jsonl",
        "sensitive-access-token",
        "sensitive-request-id",
        "access_token",
        "transcript_path",
        "conversation_id",
    ] {
        #expect(!persisted.contains(sensitiveValue))
    }
}

@Test func googleAntigravityBridgePreservesLastGoodSnapshotWhenQuotaIsMissing() throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
    let original = GoogleAntigravityStatusLineSnapshot(
        sourceVersion: "1.1.0",
        observedAt: Date(timeIntervalSince1970: 100),
        buckets: [GoogleAntigravityStatusLineBucket(id: "gemini-weekly", remainingFraction: 0.8, resetsAt: nil)]
    )
    try store.save(original)

    let missingResult = try GoogleAntigravityStatusLineBridge.ingest(
        data: Data(#"{"version":"1.1.1","email":"ignored@example.com"}"#.utf8),
        observedAt: Date(timeIntervalSince1970: 200),
        store: store
    )
    let emptyResult = try GoogleAntigravityStatusLineBridge.ingest(
        data: Data(#"{"version":"1.1.1","quota":{}}"#.utf8),
        observedAt: Date(timeIntervalSince1970: 300),
        store: store
    )

    #expect(missingResult == .ignoredMissingQuota)
    #expect(emptyResult == .ignoredEmptyQuota)
    let preservedSnapshot = try store.load()
    #expect(preservedSnapshot == original)
}

@Test func googleAntigravityBridgeRejectsMalformedKnownFieldsAndOversizedInput() throws {
    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: try googleAntigravityTemporarySnapshotURL())
    let invalidPayloads = [
        #"{"version":"bad version!","quota":{}}"#,
        #"{"plan_tier":"bad/tier","quota":{}}"#,
        #"{"quota":{"gemini-weekly":{"remaining_fraction":1.1}}}"#,
        #"{"quota":{"gemini weekly":{"remaining_fraction":0.5}}}"#,
        #"{"quota":{"gemini-weekly":{"reset_time":"not-a-date"}}}"#,
        #"{"quota":{"gemini-weekly":{"reset_in_seconds":999999999}}}"#,
    ]

    for payload in invalidPayloads {
        do {
            _ = try GoogleAntigravityStatusLineBridge.ingest(data: Data(payload.utf8), store: store)
            Issue.record("Expected malformed Antigravity payload to fail")
        } catch let error as GoogleAntigravityStatusLineBridgeError {
            #expect(error == .invalidPayload)
        }
    }

    do {
        _ = try GoogleAntigravityStatusLineBridge.ingest(
            data: Data(repeating: 0, count: GoogleAntigravityStatusLineBridge.maximumInputBytes + 1),
            store: store
        )
        Issue.record("Expected oversized Antigravity payload to fail")
    } catch let error as GoogleAntigravityStatusLineBridgeError {
        #expect(error == .oversizedInput)
    }
}

@Test func googleAntigravityStoreRejectsSymlinkSnapshots() throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let directoryURL = snapshotURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let targetURL = directoryURL.appending(path: "target.json")
    try Data("{}".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: targetURL)

    do {
        _ = try GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL).load()
        Issue.record("Expected a symlink Antigravity snapshot to fail")
    } catch let error as GoogleAntigravityStatusLineStoreError {
        #expect(error == .unsafeFile)
    }
}

@Test func googleAntigravityStoreRejectsFIFOSnapshotsWithoutBlocking() throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let directoryURL = snapshotURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(mkfifo(snapshotURL.path, S_IRUSR | S_IWUSR) == 0)

    do {
        _ = try GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL).load()
        Issue.record("Expected a FIFO Antigravity snapshot to fail")
    } catch let error as GoogleAntigravityStatusLineStoreError {
        #expect(error == .unsafeFile)
    }
}

@Test func googleAntigravityStoreRemovesOnlyStaleCanonicalTemporaryFilesBeforeSave() throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let testDirectoryURL = snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
    let original = googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 100))
    let updated = googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 200))
    try store.save(original)

    let directoryURL = snapshotURL.deletingLastPathComponent()
    let staleTemporaryURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let recentTemporaryURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let malformedTemporaryURL = directoryURL.appending(
        path: ".antigravity-status-line.json.not-a-uuid.tmp"
    )
    let lowercaseUUIDTemporaryURL = directoryURL.appending(
        path: ".antigravity-status-line.json.01234567-89ab-cdef-0123-456789abcdef.tmp"
    )
    let unrelatedURL = directoryURL.appending(path: "unrelated.tmp")

    for url in [
        staleTemporaryURL,
        recentTemporaryURL,
        malformedTemporaryURL,
        lowercaseUUIDTemporaryURL,
        unrelatedURL,
    ] {
        try writeGoogleAntigravityTestFile(Data("temporary".utf8), to: url)
    }
    let staleDate = Date().addingTimeInterval(-48 * 60 * 60)
    for url in [
        staleTemporaryURL,
        malformedTemporaryURL,
        lowercaseUUIDTemporaryURL,
        unrelatedURL,
    ] {
        try setGoogleAntigravityTestModificationDate(staleDate, for: url)
    }

    #expect(try store.load() == original)
    #expect(FileManager.default.fileExists(atPath: staleTemporaryURL.path))

    try store.save(updated)

    #expect(!FileManager.default.fileExists(atPath: staleTemporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: recentTemporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: malformedTemporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: lowercaseUUIDTemporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    #expect(try store.load() == updated)
}

@Test func googleAntigravityStoreCleansTemporaryFilesOnlyForCanonicalSnapshot() throws {
    let canonicalSnapshotURL = try googleAntigravityTemporarySnapshotURL()
    let testDirectoryURL = canonicalSnapshotURL.deletingLastPathComponent().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

    let directoryURL = canonicalSnapshotURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let staleCanonicalTemporaryURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    try writeGoogleAntigravityTestFile(Data("stale".utf8), to: staleCanonicalTemporaryURL)
    try setGoogleAntigravityTestModificationDate(
        Date().addingTimeInterval(-48 * 60 * 60),
        for: staleCanonicalTemporaryURL
    )

    let customSnapshotURL = directoryURL.appending(path: "custom-status-line.json")
    let customStore = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: customSnapshotURL)
    let snapshot = googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 200))
    try customStore.save(snapshot)

    #expect(FileManager.default.fileExists(atPath: staleCanonicalTemporaryURL.path))
    #expect(try customStore.load() == snapshot)
}

@Test func googleAntigravityStorePreservesUnsafeStaleTemporaryEntries() throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let testDirectoryURL = snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
    try store.save(googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 100)))

    let directoryURL = snapshotURL.deletingLastPathComponent()
    let staleDate = Date().addingTimeInterval(-48 * 60 * 60)
    let sentinelURL = directoryURL.appending(path: "sentinel")
    let symlinkURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let fifoURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let directoryEntryURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let permissiveURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let oversizedURL = googleAntigravityTemporaryFileURL(in: directoryURL)
    let hardLinkSourceURL = directoryURL.appending(path: "hard-link-source")
    let hardLinkURL = googleAntigravityTemporaryFileURL(in: directoryURL)

    try Data("sentinel".utf8).write(to: sentinelURL)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sentinelURL)
    #expect(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR) == 0)
    try FileManager.default.createDirectory(at: directoryEntryURL, withIntermediateDirectories: false)
    try writeGoogleAntigravityTestFile(Data("permissive".utf8), to: permissiveURL, permissions: 0o644)
    try writeGoogleAntigravityTestFile(
        Data(repeating: 0x41, count: GoogleAntigravityStatusLineSnapshotStore.maximumSnapshotBytes + 1),
        to: oversizedURL
    )
    try writeGoogleAntigravityTestFile(Data("hard link".utf8), to: hardLinkSourceURL)
    #expect(link(hardLinkSourceURL.path, hardLinkURL.path) == 0)

    for url in [
        symlinkURL,
        fifoURL,
        directoryEntryURL,
        permissiveURL,
        oversizedURL,
        hardLinkURL,
    ] {
        try setGoogleAntigravityTestModificationDate(staleDate, for: url, noFollow: url == symlinkURL)
    }

    try store.save(googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 200)))

    for url in [
        symlinkURL,
        fifoURL,
        directoryEntryURL,
        permissiveURL,
        oversizedURL,
        hardLinkURL,
    ] {
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    #expect(try Data(contentsOf: sentinelURL) == Data("sentinel".utf8))
    #expect(try Data(contentsOf: hardLinkSourceURL) == Data("hard link".utf8))
}

@Test func googleAntigravityTemporaryCleanupRequiresSafeOwnerModeLinkSizeAndAge() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var safeInformation = stat()
    safeInformation.st_mode = S_IFREG | S_IRUSR | S_IWUSR
    safeInformation.st_uid = geteuid()
    safeInformation.st_nlink = 1
    safeInformation.st_size = off_t(GoogleAntigravityStatusLineSnapshotStore.maximumSnapshotBytes)
    safeInformation.st_mtimespec = timespec(
        tv_sec: Int(now.timeIntervalSince1970 - 25 * 60 * 60),
        tv_nsec: 0
    )

    #expect(GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(safeInformation, now: now))

    var wrongOwner = safeInformation
    wrongOwner.st_uid = safeInformation.st_uid == 0 ? 1 : 0
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(wrongOwner, now: now))

    var permissive = safeInformation
    permissive.st_mode |= S_IRGRP
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(permissive, now: now))

    var hardLinked = safeInformation
    hardLinked.st_nlink = 2
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(hardLinked, now: now))

    var oversized = safeInformation
    oversized.st_size += 1
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(oversized, now: now))

    var recent = safeInformation
    recent.st_mtimespec = timespec(
        tv_sec: Int(now.timeIntervalSince1970 - 23 * 60 * 60),
        tv_nsec: 0
    )
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(recent, now: now))

    var exactBoundary = safeInformation
    exactBoundary.st_mtimespec = timespec(
        tv_sec: Int(now.timeIntervalSince1970 - 24 * 60 * 60),
        tv_nsec: 0
    )
    #expect(GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(exactBoundary, now: now))

    var specialModeBits = safeInformation
    specialModeBits.st_mode |= S_ISUID
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(specialModeBits, now: now))

    var negativeNanoseconds = safeInformation
    negativeNanoseconds.st_mtimespec.tv_nsec = -1
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(negativeNanoseconds, now: now))

    var excessiveNanoseconds = safeInformation
    excessiveNanoseconds.st_mtimespec.tv_nsec = 1_000_000_000
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(excessiveNanoseconds, now: now))

    var fifo = safeInformation
    fifo.st_mode = S_IFIFO | S_IRUSR | S_IWUSR
    #expect(!GoogleAntigravityStatusLineSnapshotStore.isEligibleStaleTemporaryFile(fifo, now: now))
}

@Test func googleAntigravityStoreIgnoresTemporaryCleanupFailures() throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let testDirectoryURL = snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
    try store.save(googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 100)))

    let temporaryURL = googleAntigravityTemporaryFileURL(in: snapshotURL.deletingLastPathComponent())
    try writeGoogleAntigravityTestFile(Data("immutable".utf8), to: temporaryURL)
    try setGoogleAntigravityTestModificationDate(
        Date().addingTimeInterval(-48 * 60 * 60),
        for: temporaryURL
    )
    #expect(chflags(temporaryURL.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { _ = chflags(temporaryURL.path, 0) }

    let updated = googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 200))
    try store.save(updated)

    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(try store.load() == updated)
}

@Test func googleAntigravityStoreConcurrentSavesRemainAtomicWhileCleaning() async throws {
    let snapshotURL = try googleAntigravityTemporarySnapshotURL()
    let testDirectoryURL = snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

    let store = GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
    try store.save(googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 100)))

    let staleTemporaryURL = googleAntigravityTemporaryFileURL(in: snapshotURL.deletingLastPathComponent())
    try writeGoogleAntigravityTestFile(Data("stale".utf8), to: staleTemporaryURL)
    try setGoogleAntigravityTestModificationDate(
        Date().addingTimeInterval(-48 * 60 * 60),
        for: staleTemporaryURL
    )
    let snapshots = (0 ..< 12).map { offset in
        googleAntigravityTestSnapshot(observedAt: Date(timeIntervalSince1970: 1_000 + Double(offset)))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for snapshot in snapshots {
            group.addTask {
                try store.save(snapshot)
            }
        }
        try await group.waitForAll()
    }

    let loaded = try store.load()
    let loadedSnapshot = try #require(loaded)
    #expect(snapshots.contains(loadedSnapshot))
    #expect(!FileManager.default.fileExists(atPath: staleTemporaryURL.path))
}

@Test func googleAntigravityConnectorMapsFreshObservedBucketsWithoutPrivateAPIs() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = GoogleAntigravityStatusLineSnapshot(
        sourceVersion: "1.1.1",
        planTier: "Google AI Pro",
        observedAt: now,
        buckets: [
            GoogleAntigravityStatusLineBucket(
                id: "gemini-3.1-pro-high-5h",
                remainingFraction: 0.9,
                resetsAt: now.addingTimeInterval(3_600)
            ),
            GoogleAntigravityStatusLineBucket(
                id: "claude-sonnet-4.6-weekly",
                remainingFraction: 0.85,
                resetsAt: now.addingTimeInterval(7 * 24 * 3_600)
            ),
            GoogleAntigravityStatusLineBucket(
                id: "mystery-model",
                remainingFraction: 0.95,
                resetsAt: nil
            ),
            GoogleAntigravityStatusLineBucket(
                id: "mystery_model",
                remainingFraction: 0.96,
                resetsAt: nil
            ),
            GoogleAntigravityStatusLineBucket(
                id: "gpt-oss-120b-weekly",
                remainingFraction: 0.01,
                resetsAt: nil,
                isDisabled: true
            ),
        ]
    )
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        snapshotLoader: StubGoogleAntigravitySnapshotLoader(snapshot: snapshot)
    )

    let result = await connector.refresh(now: now)
    let report = try #require(result.reports.first)

    #expect(report.status == .healthy)
    #expect(report.generatedAt == now)
    #expect(report.errorMessage == nil)
    #expect(report.limits.map(\.label) == [
        "Gemini 3.1 Pro High 5-hour",
        "Claude Sonnet 4.6 Weekly",
        "Mystery Model",
        "Mystery Model",
    ])
    #expect(report.limits.map(\.windowLabel) == ["5-hour", "Weekly", nil, nil])
    #expect(report.limits.map(\.used) == [10, 15, 5, 4])
    #expect(Set(report.limits.map(\.id)).count == 4)
    #expect(report.limits.map(\.confidence).allSatisfy { $0 == .observed })
    #expect(report.limits.allSatisfy { $0.note?.contains("documented status-line quota export") == true })
    #expect(!report.limits.contains { $0.label.contains("GPT") })
}

@Test func googleAntigravityConnectorPreservesObservedUsageAcrossElapsedResets() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let observedAt = now.addingTimeInterval(-24 * 3_600)
    let elapsedReset = now.addingTimeInterval(-3_600)
    let futureReset = now.addingTimeInterval(6 * 24 * 3_600)
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        snapshotLoader: StubGoogleAntigravitySnapshotLoader(snapshot: GoogleAntigravityStatusLineSnapshot(
            observedAt: observedAt,
            buckets: [
                GoogleAntigravityStatusLineBucket(
                    id: "gemini-5h",
                    remainingFraction: 0.8,
                    resetsAt: elapsedReset
                ),
                GoogleAntigravityStatusLineBucket(
                    id: "gemini-weekly",
                    remainingFraction: 0.9,
                    resetsAt: futureReset
                ),
                GoogleAntigravityStatusLineBucket(
                    id: "disabled-weekly",
                    remainingFraction: 0.1,
                    resetsAt: now.addingTimeInterval(-3_600),
                    isDisabled: true
                ),
            ]
        ))
    )

    let report = try #require(await connector.refresh(now: now).reports.first)
    let elapsed = try #require(report.limits.first { $0.label == "Gemini 5-hour" })
    let current = try #require(report.limits.first { $0.label == "Gemini Weekly" })
    let presentedElapsed = elapsed.presented(at: now)

    #expect(report.status == .healthy)
    #expect(report.errorMessage == nil)
    #expect(report.generatedAt == observedAt)
    #expect(elapsed.status == .healthy)
    #expect(elapsed.used == 20)
    #expect(elapsed.resetsAt == elapsedReset)
    #expect(elapsed.lastUpdatedAt == observedAt)
    #expect(elapsed.confidence == .observed)
    #expect(elapsed.presentationAssumption == nil)
    #expect(presentedElapsed.used == 0)
    #expect(presentedElapsed.remaining == 100)
    #expect(presentedElapsed.resetsAt == nil)
    #expect(presentedElapsed.lastUpdatedAt == observedAt)
    #expect(presentedElapsed.confidence == .estimated)
    #expect(presentedElapsed.presentationAssumption == .scheduledReset)
    #expect(current.status == .healthy)
    #expect(current.used == 10)
    #expect(current.resetsAt == futureReset)
    #expect(current.lastUpdatedAt == observedAt)
    #expect(current.confidence == .observed)
    #expect(!report.limits.contains { $0.label.contains("Disabled") })
}

@Test func googleAntigravityConnectorTreatsDisabledOnlySnapshotsAsUnknown() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        snapshotLoader: StubGoogleAntigravitySnapshotLoader(snapshot: GoogleAntigravityStatusLineSnapshot(
            observedAt: now,
            buckets: [GoogleAntigravityStatusLineBucket(
                id: "disabled-weekly",
                remainingFraction: 0.1,
                resetsAt: now.addingTimeInterval(-3_600),
                isDisabled: true
            )]
        ))
    )

    let report = try #require(await connector.refresh(now: now).reports.first)

    #expect(report.status == .unknown)
    #expect(report.limits.isEmpty)
    #expect(report.errorMessage?.contains("active quota buckets") == true)
}

@Test func googleAntigravityConnectorReportsSetupReadAndObservationFailuresSeparately() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let account = googleAntigravityTestAccount()
    let missing = GoogleAntigravityQuotaConnector(
        accounts: [account],
        snapshotLoader: StubGoogleAntigravitySnapshotLoader(snapshot: nil)
    )
    let unreadable = GoogleAntigravityQuotaConnector(
        accounts: [account],
        snapshotLoader: StubGoogleAntigravitySnapshotLoader(error: .unsafeFile)
    )
    let future = GoogleAntigravityQuotaConnector(
        accounts: [account],
        snapshotLoader: StubGoogleAntigravitySnapshotLoader(snapshot: GoogleAntigravityStatusLineSnapshot(
            observedAt: now.addingTimeInterval(301),
            buckets: [GoogleAntigravityStatusLineBucket(id: "gemini-weekly", remainingFraction: 0.8, resetsAt: nil)]
        ))
    )

    let missingReport = try #require(await missing.refresh(now: now).reports.first)
    let unreadableReport = try #require(await unreadable.refresh(now: now).reports.first)
    let futureReport = try #require(await future.refresh(now: now).reports.first)

    #expect(missingReport.status == .unknown)
    #expect(missingReport.errorMessage?.contains("setup is required") == true)
    #expect(missingReport.errorMessage?.contains("Every Code") == true)
    #expect(unreadableReport.status == .failure)
    #expect(unreadableReport.errorMessage?.contains("could not be read") == true)
    #expect(futureReport.status == .failure)
    #expect(futureReport.errorMessage?.contains("invalid observation time") == true)
}

@Test func googleAntigravitySetupCommandsAreQuotedAndReversible() {
    let bundleURL = URL(fileURLWithPath: "/Applications/Context Panel's Preview.app")
    let command = GoogleAntigravityStatusLineSetup.setupCommand(applicationBundleURL: bundleURL)

    #expect(command.hasPrefix("/statusline '"))
    #expect(command.contains("Context Panel'\\''s Preview.app"))
    #expect(command.hasSuffix("ContextPanelRefreshAgent' --ingest-antigravity-status-line"))
    #expect(GoogleAntigravityStatusLineSetup.removeCommand == "/statusline delete")
}

@Test func claudeOAuthConnectorRefreshesUsageWindows() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "five_hour": { "utilization": 9.0, "resets_at": "2026-05-14T23:10:00.961640+00:00" },
      "seven_day": { "utilization": 12.0, "resets_at": "2026-05-17T03:00:00.961658+00:00" },
      "seven_day_sonnet": { "utilization": 14.0, "resets_at": "2026-05-17T03:00:00.961664+00:00" },
      "seven_day_opus": null,
      "extra_usage": { "is_enabled": false, "disabled_reason": "org_level_disabled_until" }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .available))
    #expect(result.snapshot.limits.count == 3)
    #expect(result.snapshot.limits.map(\.windowLabel) == ["5-hour", "Weekly", "Weekly"])
    #expect(result.snapshot.limits.map(\.modelLabel) == ["Claude", "Claude", "Sonnet"])
    #expect(result.snapshot.limits.map(\.used) == [9, 12, 14])
    #expect(result.snapshot.limits.allSatisfy { $0.provider == .anthropic && $0.unit == .percent })
    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(http.requests[0].headers["Authorization"] == "Bearer access-secret")
}

@Test func claudeOAuthConnectorReportsBlockedAccessFromStructuredUsage() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "limits": [
        { "id": "five_hour", "metric": "percent", "current_value": 100, "reset_at": "2026-07-23T19:30:00Z" },
        { "id": "seven_day", "metric": "percent", "current_value": 29, "reset_at": "2026-07-27T12:00:00Z" }
      ],
      "spend": { "enabled": false, "used_minor_units": 999999 },
      "extra_usage": { "is_enabled": true, "disabled_reason": "must-not-survive" }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )
    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let resetsAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:30:00Z"))

    let result = await connector.refresh(now: observedAt)

    #expect(result.reports[0].status == .limited)
    #expect(result.reports[0].accessState == ProviderAccessState(
        kind: .blockedUntilReset,
        resetsAt: resetsAt
    ))
    #expect(result.snapshot.limits.map(\.used) == [100, 29])
    #expect(result.snapshot.limits.allSatisfy { $0.note == nil })
}

@Test func claudeOAuthConnectorKeepsLimitedQuotaWhilePaidFallbackIsActive() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "limits": [
        { "id": "five_hour", "metric": "utilization", "current_value": 100, "reset_at": "2026-07-23T19:30:00Z" },
        { "id": "seven_day", "metric": "percent", "current_value": 100, "reset_at": "2026-07-27T12:00:00Z" }
      ],
      "spend": { "enabled": true }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )
    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let resetsAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-27T12:00:00Z"))

    let result = await connector.refresh(now: observedAt)

    #expect(result.reports[0].status == .limited)
    #expect(result.reports[0].accessState == ProviderAccessState(
        kind: .paidFallbackActive,
        resetsAt: resetsAt
    ))
}

@Test func claudeOAuthStructuredUsageWinsAndFallsBackPerWindow() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "limits": [
        "ignore me",
        { "id": "five_hour", "metric": "percent", "current_value": 35, "reset_at": "not-a-date" },
        { "id": "seven_day_sonnet", "metric": "tokens", "current_value": 999 },
        { "id": "unknown_window", "metric": "percent", "current_value": 100 }
      ],
      "five_hour": { "utilization": 99, "resets_at": "2026-07-23T19:30:00Z" },
      "seven_day": { "utilization": 45, "resets_at": "2026-07-27T12:00:00Z" },
      "seven_day_sonnet": { "utilization": 55, "resets_at": "2026-07-27T12:00:00Z" },
      "extra_usage": { "is_enabled": false }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let result = await connector.refresh(now: observedAt)

    #expect(result.snapshot.limits.map(\.used) == [35, 45, 55])
    #expect(result.snapshot.limits.map(\.modelLabel) == ["Claude", "Claude", "Sonnet"])
    #expect(result.snapshot.limits[0].resetsAt == nil)
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .available))
}

@Test func claudeOAuthSaturatedUsageWithoutFallbackSignalIsDegraded() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "five_hour": { "utilization": 100, "resets_at": "2026-07-23T19:30:00Z" },
      "seven_day": { "utilization": 29, "resets_at": "2026-07-27T12:00:00Z" }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let result = await connector.refresh(now: observedAt)

    #expect(result.reports[0].status == .limited)
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .degraded))
}

@Test func claudeOAuthAccessReturnsToAvailableAfterReset() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let blocked = Data(#"{"five_hour":{"utilization":100,"resets_at":"2026-07-23T19:30:00Z"},"seven_day":{"utilization":29},"extra_usage":{"is_enabled":false}}"#.utf8)
    let available = Data(#"{"five_hour":{"utilization":0,"resets_at":"2026-07-23T23:30:00Z"},"seven_day":{"utilization":29},"extra_usage":{"is_enabled":false}}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: blocked),
        ConnectorHTTPResponse(statusCode: 200, data: available),
    ])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: StubCredentialStore(storage: ["claude-oauth-default": credentials])
    )
    let beforeReset = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let afterReset = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:31:00Z"))

    let blockedResult = await connector.refresh(now: beforeReset)
    let availableResult = await connector.refresh(now: afterReset)

    #expect(blockedResult.reports[0].accessState.kind == .blockedUntilReset)
    #expect(availableResult.reports[0].accessState == ProviderAccessState(kind: .available))
}

@Test func claudeOAuthFractionalUtilizationDoesNotRoundIntoAccessThresholds() async throws {
    let usage = Data(#"{"five_hour":{"utilization":99.6},"seven_day":{"utilization":79.6},"extra_usage":{"is_enabled":false}}"#.utf8)

    let result = try await claudeUsageRefreshResult(usage: usage)

    #expect(result.snapshot.limits.map(\.used) == [99, 79])
    #expect(result.snapshot.limits.map(\.status) == [.close, .healthy])
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .pressure))
}

@Test func claudeOAuthUtilizationAtOrAboveOneHundredSaturates() async throws {
    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))
    let resetsAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:30:00Z"))
    let usage = Data(#"{"five_hour":{"utilization":100.4,"resets_at":"2026-07-23T19:30:00Z"},"seven_day":{"utilization":20},"extra_usage":{"is_enabled":false}}"#.utf8)

    let result = try await claudeUsageRefreshResult(usage: usage, now: observedAt)

    #expect(result.snapshot.limits.first?.used == 100)
    #expect(result.reports[0].accessState == ProviderAccessState(
        kind: .blockedUntilReset,
        resetsAt: resetsAt
    ))
}

@Test func claudeOAuthFractionalUtilizationIsNotRescaledFromZeroToOne() async throws {
    let usage = Data(#"{"five_hour":{"utilization":0.6},"seven_day":{"utilization":0.2},"extra_usage":{"is_enabled":false}}"#.utf8)

    let result = try await claudeUsageRefreshResult(usage: usage)

    #expect(result.snapshot.limits.map(\.used) == [1, 0])
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .available))
}

@Test func claudeOAuthMetriclessStructuredValueDoesNotFabricateBlock() async throws {
    let usage = #"""
    {
      "limits": [
        { "id": "five_hour", "current_value": 41234, "reset_at": "2026-07-23T19:30:00Z" }
      ],
      "five_hour": { "utilization": 12, "resets_at": "2026-07-23T19:30:00Z" },
      "seven_day": { "utilization": 20 },
      "extra_usage": { "is_enabled": false }
    }
    """#.data(using: .utf8)!

    let result = try await claudeUsageRefreshResult(usage: usage)

    #expect(result.snapshot.limits.map(\.used) == [12, 20])
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .available))
}

@Test func claudeOAuthMetriclessStructuredEntryPrefersUtilization() async throws {
    let usage = #"""
    {
      "limits": [
        { "id": "five_hour", "current_value": 87, "utilization": 42 }
      ],
      "seven_day": { "utilization": 20 },
      "extra_usage": { "is_enabled": false }
    }
    """#.data(using: .utf8)!

    let result = try await claudeUsageRefreshResult(usage: usage)

    #expect(result.snapshot.limits.map(\.used) == [42, 20])
    #expect(result.reports[0].accessState == ProviderAccessState(kind: .available))
}

@Test func claudeOAuthNonFiniteUtilizationStaysUnknown() async throws {
    let usage = Data(#"{"five_hour":{"utilization":"NaN"},"seven_day":{"utilization":"Infinity"}}"#.utf8)

    let result = try await claudeUsageRefreshResult(usage: usage)

    #expect(result.snapshot.limits.isEmpty)
    #expect(result.reports[0].status == .unknown)
    #expect(result.reports[0].accessState == .unknown)
}

@Test func claudeOAuthAccessStateRemainsIsolatedPerAccount() async throws {
    let personalCredentials = #"{"accessToken":"personal-secret","refreshToken":"personal-refresh","expiresAt":"2099-01-01T00:00:00Z","scopes":[]}"#.data(using: .utf8)!
    let workCredentials = #"{"accessToken":"work-secret","refreshToken":"work-refresh","expiresAt":"2099-01-01T00:00:00Z","scopes":[]}"#.data(using: .utf8)!
    let personalUsage = Data(#"{"five_hour":{"utilization":100,"resets_at":"2026-07-23T19:30:00Z"},"seven_day":{"utilization":20},"extra_usage":{"is_enabled":false}}"#.utf8)
    let workUsage = Data(#"{"five_hour":{"utilization":100,"resets_at":"2026-07-23T20:00:00Z"},"seven_day":{"utilization":80},"extra_usage":{"is_enabled":true}}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: personalUsage),
        ConnectorHTTPResponse(statusCode: 200, data: workUsage),
    ])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [
            ClaudeOAuthAccountConfiguration(accountID: "personal", accountName: "Personal Claude"),
            ClaudeOAuthAccountConfiguration(accountID: "work", accountName: "Work Claude"),
        ],
        httpClient: http,
        credentialStore: StubCredentialStore(storage: [
            "personal": personalCredentials,
            "work": workCredentials,
        ])
    )
    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-23T19:00:00Z"))

    let result = await connector.refresh(now: observedAt)

    #expect(result.reports.map(\.accountName) == ["Personal Claude", "Work Claude"])
    #expect(result.reports.map(\.accessState.kind) == [.blockedUntilReset, .paidFallbackActive])
    #expect(Set(result.reports.map(\.accountID)).count == 2)
}

@Test func claudeOAuthConnectorAcceptsEpochResetTimes() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "five_hour": { "utilization": 9.0, "resets_at": 1780793400 },
      "seven_day": { "utilization": 12.0, "resets_at": "1780801200" }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.map(\.resetsAt) == [
        Date(timeIntervalSince1970: 1_780_793_400),
        Date(timeIntervalSince1970: 1_780_801_200),
    ])
}

@Test func claudeOAuthConnectorDoesNotFillMissingResetTimesFromStatuslineHints() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let usage = #"""
    {
      "five_hour": { "utilization": 9.0 },
      "seven_day": { "utilization": 12.0 },
      "seven_day_sonnet": { "utilization": 14.0 }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.map(\.used) == [9, 12, 14])
    #expect(result.snapshot.limits.allSatisfy { $0.resetsAt == nil })
    #expect(result.snapshot.limits.allSatisfy { $0.note?.contains("statusline") != true })
}

@Test func claudeOAuthConnectorTreatsSuccessfulEmptyUsageAsAuthoritativeUnknown() async throws {
    let credentials = try claudeCredentialsData(
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let usage = Data(#"{"five_hour":null,"seven_day":{"utilization":null}}"#.utf8)
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .unknown)
    #expect(result.reports[0].accessState == .unknown)
    #expect(result.reports[0].limits.isEmpty)
    #expect(result.snapshot.limits.isEmpty)
}

@Test func claudeOAuthConnectorRedactsMalformedAndFailedUsageResponses() async throws {
    let credentials = try claudeCredentialsData(
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let cases: [(Int, Data)] = [
        (200, Data(#"{"five_hour":"malformed-secret"}"#.utf8)),
        (429, Data(#"{"request_id":"request-secret","message":"rate body secret"}"#.utf8)),
        (503, Data(#"{"request_id":"request-secret","message":"service body secret"}"#.utf8)),
    ]

    for (statusCode, body) in cases {
        let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: statusCode, data: body)])
        let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
        let connector = ClaudeOAuthUsageConnector(
            accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
            httpClient: http,
            credentialStore: store
        )

        let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(result.reports[0].status == .failure)
        #expect(result.reports[0].accessState == .unknown)
        #expect(result.reports[0].limits.isEmpty)
        #expect(result.reports[0].errorMessage?.contains("request-secret") == false)
        #expect(result.reports[0].errorMessage?.contains("body secret") == false)
    }
}

@Test func claudeOAuthFlowBuildsClaudeCodeAuthorizeURL() throws {
    let url = try ClaudeOAuthFlow.authorizationURL(codeChallenge: "challenge-value", state: "state-value")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })

    #expect(components.scheme == "https")
    #expect(components.host == "claude.com")
    #expect(components.path == "/cai/oauth/authorize")
    #expect(queryItems["code"] == "true")
    #expect(queryItems["client_id"] == ClaudeOAuthMetadata.clientID)
    #expect(queryItems["response_type"] == "code")
    #expect(queryItems["redirect_uri"] == ClaudeOAuthFlow.manualRedirectURI)
    #expect(queryItems["code_challenge"] == "challenge-value")
    #expect(queryItems["code_challenge_method"] == "S256")
    #expect(queryItems["state"] == "state-value")
    #expect(queryItems["scope"] == ClaudeOAuthMetadata.scopes.joined(separator: " "))
    #expect(queryItems["scope"]?.contains("user:profile") == true)
    #expect(queryItems["scope"]?.contains("user:inference") == true)
}

@Test func claudeOAuthFlowNormalizesCopiedCodeAndCallbackURLs() {
    let raw = ClaudeOAuthFlow.normalizedAuthorizationCode(from: "  code-secret#state-secret\n")
    #expect(raw.code == "code-secret")
    #expect(raw.state == "state-secret")

    let callback = ClaudeOAuthFlow.normalizedAuthorizationCode(
        from: "https://platform.claude.com/oauth/code/callback?code=callback-code%23callback-state"
    )
    #expect(callback.code == "callback-code")
    #expect(callback.state == "callback-state")
}

@Test func claudeOAuthFlowBuildsClaudeCodeTokenRequestJSON() throws {
    let code = ClaudeOAuthAuthorizationCode(code: "code-secret", state: "copied-state")
    let data = try ClaudeOAuthFlow.authorizationCodeTokenRequestBody(
        code: code,
        codeVerifier: "verifier-secret",
        state: "flow-state"
    )
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

    #expect(payload["grant_type"] == "authorization_code")
    #expect(payload["client_id"] == ClaudeOAuthMetadata.clientID)
    #expect(payload["code"] == "code-secret")
    #expect(payload["redirect_uri"] == ClaudeOAuthFlow.manualRedirectURI)
    #expect(payload["code_verifier"] == "verifier-secret")
    #expect(payload["state"] == "copied-state")
}

@Test func claudeOAuthFlowBuildsRefreshTokenRequestJSON() throws {
    let data = try ClaudeOAuthFlow.refreshTokenRequestBody(refreshToken: "refresh-secret")
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

    #expect(payload["grant_type"] == "refresh_token")
    #expect(payload["refresh_token"] == "refresh-secret")
    #expect(payload["client_id"] == ClaudeOAuthMetadata.clientID)
    #expect(payload["scope"] == nil)
}

@Test func claudeOAuthConnectorRefreshesExpiredAccessToken() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let token = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"user:profile user:inference"}"#.data(using: .utf8)!
    let usage = #"{"five_hour":{"utilization":1,"resets_at":"2026-05-14T23:10:00Z"}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 200, data: usage),
    ])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.map(\.method) == ["POST", "GET"])
    #expect(http.requests[0].headers["anthropic-beta"] == ClaudeOAuthMetadata.oauthBetaHeader)
    #expect(http.requests[0].headers["User-Agent"] == "context-panel")
    #expect(http.requests[0].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("refresh-secret") == true)
    #expect(http.requests[1].headers["Authorization"] == "Bearer new-access")
    #expect(store.savedAccountID == "claude-oauth-default")
    #expect(store.savedData.flatMap { try? JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: $0) }?.refreshToken == "new-refresh")
}

@Test func claudeOAuthConnectorUsesExpirationSkewBoundary() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let usage = Data(#"{"five_hour":{"utilization":1}}"#.utf8)
    let validCredentials = try claudeCredentialsData(
        accessToken: "current-access",
        refreshToken: "refresh-secret",
        expiresAt: now.addingTimeInterval(301)
    )
    let validHTTP = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)])
    let validConnector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: validHTTP,
        credentialStore: StubCredentialStore(storage: ["claude-oauth-default": validCredentials])
    )

    _ = await validConnector.refresh(now: now)

    #expect(validHTTP.requests.map(\.method) == ["GET"])
    #expect(validHTTP.requests[0].headers["Authorization"] == "Bearer current-access")

    let boundaryCredentials = try claudeCredentialsData(
        accessToken: "old-access",
        refreshToken: "refresh-secret",
        expiresAt: now.addingTimeInterval(300)
    )
    let token = Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8)
    let boundaryHTTP = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 200, data: usage),
    ])
    let boundaryConnector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: boundaryHTTP,
        credentialStore: StubCredentialStore(storage: ["claude-oauth-default": boundaryCredentials])
    )

    _ = await boundaryConnector.refresh(now: now)

    #expect(boundaryHTTP.requests.map(\.method) == ["POST", "GET"])
    #expect(boundaryHTTP.requests[1].headers["Authorization"] == "Bearer new-access")
}

@Test func claudeOAuthConnectorRequiresRefreshTokenWhenAccessTokenIsExpired() async throws {
    let credentials = try claudeCredentialsData(
        accessToken: "old-access",
        refreshToken: nil,
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let http = StubHTTPClient(responses: [])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: StubCredentialStore(storage: ["claude-oauth-default": credentials])
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(http.requests.isEmpty)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].accessState == .unknown)
    #expect(result.reports[0].errorMessage?.contains("do not contain a refresh token") == true)
}

@Test func claudeOAuthConnectorPreservesRefreshTokenWhenRotationOmitsIt() async throws {
    let credentials = try claudeCredentialsData(
        accessToken: "old-access",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let token = Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8)
    let usage = Data(#"{"five_hour":{"utilization":1}}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 200, data: usage),
    ])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))
    let savedData = try #require(store.savedData)
    let savedCredentials = try JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: savedData)

    #expect(result.reports[0].status == .healthy)
    #expect(savedCredentials.refreshToken == "refresh-secret")
}

@Test func claudeOAuthConnectorRefreshesWhenUsageCallRejectsAccessToken() async throws {
    for statusCode in [401, 403] {
        let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
        let token = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"user:profile user:inference"}"#.data(using: .utf8)!
        let usage = #"{"five_hour":{"utilization":1,"resets_at":"2026-05-14T23:10:00Z"}}"#.data(using: .utf8)!
        let http = StubHTTPClient(responses: [
            ConnectorHTTPResponse(statusCode: statusCode, data: Data(#"{"error":"invalid_token"}"#.utf8)),
            ConnectorHTTPResponse(statusCode: 200, data: token),
            ConnectorHTTPResponse(statusCode: 200, data: usage),
        ])
        let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
        let connector = ClaudeOAuthUsageConnector(
            accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
            httpClient: http,
            credentialStore: store
        )

        let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(result.reports[0].status == .healthy)
        #expect(http.requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(http.requests[1].headers["anthropic-beta"] == ClaudeOAuthMetadata.oauthBetaHeader)
        #expect(http.requests[1].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("refresh-secret") == true)
        #expect(http.requests[2].headers["Authorization"] == "Bearer new-access")
        #expect(http.requests[2].headers["anthropic-beta"] == ClaudeOAuthMetadata.oauthBetaHeader)
        #expect(store.savedAccountID == "claude-oauth-default")
    }
}

@Test func claudeOAuthConnectorReportsSecondUnauthorizedUsageWithoutLeakingBody() async throws {
    let credentials = try claudeCredentialsData(
        accessToken: "old-access",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let token = Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 401, data: Data(#"{"request_id":"first-secret"}"#.utf8)),
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 401, data: Data(#"{"request_id":"second-secret"}"#.utf8)),
    ])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: StubCredentialStore(storage: ["claude-oauth-default": credentials])
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(http.requests.map(\.method) == ["GET", "POST", "GET"])
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage == "Claude usage was not authorized. Reauthorize this account and try again.")
    #expect(result.reports[0].errorMessage?.contains("second-secret") == false)
}

@Test func claudeOAuthConnectorKeepsMultiAccountFailuresIsolated() async throws {
    let credentials = try claudeCredentialsData(
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let usage = Data(#"{"five_hour":{"utilization":8}}"#.utf8)
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: usage),
        ConnectorHTTPResponse(statusCode: 503, data: Data(#"{"request_id":"second-secret"}"#.utf8)),
    ])
    let store = StubCredentialStore(storage: [
        "claude-a": credentials,
        "claude-b": credentials,
    ])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [
            ClaudeOAuthAccountConfiguration(accountID: "claude-a", accountName: "Claude A"),
            ClaudeOAuthAccountConfiguration(accountID: "claude-b", accountName: "Claude B"),
        ],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.map(\.status) == [.healthy, .failure])
    #expect(result.reports[0].limits.count == 1)
    #expect(result.reports[1].limits.isEmpty)
    #expect(result.reports[0].accountID != result.reports[1].accountID)
}

@Test func claudeOAuthTokenRotationIsSerializedBySharedSnapshotRefreshLock() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-claude-lock-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let now = Date()
    let credentials = try claudeCredentialsData(
        accessToken: "expired-access",
        refreshToken: "refresh-secret",
        expiresAt: now.addingTimeInterval(-60)
    )
    let http = GatedClaudeHTTPClient()
    let store = CountingCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )
    let lock = SnapshotRefreshLock(lockURL: directory.appending(path: "refresh.lock"))

    let firstRefresh = Task {
        try await lock.withLock {
            await connector.refresh(now: now)
        }
    }
    guard await http.waitUntilFirstTokenPOSTStarts() else {
        await http.releaseFirstTokenPOST()
        firstRefresh.cancel()
        _ = try? await firstRefresh.value
        Issue.record("first Claude token POST did not start before the test deadline")
        return
    }

    let secondRefresh: ConnectorRefreshResult?
    do {
        secondRefresh = try await lock.withLock {
            await connector.refresh(now: now)
        }
    } catch {
        await http.releaseFirstTokenPOST()
        _ = try? await firstRefresh.value
        throw error
    }

    await http.releaseFirstTokenPOST()
    let firstResult = try await firstRefresh.value

    #expect(firstResult?.reports.first?.status == .healthy)
    #expect(secondRefresh == nil)
    #expect(await http.tokenPOSTCount == 1)
    #expect(store.saveCount == 1)
    let savedData = try #require(store.data(accountID: "claude-oauth-default"))
    let savedCredentials = try JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: savedData)
    #expect(savedCredentials.refreshToken == "rotated-refresh")
    #expect(try await lock.withLock { true } == true)
}

@Test func claudeOAuthCodeExchangeRedactsFailureBody() async throws {
    let directory = try temporaryProviderConnectorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(
        statusCode: 500,
        data: Data(#"{"access_token":"must-not-leak"}"#.utf8)
    )])
    let service = ClaudeOAuthCodeExchangeService(
        httpClient: http,
        credentialStore: CountingCredentialStore(storage: [:]),
        lock: SnapshotRefreshLock(lockURL: directory.appending(path: "refresh.lock"))
    )

    await #expect(throws: ConnectorError.redactedHTTPFailure(
        operation: "Claude OAuth token exchange",
        statusCode: 500
    )) {
        try await service.exchangeAndSave(
            authorizationCode: ClaudeOAuthAuthorizationCode(code: "code", state: nil),
            codeVerifier: "verifier",
            state: "state",
            accountID: "claude-oauth-default"
        )
    }
}

@Test func claudeOAuthCodeExchangeDoesNotConsumeCodeWhileRefreshLockIsHeld() async throws {
    let directory = try temporaryProviderConnectorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = SnapshotRefreshLock(lockURL: directory.appending(path: "refresh.lock"))
    let gate = SnapshotLockTestGate()
    let holder = Task {
        try await lock.withLock {
            await gate.markStarted()
            await gate.waitForRelease()
        }
    }
    #expect(await gate.waitUntilStarted())
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(
        statusCode: 200,
        data: Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
    )])
    let store = CountingCredentialStore(storage: [:])
    let service = ClaudeOAuthCodeExchangeService(httpClient: http, credentialStore: store, lock: lock)

    await #expect(throws: ConnectorError.foregroundRefreshRequired(
        "Claude usage is already refreshing. Try signing in again in a moment."
    )) {
        try await service.exchangeAndSave(
            authorizationCode: ClaudeOAuthAuthorizationCode(code: "code", state: nil),
            codeVerifier: "verifier",
            state: "state",
            accountID: "claude-oauth-default"
        )
    }
    #expect(http.requests.isEmpty)
    #expect(store.saveCount == 0)

    await gate.release()
    _ = try await holder.value
}

@Test func claudeOAuthCodeExchangeCancellationDoesNotSaveCredentials() async throws {
    let directory = try temporaryProviderConnectorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = SnapshotRefreshLock(lockURL: directory.appending(path: "refresh.lock"))
    let http = GatedClaudeHTTPClient()
    let store = CountingCredentialStore(storage: [:])
    let service = ClaudeOAuthCodeExchangeService(httpClient: http, credentialStore: store, lock: lock)
    let exchange = Task {
        try await service.exchangeAndSave(
            authorizationCode: ClaudeOAuthAuthorizationCode(code: "code", state: nil),
            codeVerifier: "verifier",
            state: "state",
            accountID: "claude-oauth-default"
        )
    }
    guard await http.waitUntilFirstTokenPOSTStarts() else {
        exchange.cancel()
        await http.releaseFirstTokenPOST()
        Issue.record("Claude authorization-code POST did not start before the test deadline")
        return
    }

    exchange.cancel()
    await http.releaseFirstTokenPOST()
    do {
        _ = try await exchange.value
        Issue.record("canceled Claude code exchange unexpectedly succeeded")
    } catch is CancellationError {
    } catch {
        Issue.record("canceled Claude code exchange failed with unexpected error: \(error)")
    }

    #expect(store.saveCount == 0)
    #expect(try await lock.withLock { true } == true)
}

@Test func claudeOAuthCodeExchangeCommitCanRejectStaleFlow() async throws {
    let directory = try temporaryProviderConnectorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CountingCredentialStore(storage: [:])
    let service = ClaudeOAuthCodeExchangeService(
        httpClient: StubHTTPClient(responses: [ConnectorHTTPResponse(
            statusCode: 200,
            data: Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
        )]),
        credentialStore: store,
        lock: SnapshotRefreshLock(lockURL: directory.appending(path: "refresh.lock"))
    )

    do {
        _ = try await service.exchangeAndCommit(
            authorizationCode: ClaudeOAuthAuthorizationCode(code: "code", state: nil),
            codeVerifier: "verifier",
            state: "state"
        ) { _ in
            throw CancellationError()
        }
        Issue.record("stale Claude OAuth flow unexpectedly committed credentials")
    } catch is CancellationError {
    } catch {
        Issue.record("stale Claude OAuth flow failed with unexpected error: \(error)")
    }

    #expect(store.saveCount == 0)
}

@Test func claudeOAuthConnectorTreatsInvalidRefreshRequestAsHTTPFailure() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let errorBody = #"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid request format"},"request_id":"request-secret"}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 400, data: errorBody),
    ])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage == "Claude OAuth refresh returned HTTP 400; raw body redacted")
    #expect(result.reports[0].errorMessage?.contains("request-secret") == false)
}

@Test func claudeOAuthConnectorDoesNotTreatMissingBetaHeaderAsExpiredAuth() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let errorBody = #"{"type":"error","error":{"type":"invalid_request_error","message":"Missing required beta header"},"request_id":"request-secret"}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 403, data: errorBody),
    ])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage == "Claude OAuth refresh returned HTTP 403; raw body redacted")
    #expect(result.reports[0].errorMessage?.contains("expired") == false)
    #expect(result.reports[0].errorMessage?.contains("request-secret") == false)
}

@Test func claudeOAuthConnectorTreatsInvalidGrantAsReauthRequired() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let errorBody = #"{"error":"invalid_grant","error_description":"Refresh token has expired","request_id":"request-secret"}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 400, data: errorBody),
    ])
    let store = StubCredentialStore(storage: ["claude-oauth-default": credentials])
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage == "Claude OAuth session has expired. Sign in again from Settings.")
    #expect(result.reports[0].errorMessage?.contains("request-secret") == false)
}

@Test func providerConnectorRuntimeAggregatesConnectorSnapshots() async {
    let connectorA = StubConnector(provider: .openAI, report: ProviderConnectorReport(
        provider: .openAI,
        accountID: "a",
        accountName: "A",
        generatedAt: Date(timeIntervalSince1970: 0),
        limits: [UsageLimit(provider: .openAI, label: "A", used: 1, limit: 100)]
    ))
    let connectorB = StubConnector(provider: .google, report: ProviderConnectorReport(
        provider: .google,
        accountID: "b",
        accountName: "B",
        generatedAt: Date(timeIntervalSince1970: 0),
        limits: [UsageLimit(provider: .google, label: "B", used: 2, limit: 100)]
    ))

    let result = await ProviderConnectorRuntime(connectors: [connectorA, connectorB]).refreshAll(now: Date(timeIntervalSince1970: 10))

    #expect(result.reports.count == 2)
    #expect(result.snapshot.generatedAt == Date(timeIntervalSince1970: 10))
    #expect(Set(result.snapshot.limits.map(\.provider)) == [.openAI, .google])
}

private func codexResetConnector(http: StubHTTPClient) -> CodexRateLimitConnector {
    CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in Data(#"{"tokens":{"access_token":"token-secret","account_id":"account-a"}}"#.utf8) }
    )
}

private func codexResetUsage(available: Int, applicable: Int? = nil) -> Data {
    let applicableJSON = applicable.map { ",\"applicable_available_count\":\($0)" } ?? ""
    return Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":20,\"limit_window_seconds\":18000,\"reset_at\":1800003600}},\"rate_limit_reset_credits\":{\"available_count\":\(available)\(applicableJSON)}}".utf8)
}

private func codexResetDetails(available: Int? = nil, expiries: [String]) -> Data {
    let availableCount = available ?? expiries.count
    let rows = expiries.map {
        "{\"id\":\"discard-me\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"granted_at\":\"2027-01-01T00:00:00Z\",\"expires_at\":\"\($0)\"}"
    }.joined(separator: ",")
    return Data("{\"credits\":[\(rows)],\"available_count\":\(availableCount)}".utf8)
}

private func resetCreditSummary(
    count: Int,
    observedAt: TimeInterval,
    coverage: ProviderResetCreditCoverage = .countOnly,
    expiry: TimeInterval? = nil
) -> ProviderResetCreditSummary {
    ProviderResetCreditSummary(
        availableCount: count,
        observedAt: Date(timeIntervalSince1970: observedAt),
        coverage: coverage,
        earliestKnownExpiry: expiry.map(Date.init(timeIntervalSince1970:))
    )
}

private func resetCreditReport(
    accountID: String,
    summary: ProviderResetCreditSummary,
    hasLimit: Bool = false,
    status: UsageStatus? = nil
) -> ProviderConnectorReport {
    ProviderConnectorReport(
        provider: .openAI,
        accountID: accountID,
        accountName: accountID,
        generatedAt: Date(timeIntervalSince1970: 200),
        limits: hasLimit ? [UsageLimit(
            provider: .openAI,
            accountID: accountID,
            accountName: accountID,
            label: "Weekly",
            used: 20,
            limit: 100
        )] : [],
        resetCredits: summary,
        status: status
    )
}

private final class StubHTTPClient: ConnectorHTTPClient, @unchecked Sendable {
    private var responses: [ConnectorHTTPResponse]
    private(set) var requests: [ConnectorHTTPRequest] = []

    init(responses: [ConnectorHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return ConnectorHTTPResponse(statusCode: 500, data: Data())
        }
        if responses.count == 1 {
            return responses[0]
        }
        return responses.removeFirst()
    }
}

private actor GatedClaudeHTTPClient: ConnectorHTTPClient {
    private var firstTokenPOSTStarted = false
    private var firstTokenPOSTReleased = false
    private var firstTokenPOSTReleaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var tokenPOSTCount = 0

    func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse {
        if request.method == "POST", request.url == ClaudeOAuthMetadata.tokenEndpoint {
            tokenPOSTCount += 1
            if tokenPOSTCount == 1 {
                firstTokenPOSTStarted = true
                if !firstTokenPOSTReleased {
                    await withCheckedContinuation { continuation in
                        firstTokenPOSTReleaseWaiter = continuation
                    }
                }
            }
            return ConnectorHTTPResponse(
                statusCode: 200,
                data: Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
            )
        }

        guard request.method == "GET", request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage" else {
            return ConnectorHTTPResponse(statusCode: 404, data: Data())
        }
        return ConnectorHTTPResponse(
            statusCode: 200,
            data: Data(#"{"five_hour":{"utilization":1}}"#.utf8)
        )
    }

    func waitUntilFirstTokenPOSTStarts() async -> Bool {
        for _ in 0..<200 {
            if firstTokenPOSTStarted {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return firstTokenPOSTStarted
    }

    func releaseFirstTokenPOST() {
        firstTokenPOSTReleased = true
        firstTokenPOSTReleaseWaiter?.resume()
        firstTokenPOSTReleaseWaiter = nil
    }
}

private actor SnapshotLockTestGate {
    private var started = false
    private var released = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return started
    }

    func waitForRelease() async {
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        released = true
    }
}

private func temporaryProviderConnectorDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-provider-connector-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func codexUsageWithAdditionalLimits(_ limits: [(name: String, feature: String, used: Int)]) -> Data {
    let additional = limits.map { limit in
        """
        {
          "limit_name": "\(limit.name)",
          "metered_feature": "\(limit.feature)",
          "rate_limit": {
            "primary_window": {
              "used_percent": \(limit.used),
              "limit_window_seconds": 18000,
              "reset_at": 1788400000
            }
          }
        }
        """
    }.joined(separator: ",")

    return Data("""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 45, "limit_window_seconds": 18000, "reset_at": 1788393600 }
      },
      "additional_rate_limits": [
        \(additional)
      ]
    }
    """.utf8)
}

private func claudeCredentialsData(
    accessToken: String?,
    refreshToken: String?,
    expiresAt: Date?,
    scopes: [String] = ["user:profile", "user:inference"]
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(ClaudeOAuthCredentials(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        scopes: scopes
    ))
}

private func claudeUsageRefreshResult(
    usage: Data,
    now: Date = Date(timeIntervalSince1970: 1_800_000_000)
) async throws -> ConnectorRefreshResult {
    let credentials = try claudeCredentialsData(
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let connector = ClaudeOAuthUsageConnector(
        accounts: [ClaudeOAuthAccountConfiguration(accountID: "claude-oauth-default", accountName: "Claude")],
        httpClient: StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: usage)]),
        credentialStore: StubCredentialStore(storage: ["claude-oauth-default": credentials])
    )
    return await connector.refresh(now: now)
}

private func googleAntigravityTestAccount() -> GoogleAntigravityAccountConfiguration {
    GoogleAntigravityAccountConfiguration(
        accountID: "google-antigravity-default",
        accountName: "Antigravity"
    )
}

private func googleAntigravityTemporarySnapshotURL() throws -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "context-panel-antigravity-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "Provider Inputs", directoryHint: .isDirectory)
        .appending(path: "antigravity-status-line.json")
}

private func googleAntigravityTemporaryFileURL(in directoryURL: URL) -> URL {
    directoryURL.appending(path: ".antigravity-status-line.json.\(UUID().uuidString).tmp")
}

private func googleAntigravityTestSnapshot(observedAt: Date) -> GoogleAntigravityStatusLineSnapshot {
    GoogleAntigravityStatusLineSnapshot(
        sourceVersion: "1.1.3",
        planTier: "Google AI Pro",
        observedAt: observedAt,
        buckets: [
            GoogleAntigravityStatusLineBucket(
                id: "gemini-3.1-pro-high-5h",
                remainingFraction: 0.75,
                resetsAt: observedAt.addingTimeInterval(3_600)
            ),
        ]
    )
}

private func writeGoogleAntigravityTestFile(
    _ data: Data,
    to url: URL,
    permissions: mode_t = S_IRUSR | S_IWUSR
) throws {
    try data.write(to: url)
    guard chmod(url.path, permissions) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func setGoogleAntigravityTestModificationDate(
    _ date: Date,
    for url: URL,
    noFollow: Bool = false
) throws {
    let seconds = Int(date.timeIntervalSince1970)
    let timestamps = [
        timespec(tv_sec: seconds, tv_nsec: 0),
        timespec(tv_sec: seconds, tv_nsec: 0),
    ]
    let result = timestamps.withUnsafeBufferPointer { buffer in
        utimensat(
            AT_FDCWD,
            url.path,
            buffer.baseAddress,
            noFollow ? AT_SYMLINK_NOFOLLOW : 0
        )
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private struct StubGoogleAntigravitySnapshotLoader: GoogleAntigravityQuotaSnapshotLoading {
    let snapshot: GoogleAntigravityStatusLineSnapshot?
    let error: GoogleAntigravityStatusLineStoreError?

    init(
        snapshot: GoogleAntigravityStatusLineSnapshot? = nil,
        error: GoogleAntigravityStatusLineStoreError? = nil
    ) {
        self.snapshot = snapshot
        self.error = error
    }

    func load() throws -> GoogleAntigravityStatusLineSnapshot? {
        if let error { throw error }
        return snapshot
    }
}

private final class StubCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private var storage: [String: Data]
    private(set) var savedAccountID: String?
    private(set) var savedData: Data?

    init(storage: [String: Data]) {
        self.storage = storage
    }

    func load(accountID: String) throws -> Data? {
        storage[accountID]
    }

    func save(_ data: Data, accountID: String) throws {
        storage[accountID] = data
        savedAccountID = accountID
        savedData = data
    }
}

private final class CountingCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]
    private var storedSaveCount = 0

    init(storage: [String: Data]) {
        self.storage = storage
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
    }

    func load(accountID: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountID]
    }

    func save(_ data: Data, accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountID] = data
        storedSaveCount += 1
    }

    func data(accountID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountID]
    }
}

private struct StubConnector: ProviderConnector {
    let provider: Provider
    let report: ProviderConnectorReport

    func refresh(now: Date) async -> ConnectorRefreshResult {
        ConnectorRefreshResult(generatedAt: now, reports: [report])
    }
}

private func formValues(from body: String) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private func jwtPayload(email: String, name: String, accountID: String, planType: String) -> String {
    let payload: [String: Any] = [
        "email": email,
        "name": name,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": accountID,
            "chatgpt_plan_type": planType,
        ],
    ]
    let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "header.\(base64URLEncoded(payloadData)).signature"
}

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
