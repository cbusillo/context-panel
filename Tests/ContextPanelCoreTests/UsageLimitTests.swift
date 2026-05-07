import Foundation
import Testing

@testable import ContextPanelCore

@Test func remainingCapacityDoesNotGoBelowZero() {
    let limit = UsageLimit(provider: .openAI, label: "GPT-5", used: 12, limit: 10)

    #expect(limit.remaining == 0)
}

@Test func usageRatioIsCappedAtOne() {
    let limit = UsageLimit(provider: .anthropic, label: "Claude", used: 15, limit: 10)

    #expect(limit.usageRatio == 1)
}

@Test func unknownLimitsHaveUnknownStatus() {
    let limit = UsageLimit(
        provider: .google,
        accountID: "google-personal",
        accountName: "Personal",
        label: "Gemini Pro",
        used: nil,
        limit: nil,
        confidence: .unknown
    )

    #expect(limit.remaining == nil)
    #expect(limit.usageRatio == nil)
    #expect(limit.status == .unknown)
}

@Test func snapshotSortsMostConstrainedFirst() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google-work",
                accountName: "Work",
                label: "Gemini Deep Research",
                used: nil,
                limit: nil,
                confidence: .unknown,
                statusOverride: .failure
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai-team",
                accountName: "Team",
                label: "Image generation",
                used: 49,
                limit: 50,
                confidence: .observed
            )
        ]
    )
    let first = snapshot.mostConstrainedLimits.first

    #expect(first?.label == "Image generation")
    #expect(abs(snapshot.aggregateCapacityRatio - 0.02) < 0.0001)
}

@Test func aggregateCapacityUsesTightestTrackedWindow() {
    let snapshot = UsageSnapshot(
        generatedAt: Date(),
        limits: [
            UsageLimit(provider: .openAI, label: "Weekly", used: 95, limit: 100),
            UsageLimit(provider: .openAI, label: "5-hour", used: 5, limit: 100),
        ]
    )

    #expect(abs(snapshot.aggregateCapacityRatio - 0.05) < 0.0001)
}

@Test func usageLimitSeparatesWindowAndModelLabels() {
    let limit = UsageLimit(
        provider: .openAI,
        accountID: "openai-personal",
        accountName: "Personal",
        label: "Codex 5-hour",
        windowLabel: "5-hour",
        modelLabel: "Codex",
        used: 42,
        limit: 100
    )

    #expect(limit.displayLabel == "5-hour")
    #expect(limit.contextLabel == "Codex · Personal")
}

@Test func providersCoverInitialScope() {
    #expect(Provider.allCases == [.openAI, .anthropic, .google])
}

@Test func usageLimitCanRepresentPercentPressure() {
    let limit = UsageLimit(
        provider: .openAI,
        accountID: "openai-personal",
        accountName: "Personal",
        label: "Codex weekly",
        unit: .percent,
        used: 38,
        limit: 100,
        confidence: .official
    )

    #expect(limit.unit == .percent)
    #expect(limit.remaining == 62)
    #expect(limit.usageRatio == 0.38)
}
