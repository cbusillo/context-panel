import Foundation
import Testing
@testable import ContextPanelCore

@MainActor
@Test
func allAccountsRowsIncludeLimitsWithPartialData() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configs = (0..<6).map { index in
        LocalProviderAccountConfiguration(id: "fixture-\(index)", provider: index < 3 ? .openAI : index < 5 ? .anthropic : .google,
            connectorKind: index < 3 ? .codexRateLimits : index < 5 ? .claudeOAuthUsage : .googleAntigravityQuota,
            displayName: ["Personal", "Projects", "Research", "Writing", "Secondary", "Antigravity"][index],
            codexQuotaPath: index < 3 ? "/fixture/account-\(index)/sessions" : nil)
    }
    let limits = configs.prefix(4).flatMap { config in
        ["5-hour", "Weekly"].map { window in
            UsageLimit(provider: config.provider, accountID: config.id, configuredAccountID: config.id,
                accountName: config.displayName, label: window, windowLabel: window, unit: .percent,
                used: config.provider == .openAI ? 45 : 80, limit: 100,
                resetsAt: now.addingTimeInterval(86_400), lastUpdatedAt: now)
        }
    }
    let reports = configs.prefix(4).map { config in
        StoredProviderReport(provider: config.provider, accountID: config.id, configuredAccountID: config.id,
            accountName: config.displayName, generatedAt: now,
            resetCredits: config == configs[0] ? ProviderResetCreditSummary(availableCount: 3, observedAt: now,
                coverage: .complete, earliestKnownExpiry: now.addingTimeInterval(86_400),
                knownExpiries: [1, 8, 15].map { now.addingTimeInterval(Double($0) * 86_400) }) : nil,
            usageCredits: config == configs[0] ? ProviderUsageCreditSummary(hasCredits: true, unlimited: false, balance: 500) : nil,
            status: .healthy, errorMessage: nil)
    }
    let rows = AccountCapacity.rows(configuration: configs, snapshot: UsageSnapshot(generatedAt: now, limits: limits), reports: reports, now: now)
    #expect(rows.prefix(3).allSatisfy { !$0.limits.isEmpty })
}
