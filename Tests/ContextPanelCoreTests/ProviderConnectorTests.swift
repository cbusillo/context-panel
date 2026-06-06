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
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 401, data: Data("secret body".utf8))])
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(authPath: "/tmp/openai.json", accountName: "OpenAI")],
        httpClient: http,
        fileLoader: { _ in auth }
    )

    let result = await connector.refresh(now: Date())

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("not authorized") == true)
    #expect(result.reports[0].errorMessage?.contains("Reauthorize") == true)
    #expect(result.reports[0].errorMessage?.contains("secret body") == false)
    #expect(result.snapshot.limits.isEmpty)
}

@Test func geminiConnectorRefreshesQuotaBuckets() async throws {
    let credentials = #"{"refresh_token":"refresh-secret"}"#.data(using: .utf8)!
    let refresh = #"{"access_token":"access-secret"}"#.data(using: .utf8)!
    let load = #"{"cloudaicompanionProject":"project-secret","currentTier":{"name":"Gemini Code Assist"}}"#.data(using: .utf8)!
    let quota = #"""
    {
      "buckets": [
        { "modelId": "gemini-3-flash-preview", "remainingFraction": 0.75, "resetTime": "2026-05-06T16:04:50Z" }
      ]
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: refresh),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Gemini", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in credentials },
        antigravityCredentialSource: nil
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.snapshot.limits.count == 1)
    #expect(result.snapshot.limits[0].provider == .google)
    #expect(result.snapshot.limits[0].label == "gemini-3-flash-preview")
    #expect(result.snapshot.limits[0].used == 25)
    #expect(http.requests.map(\.method) == ["POST", "POST", "POST"])
    #expect(http.requests[2].body.flatMap { String(data: $0, encoding: .utf8) }?.contains("project-secret") == true)
}

@Test func geminiConnectorFallsBackToAntigravityKeychainCredentials() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 404, data: Data()),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/missing-gemini.json", accountName: "Google", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in throw ConnectorError.invalidAuth("missing Gemini OAuth file") },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.count == 1)
    #expect(http.requests.count == 3)
    #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer antigravity-access" })
    #expect(http.requests.allSatisfy { $0.url.host == "daily-cloudcode-pa.googleapis.com" })
}

@Test func geminiConnectorUsesLegacyGeminiWhenOAuthMetadataExists() async throws {
    let localGeminiCredentials = #"{"refresh_token":"legacy-gemini-refresh"}"#.data(using: .utf8)!
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let refresh = #"{"access_token":"legacy-access"}"#.data(using: .utf8)!
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: refresh),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in localGeminiCredentials },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.count == 3)
    #expect(http.requests.map(\.url.host) == [
        "oauth2.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "cloudcode-pa.googleapis.com",
    ])
    #expect(http.requests[1].headers["Authorization"] == "Bearer legacy-access")
}

@Test func geminiConnectorAcceptsAntigravityAccessTokenWithoutExpiry() async throws {
    let localGeminiCredentials = #"{"refresh_token":"legacy-gemini-refresh"}"#.data(using: .utf8)!
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 404, data: Data()),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: http,
        fileLoader: { _ in localGeminiCredentials },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.count == 3)
    #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer antigravity-access" })
    #expect(http.requests.allSatisfy { $0.url.host == "daily-cloudcode-pa.googleapis.com" })
}

@Test func geminiConnectorUsesLegacyGeminiWhenAntigravityTokenIsExpired() async throws {
    let localGeminiCredentials = #"{"refresh_token":"legacy-gemini-refresh"}"#.data(using: .utf8)!
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"expired-access","refresh_token":"antigravity-refresh","expiry":"2000-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let refresh = #"{"access_token":"legacy-access"}"#.data(using: .utf8)!
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: refresh),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in localGeminiCredentials },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.map(\.url.host) == [
        "oauth2.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "cloudcode-pa.googleapis.com",
    ])
}

@Test func geminiConnectorUsesLegacyGeminiWhenAntigravityCredentialIsUnreadable() async throws {
    let localGeminiCredentials = #"{"refresh_token":"legacy-gemini-refresh"}"#.data(using: .utf8)!
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: ThrowingCredentialLoader(error: ConnectorError.invalidAuth("keychain denied"))
    )
    let refresh = #"{"access_token":"legacy-access"}"#.data(using: .utf8)!
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: refresh),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in localGeminiCredentials },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .healthy)
    #expect(result.reports[0].limits.isEmpty == false)
    #expect(http.requests.map(\.url.host) == [
        "oauth2.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "cloudcode-pa.googleapis.com",
    ])
}

@Test func geminiConnectorSurfacesExhaustedAntigravityQuotaAsLimited() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"""
    {
      "quotaBuckets": [
        {
          "modelId": "Gemini 3.5 Flash (Medium)",
          "bucketLabel": "Antigravity daily agent execution",
          "remainingAmount": 0,
          "totalAmount": 100,
          "resetWindow": "daily"
        }
      ]
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 404, data: Data()),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/missing-gemini.json", accountName: "Google", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in throw ConnectorError.invalidAuth("missing Gemini OAuth file") },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    let limit = try #require(result.snapshot.limits.first)
    #expect(result.reports[0].status == .limited)
    #expect(limit.label == "Antigravity daily agent execution")
    #expect(limit.used == 100)
    #expect(limit.limit == 100)
    #expect(limit.status == .limited)
    #expect(http.requests.count == 3)
    #expect(http.requests.allSatisfy { $0.url.host == "daily-cloudcode-pa.googleapis.com" })
}

@Test func geminiConnectorPrefersAntigravityQuotaStatusBuckets() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let quota = #"""
    {
      "bucketInfo": [
        {
          "model": "Gemini 3.5 Flash (Medium)",
          "quotaType": "QUOTA_TYPE_AGENT_EXECUTION",
          "remainingFraction": 0.2,
          "resetTime": "2026-06-06T02:16:00Z"
        }
      ]
    }
    """#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: quota)])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/missing-gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: http,
        fileLoader: { _ in throw ConnectorError.invalidAuth("missing Gemini OAuth file") },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_780_707_600))

    let limit = try #require(result.snapshot.limits.first)
    #expect(result.reports[0].status == .close)
    #expect(limit.label == "Antigravity agent execution")
    #expect(limit.modelLabel == "Gemini 3.5 Flash (Medium)")
    #expect(limit.used == 80)
    #expect(limit.limit == 100)
    #expect(limit.windowLabel == "Hourly")
    #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_780_712_160))
    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.host == "daily-cloudcode-pa.googleapis.com")
    #expect(http.requests[0].url.path == "/v1main:fetchQuotaStatus")
    #expect(http.requests[0].headers["Authorization"] == "Bearer antigravity-access")
}

@Test func geminiConnectorRoutesAntigravityQuotaStatusToDailyHostWhenAccountEndpointIsCustom() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let quota = #"{"bucketInfo":[{"model":"Gemini 3.5 Flash (Medium)","quotaType":"QUOTA_TYPE_AGENT_EXECUTION","remainingFraction":0.2}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [ConnectorHTTPResponse(statusCode: 200, data: quota)])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(
            authPath: "/tmp/missing-gemini.json",
            accountName: "Google",
            codeAssistEndpoint: URL(string: "https://cloudcode-pa.googleapis.com/v1internal")!,
            clientID: "",
            clientSecret: ""
        )],
        httpClient: http,
        fileLoader: { _ in throw ConnectorError.invalidAuth("missing Gemini OAuth file") },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports[0].status == .close)
    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.host == "daily-cloudcode-pa.googleapis.com")
    #expect(http.requests[0].url.path == "/v1main:fetchQuotaStatus")
}

@Test func geminiConnectorFallsBackToLegacyAntigravityQuotaWhenQuotaStatusIsUnavailable() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 404, data: Data()),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: http,
        fileLoader: { _ in Data(#"{"refresh_token":"legacy-gemini-refresh"}"#.utf8) },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    let limit = try #require(result.snapshot.limits.first)
    #expect(result.reports[0].status == .healthy)
    #expect(limit.label == "gemini-3-flash-preview")
    #expect(limit.used == 50)
    #expect(http.requests.map(\.url.path) == [
        "/v1main:fetchQuotaStatus",
        "/v1internal/:loadCodeAssist",
        "/v1internal/:retrieveUserQuota",
    ])
}

@Test func geminiConnectorFallsBackToLegacyAntigravityQuotaWhenQuotaStatusIsRateLimited() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 429, data: Data()),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: http,
        fileLoader: { _ in Data(#"{"refresh_token":"legacy-gemini-refresh"}"#.utf8) },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    let limit = try #require(result.snapshot.limits.first)
    #expect(result.reports[0].status == .healthy)
    #expect(limit.used == 50)
    #expect(http.requests.map(\.url.path) == [
        "/v1main:fetchQuotaStatus",
        "/v1internal/:loadCodeAssist",
        "/v1internal/:retrieveUserQuota",
    ])
}

@Test func geminiConnectorFallsBackToLegacyAntigravityQuotaWhenQuotaStatusHasNoBuckets() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: Data(#"{"bucketInfo":[]}"#.utf8)),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: http,
        fileLoader: { _ in Data(#"{"refresh_token":"legacy-gemini-refresh"}"#.utf8) },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    let limit = try #require(result.snapshot.limits.first)
    #expect(result.reports[0].status == .healthy)
    #expect(limit.used == 50)
    #expect(http.requests.map(\.url.path) == [
        "/v1main:fetchQuotaStatus",
        "/v1internal/:loadCodeAssist",
        "/v1internal/:retrieveUserQuota",
    ])
}

@Test func geminiConnectorPrefersAntigravityWhenGeminiMetadataIsUnavailable() async throws {
    let localGeminiCredentials = #"{"refresh_token":"legacy-gemini-refresh"}"#.data(using: .utf8)!
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"antigravity-access","refresh_token":"antigravity-refresh","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-flash-preview","remainingFraction":0.5}]}"#.data(using: .utf8)!
    let http = StubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 404, data: Data()),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: http,
        fileLoader: { _ in localGeminiCredentials },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports[0].status == .healthy)
    #expect(http.requests.count == 3)
    #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer antigravity-access" })
    #expect(http.requests.allSatisfy { $0.url.host == "daily-cloudcode-pa.googleapis.com" })
}

@Test func geminiConnectorReportsExpiredAntigravityTokenWithoutGeminiMetadata() async throws {
    let antigravityPayload = #"{"auth_method":"consumer","token":{"access_token":"expired-access","refresh_token":"antigravity-refresh","expiry":"2000-05-22T17:00:00.000000000Z"}}"#
    let storedAntigravityPayload = "go-keyring-base64:\(Data(antigravityPayload.utf8).base64EncodedString())"
    let antigravitySource = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(storedAntigravityPayload.utf8),
        ])
    )
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/missing-gemini.json", accountName: "Google", clientID: "", clientSecret: "")],
        httpClient: StubHTTPClient(responses: []),
        fileLoader: { _ in throw ConnectorError.invalidAuth("missing Gemini OAuth file") },
        antigravityCredentialSource: antigravitySource
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .failure)
    #expect(result.reports[0].errorMessage?.contains("Open Antigravity") == true)
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

@Test func claudeConnectorReportsUnknownLiveAllowanceFromLocalStatus() async throws {
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(accountName: "Claude", statsPath: "/tmp/stats.json")],
        fileLoader: { _ in stats },
        fileExists: { path in path == "/tmp/stats.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .unknown)
    #expect(result.snapshot.limits.count == 1)
    #expect(result.snapshot.limits[0].provider == .anthropic)
    #expect(result.snapshot.limits[0].status == .unknown)
}

@Test func claudeConnectorReportsHealthyWhenStatuslineLimitsExist() async throws {
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let cache = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1788397200},"seven_day":{"used_percentage":0,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            statsPath: "/tmp/stats.json",
            rateLimitSnapshotPath: "/tmp/claude-statusline.json",
            rateLimitSnapshotMaximumAge: 60
        )],
        fileLoader: { path in path == "/tmp/claude-statusline.json" ? cache : stats },
        fileExists: { path in path == "/tmp/stats.json" || path == "/tmp/claude-statusline.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_230))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.count == 2)
    #expect(result.snapshot.limits.map(\.windowLabel) == ["5-hour", "Weekly"])
}

@Test func claudeConnectorMarksOldStatuslineLimitsStale() async throws {
    let cache = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1788397200},"seven_day":{"used_percentage":0,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            statsPath: nil,
            rateLimitSnapshotPath: "/tmp/claude-statusline.json",
            rateLimitSnapshotMaximumAge: 60
        )],
        fileLoader: { _ in cache },
        fileExists: { path in path == "/tmp/claude-statusline.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_500))

    #expect(result.reports[0].status == .stale)
    #expect(result.snapshot.limits.map(\.status) == [.stale, .stale])
    #expect(result.snapshot.limits.contains { $0.windowLabel == "Weekly" && $0.used == 0 })
    #expect(result.snapshot.limits[0].note?.contains("stale Claude Code statusline") == true)
}

@Test func claudeConnectorChoosesNewestStatuslineCacheAcrossFallbackPaths() async throws {
    let stale = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1788397200}}}"#.data(using: .utf8)!
    let fresh = #"{"observed_at":1788379800,"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1788397200},"seven_day":{"used_percentage":7,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let primaryPath = "/tmp/claude-primary-statusline.json"
    let fallbackPath = "/tmp/claude-fallback-statusline.json"
    let account = ClaudeAccountConfiguration(
        accountName: "Claude",
        statsPath: nil,
        rateLimitSnapshotPath: primaryPath,
        fallbackRateLimitSnapshotPaths: [fallbackPath],
        rateLimitSnapshotMaximumAge: 60
    )
    let connector = ClaudeLocalStatusConnector(
        accounts: [account],
        fileLoader: { path in path == primaryPath ? stale : fresh },
        fileExists: { path in path == primaryPath || path == fallbackPath }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_830))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.map(\.used) == [5, 7])
}

@Test func claudeConnectorSkipsCorruptStatuslineCacheWhenFallbackIsValid() async throws {
    let corrupt = #"{"observed_at":"not-a-date","rate_limits":{}}"#.data(using: .utf8)!
    let fallback = #"{"observed_at":1788379800,"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1788397200},"seven_day":{"used_percentage":7,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let primaryPath = "/tmp/claude-corrupt-statusline.json"
    let fallbackPath = "/tmp/claude-fallback-statusline.json"
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            statsPath: nil,
            rateLimitSnapshotPath: primaryPath,
            fallbackRateLimitSnapshotPaths: [fallbackPath],
            rateLimitSnapshotMaximumAge: 60
        )],
        fileLoader: { path in path == primaryPath ? corrupt : fallback },
        fileExists: { path in path == primaryPath || path == fallbackPath }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_830))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.map(\.used) == [5, 7])
}

@Test func claudeConnectorUsesUsageEstimateWhenStatuslineCacheIsStale() async throws {
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let cache = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1788397200},"seven_day":{"used_percentage":0,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let blocks = #"{"blocks":[{"isActive":false,"totalTokens":1000},{"isActive":true,"totalTokens":500,"projection":{"totalTokens":1200,"remainingMinutes":30},"models":["claude-sonnet-4-6"]}]}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            statsPath: "/tmp/stats.json",
            rateLimitSnapshotPath: "/tmp/claude-statusline.json",
            rateLimitSnapshotMaximumAge: 60,
            usageBlocksPath: "/tmp/ccusage-blocks.json"
        )],
        fileLoader: { path in
            switch path {
            case "/tmp/claude-statusline.json": cache
            case "/tmp/ccusage-blocks.json": blocks
            default: stats
            }
        },
        fileExists: { path in path == "/tmp/stats.json" || path == "/tmp/claude-statusline.json" || path == "/tmp/ccusage-blocks.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_500))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.count == 1)
    #expect(result.snapshot.limits[0].label == "Claude 5-hour estimate")
    #expect(result.snapshot.limits[0].confidence == .estimated)
    #expect(result.snapshot.limits[0].lastUpdatedAt == Date(timeIntervalSince1970: 1_788_379_500))
}

@Test func claudeConnectorSkipsCorruptUsageBlocksCacheWhenFallbackIsValid() async throws {
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let corrupt = #"{"blocks":"not-an-array"}"#.data(using: .utf8)!
    let fallback = #"{"blocks":[{"isActive":false,"totalTokens":1000},{"isActive":true,"totalTokens":500,"projection":{"totalTokens":1200,"remainingMinutes":30},"models":["claude-sonnet-4-6"]}]}"#.data(using: .utf8)!
    let primaryPath = "/tmp/ccusage-corrupt-blocks.json"
    let fallbackPath = "/tmp/ccusage-fallback-blocks.json"
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            statsPath: "/tmp/stats.json",
            usageBlocksPath: primaryPath,
            fallbackUsageBlocksPaths: [fallbackPath]
        )],
        fileLoader: { path in
            switch path {
            case primaryPath: corrupt
            case fallbackPath: fallback
            default: stats
            }
        },
        fileExists: { path in path == "/tmp/stats.json" || path == primaryPath || path == fallbackPath }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_000))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.count == 1)
    #expect(result.snapshot.limits[0].confidence == .estimated)
    #expect(result.snapshot.limits[0].used == 500)
    #expect(result.snapshot.limits[0].limit == 1000)
}

@Test func claudeConnectorReportsEveryCodeUsageEstimate() async throws {
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let blocks = #"{"blocks":[{"isActive":false,"totalTokens":1000},{"isActive":true,"totalTokens":500,"projection":{"totalTokens":1200,"remainingMinutes":30},"models":["claude-sonnet-4-6"]}]}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            statsPath: "/tmp/stats.json",
            usageBlocksPath: "/tmp/ccusage-blocks.json"
        )],
        fileLoader: { path in path == "/tmp/ccusage-blocks.json" ? blocks : stats },
        fileExists: { path in path == "/tmp/stats.json" || path == "/tmp/ccusage-blocks.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_000))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.count == 1)
    #expect(result.snapshot.limits[0].confidence == .estimated)
    #expect(result.snapshot.limits[0].used == 500)
    #expect(result.snapshot.limits[0].limit == 1000)
    #expect(result.snapshot.limits[0].note?.contains("Every Code/Claude sessions") == true)
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
