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
    #expect(result.snapshot.limits.map(\.accountName) == [
        "first@example.com · pro",
        "first@example.com · pro",
        "second@example.com · pro",
        "second@example.com · pro",
    ])
    #expect(http.requests.map { $0.headers["ChatGPT-Account-Id"] } == ["account-a", "account-b"])
    #expect(Set(result.reports.map(\.accountID)).count == 2)
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
    #expect(payload["scope"] == ClaudeOAuthMetadata.scopes.joined(separator: " "))
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
