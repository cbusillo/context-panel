import ContextPanelCore
import Foundation

public struct WatchLimitDisplay: Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let title: String
    public let subtitle: String
    public let context: String
    public let remainingText: String
    public let resetText: String?
    public let capacityRatio: Double
    public let status: UsageStatus

    public static func rows(from snapshot: WidgetSnapshot, maximumCount: Int) -> [WatchLimitDisplay] {
        let mainRows = snapshot.usageSnapshot.mostConstrainedMainLimitSummaries.compactMap { summary in
            row(from: summary)
        }
        let mainIDs = Set(mainRows.map(\.id))
        let supplementalRows = snapshot.mostConstrainedLimits.compactMap { limit -> WatchLimitDisplay? in
            if let mainLimitWindow = limit.mainLimitWindow,
               mainIDs.contains(summaryID(provider: limit.provider, window: mainLimitWindow)) {
                return nil
            }
            let row = row(from: limit)
            return mainIDs.contains(row.id) ? nil : row
        }
        return Array((mainRows + supplementalRows).prefix(maximumCount))
    }

    private static func row(from summary: MainLimitSummary) -> WatchLimitDisplay? {
        guard summary.pooledLimit != nil else { return nil }
        let accountText = summary.accountCount == 1 ? "1 account" : "\(summary.accountCount) accounts"
        return WatchLimitDisplay(
            id: summaryID(provider: summary.provider, window: summary.window),
            provider: summary.provider,
            title: summary.provider.displayName,
            subtitle: summary.compactDisplayWindowName,
            context: accountText,
            remainingText: remainingText(
                remaining: summary.remaining,
                unit: summary.unit,
                capacityRatio: summary.capacityRatio,
                isPooled: true
            ),
            resetText: summary.resetCountdownText,
            capacityRatio: clampedCapacityRatio(summary.capacityRatio),
            status: summary.status
        )
    }

    private static func summaryID(provider: Provider, window: MainLimitWindow) -> String {
        "summary:\(provider.rawValue):\(window.rawValue)"
    }

    private static func row(from limit: UsageLimit) -> WatchLimitDisplay {
        WatchLimitDisplay(
            id: "limit:\(limit.id)",
            provider: limit.provider,
            title: limit.provider.displayName,
            subtitle: limit.displayLabel,
            context: limit.contextLabel.isEmpty ? limit.accountName : limit.contextLabel,
            remainingText: remainingText(remaining: limit.remaining, unit: limit.unit, capacityRatio: capacityRatio(for: limit)),
            resetText: resetText(for: limit),
            capacityRatio: capacityRatio(for: limit),
            status: limit.status
        )
    }

    private static func capacityRatio(for limit: UsageLimit) -> Double {
        guard let usageRatio = limit.usageRatio else { return 0 }
        return clampedCapacityRatio(1 - usageRatio)
    }

    private static func clampedCapacityRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0), 1)
    }

    private static func remainingText(
        remaining: Int?,
        unit: UsageUnit?,
        capacityRatio: Double,
        isPooled: Bool = false
    ) -> String {
        guard let remaining else { return "?" }
        if unit == .percent {
            let normalizedRemaining = isPooled ? Int((clampedCapacityRatio(capacityRatio) * 100).rounded()) : remaining
            return "\(min(max(normalizedRemaining, 0), 100))%"
        }
        return "\(remaining)"
    }

    private static func resetText(for limit: UsageLimit) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        if resetsAt < Date().addingTimeInterval(-60) { return "passed" }
        return resetsAt.formatted(.relative(presentation: .numeric))
    }
}
