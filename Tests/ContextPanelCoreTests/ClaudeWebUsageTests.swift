import Foundation
import Testing

@testable import ContextPanelCore

@Test func claudeWebUsageParserBuildsSubscriptionPercentWindows() throws {
    let payload = #"""
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 42.4,
          "resets_at": 1778109600
        },
        "seven_day": {
          "remaining_percentage": 30,
          "resets_at": "2026-05-08T01:00:00Z"
        },
        "seven_day_opus": {
          "utilization": 0.91,
          "resets_at": 1778192400000
        }
      },
      "account_uuid": "1e13c5e0-a592-428d-a051-9fe5d6260e38"
    }
    """#.data(using: .utf8)!

    let limits = try ClaudeWebUsageParser.usageLimits(
        from: payload,
        accountID: "claude-local",
        accountName: "Claude Max",
        observedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(limits.count == 3)
    #expect(limits[0].label == "Claude 5-hour")
    #expect(limits[0].windowLabel == "5-hour")
    #expect(limits[0].used == 42)
    #expect(limits[0].confidence == .observed)
    #expect(limits[1].used == 70)
    #expect(limits[2].modelLabel == "Opus")
    #expect(limits[2].used == 91)
}

@Test func claudeWebUsageSanitizerReturnsOnlyAllowedUsageFields() throws {
    let payload = #"""
    {
      "rate_limits": {
        "five_hour": { "used_percentage": 12, "resets_at": 1778109600 }
      },
      "email": "chris@example.com",
      "organization_uuid": "1e13c5e0-a592-428d-a051-9fe5d6260e38"
    }
    """#.data(using: .utf8)!

    let fields = try ClaudeWebUsageParser.sanitizedUsageFields(from: payload)

    #expect(fields.contains("rate_limits"))
    #expect(fields.contains("rate_limits.five_hour"))
    #expect(fields.contains("rate_limits.five_hour.used_percentage"))
    #expect(!fields.contains { $0.localizedCaseInsensitiveContains("email") })
    #expect(!fields.contains { $0.localizedCaseInsensitiveContains("uuid") })
}
