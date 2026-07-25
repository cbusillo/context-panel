import ContextPanelCore
import Foundation

func makeGoogleAntigravityWeeklyLimits(
    accountID: String,
    accountName: String,
    thirdPartyUsed: Int,
    geminiUsed: Int,
    now: Date,
    statusOverride: UsageStatus? = nil
) -> [UsageLimit] {
    let resetsAt = now.addingTimeInterval(3 * 24 * 3_600 + 5 * 3_600)
    return [
        UsageLimit(
            id: "google:\(accountID):agy:third-party-weekly",
            provider: .google,
            accountID: accountID,
            configuredAccountID: accountID,
            accountName: accountName,
            label: "3p Weekly",
            windowLabel: "Weekly",
            modelLabel: "3p",
            unit: .percent,
            used: thirdPartyUsed,
            limit: 100,
            resetsAt: resetsAt,
            lastUpdatedAt: now,
            confidence: .observed,
            statusOverride: statusOverride
        ),
        UsageLimit(
            id: "google:\(accountID):agy:gemini-weekly",
            provider: .google,
            accountID: accountID,
            configuredAccountID: accountID,
            accountName: accountName,
            label: "Gemini Weekly",
            windowLabel: "Weekly",
            modelLabel: "Gemini",
            unit: .percent,
            used: geminiUsed,
            limit: 100,
            resetsAt: resetsAt,
            lastUpdatedAt: now,
            confidence: .observed,
            statusOverride: statusOverride
        ),
    ]
}
