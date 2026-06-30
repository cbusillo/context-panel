import ContextPanelCore
import Foundation

struct WatchLimitDisplay: Identifiable, Sendable {
    let id: String
    let provider: Provider
    let title: String
    let subtitle: String
    let context: String
    let remainingText: String
    let resetText: String?
    let capacityRatio: Double
    let status: UsageStatus

    static func rows(from snapshot: WidgetSnapshot, maximumCount: Int) -> [WatchLimitDisplay] {
        let mainRows = snapshot.usageSnapshot.mostConstrainedMainLimitSummaries.compactMap { summary in
            row(from: summary)
        }
        let mainIDs = Set(mainRows.map(\.id))
        let supplementalRows = snapshot.mostConstrainedLimits.compactMap { limit -> WatchLimitDisplay? in
            guard !limit.isMainLimit else { return nil }
            let row = row(from: limit)
            return mainIDs.contains(row.id) ? nil : row
        }
        return Array((mainRows + supplementalRows).prefix(maximumCount))
    }

    private static func row(from summary: MainLimitSummary) -> WatchLimitDisplay? {
        guard summary.pooledLimit != nil else { return nil }
        let accountText = summary.accountCount == 1 ? "1 account" : "\(summary.accountCount) accounts"
        return WatchLimitDisplay(
            id: "summary:\(summary.id)",
            provider: summary.provider,
            title: summary.provider.displayName,
            subtitle: summary.compactDisplayWindowName,
            context: accountText,
            remainingText: remainingText(remaining: summary.remaining, unit: summary.unit),
            resetText: summary.resetCountdownText,
            capacityRatio: summary.capacityRatio,
            status: summary.status
        )
    }

    private static func row(from limit: UsageLimit) -> WatchLimitDisplay {
        WatchLimitDisplay(
            id: "limit:\(limit.id)",
            provider: limit.provider,
            title: limit.provider.displayName,
            subtitle: limit.displayLabel,
            context: limit.contextLabel.isEmpty ? limit.accountName : limit.contextLabel,
            remainingText: remainingText(remaining: limit.remaining, unit: limit.unit),
            resetText: resetText(for: limit),
            capacityRatio: capacityRatio(for: limit),
            status: limit.status
        )
    }

    private static func capacityRatio(for limit: UsageLimit) -> Double {
        guard let usageRatio = limit.usageRatio else { return 0 }
        return max(1 - usageRatio, 0)
    }

    private static func remainingText(remaining: Int?, unit: UsageUnit?) -> String {
        guard let remaining else { return "?" }
        if unit == .percent { return "\(remaining)%" }
        return "\(remaining)"
    }

    private static func resetText(for limit: UsageLimit) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        if resetsAt < Date().addingTimeInterval(-60) { return "passed" }
        return resetsAt.formatted(.relative(presentation: .numeric))
    }
}
