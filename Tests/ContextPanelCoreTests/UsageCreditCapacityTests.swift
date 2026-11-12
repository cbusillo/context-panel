import Foundation
import Testing
@testable import ContextPanelCore

private let creditNow = Date(timeIntervalSince1970: 1_800_000_000)

private func creditReading(hoursAgo: Double, balance: Double, expiry: Date? = nil, used: Int = 100) -> StoredUsageSnapshot {
    let at = creditNow.addingTimeInterval(-hoursAgo * 3_600)
    let limit = UsageLimit(provider: .openAI, accountID: "sample", accountName: "Sample",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: used, limit: 100,
        resetsAt: creditNow.addingTimeInterval(86_400), lastUpdatedAt: at)
    return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: [limit]), reports: [
        StoredProviderReport(provider: .openAI, accountID: "sample", accountName: "Sample", generatedAt: at,
            usageCredits: ProviderUsageCreditSummary(hasCredits: balance > 0, unlimited: false, balance: balance, expiresAt: expiry),
            status: .healthy, errorMessage: nil)
    ])
}

@Test func creditCapacityMeasuresSpendAndRestartsAfterATopUp() throws {
    let current = creditReading(hoursAgo: 0, balance: 80)
    let history = [creditReading(hoursAgo: 4, balance: 120), creditReading(hoursAgo: 2, balance: 100)]
    let capacity = UsageCreditCapacity.make(stored: current, history: history,
        resolve: ProviderRefillDetector.localAccountID, entered: [:])
    let value = try #require(capacity.values.first)
    #expect(value.runwayHours == 8)
    let toppedUp = UsageCreditCapacity.make(stored: creditReading(hoursAgo: 0, balance: 200), history: history,
        resolve: ProviderRefillDetector.localAccountID, entered: [:])
    #expect(toppedUp.values.first?.runwayHours == nil)
}

@Test func creditCapacityUsesTheReportedExpiryBeforeSettingsAndKeepsAccountIdentityOpaque() throws {
    let reported = creditNow.addingTimeInterval(3_600)
    let entered = creditNow.addingTimeInterval(86_400)
    let resolve: ProviderRefillDetector.AccountResolver = { _ in "openai-0123456789abcdef" }
    let current = creditReading(hoursAgo: 0, balance: 100, expiry: reported)
    let capacity = UsageCreditCapacity.make(stored: current, history: [], resolve: resolve, entered: [.openAI: entered])
    #expect(capacity.values.first?.expiresAt == reported)
    let fallback = UsageCreditCapacity.make(stored: creditReading(hoursAgo: 0, balance: 100), history: [],
        resolve: resolve, entered: [.openAI: entered])
    #expect(fallback.values.first?.expiresAt == entered)
    let evidence = UseNextEvidence(credits: capacity)
    #expect(evidence.excludingAccounts(Set(capacity.keys)).credits?.isEmpty == true)
    let moved = evidence.reidentifyingAccounts(using: ["openai-0123456789abcdef": "openai-fedcba9876543210"])
    #expect(moved.credits?["openai-fedcba9876543210"]?.available == true)
}

@Test func creditCapacityExcludesHoursBeforeQuotaReachedZero() throws {
    let current = creditReading(hoursAgo: 0, balance: 70)
    let history = [creditReading(hoursAgo: 24, balance: 100, used: 20), creditReading(hoursAgo: 3, balance: 100)]
    let value = try #require(UsageCreditCapacity.make(stored: current, history: history,
        resolve: ProviderRefillDetector.localAccountID, entered: [:]).values.first)
    #expect(value.runwayHours == 7)
    let restored = try JSONDecoder().decode(UsageCreditCapacity.self, from: JSONEncoder().encode(value))
    #expect(restored == value)
}
