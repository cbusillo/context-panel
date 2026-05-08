import ContextPanelCore
import Foundation

enum SampleUsageData {
    static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static var snapshot: UsageSnapshot {
        UsageSnapshot(
            generatedAt: referenceNow,
            limits: [
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-personal",
                    accountName: "Personal",
                    label: "GPT-5 5-hour",
                    windowLabel: "5-hour",
                    modelLabel: "GPT-5",
                    unit: .percent,
                    used: 72,
                    limit: 100,
                    resetsAt: referenceNow.addingTimeInterval(12_000),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .manual
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-work",
                    accountName: "Work",
                    label: "GPT-5 Thinking Weekly",
                    windowLabel: "Weekly",
                    modelLabel: "GPT-5 Thinking",
                    unit: .percent,
                    used: 18,
                    limit: 100,
                    resetsAt: referenceNow.addingTimeInterval(86_400),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .estimated,
                    note: "Fast mode looks safe for about 2h."
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-team",
                    accountName: "Team",
                    label: "Image generation Hourly",
                    windowLabel: "Hourly",
                    modelLabel: "Image generation",
                    unit: .percent,
                    used: 49,
                    limit: 100,
                    resetsAt: referenceNow.addingTimeInterval(2_520),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .anthropic,
                    accountID: "anthropic-personal",
                    accountName: "Personal",
                    label: "Claude Opus 5-hour",
                    windowLabel: "5-hour",
                    modelLabel: "Claude Opus",
                    used: 38,
                    limit: 45,
                    resetsAt: referenceNow.addingTimeInterval(4_500),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .official
                ),
                UsageLimit(
                    provider: .anthropic,
                    accountID: "anthropic-work",
                    accountName: "Work",
                    label: "Claude Sonnet Weekly",
                    windowLabel: "Weekly",
                    modelLabel: "Claude Sonnet",
                    unit: .percent,
                    used: 12,
                    limit: 100,
                    resetsAt: referenceNow.addingTimeInterval(21_600),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .official
                ),
                UsageLimit(
                    provider: .google,
                    accountID: "google-personal",
                    accountName: "Personal",
                    label: "Gemini Pro Daily",
                    windowLabel: "Daily",
                    modelLabel: "Gemini Pro",
                    unit: .percent,
                    used: 28,
                    limit: 100,
                    resetsAt: referenceNow.addingTimeInterval(42_000),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .google,
                    accountID: "google-work",
                    accountName: "Work",
                    label: "Gemini Deep Research",
                    modelLabel: "Gemini Deep Research",
                    used: nil,
                    limit: nil,
                    lastUpdatedAt: referenceNow.addingTimeInterval(-21_600),
                    confidence: .unknown,
                    statusOverride: .failure,
                    note: "Last good snapshot 6h ago."
                )
            ]
        )
    }

    static var fastModeForecast: FastModeCapacityPortfolioForecast {
        let forecasts = snapshot.mainLimitSummaries
            .filter { $0.provider == .openAI && $0.unit == .percent }
            .map { summary in
                FastModeCapacityForecast(
                    limitID: summary.id,
                    accountName: "\(summary.provider.displayName) \(summary.window.displayName) pool",
                    providerLimits: summary.limits,
                    now: referenceNow,
                    standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
                    fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
                    reserveUnits: 6,
                    minimumSafeHours: 1
                )
            }
        return FastModeCapacityPortfolioForecast(forecasts: forecasts)
    }
}
