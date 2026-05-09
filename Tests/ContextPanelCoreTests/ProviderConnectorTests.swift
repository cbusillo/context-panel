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

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

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

@Test func codexConnectorReadsAuthAccountsFile() async throws {
    let authAccounts = #"""
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
            "id_token": "id-secret-a",
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
            "id_token": "id-secret-b",
            "refresh_token": "refresh-secret-b"
          }
        }
      ]
    }
    """#.data(using: .utf8)!
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

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 2)
    #expect(result.snapshot.limits.count == 4)
    #expect(result.reports.map(\.accountName) == ["OpenAI Code 1", "OpenAI Code 2"])
    #expect(http.requests.map { $0.headers["ChatGPT-Account-Id"] } == ["account-a", "account-b"])
    #expect(Set(result.reports.map(\.accountID)).count == 2)
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
    #expect(result.reports[0].errorMessage?.contains("HTTP 401") == true)
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
        fileLoader: { _ in credentials }
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

@Test func claudeConnectorReportsUnknownLiveAllowanceFromLocalStatus() async throws {
    let auth = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#.data(using: .utf8)!
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(accountName: "Claude", claudeBinary: "claude", statsPath: "/tmp/stats.json")],
        processClient: StubProcessClient(result: ConnectorProcessResult(exitCode: 0, stdout: auth)),
        fileLoader: { _ in stats },
        fileExists: { path in path == "/tmp/stats.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == .unknown)
    #expect(result.snapshot.limits.count == 1)
    #expect(result.snapshot.limits[0].provider == .anthropic)
    #expect(result.snapshot.limits[0].status == .unknown)
    #expect(result.snapshot.limits[0].note?.contains("subscription: pro") == true)
}

@Test func claudeConnectorReportsHealthyWhenStatuslineLimitsExist() async throws {
    let auth = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#.data(using: .utf8)!
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let cache = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1788397200},"seven_day":{"used_percentage":0,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            claudeBinary: "claude",
            statsPath: "/tmp/stats.json",
            rateLimitSnapshotPath: "/tmp/claude-statusline.json",
            rateLimitSnapshotMaximumAge: 60
        )],
        processClient: StubProcessClient(result: ConnectorProcessResult(exitCode: 0, stdout: auth)),
        fileLoader: { path in path == "/tmp/claude-statusline.json" ? cache : stats },
        fileExists: { path in path == "/tmp/stats.json" || path == "/tmp/claude-statusline.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_230))

    #expect(result.reports[0].status == .healthy)
    #expect(result.snapshot.limits.count == 2)
    #expect(result.snapshot.limits.map(\.windowLabel) == ["5-hour", "Weekly"])
}

@Test func claudeConnectorMarksOldStatuslineLimitsStale() async throws {
    let auth = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#.data(using: .utf8)!
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let cache = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1788397200},"seven_day":{"used_percentage":0,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            claudeBinary: "claude",
            statsPath: "/tmp/stats.json",
            rateLimitSnapshotPath: "/tmp/claude-statusline.json",
            rateLimitSnapshotMaximumAge: 60
        )],
        processClient: StubProcessClient(result: ConnectorProcessResult(exitCode: 0, stdout: auth)),
        fileLoader: { path in path == "/tmp/claude-statusline.json" ? cache : stats },
        fileExists: { path in path == "/tmp/stats.json" || path == "/tmp/claude-statusline.json" }
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 1_788_379_500))

    #expect(result.reports[0].status == .stale)
    #expect(result.snapshot.limits.map(\.status) == [.stale, .stale])
    #expect(result.snapshot.limits[0].note?.contains("stale Claude Code statusline") == true)
}

@Test func claudeConnectorUsesUsageEstimateWhenStatuslineCacheIsStale() async throws {
    let auth = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#.data(using: .utf8)!
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let cache = #"{"observed_at":1788379200,"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":1788397200},"seven_day":{"used_percentage":0,"resets_at":1788984000}}}"#.data(using: .utf8)!
    let blocks = #"{"blocks":[{"isActive":false,"totalTokens":1000},{"isActive":true,"totalTokens":500,"projection":{"totalTokens":1200,"remainingMinutes":30},"models":["claude-sonnet-4-6"]}]}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            claudeBinary: "claude",
            statsPath: "/tmp/stats.json",
            rateLimitSnapshotPath: "/tmp/claude-statusline.json",
            rateLimitSnapshotMaximumAge: 60,
            usageBlocksPath: "/tmp/ccusage-blocks.json"
        )],
        processClient: StubProcessClient(result: ConnectorProcessResult(exitCode: 0, stdout: auth)),
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

@Test func claudeConnectorReportsEveryCodeUsageEstimate() async throws {
    let auth = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#.data(using: .utf8)!
    let stats = #"{"version":3,"lastComputedDate":"2026-04-26","dailyActivity":[],"modelUsage":{},"totalSessions":2,"totalMessages":3}"#.data(using: .utf8)!
    let blocks = #"{"blocks":[{"isActive":false,"totalTokens":1000},{"isActive":true,"totalTokens":500,"projection":{"totalTokens":1200,"remainingMinutes":30},"models":["claude-sonnet-4-6"]}]}"#.data(using: .utf8)!
    let connector = ClaudeLocalStatusConnector(
        accounts: [ClaudeAccountConfiguration(
            accountName: "Claude",
            claudeBinary: "claude",
            statsPath: "/tmp/stats.json",
            usageBlocksPath: "/tmp/ccusage-blocks.json"
        )],
        processClient: StubProcessClient(result: ConnectorProcessResult(exitCode: 0, stdout: auth)),
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

private struct StubProcessClient: ConnectorProcessClient {
    let result: ConnectorProcessResult

    func run(executable: String, arguments: [String]) throws -> ConnectorProcessResult {
        result
    }
}

private struct StubConnector: ProviderConnector {
    let provider: Provider
    let report: ProviderConnectorReport

    func refresh(now: Date) async -> ConnectorRefreshResult {
        ConnectorRefreshResult(generatedAt: now, reports: [report])
    }
}
