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
                    label: "GPT-5",
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
                    label: "GPT-5 Thinking",
                    used: 18,
                    limit: 40,
                    resetsAt: referenceNow.addingTimeInterval(86_400),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .estimated,
                    note: "Fast mode looks safe for about 2h."
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-team",
                    accountName: "Team",
                    label: "Image generation",
                    used: 49,
                    limit: 50,
                    resetsAt: referenceNow.addingTimeInterval(2_520),
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .anthropic,
                    accountID: "anthropic-personal",
                    accountName: "Personal",
                    label: "Claude Opus",
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
                    label: "Claude Sonnet",
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
                    label: "Gemini Pro",
                    used: nil,
                    limit: nil,
                    lastUpdatedAt: referenceNow.addingTimeInterval(-120),
                    confidence: .unknown,
                    statusOverride: .unknown,
                    note: "Provider does not expose this limit."
                ),
                UsageLimit(
                    provider: .google,
                    accountID: "google-work",
                    accountName: "Work",
                    label: "Gemini Deep Research",
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

    static var fastModeForecast: FastModePortfolioForecast {
        let forecasts = snapshot.limits
            .filter { $0.provider == .openAI && $0.label.contains("GPT-5") }
            .map { limit in
                FastModeForecast(
                    input: FastModeForecastInput(
                        limit: limit,
                        now: referenceNow,
                        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
                        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 12),
                        reserveUnits: 6,
                        minimumSafeHours: 1
                    )
                )
            }
        return FastModePortfolioForecast(forecasts: forecasts)
    }
}
