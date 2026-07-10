import ContextPanelCore
import Foundation

public struct WatchLimitDisplay: Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let title: String
    public let subtitle: String
    public let context: String
    public let usageText: String
    public let resetText: String?
    public let capacityRatio: Double
    public let pressureRatio: Double
    public let status: UsageStatus

    public static func rows(from snapshot: WidgetSnapshot, maximumCount: Int) -> [WatchLimitDisplay] {
        guard maximumCount > 0 else { return [] }

        var rows: [WatchLimitDisplay] = []
        var representedMainWindows = Set<MainLimitRowKey>()
        let summaryByKey = Dictionary(uniqueKeysWithValues: snapshot.usageSnapshot.mostConstrainedMainLimitSummaries.map { summary in
            (MainLimitRowKey(provider: summary.provider, window: summary.window), summary)
        })

        for limit in snapshot.mostConstrainedLimits where rows.count < maximumCount {
            if let window = limit.mainLimitWindow {
                let key = MainLimitRowKey(provider: limit.provider, window: window)
                guard !representedMainWindows.contains(key) else { continue }
                representedMainWindows.insert(key)
                if let summary = summaryByKey[key], let summaryRow = row(from: summary) {
                    rows.append(summaryRow)
                    continue
                }
            }

            rows.append(row(from: limit))
        }

        for summary in snapshot.usageSnapshot.mostConstrainedMainLimitSummaries where rows.count < maximumCount {
            let key = MainLimitRowKey(provider: summary.provider, window: summary.window)
            guard !representedMainWindows.contains(key), let summaryRow = row(from: summary) else {
                continue
            }
            rows.append(summaryRow)
            representedMainWindows.insert(key)
        }

        return rows
    }

    public static func mainLaneRows(
        from snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        maximumCount: Int
    ) -> [WatchLimitDisplay] {
        guard maximumCount > 0 else { return [] }

        let preferredRows = preferences
            .visibleMainLimitLanes(from: snapshot.usageSnapshot.mainLimitSummaries, maximumCount: maximumCount)
            .compactMap { lane in
                if let summary = lane.summary {
                    return row(from: summary)
                }
                return snapshot.mostConstrainedLimits
                    .first {
                        $0.provider == lane.preference.provider
                            && $0.mainLimitWindow == lane.preference.window
                    }
                    .map(row(from:))
            }
        return preferredRows.isEmpty
            ? rows(from: snapshot, maximumCount: maximumCount)
            : preferredRows
    }

    private static func row(from summary: MainLimitSummary) -> WatchLimitDisplay? {
        guard summary.pooledLimit != nil else { return nil }
        let accountText = summary.accountCount == 1 ? "1 account" : "\(summary.accountCount) accounts"
        let usageRatio = summary.usageRatio
        return WatchLimitDisplay(
            id: summaryID(provider: summary.provider, window: summary.window),
            provider: summary.provider,
            title: summary.provider.displayName,
            subtitle: summary.compactDisplayWindowName,
            context: accountText,
            usageText: usageText(
                used: summary.used,
                unit: summary.unit,
                usageRatio: usageRatio
            ),
            resetText: summary.resetCountdownText,
            capacityRatio: clampedCapacityRatio(summary.capacityRatio),
            pressureRatio: clampedRatio(usageRatio ?? 0),
            status: summary.status
        )
    }

    private static func summaryID(provider: Provider, window: MainLimitWindow) -> String {
        "summary:\(provider.rawValue):\(window.rawValue)"
    }

    private static func row(from limit: UsageLimit) -> WatchLimitDisplay {
        let usageRatio = limit.usageRatio
        let pressureRatio = clampedRatio(usageRatio ?? 0)
        return WatchLimitDisplay(
            id: "limit:\(limit.id)",
            provider: limit.provider,
            title: limit.provider.displayName,
            subtitle: limit.displayLabel,
            context: limit.contextLabel.isEmpty ? limit.accountName : limit.contextLabel,
            usageText: usageText(used: limit.used, unit: limit.unit, usageRatio: usageRatio),
            resetText: resetText(for: limit),
            capacityRatio: capacityRatio(for: limit),
            pressureRatio: pressureRatio,
            status: limit.status
        )
    }

    private static func capacityRatio(for limit: UsageLimit) -> Double {
        guard let usageRatio = limit.usageRatio else { return 0 }
        return clampedCapacityRatio(1 - usageRatio)
    }

    private static func clampedCapacityRatio(_ ratio: Double) -> Double {
        clampedRatio(ratio)
    }

    private static func clampedRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0), 1)
    }

    private static func usageText(
        used: Int?,
        unit: UsageUnit?,
        usageRatio: Double?
    ) -> String {
        if unit == .percent {
            guard let usageRatio else { return "?" }
            return "\(Int((clampedRatio(usageRatio) * 100).rounded()))%"
        }
        guard let used else { return "?" }
        return "\(used)"
    }

    private static func resetText(for limit: UsageLimit) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        if resetsAt < Date().addingTimeInterval(-60) { return "passed" }
        return resetsAt.formatted(.relative(presentation: .numeric))
    }
}

private struct MainLimitRowKey: Hashable {
    let provider: Provider
    let window: MainLimitWindow
}
