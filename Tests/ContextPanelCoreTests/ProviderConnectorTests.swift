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
    #expect(http.requests.map { $0.headers["ChatGPT-Account-Id"] } == ["account-a", "account-b"])
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

@Test func googleAntigravityParserGroupsReportedModelQuota() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = #"""
    {
      "models": {
        "gemini-3-pro-high": { "quotaInfo": { "remainingFraction": 0.42, "resetTime": "2026-06-07T12:00:00Z" } },
        "gemini-3-pro-low": { "quotaInfo": { "remainingFraction": 0.51, "resetTime": "2026-06-07T13:00:00Z" } },
        "gemini-3-flash": { "quotaInfo": { "remainingFraction": 0.9, "resetTime": "2026-06-07T14:00:00Z" } },
        "claude-sonnet-4-6": { "quotaInfo": { "remainingFraction": 0.7, "resetTime": "2026-06-08T12:00:00Z" } },
        "gpt-oss-120b": { "quotaInfo": { "remainingFraction": 0.6, "resetTime": "2026-06-08T12:30:00Z" } },
        "veo-3-fast": { "quotaInfo": { "remainingFraction": 0.2, "resetTime": "2026-06-08T13:00:00Z" } },
        "not-a-quota-model": {}
      }
    }
    """#.data(using: .utf8)!

    let limits = try GoogleAntigravityQuotaParser.usageLimits(
        from: payload,
        accountID: "google-account",
        configuredAccountID: "google-antigravity-default",
        accountName: "Antigravity",
        observedAt: observedAt
    )

    #expect(limits.map(\.modelLabel) == ["Gemini Pro", "Gemini Flash", "Claude", "GPT-OSS", "Veo 3 Fast"])
    #expect(limits.map(\.windowLabel) == [
        "Model capacity",
        "Model capacity",
        "Model capacity",
        "Model capacity",
        "Model capacity",
    ])
    #expect(limits.map(\.used) == [58, 10, 30, 40, 80])
    #expect(limits.allSatisfy { $0.provider == .google && $0.unit == .percent && $0.limit == 100 })
    #expect(limits.allSatisfy { $0.configuredAccountID == "google-antigravity-default" })
    #expect(limits[0].resetsAt == ISO8601DateFormatter().date(from: "2026-06-07T12:00:00Z"))
    #expect(limits[0].confidence == .observed)
}

@Test func googleAntigravityParserAcceptsDisplayNamesAndSparseQuotaInfo() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = #"""
    {
      "models": {
        "models/model-a": {
          "displayName": "Gemini 3 Pro",
          "quotaInfo": { "remainingFraction": "0.25", "resetTime": "2026-06-07T12:00:00Z" }
        },
        "models/model-b": {
          "displayName": "Gemini 3 Flash",
          "quotaInfo": { "resetTime": "2026-06-07T13:00:00Z" }
        },
        "models/model-c": {
          "displayName": "Claude Sonnet",
          "quotaInfo": { "remainingFraction": 0.5 }
        }
      }
    }
    """#.data(using: .utf8)!

    let limits = try GoogleAntigravityQuotaParser.usageLimits(
        from: payload,
        accountID: "google-antigravity",
        configuredAccountID: "google-antigravity-default",
        accountName: "Antigravity",
        observedAt: observedAt
    )

    #expect(limits.map(\.modelLabel) == ["Gemini Pro", "Gemini Flash", "Claude"])
    #expect(limits.map(\.used) == [75, 100, 50])
    #expect(limits[1].resetsAt == ISO8601DateFormatter().date(from: "2026-06-07T13:00:00Z"))
}

@Test func googleAntigravityConnectorDiscoversProjectAndFetchesModelQuota() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["https://www.googleapis.com/auth/cloud-platform"]}"#.data(using: .utf8)!
    let project = #"{"cloudaicompanionProject":{"id":"project-a"}}"#.data(using: .utf8)!
    let models = #"""
    {
      "models": {
        "gemini-3-pro-high": { "quotaInfo": { "remainingFraction": 0.25, "resetTime": "2026-06-07T12:00:00Z" } },
        "gemini-3-flash": { "quotaInfo": { "remainingFraction": 1.0, "resetTime": "2026-06-07T13:00:00Z" } }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: project),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let store = StubCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].provider == .google)
    #expect(result.reports[0].status == .healthy)
    #expect(result.reports[0].configuredAccountID == "google-antigravity-default")
    #expect(result.snapshot.limits.map(\.modelLabel) == ["Gemini Pro", "Gemini Flash"])
    #expect(result.snapshot.limits.map(\.used) == [75, 0])
    #expect(http.requests.map(\.url.path) == ["/v1internal:loadCodeAssist", "/v1internal:fetchAvailableModels"])
    #expect(http.requests.map(\.url.absoluteString) == [
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    ])
    #expect(http.requests[0].headers["Authorization"] == "Bearer access-secret")
    #expect(http.requests[0].headers["X-Goog-Api-Client"] == "gl-mac/1.0.0 antigravity-context-panel/1.0.0")
    #expect(http.requests[0].headers["X-Goog-QuotaUser"] == "google-antigravity-default")
    #expect(http.requests[0].headers["Client-Metadata"] == #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#)
    #expect(http.requests[1].headers["X-Goog-Api-Client"] == "gl-mac/1.0.0 antigravity-context-panel/1.0.0")
    #expect(http.requests[1].headers["X-Goog-QuotaUser"] == "google-antigravity-default")
    #expect(http.requests[1].headers["Client-Metadata"] == #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#)
    #expect(http.requests[1].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("project-a") == true)
    #expect(store.savedAccountID == "google-antigravity-default")
    #expect(store.savedData.flatMap {
        try? JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityOAuthCredentials.self, from: $0)
    }?.projectID == "project-a")
}

@Test func googleAntigravityConnectorContinuesWhenProjectCacheWriteFails() async throws {
    let credentials = #"{"accessToken":"access-secret","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":[]}"#.data(using: .utf8)!
    let project = #"{"cloudaicompanionProject":{"id":"project-a"}}"#.data(using: .utf8)!
    let models = #"{"models":{"gemini-3-pro-high":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-06-07T12:00:00Z"}}}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: project),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let store = FailingCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.count == 2)
    #expect(store.saveErrorCount == 1)
}

@Test func googleAntigravityConnectorAcceptsStoredCredentialsWithoutScopes() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","projectID":"project-a"}"#.data(using: .utf8)!
    let token = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.data(using: .utf8)!
    let models = #"""
    {
      "models": {
        "gemini-3-pro-high": { "quotaInfo": { "remainingFraction": 0.25, "resetTime": "2026-06-07T12:00:00Z" } }
      }
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let store = StubCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(result.reports[0].errorMessage == nil)
    #expect(result.snapshot.limits.map(\.modelLabel) == ["Gemini Pro"])
    let savedCredentials = try #require(store.savedData.flatMap {
        try? JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityOAuthCredentials.self, from: $0)
    })
    #expect(savedCredentials.scopes == GoogleAntigravityOAuthMetadata.scopes)
}

@Test func googleAntigravityConnectorReportsUnexpectedCredentialFormatClearly() async throws {
    let credentials = #"{"refreshToken":42}"#.data(using: .utf8)!
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: StubHTTPClient(responses: []),
        credentialStore: StubCredentialStore(storage: ["google-antigravity-default": credentials])
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("unexpected format") == true)
    #expect(result.reports[0].errorMessage?.contains("missing") == false)
}

@Test func googleAntigravityConnectorRefreshesExpiredAccessToken() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":[]}"#.data(using: .utf8)!
    let token = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"https://www.googleapis.com/auth/cloud-platform"}"#.data(using: .utf8)!
    let models = #"{"models":{"gemini-3-pro-high":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-06-07T12:00:00Z"}}}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let store = StubCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount(projectID: "configured-project")],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.map(\.url.host) == ["oauth2.googleapis.com", "cloudcode-pa.googleapis.com"])
    #expect(http.requests[0].headers["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(http.requests[0].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("refresh-secret") == true)
    #expect(http.requests[1].headers["Authorization"] == "Bearer new-access")
    #expect(store.savedAccountID == "google-antigravity-default")
    #expect(store.savedData.flatMap { try? JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityOAuthCredentials.self, from: $0) }?.refreshToken == "new-refresh")
}

@Test func googleAntigravityConnectorReportsInvalidRequestRefreshDetails() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":[]}"#.data(using: .utf8)!
    let error = #"{"error":"invalid_request","error_description":"Token was issued to a different client."}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 400, data: error),
    ])
    let store = StubCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("invalid_request") == true)
    #expect(result.reports[0].errorMessage?.contains("Token was issued to a different client.") == true)
    #expect(result.reports[0].errorMessage?.contains("Sign in again from Settings") == true)
    #expect(store.savedData == nil)
}

@Test func googleAntigravityConnectorReportsMissingClientSecretAsConfigurationError() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2000-01-01T00:00:00Z","scopes":[]}"#.data(using: .utf8)!
    let error = #"{"error":"invalid_request","error_description":"client_secret is missing."}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 400, data: error),
    ])
    let store = StubCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("client secret is not configured") == true)
    #expect(result.reports[0].errorMessage?.contains("client_secret is missing.") == true)
    #expect(result.reports[0].errorMessage?.contains("Sign in again") == false)
    #expect(store.savedData == nil)
}

@Test func googleAntigravityConnectorRefreshesWhenModelAvailabilityIsUnauthorized() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":[],"projectID":"project-a"}"#.data(using: .utf8)!
    let token = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"https://www.googleapis.com/auth/cloud-platform"}"#.data(using: .utf8)!
    let models = #"{"models":{"gemini-3-pro-high":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-06-07T12:00:00Z"}}}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 401, data: Data(#"{"error":"invalid_token"}"#.utf8)),
        ConnectorHTTPResponse(statusCode: 200, data: token),
        ConnectorHTTPResponse(statusCode: 200, data: models),
    ])
    let store = StubCredentialStore(storage: ["google-antigravity-default": credentials])
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: http,
        credentialStore: store
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.map(\.url.host) == ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com", "cloudcode-pa.googleapis.com"])
    #expect(http.requests[2].headers["Authorization"] == "Bearer new-access")
    #expect(store.savedAccountID == "google-antigravity-default")
}

@Test func googleAntigravityConnectorReportsMissingCredentialsWithoutPromptingExternalStores() async throws {
    let connector = GoogleAntigravityQuotaConnector(
        accounts: [googleAntigravityTestAccount()],
        httpClient: StubHTTPClient(responses: []),
        credentialStore: StubCredentialStore(storage: [:])
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].provider == .google)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage == "Google Antigravity is not connected. Sign in to Google from Settings.")
}

@Test func googleAntigravityOAuthFlowBuildsAuthorizeURL() throws {
    let url = try GoogleAntigravityOAuthFlow.authorizationURL(
        codeChallenge: "challenge-value",
        state: "state-value",
        clientID: "google-client-id"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })

    #expect(components.scheme == "https")
    #expect(components.host == "accounts.google.com")
    #expect(components.path == "/o/oauth2/v2/auth")
    #expect(queryItems["client_id"] == "google-client-id")
    #expect(queryItems["response_type"] == "code")
    #expect(queryItems["redirect_uri"] == GoogleAntigravityOAuthFlow.manualRedirectURI)
    #expect(queryItems["code_challenge"] == "challenge-value")
    #expect(queryItems["code_challenge_method"] == "S256")
    #expect(queryItems["state"] == "state-value")
    #expect(queryItems["access_type"] == "offline")
    #expect(queryItems["prompt"] == "consent")
    #expect(queryItems["scope"]?.contains("https://www.googleapis.com/auth/cloud-platform") == true)
}

@Test func googleAntigravityOAuthFlowBuildsLoopbackRedirectURIForAvailablePort() throws {
    #expect(GoogleAntigravityOAuthFlow.callbackPath == "/oauth-callback")
    #expect(GoogleAntigravityOAuthFlow.manualRedirectURI == "http://127.0.0.1:51121/oauth-callback")
    #expect(GoogleAntigravityOAuthFlow.loopbackRedirectURI(port: 49_152) == "http://127.0.0.1:49152/oauth-callback")

    let url = try GoogleAntigravityOAuthFlow.authorizationURL(
        codeChallenge: "challenge-value",
        state: "state-value",
        redirectURI: GoogleAntigravityOAuthFlow.loopbackRedirectURI(port: 49_152),
        clientID: "google-client-id"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
    #expect(redirectURI == "http://127.0.0.1:49152/oauth-callback")
}

@Test func googleAntigravityOAuthFlowNormalizesCallbackURLsAndBuildsTokenBodies() throws {
    let callback = GoogleAntigravityOAuthFlow.normalizedAuthorizationCode(
        from: "http://localhost:51121/oauth-callback?code=callback-code&state=callback-state"
    )
    #expect(callback.code == "callback-code")
    #expect(callback.state == "callback-state")

    let codeBody = String(data: try GoogleAntigravityOAuthFlow.authorizationCodeTokenRequestBody(
        code: GoogleAntigravityAuthorizationCode(code: "code-secret", state: "state-secret"),
        codeVerifier: "verifier-secret",
        clientID: "google-client-id",
        clientSecret: "google-client-secret"
    ), encoding: .utf8)
    #expect(codeBody?.contains("grant_type=authorization_code") == true)
    #expect(codeBody?.contains("code=code-secret") == true)
    #expect(codeBody?.contains("code_verifier=verifier-secret") == true)
    #expect(codeBody?.contains("client_secret=") == true)

    let refreshBody = String(data: try GoogleAntigravityOAuthFlow.refreshTokenRequestBody(
        refreshToken: "refresh-secret",
        clientID: "google-client-id",
        clientSecret: "google-client-secret"
    ), encoding: .utf8)
    #expect(refreshBody?.contains("grant_type=refresh_token") == true)
    #expect(refreshBody?.contains("refresh_token=refresh-secret") == true)
    #expect(refreshBody?.contains("client_id=") == true)
    #expect(refreshBody?.contains("client_secret=") == true)

    let confidentialClientBody = String(data: try GoogleAntigravityOAuthFlow.authorizationCodeTokenRequestBody(
        code: GoogleAntigravityAuthorizationCode(code: "code-secret", state: "state-secret"),
        codeVerifier: "verifier-secret",
        clientID: "google-client-id",
        clientSecret: "configured-secret"
    ), encoding: .utf8)
    #expect(confidentialClientBody?.contains("client_secret=configured-secret") == true)
}

@Test func googleAntigravityOAuthFlowFailsWhenClientIDIsMissing() throws {
    #expect(throws: ConnectorError.self) {
        _ = try GoogleAntigravityOAuthFlow.authorizationURL(
            codeChallenge: "challenge-value",
            state: "state-value",
            clientID: nil
        )
    }

    #expect(throws: ConnectorError.self) {
        _ = try GoogleAntigravityOAuthFlow.refreshTokenRequestBody(
            refreshToken: "refresh-secret",
            clientID: ""
        )
    }
}

@Test func googleAntigravityOAuthMetadataUsesDefaultFallback() {
    #expect(GoogleAntigravityOAuthMetadata.defaultClientID == "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com")
    #expect(GoogleAntigravityOAuthMetadata.clientID != nil)
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
    #expect(result.snapshot.limits.count == 3)
    #expect(result.snapshot.limits.map(\.windowLabel) == ["5-hour", "Weekly", "Weekly"])
    #expect(result.snapshot.limits.map(\.modelLabel) == ["Claude", "Claude", "Sonnet"])
    #expect(result.snapshot.limits.map(\.used) == [9, 12, 14])
    #expect(result.snapshot.limits.allSatisfy { $0.provider == .anthropic && $0.unit == .percent })
    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(http.requests[0].headers["Authorization"] == "Bearer access-secret")
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
    #expect(http.requests[0].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("refresh-secret") == true)
    #expect(http.requests[1].headers["Authorization"] == "Bearer new-access")
    #expect(store.savedAccountID == "claude-oauth-default")
    #expect(store.savedData.flatMap { try? JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: $0) }?.refreshToken == "new-refresh")
}

@Test func claudeOAuthConnectorRefreshesWhenUsageCallIsUnauthorized() async throws {
    let credentials = #"{"accessToken":"old-access","refreshToken":"refresh-secret","expiresAt":"2099-01-01T00:00:00Z","scopes":["user:profile","user:inference"]}"#.data(using: .utf8)!
    let token = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"user:profile user:inference"}"#.data(using: .utf8)!
    let usage = #"{"five_hour":{"utilization":1,"resets_at":"2026-05-14T23:10:00Z"}}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 401, data: Data(#"{"error":"invalid_token"}"#.utf8)),
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
    #expect(http.requests[1].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("refresh-secret") == true)
    #expect(http.requests[2].headers["Authorization"] == "Bearer new-access")
    #expect(store.savedAccountID == "claude-oauth-default")
}

@Test func claudeOAuthConnectorTreatsRefreshRejectionAsReauthRequired() async throws {
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
    #expect(result.reports[0].errorMessage == "Claude OAuth session has expired. Sign in again from Settings.")
    #expect(result.reports[0].errorMessage?.contains("400") == false)
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

private func googleAntigravityTestAccount(projectID: String? = nil) -> GoogleAntigravityAccountConfiguration {
    GoogleAntigravityAccountConfiguration(
        accountID: "google-antigravity-default",
        accountName: "Antigravity",
        clientID: "google-client-id",
        clientSecret: "google-client-secret",
        projectID: projectID
    )
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

private final class FailingCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private let storage: [String: Data]
    private(set) var saveErrorCount = 0

    init(storage: [String: Data]) {
        self.storage = storage
    }

    func load(accountID: String) throws -> Data? {
        storage[accountID]
    }

    func save(_ data: Data, accountID: String) throws {
        saveErrorCount += 1
        throw NSError(domain: "FailingCredentialStore", code: 1)
    }
}

private struct ThrowingCredentialLoader: ProviderCredentialLoading {
    let error: any Error

    func load(accountID: String) throws -> Data? {
        throw error
    }
}

private struct StubConnector: ProviderConnector {
    let provider: Provider
    let report: ProviderConnectorReport

    func refresh(now: Date) async -> ConnectorRefreshResult {
        ConnectorRefreshResult(generatedAt: now, reports: [report])
    }
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
