import ContextPanelCore
import Foundation

public enum WatchMetricDirection: Equatable, Sendable {
    case remaining
    case used
}

public struct WatchLimitDisplay: Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let title: String
    public let subtitle: String
    public let context: String
    public let usedText: String
    public let remainingText: String
    public let remainingCapacity: MetricProgress
    public let usedPressure: MetricProgress
    public let status: UsageStatus
    private let accessibilityWindow: String
    private let accessibilityContext: String
    private let usedAccessibilityText: String
    private let remainingAccessibilityText: String
    private let resetsAt: Date?
    private let snapshotGeneratedAt: Date
    private let snapshotState: WidgetSnapshotState

    public var usedTextLabeled: String {
        usedPressure.isIndeterminate ? "usage unknown" : "\(usedText) used"
    }

    public var remainingTextLabeled: String {
        remainingCapacity.isIndeterminate ? "remaining unknown" : "\(remainingText) left"
    }

    public var remainingComplicationText: String {
        complicationText(remainingCapacity.isIndeterminate ? "unknown" : remainingTextLabeled)
    }

    public var remainingInlineText: String {
        complicationText(remainingCapacity.isIndeterminate ? "capacity unknown" : remainingTextLabeled)
    }

    public var exceptionalStatusText: String? {
        switch status {
        case .stale:
            "stale"
        case .failure:
            "failed"
        case .loading:
            "refreshing"
        case .healthy, .close, .limited, .unknown:
            nil
        }
    }

    public var resetText: String? {
        resetText(now: Date())
    }

    public func resetText(now: Date) -> String? {
        guard let resetsAt else { return nil }
        return Self.compactResetText(until: resetsAt, now: now)
    }

    public func accessibilitySentence(direction: WatchMetricDirection, now: Date = Date()) -> String {
        var identityParts = [title]
        if accessibilityWindow != title {
            identityParts.append(accessibilityWindow)
        }
        if !accessibilityContext.isEmpty {
            identityParts.append(accessibilityContext)
        }
        let identity = identityParts
            .joined(separator: ", ")
        let isIndeterminate = direction == .remaining
            ? remainingCapacity.isIndeterminate
            : usedPressure.isIndeterminate
        let quantity = direction == .remaining ? remainingAccessibilityText : usedAccessibilityText
        let quantityAndStatus = isIndeterminate && status == .unknown
            ? quantity
            : "\(quantity), \(statusText)"
        return "\(identity). \(quantityAndStatus). \(resetAccessibilityText(now: now)) \(freshnessAccessibilityText(now: now))"
    }

    private func complicationText(_ quantity: String) -> String {
        guard let exceptionalStatusText else { return quantity }
        return "\(quantity) · \(exceptionalStatusText)"
    }

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
                if let summary = summaryByKey[key], let summaryRow = row(from: summary, snapshot: snapshot) {
                    rows.append(summaryRow)
                    continue
                }
            }

            rows.append(row(from: limit, snapshot: snapshot))
        }

        for summary in snapshot.usageSnapshot.mostConstrainedMainLimitSummaries where rows.count < maximumCount {
            let key = MainLimitRowKey(provider: summary.provider, window: summary.window)
            guard !representedMainWindows.contains(key), let summaryRow = row(from: summary, snapshot: snapshot) else {
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
                if let summary = lane.summary,
                   let summaryRow = row(from: summary, snapshot: snapshot) {
                    return summaryRow
                }
                return snapshot.mostConstrainedLimits
                    .first {
                        $0.provider == lane.preference.provider
                            && $0.mainLimitWindow == lane.preference.window
                    }
                    .map { row(from: $0, snapshot: snapshot) }
            }
        return preferredRows.isEmpty
            ? rows(from: snapshot, maximumCount: maximumCount)
            : preferredRows
    }

    private static func row(from summary: MainLimitSummary, snapshot: WidgetSnapshot) -> WatchLimitDisplay? {
        guard summary.pooledLimit != nil else { return nil }
        let accountText = summary.accountCount == 1 ? "1 account" : "\(summary.accountCount) accounts"
        let status = displayStatus(source: summary.status, snapshotState: snapshot.state)
        let metrics = metricValues(
            remainingRatio: summary.remainingCapacityRatio,
            usedRatio: summary.usageRatio,
            status: status
        )
        return WatchLimitDisplay(
            id: summaryID(provider: summary.provider, window: summary.window),
            provider: summary.provider,
            title: summary.provider.displayName,
            subtitle: summary.compactDisplayWindowName,
            context: accountText,
            usedText: usedDisplayText(
                used: summary.used,
                unit: summary.unit,
                usedPercent: metrics.usedPercent,
                isIndeterminate: metrics.used.isIndeterminate
            ),
            remainingText: remainingDisplayText(
                used: summary.used,
                limit: summary.limit,
                unit: summary.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate
            ),
            remainingCapacity: metrics.remaining,
            usedPressure: metrics.used,
            status: status,
            accessibilityWindow: summary.displayWindowName,
            accessibilityContext: accountText,
            usedAccessibilityText: usedAccessibilityText(
                used: summary.used,
                limit: summary.limit,
                unit: summary.unit,
                usedPercent: metrics.usedPercent,
                isIndeterminate: metrics.used.isIndeterminate
            ),
            remainingAccessibilityText: remainingAccessibilityText(
                used: summary.used,
                limit: summary.limit,
                unit: summary.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate
            ),
            resetsAt: summary.resetsAt,
            snapshotGeneratedAt: snapshot.generatedAt,
            snapshotState: snapshot.state
        )
    }

    private static func summaryID(provider: Provider, window: MainLimitWindow) -> String {
        "summary:\(provider.rawValue):\(window.rawValue)"
    }

    private static func row(from limit: UsageLimit, snapshot: WidgetSnapshot) -> WatchLimitDisplay {
        let status = displayStatus(source: limit.status, snapshotState: snapshot.state)
        let metrics = metricValues(
            remainingRatio: limit.remainingCapacityRatio,
            usedRatio: limit.usageRatio,
            status: status
        )
        return WatchLimitDisplay(
            id: "limit:\(limit.id)",
            provider: limit.provider,
            title: limit.provider.displayName,
            subtitle: limit.displayLabel,
            context: limit.contextLabel.isEmpty ? limit.accountName : limit.contextLabel,
            usedText: usedDisplayText(
                used: limit.used,
                unit: limit.unit,
                usedPercent: metrics.usedPercent,
                isIndeterminate: metrics.used.isIndeterminate
            ),
            remainingText: remainingDisplayText(
                used: limit.used,
                limit: limit.limit,
                unit: limit.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate
            ),
            remainingCapacity: metrics.remaining,
            usedPressure: metrics.used,
            status: status,
            accessibilityWindow: limit.mainLimitWindow?.displayName ?? limit.windowLabel ?? limit.displayLabel,
            accessibilityContext: accessibilityContext(for: limit),
            usedAccessibilityText: usedAccessibilityText(
                used: limit.used,
                limit: limit.limit,
                unit: limit.unit,
                usedPercent: metrics.usedPercent,
                isIndeterminate: metrics.used.isIndeterminate
            ),
            remainingAccessibilityText: remainingAccessibilityText(
                used: limit.used,
                limit: limit.limit,
                unit: limit.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate
            ),
            resetsAt: limit.resetsAt,
            snapshotGeneratedAt: snapshot.generatedAt,
            snapshotState: snapshot.state
        )
    }

    private static func metricValues(
        remainingRatio: Double?,
        usedRatio: Double?,
        status: UsageStatus
    ) -> (
        remaining: MetricProgress,
        used: MetricProgress,
        remainingPercent: Int?,
        usedPercent: Int?
    ) {
        let shouldHideValue = status == .unknown
        let remaining = MetricProgress.remainingCapacity(
            remainingRatio: shouldHideValue ? nil : remainingRatio
        )
        let used = MetricProgress.usedPressure(
            usedRatio: shouldHideValue ? nil : usedRatio
        )
        let remainingPercent = remaining.ratio.map { Int(($0 * 100).rounded()) }
        return (
            remaining,
            used,
            remainingPercent,
            remainingPercent.map { max(100 - $0, 0) }
        )
    }

    private static func displayStatus(
        source: UsageStatus,
        snapshotState: WidgetSnapshotState
    ) -> UsageStatus {
        switch snapshotState {
        case .ready:
            source
        case .stale:
            .stale
        case .failure:
            .failure
        case .setupNeeded:
            .unknown
        }
    }

    private static func accessibilityContext(for limit: UsageLimit) -> String {
        let account = "account \(limit.accountName)"
        guard let modelLabel = limit.modelLabel, !modelLabel.isEmpty else { return account }
        return "\(modelLabel), \(account)"
    }

    private static func usedDisplayText(
        used: Int?,
        unit: UsageUnit?,
        usedPercent: Int?,
        isIndeterminate: Bool
    ) -> String {
        guard !isIndeterminate else { return "—" }
        if unit == .percent {
            return usedPercent.map { "\($0)%" } ?? "—"
        }
        guard let used else { return "—" }
        return "\(used)"
    }

    private static func remainingDisplayText(
        used: Int?,
        limit: Int?,
        unit: UsageUnit?,
        remainingPercent: Int?,
        isIndeterminate: Bool
    ) -> String {
        guard !isIndeterminate else { return "—" }
        if unit == .percent {
            return remainingPercent.map { "\($0)%" } ?? "—"
        }
        guard let used, let limit else { return "—" }
        return "\(max(limit - used, 0))"
    }

    private static func usedAccessibilityText(
        used: Int?,
        limit: Int?,
        unit: UsageUnit?,
        usedPercent: Int?,
        isIndeterminate: Bool
    ) -> String {
        guard !isIndeterminate else { return "usage unknown" }
        if unit == .percent {
            return usedPercent.map { "\($0) percent used" } ?? "usage unknown"
        }
        guard let used else { return "usage unknown" }
        let unitText = accessibilityUnitText(unit)
        guard let limit else { return "\(used) \(unitText) used, total unknown" }
        return "\(used) of \(limit) \(unitText) used"
    }

    private static func remainingAccessibilityText(
        used: Int?,
        limit: Int?,
        unit: UsageUnit?,
        remainingPercent: Int?,
        isIndeterminate: Bool
    ) -> String {
        guard !isIndeterminate else { return "remaining capacity unknown" }
        if unit == .percent {
            return remainingPercent.map { "\($0) percent remaining" } ?? "remaining capacity unknown"
        }
        if let used, let limit {
            return "\(max(limit - used, 0)) of \(limit) \(accessibilityUnitText(unit)) remaining"
        }
        return remainingPercent.map { "\($0) percent remaining" } ?? "remaining capacity unknown"
    }

    private static func accessibilityUnitText(_ unit: UsageUnit?) -> String {
        switch unit {
        case .tokens:
            "tokens"
        case .requests:
            "requests"
        case .credits:
            "credits"
        case .percent:
            "percentage points"
        case .units, .unknown, nil:
            "units"
        }
    }

    private var statusText: String {
        switch status {
        case .healthy:
            "available"
        case .close:
            "close to limit"
        case .limited:
            "limited"
        case .stale:
            "stale"
        case .unknown:
            "unknown"
        case .failure:
            "refresh failed"
        case .loading:
            "refreshing"
        }
    }

    private func resetAccessibilityText(now: Date) -> String {
        guard let resetsAt else { return "Reset time unknown." }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        if seconds < -60 { return "Reset just passed." }
        if seconds < 60 { return "Resets now." }
        let minutes = max((seconds + 59) / 60, 1)
        if minutes < 60 {
            return "Resets in \(minutes) \(minutes == 1 ? "minute" : "minutes")."
        }
        let hours = max((minutes + 59) / 60, 1)
        if hours <= 24 {
            return "Resets in \(hours) \(hours == 1 ? "hour" : "hours")."
        }
        let days = max(hours / 24, 1)
        let remainingHours = hours % 24
        guard remainingHours > 0 else {
            return "Resets in \(days) \(days == 1 ? "day" : "days")."
        }
        let dayText = "\(days) \(days == 1 ? "day" : "days")"
        let hourText = "\(remainingHours) \(remainingHours == 1 ? "hour" : "hours")"
        return "Resets in \(dayText) and \(hourText)."
    }

    private func freshnessAccessibilityText(now: Date) -> String {
        let age = Self.accessibilityAgeText(since: snapshotGeneratedAt, now: now)
        switch snapshotState {
        case .ready:
            return "Synced \(age)."
        case .stale:
            return "Showing saved data, last synced \(age)."
        case .failure, .setupNeeded:
            return "Not synced."
        }
    }

    private static func compactResetText(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds < -60 { return "passed" }
        if seconds < 60 { return "now" }
        let minutes = max((seconds + 59) / 60, 1)
        if minutes < 60 { return "\(minutes)m" }
        let hours = max((minutes + 59) / 60, 1)
        if hours <= 24 { return "\(hours)h" }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }

    private static func accessibilityAgeText(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        let days = hours / 24
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
}

private struct MainLimitRowKey: Hashable {
    let provider: Provider
    let window: MainLimitWindow
}
