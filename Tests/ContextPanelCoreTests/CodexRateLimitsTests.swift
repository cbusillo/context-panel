import Foundation
import Testing

@testable import ContextPanelCore

@Test func codexUsagePayloadParserNormalizesPrimarySecondaryAndAdditionalWindows() throws {
    let json = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 45,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 14000,
          "reset_at": 1788393600
        },
        "secondary_window": {
          "used_percent": 36,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 500000,
          "reset_at": 1788998400
        }
      },
      "credits": {
        "has_credits": true,
        "unlimited": false,
        "balance": "0"
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 1,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 1000,
              "reset_at": 1788400000
            },
            "secondary_window": null
          }
        }
      ],
      "rate_limit_reached_type": {
        "type": "workspace_member_usage_limit_reached"
      }
    }
    """#

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8))

    #expect(snapshots.count == 2)
    #expect(snapshots[0].id == "codex")
    #expect(snapshots[0].planType == "pro")
    #expect(snapshots[0].primary?.usedPercent == 45)
    #expect(snapshots[0].primary?.windowMinutes == 300)
    #expect(snapshots[0].secondary?.windowMinutes == 10080)
    #expect(snapshots[0].credits == CodexCreditsSnapshot(hasCredits: true, unlimited: false, balance: "0"))
    #expect(snapshots[0].rateLimitReachedType == .workspaceMemberUsageLimitReached)
    #expect(snapshots[1].id == "codex_bengalfox")
    #expect(snapshots[1].limitName == "GPT-5.3-Codex-Spark")
    #expect(snapshots[1].primary?.usedPercent == 1)
    #expect(snapshots[1].credits == nil)
}

@Test func codexUsagePayloadParserHandlesMissingLimitDetails() throws {
    let json = #"""
    {
      "plan_type": "plus",
      "rate_limit": null,
      "additional_rate_limits": null,
      "credits": null
    }
    """#

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8))

    #expect(snapshots.count == 1)
    #expect(snapshots[0].id == "codex")
    #expect(snapshots[0].planType == "plus")
    #expect(snapshots[0].primary == nil)
    #expect(snapshots[0].secondary == nil)
}

