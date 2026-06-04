import ContextPanelCore
import Foundation

@main
struct PromptCacheTelemetryProbe {
    static func main() {
        let observations = PromptCacheTelemetryReader.everyCodeUsageObservations()
        let summary = PromptCacheSummary(observations: observations)
        print("prompt-cache observations: \(observations.count)")
        if let rate = summary.tokenWeightedHitRate {
            print("token-weighted hit rate: \(Int((rate * 100).rounded()))%")
        } else {
            print("token-weighted hit rate: unavailable")
        }
        if let latest = summary.latest {
            print("latest: \(latest.windowLabel) \(latest.tokens.cachedInputTokens ?? 0)/\(latest.tokens.inputTokens)")
        }
    }
}
