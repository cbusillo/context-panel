import Foundation
import Testing

@testable import ContextPanelCore

@Test func claudeAuthStatusParserReducesStatusToNonSecretFields() throws {
    let json = #"""
    {
      "loggedIn": true,
      "authMethod": "claude.ai",
      "apiProvider": "firstParty",
      "email": "friend@example.com",
      "orgId": "org_secret",
      "subscriptionType": "pro"
    }
    """#

    let status = try ClaudeAuthStatusParser.status(from: Data(json.utf8))

    #expect(status.loggedIn)
    #expect(status.authMethod == "claude.ai")
    #expect(status.apiProvider == "firstParty")
    #expect(status.subscriptionType == "pro")
    #expect(status.subscriptionDisplayName == "Claude Pro")
}

@Test func claudeStatsCacheParserSummarizesLocalActivityOnly() throws {
    let json = #"""
    {
      "version": 2,
      "lastComputedDate": "2026-05-06T14:00:00Z",
      "dailyActivity": {
        "2026-05-06": { "messageCount": 5 }
      },
      "modelUsage": {
        "claude-sonnet-4-6": { "inputTokens": 12 },
        "claude-opus-4-6": { "inputTokens": 3 }
      },
      "totalSessions": 7,
      "totalMessages": 42,
      "firstSessionDate": "2026-05-01"
    }
    """#

    let summary = try ClaudeStatsCacheParser.summary(from: Data(json.utf8))

    #expect(summary.version == 2)
    #expect(ContextPanelDateFormatting.string(from: summary.lastComputedDate!) == "2026-05-06T14:00:00Z")
    #expect(summary.totalSessions == 7)
    #expect(summary.totalMessages == 42)
    #expect(summary.modelUsageCount == 2)
    #expect(summary.dailyActivityCount == 1)
}

@Test func claudeStatsCacheParserAcceptsArrayShapedDailyActivity() throws {
    let json = #"""
    {
      "lastComputedDate": "2026-04-26",
      "dailyActivity": [
        { "date": "2026-04-25" },
        { "date": "2026-04-26" }
      ],
      "modelUsage": {},
      "totalSessions": 1,
      "totalMessages": 2
    }
    """#

    let summary = try ClaudeStatsCacheParser.summary(from: Data(json.utf8))

    #expect(ContextPanelDateFormatting.string(from: summary.lastComputedDate!) == "2026-04-26T00:00:00Z")
    #expect(summary.dailyActivityCount == 2)
    #expect(summary.modelUsageCount == 0)
}

@Test func claudeStatsCacheParserAcceptsRateLimitSnapshotWhenPresent() throws {
    let json = #"""
    {
      "lastComputedDate": "2026-05-06T14:00:00Z",
      "rate_limits": {
        "five_hour": {
          "used_percentage": 42.4,
          "resets_at": 1788397200
        },
        "seven_day": {
          "used_percentage": 51.6,
          "resets_at": 1788984000
        }
      }
    }
    """#

    let summary = try ClaudeStatsCacheParser.summary(from: Data(json.utf8))

    #expect(summary.rateLimitSnapshot?.windows.map(\.label) == ["5-hour", "Weekly"])
    #expect(summary.rateLimitSnapshot?.windows.map { Int($0.usedPercent.rounded()) } == [42, 52])
}

@Test func claudeLocalStatusLimitMakesUnknownAllowanceExplicit() {
    let limit = claudeLocalStatusLimits(
        authStatus: ClaudeAuthStatus(
            loggedIn: true,
            authMethod: "claude.ai",
            apiProvider: "firstParty",
            subscriptionType: "pro"
        ),
        statsSummary: nil,
        accountID: "local",
        accountName: "Claude",
        observedAt: Date(timeIntervalSince1970: 0)
    ).first!

    #expect(limit.label == "Claude Pro status")
    #expect(limit.modelLabel == "Claude Code")
    #expect(limit.confidence == .observed)
    #expect(limit.status == .unknown)
    #expect(limit.note?.contains("allowance: not exposed by Claude Code") == true)
}

@Test func claudeStatuslineRateLimitCacheParsesSubscriptionWindows() throws {
    let json = #"""
    {
      "observed_at": 1788379200,
      "rate_limits": {
        "five_hour": {
          "used_percentage": 42.4,
          "resets_at": 1788397200
        },
        "seven_day": {
          "used_percentage": 51.6,
          "resets_at": 1788984000
        }
      }
    }
    """#

    let snapshot = try ClaudeSubscriptionRateLimitCacheParser.snapshot(from: Data(json.utf8))

    #expect(ContextPanelDateFormatting.string(from: snapshot.observedAt) == "2026-09-02T20:00:00Z")
    #expect(snapshot.windows.map(\.label) == ["5-hour", "Weekly"])
    #expect(snapshot.windows.map { Int($0.usedPercent.rounded()) } == [42, 52])
}

@Test func claudeLocalStatusLimitsPrefersStatuslineSubscriptionWindows() {
    let limits = claudeLocalStatusLimits(
        authStatus: ClaudeAuthStatus(
            loggedIn: true,
            authMethod: "claude.ai",
            apiProvider: "firstParty",
            subscriptionType: "pro"
        ),
        statsSummary: nil,
        rateLimitSnapshot: ClaudeSubscriptionRateLimitSnapshot(
            observedAt: Date(timeIntervalSince1970: 10),
            windows: [
                ClaudeSubscriptionRateLimitWindow(
                    label: "5-hour",
                    usedPercent: 42.4,
                    resetsAt: Date(timeIntervalSince1970: 100)
                ),
                ClaudeSubscriptionRateLimitWindow(
                    label: "Weekly",
                    usedPercent: 51.6,
                    resetsAt: Date(timeIntervalSince1970: 200)
                ),
            ]
        ),
        accountID: "local",
        accountName: "Claude",
        observedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(limits.count == 2)
    #expect(limits.map(\.provider) == [.anthropic, .anthropic])
    #expect(limits.map(\.windowLabel) == ["5-hour", "Weekly"])
    #expect(limits.map(\.modelLabel) == ["Claude Pro", "Claude Pro"])
    #expect(limits.map(\.used) == [42, 52])
    #expect(limits.allSatisfy { $0.unit == .percent && $0.limit == 100 && $0.confidence == .observed })
}
