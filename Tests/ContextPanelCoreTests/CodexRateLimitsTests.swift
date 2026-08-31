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

    let limits = codexUsageLimits(
        from: snapshots[0],
        accountID: "acct",
        accountName: "Personal",
        observedAt: Date(timeIntervalSince1970: 0)
    )
    #expect(limits.map(\.windowLabel) == ["5-hour", "Weekly"])
    #expect(limits.first?.modelLabel == "Codex")
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

@Test func codexRateLimitReachedTypeDecodesKnownAndUnknownStrings() throws {
    let cases: [(String, CodexRateLimitReachedType)] = [
        ("rate_limit_reached", .rateLimitReached),
        ("workspace_owner_credits_depleted", .workspaceOwnerCreditsDepleted),
        ("workspace_member_credits_depleted", .workspaceMemberCreditsDepleted),
        ("workspace_owner_usage_limit_reached", .workspaceOwnerUsageLimitReached),
        ("workspace_member_usage_limit_reached", .workspaceMemberUsageLimitReached),
        ("future_provider_value", .unknown),
    ]

    for (rawValue, expected) in cases {
        let decoded = try JSONDecoder().decode(
            CodexRateLimitReachedType.self,
            from: Data("\"\(rawValue)\"".utf8)
        )
        #expect(decoded == expected)
    }
}

@Test func codexUsagePayloadParserPreservesUsageForUnknownReachedType() throws {
    let snapshots = try CodexUsagePayloadParser.snapshots(
        from: Data(codexUsagePayload(rateLimitReachedType: #"{"type":"future_provider_value"}"#).utf8)
    )

    #expect(snapshots.count == 2)
    #expect(snapshots[0].primary?.windowMinutes == 300)
    #expect(snapshots[0].secondary?.windowMinutes == 10080)
    #expect(snapshots[0].credits == CodexCreditsSnapshot(hasCredits: true, unlimited: false, balance: "0"))
    #expect(snapshots[0].rateLimitReachedType == .unknown)
    #expect(snapshots[1].id == "codex_bengalfox")
    #expect(snapshots[1].primary?.usedPercent == 1)
}

@Test func codexUsagePayloadParserDegradesMalformedReachedTypeToUnknown() throws {
    for reachedType in [
        #"{}"#,
        #"{"type":null}"#,
        #"{"type":42}"#,
        #""rate_limit_reached""#,
        "42",
        "[]",
    ] {
        let snapshots = try CodexUsagePayloadParser.snapshots(
            from: Data(codexUsagePayload(rateLimitReachedType: reachedType).utf8)
        )

        #expect(snapshots.count == 2)
        #expect(snapshots[0].rateLimitReachedType == .unknown)
        #expect(snapshots[0].primary?.usedPercent == 45)
    }
}

@Test func codexUsagePayloadParserKeepsAbsentOrNullReachedTypeNil() throws {
    let absent = try CodexUsagePayloadParser.snapshots(from: Data(codexUsagePayload().utf8))
    let explicitNull = try CodexUsagePayloadParser.snapshots(
        from: Data(codexUsagePayload(rateLimitReachedType: "null").utf8)
    )

    #expect(absent[0].rateLimitReachedType == nil)
    #expect(explicitNull[0].rateLimitReachedType == nil)
}

@Test func codexResetCreditCountUsesAuthoritativeAvailableCountAndClampsAtZero() {
    let applicable = Data(#"{"rate_limit_reset_credits":{"available_count":5,"applicable_available_count":2}}"#.utf8)
    let zeroApplicable = Data(#"{"rate_limit_reset_credits":{"available_count":5,"applicable_available_count":0}}"#.utf8)
    let fallback = Data(#"{"rate_limit_reset_credits":{"available_count":5}}"#.utf8)
    let negative = Data(#"{"rate_limit_reset_credits":{"available_count":5,"applicable_available_count":-3}}"#.utf8)
    let malformedApplicable = Data(#"{"rate_limit_reset_credits":{"available_count":5,"applicable_available_count":"unknown"}}"#.utf8)
    let negativeAvailable = Data(#"{"rate_limit_reset_credits":{"available_count":-3,"applicable_available_count":5}}"#.utf8)
    let missing = Data(#"{"available_count":9}"#.utf8)

    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: applicable) == 5)
    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: zeroApplicable) == 5)
    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: fallback) == 5)
    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: negative) == 5)
    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: malformedApplicable) == 5)
    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: negativeAvailable) == 0)
    #expect(CodexUsagePayloadParser.resetCreditAvailableCount(from: missing) == nil)
}

@Test func codexResetCreditDetailsRequireExactTrustworthyTopLevelCoverage() throws {
    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-28T12:00:00Z"))
    let firstExpiry = try #require(ContextPanelDateFormatting.date(from: "2026-07-29T12:00:00Z"))
    let completeSummary = try CodexResetCreditDetailsParser.summary(
        from: resetCreditDetails([
            resetCreditRow(expiresAt: "2026-07-29T12:00:00Z"),
            resetCreditRow(expiresAt: "2026-07-30T12:00:00Z"),
            resetCreditRow(resetType: "future_provider_value", expiresAt: "2026-07-31T12:00:00Z"),
        ], availableCount: 2),
        observedAt: observedAt
    )
    let partialSummary = try CodexResetCreditDetailsParser.summary(
        from: resetCreditDetails([
            resetCreditRow(expiresAt: "2026-07-29T12:00:00Z"),
            resetCreditRow(expiresAt: "2026-07-27T12:00:00Z"),
            resetCreditRow(resetType: "future_provider_value", expiresAt: "2026-07-30T12:00:00Z"),
            resetCreditRow(status: "future-provider-value", expiresAt: "2026-07-30T12:00:00Z"),
        ], availableCount: 2),
        observedAt: observedAt
    )
    let ambiguousSummary = try CodexResetCreditDetailsParser.summary(
        from: resetCreditDetails([
            resetCreditRow(expiresAt: "2026-07-29T12:00:00Z"),
            resetCreditRow(expiresAt: "2026-07-30T12:00:00Z"),
        ], availableCount: 1),
        observedAt: observedAt
    )
    let expiredSummary = try CodexResetCreditDetailsParser.summary(
        from: resetCreditDetails(
            [resetCreditRow(expiresAt: "2026-07-27T12:00:00Z")],
            availableCount: 1
        ),
        observedAt: observedAt
    )
    let negativeSummary = try CodexResetCreditDetailsParser.summary(
        from: resetCreditDetails(
            [resetCreditRow(expiresAt: "2026-07-29T12:00:00Z")],
            availableCount: -1
        ),
        observedAt: observedAt
    )

    #expect((completeSummary.coverage, completeSummary.earliestKnownExpiry) == (.complete, firstExpiry))
    #expect((partialSummary.coverage, partialSummary.earliestKnownExpiry) == (.partial, firstExpiry))
    #expect((ambiguousSummary.coverage, ambiguousSummary.earliestKnownExpiry) == (.countOnly, nil))
    #expect((expiredSummary.coverage, expiredSummary.earliestKnownExpiry) == (.countOnly, nil))
    #expect((negativeSummary.availableCount, negativeSummary.coverage) == (0, .countOnly))
    #expect((try? CodexResetCreditDetailsParser.summary(
        from: Data(#"{"data":{"credits":[]}}"#.utf8),
        observedAt: observedAt
    )) == nil)
    #expect((try? CodexResetCreditDetailsParser.summary(
        from: Data(#"{"credits":null}"#.utf8),
        observedAt: observedAt
    )) == nil)
}

@Test func codexResetCreditDetailsRejectMissingRequiredContractFields() throws {
    let observedAt = try #require(ContextPanelDateFormatting.date(from: "2026-07-28T12:00:00Z"))
    let missingCount = Data(#"{"credits":[]}"#.utf8)
    let missingID = Data(#"{"available_count":1,"credits":[{"reset_type":"codex_rate_limits","status":"available","granted_at":"2026-07-28T00:00:00Z","expires_at":"2026-07-29T00:00:00Z"}]}"#.utf8)
    let missingGrant = Data(#"{"available_count":1,"credits":[{"id":"discard-me","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-07-29T00:00:00Z"}]}"#.utf8)
    let malformedGrant = Data(#"{"available_count":1,"credits":[{"id":"discard-me","reset_type":"codex_rate_limits","status":"available","granted_at":"not-a-date","expires_at":"2026-07-29T00:00:00Z"}]}"#.utf8)

    for payload in [missingCount, missingID, missingGrant, malformedGrant] {
        #expect((try? CodexResetCreditDetailsParser.summary(from: payload, observedAt: observedAt)) == nil)
    }
}

@Test func codexUsagePayloadParserFiltersRetiredModelAdditionalLimitsWhenAvailabilityIsKnown() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
        ("GPT-5.5 Thinking", "gpt-5-5-thinking", 2),
        ("Workspace review", "workspace_review", 3),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-5-thinking", "GPT-5.5 Thinking"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex", "GPT-5.5 Thinking", "Workspace review"])
}

@Test func codexUsagePayloadParserKeepsCodexVariantWhenStandaloneGPTFamilyIsAvailable() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
        ("GPT-5.2-Codex-Legacy", "codex_legacy", 2),
        ("GPT-5.3 Thinking", "gpt-5-3-thinking", 3),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-3", "GPT-5.3"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex", "GPT-5.3-Codex-Spark"])
}

@Test func codexUsagePayloadParserDoesNotTreatMajorOrFullModelNamesAsGPTFamilies() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
    ])
    let availability = CodexModelAvailability(identifiers: ["GPT-5", "GPT-5.3 Instant"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex"])
}

@Test func codexUsagePayloadParserKeepsActiveModelAdditionalLimitsByMeteredFeature() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("Daily Thinking", "gpt-5-5-thinking", 2),
        ("Daily Spark", "codex_bengalfox", 1),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-5-thinking"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex", "Daily Thinking"])
}

@Test func codexUsagePayloadParserKeepsCodexFamilyAdditionalLimitsByMeteredFeature() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("Daily Spark", "gpt-5-3-codex-spark", 1),
        ("Daily Thinking", "gpt-5-3-thinking", 2),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-3"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex", "Daily Spark"])
}

@Test func codexUsagePayloadParserRequiresCodexImmediatelyAfterGPTFamily() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("GPT-5.3-Non-Codex", "daily_non_codex", 1),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-3"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex"])
}

@Test func codexUsagePayloadParserDoesNotFamilyMatchNonASCIIVersions() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("GPT-５.３-Codex-Spark", "codex_bengalfox", 1),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-3"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex"])
}

@Test func codexUsagePayloadParserDropsRetiredModelAdditionalLimitsByMeteredFeature() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("Daily Spark", "codex_bengalfox", 1),
    ])
    let availability = CodexModelAvailability(identifiers: ["gpt-5-5-thinking"])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: availability)

    #expect(snapshots.map(\.displayName) == ["Codex"])
}

@Test func codexUsagePayloadParserKeepsAdditionalLimitsWhenAvailabilityIsUnknown() throws {
    let json = codexUsagePayloadWithAdditionalLimits([
        ("GPT-5.3-Codex-Spark", "codex_bengalfox", 1),
    ])

    let snapshots = try CodexUsagePayloadParser.snapshots(from: Data(json.utf8), modelAvailability: nil)

    #expect(snapshots.map(\.displayName) == ["Codex", "GPT-5.3-Codex-Spark"])
}

@Test func codexModelAvailabilityParserNormalizesModelSlugsAndTitles() throws {
    let json = #"""
    {
      "models": [
        { "slug": "gpt-5-5-thinking", "title": "GPT-5.5 Thinking" },
        { "id": "o3-pro", "display_name": "o3-pro" }
      ]
    }
    """#

    let availability = try CodexModelAvailabilityParser.availability(from: Data(json.utf8))

    #expect(availability.contains(limitName: "GPT-5.5-Thinking"))
    #expect(availability.contains(limitName: "o3 pro"))
    #expect(!availability.contains(limitName: "GPT-5.3-Codex-Spark"))
}

private func resetCreditDetails(_ rows: [String], availableCount: Int) -> Data {
    Data("{\"credits\":[\(rows.joined(separator: ","))],\"available_count\":\(availableCount)}".utf8)
}

private func resetCreditRow(
    resetType: String = "codex_rate_limits",
    status: String = "available",
    expiresAt: String
) -> String {
    "{\"id\":\"discard-me\",\"reset_type\":\"\(resetType)\",\"status\":\"\(status)\",\"granted_at\":\"2026-07-28T00:00:00Z\",\"expires_at\":\"\(expiresAt)\"}"
}

private func codexUsagePayloadWithAdditionalLimits(_ limits: [(name: String, feature: String, used: Int)]) -> String {
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

    return """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": { "used_percent": 45, "limit_window_seconds": 18000, "reset_at": 1788393600 }
      },
      "additional_rate_limits": [
        \(additional)
      ]
    }
    """
}

private func codexUsagePayload(rateLimitReachedType: String? = nil) -> String {
    let reachedTypeProperty = rateLimitReachedType.map {
        ",\n      \"rate_limit_reached_type\": \($0)"
    } ?? ""

    return """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": 45,
          "limit_window_seconds": 18000,
          "reset_at": 1788393600
        },
        "secondary_window": {
          "used_percent": 36,
          "limit_window_seconds": 604800,
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
            "primary_window": {
              "used_percent": 1,
              "limit_window_seconds": 18000,
              "reset_at": 1788400000
            }
          }
        }
      ]\(reachedTypeProperty)
    }
    """
}
