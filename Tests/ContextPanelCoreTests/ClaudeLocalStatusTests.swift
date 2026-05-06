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
