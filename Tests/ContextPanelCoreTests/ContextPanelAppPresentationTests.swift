import Foundation
import Testing

@testable import ContextPanelApp
@testable import ContextPanelCore

@Test func appProviderStatusIncludesBlockedAccessBeyondHealthyCapacity() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let summary = try #require(UsageSnapshot(
        generatedAt: generatedAt,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "blocked-claude",
                accountName: "Blocked Claude",
                label: "Claude weekly",
                windowLabel: "Weekly",
                modelLabel: "Claude",
                unit: .percent,
                used: 45,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(86_400),
                lastUpdatedAt: generatedAt,
                confidence: .observed
            ),
        ]
    ).mainLimitSummaries.first)
    let alert = providerAccessAlert(
        kind: .blockedUntilReset,
        resetsAt: generatedAt.addingTimeInterval(3_600)
    )

    #expect(summary.status == .healthy)
    let status = providerStatusIncludingAccessAlerts(
        provider: .anthropic,
        baseStatuses: [summary.status],
        alerts: [alert]
    )
    #expect(status == .limited)
    #expect(summary.detailRemainingAccessibilityValue(status: status).contains("limited"))
    #expect(summary.usedPressureAccessibilityValue(status: status).contains("limited"))
    #expect(summary.pooledCapacityAccessibilityValue(updatedText: "just now", status: status).contains("limited"))
}

@Test func appProviderStatusKeepsFallbackAndDegradedAsWarnings() {
    let paidFallback = providerAccessAlert(kind: .paidFallbackActive)
    let degraded = providerAccessAlert(kind: .degraded)

    #expect(providerStatusIncludingAccessAlerts(
        provider: .anthropic,
        baseStatuses: [.healthy],
        alerts: [paidFallback]
    ) == .close)
    #expect(providerStatusIncludingAccessAlerts(
        provider: .anthropic,
        baseStatuses: [.healthy],
        alerts: [degraded]
    ) == .close)
    #expect(providerStatusIncludingAccessAlerts(
        provider: .google,
        baseStatuses: [.healthy],
        alerts: [paidFallback, degraded]
    ) == .healthy)
}

@Test func openAIAccountPresentationKeepsResolvedAccountsUnderSharedConfigurationDistinct() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accountIDs = ["resolved-a", "resolved-b", "resolved-c"]
    let limits = accountIDs.enumerated().map { index, accountID in
        UsageLimit(
            provider: .openAI,
            accountID: accountID,
            configuredAccountID: "configured-openai",
            accountName: "OpenAI Account \(index + 1)",
            label: "Codex Weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 20 + index,
            limit: 100,
            resetsAt: now.addingTimeInterval(3 * 60 * 60),
            lastUpdatedAt: now,
            confidence: .observed
        )
    }
    let report = StoredProviderReport(
        provider: .openAI,
        accountID: "resolved-b",
        configuredAccountID: "configured-openai",
        accountName: "OpenAI Account 2",
        generatedAt: now,
        resetCredits: ProviderResetCreditSummary(
            availableCount: 1,
            observedAt: now,
            coverage: .complete,
            earliestKnownExpiry: now.addingTimeInterval(86_400)
        ),
        status: .healthy,
        errorMessage: nil
    )
    let summaries = UsageSnapshot(generatedAt: now, limits: limits).mainLimitSummaries

    let accounts = OpenAIAccountLimitSummary.accounts(from: summaries, reports: [report])

    #expect(accounts.count == 3)
    #expect(Set(accounts.map(\.accountID)) == Set(accountIDs))
    #expect(accounts.allSatisfy { account in
        account.limits.map(\.accountID) == [account.accountID]
    })
}

private func providerAccessAlert(
    kind: ProviderAccessState.Kind,
    resetsAt: Date? = nil
) -> ProviderAccessAlert {
    ProviderAccessAlert(
        provider: .anthropic,
        accountID: "claude",
        configuredAccountID: "claude",
        accountName: "Claude",
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        accessState: ProviderAccessState(kind: kind, resetsAt: resetsAt)
    )
}
