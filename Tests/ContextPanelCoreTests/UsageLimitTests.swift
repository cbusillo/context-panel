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

@Test func providersCoverInitialScope() {
    #expect(Provider.allCases == [.openAI, .anthropic, .google])
}
