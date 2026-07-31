import ContextPanelCore
import Foundation

public enum WatchMetricDirection: Equatable, Sendable {
    case remaining
    case used
}

public struct WatchComplicationContent: Sendable {
    public let limits: [WatchLimitDisplay]
    public let providerAccessFallback: ProviderAccessAlert?

    public static func mainLane(
        from snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        maximumCount: Int
    ) -> WatchComplicationContent {
        content(
            limits: WatchLimitDisplay.mainLaneRows(
                from: snapshot,
                preferences: preferences,
                maximumCount: maximumCount
            ),
            snapshot: snapshot
        )
    }

    public static func inline(
        from snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        maximumCount: Int = 2
    ) -> WatchComplicationContent {
        content(
            limits: WatchLimitDisplay.inlineRows(
                from: snapshot,
                preferences: preferences,
                maximumCount: maximumCount
            ),
            snapshot: snapshot
        )
    }

    private static func content(
        limits: [WatchLimitDisplay],
        snapshot: WidgetSnapshot
    ) -> WatchComplicationContent {
        let hasUsableCapacity = limits.contains { !$0.remainingCapacity.isIndeterminate }
        return WatchComplicationContent(
            limits: limits,
            providerAccessFallback: hasUsableCapacity ? nil : snapshot.primaryProviderAccessAlert
        )
    }
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
    private let isAssumedAfterScheduledReset: Bool
    private let usesPercentageUnit: Bool
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

    public var compactInlineQuantity: String {
        complicationText(remainingCapacity.isIndeterminate ? "?" : remainingText)
    }

    public var compactCircularQuantity: String {
        guard !remainingCapacity.isIndeterminate else { return "?" }
        guard usesPercentageUnit, remainingText.count > 1, remainingText.hasSuffix("%") else {
            return remainingText
        }
        return String(remainingText.dropLast())
    }

    public var exceptionalStatusText: String? {
        switch status {
        case .stale:
            "saved"
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
        if isAssumedAfterScheduledReset { return "assumed reset" }
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
        let assumption = isAssumedAfterScheduledReset
            ? " \(UsagePresentationAssumption.scheduledReset.accessibilityText)."
            : ""
        return "\(identity). \(quantityAndStatus). \(resetAccessibilityText(now: now))\(assumption) \(freshnessAccessibilityText(now: now))"
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
        guard snapshot.state != .setupNeeded else { return [] }

        let summaries = snapshot.usageSnapshot.mainLimitSummaries
        return preferences
            .mainLimitAnswerSelection(from: summaries)
            .saved
            .prefix(maximumCount)
            .compactMap { row(from: $0, snapshot: snapshot) }
    }

    public static func inlineRows(
        from snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        maximumCount: Int = 2
    ) -> [WatchLimitDisplay] {
        guard maximumCount > 0 else { return [] }
        guard snapshot.state != .setupNeeded else { return [] }

        let selection = preferences.mainLimitAnswerSelection(from: snapshot.usageSnapshot.mainLimitSummaries)
        var lanes: [WidgetMainLimitLane] = []
        var representedIDs = Set<String>()
        let compactLanes = [selection.primary].compactMap { $0 }
            + selection.compactSupportingLanes(maximumCount: maximumCount)
        for lane in compactLanes {
            guard representedIDs.insert(lane.id).inserted else { continue }
            lanes.append(lane)
            guard lanes.count < maximumCount else { break }
        }

        return lanes.compactMap { row(from: $0, snapshot: snapshot) }
    }

    private static func row(
        from lane: WidgetMainLimitLane,
        snapshot: WidgetSnapshot
    ) -> WatchLimitDisplay? {
        if let summary = lane.summary,
           let summaryRow = row(from: summary, snapshot: snapshot) {
            return summaryRow
        }
        if let matchingLimit = snapshot.mostConstrainedLimits.first(where: {
                $0.provider == lane.preference.provider
                    && $0.mainLimitWindow == lane.preference.window
            }) {
            return row(from: matchingLimit, snapshot: snapshot)
        }

        let status = providerDisplayStatus(
            source: .unknown,
            provider: lane.provider,
            snapshot: snapshot
        )
        let metrics = metricValues(remainingRatio: nil, usedRatio: nil, status: status)
        return WatchLimitDisplay(
            id: summaryID(provider: lane.provider, window: lane.window),
            provider: lane.provider,
            title: lane.provider.displayName,
            subtitle: lane.window.shortName,
            context: "No current data",
            usedText: "—",
            remainingText: "—",
            remainingCapacity: metrics.remaining,
            usedPressure: metrics.used,
            status: status,
            accessibilityWindow: lane.window.displayName,
            accessibilityContext: "No current data",
            usedAccessibilityText: "usage unknown",
            remainingAccessibilityText: "remaining capacity unknown",
            isAssumedAfterScheduledReset: false,
            usesPercentageUnit: false,
            resetsAt: nil,
            snapshotGeneratedAt: snapshot.generatedAt,
            snapshotState: snapshot.state
        )
    }

    private static func row(from summary: MainLimitSummary, snapshot: WidgetSnapshot) -> WatchLimitDisplay? {
        guard let pooledLimit = summary.lastKnownPooledLimit ?? summary.pooledLimit else { return nil }
        let accountText = summary.accountCount == 1 ? "1 account" : "\(summary.accountCount) accounts"
        let status = providerDisplayStatus(
            source: pooledLimit.status,
            provider: summary.provider,
            snapshot: snapshot
        )
        let capacityStatus = displayStatus(
            source: pooledLimit.status,
            snapshotState: snapshot.state
        )
        let metrics = metricValues(
            remainingRatio: pooledLimit.remainingCapacityRatio,
            usedRatio: pooledLimit.usageRatio,
            status: capacityStatus
        )
        return WatchLimitDisplay(
            id: summaryID(provider: summary.provider, window: summary.window),
            provider: summary.provider,
            title: summary.provider.displayName,
            subtitle: summary.compactDisplayWindowName,
            context: accountText,
            usedText: usedDisplayText(
                used: pooledLimit.used,
                unit: pooledLimit.unit,
                usedPercent: metrics.usedPercent,
                isIndeterminate: metrics.used.isIndeterminate,
                isAssumedAfterScheduledReset: pooledLimit.isAssumedAfterScheduledReset
            ),
            remainingText: remainingDisplayText(
                used: pooledLimit.used,
                limit: pooledLimit.limit,
                unit: pooledLimit.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate,
                isAssumedAfterScheduledReset: pooledLimit.isAssumedAfterScheduledReset
            ),
            remainingCapacity: metrics.remaining,
            usedPressure: metrics.used,
            status: status,
            accessibilityWindow: summary.displayWindowName,
            accessibilityContext: accountText,
            usedAccessibilityText: usedAccessibilityText(
                used: pooledLimit.used,
                limit: pooledLimit.limit,
                unit: pooledLimit.unit,
                usedPercent: metrics.usedPercent,
                isIndeterminate: metrics.used.isIndeterminate,
                isAssumedAfterScheduledReset: pooledLimit.isAssumedAfterScheduledReset
            ),
            remainingAccessibilityText: remainingAccessibilityText(
                used: pooledLimit.used,
                limit: pooledLimit.limit,
                unit: pooledLimit.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate,
                isAssumedAfterScheduledReset: pooledLimit.isAssumedAfterScheduledReset
            ),
            isAssumedAfterScheduledReset: pooledLimit.isAssumedAfterScheduledReset,
            usesPercentageUnit: pooledLimit.unit == .percent,
            resetsAt: pooledLimit.resetsAt,
            snapshotGeneratedAt: snapshot.generatedAt,
            snapshotState: snapshot.state
        )
    }

    private static func summaryID(provider: Provider, window: MainLimitWindow) -> String {
        "summary:\(provider.rawValue):\(window.rawValue)"
    }

    private static func row(from limit: UsageLimit, snapshot: WidgetSnapshot) -> WatchLimitDisplay {
        let status = providerDisplayStatus(
            source: limit.status,
            provider: limit.provider,
            snapshot: snapshot
        )
        let capacityStatus = displayStatus(
            source: limit.status,
            snapshotState: snapshot.state
        )
        let metrics = metricValues(
            remainingRatio: limit.remainingCapacityRatio,
            usedRatio: limit.usageRatio,
            status: capacityStatus
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
                isIndeterminate: metrics.used.isIndeterminate,
                isAssumedAfterScheduledReset: limit.isAssumedAfterScheduledReset
            ),
            remainingText: remainingDisplayText(
                used: limit.used,
                limit: limit.limit,
                unit: limit.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate,
                isAssumedAfterScheduledReset: limit.isAssumedAfterScheduledReset
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
                isIndeterminate: metrics.used.isIndeterminate,
                isAssumedAfterScheduledReset: limit.isAssumedAfterScheduledReset
            ),
            remainingAccessibilityText: remainingAccessibilityText(
                used: limit.used,
                limit: limit.limit,
                unit: limit.unit,
                remainingPercent: metrics.remainingPercent,
                isIndeterminate: metrics.remaining.isIndeterminate,
                isAssumedAfterScheduledReset: limit.isAssumedAfterScheduledReset
            ),
            isAssumedAfterScheduledReset: limit.isAssumedAfterScheduledReset,
            usesPercentageUnit: limit.unit == .percent,
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

    private static func providerDisplayStatus(
        source: UsageStatus,
        provider: Provider,
        snapshot: WidgetSnapshot
    ) -> UsageStatus {
        let accessStatuses = snapshot.reports
            .filter { $0.provider == provider }
            .compactMap(\.accessState.statusContribution)
        let providerStatus = accessStatuses.isEmpty
            ? source
            : ([source] + accessStatuses).contextPanelWorstStatus
        return displayStatus(
            source: providerStatus,
            snapshotState: snapshot.state
        )
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
        isIndeterminate: Bool,
        isAssumedAfterScheduledReset: Bool
    ) -> String {
        guard !isIndeterminate else { return "—" }
        let prefix = isAssumedAfterScheduledReset ? "≈" : ""
        if unit == .percent {
            return usedPercent.map { "\(prefix)\($0)%" } ?? "—"
        }
        guard let used else { return "—" }
        return "\(prefix)\(used)"
    }

    private static func remainingDisplayText(
        used: Int?,
        limit: Int?,
        unit: UsageUnit?,
        remainingPercent: Int?,
        isIndeterminate: Bool,
        isAssumedAfterScheduledReset: Bool
    ) -> String {
        guard !isIndeterminate else { return "—" }
        let prefix = isAssumedAfterScheduledReset ? "≈" : ""
        if unit == .percent {
            return remainingPercent.map { "\(prefix)\($0)%" } ?? "—"
        }
        guard let used, let limit else { return "—" }
        return "\(prefix)\(max(limit - used, 0))"
    }

    private static func usedAccessibilityText(
        used: Int?,
        limit: Int?,
        unit: UsageUnit?,
        usedPercent: Int?,
        isIndeterminate: Bool,
        isAssumedAfterScheduledReset: Bool
    ) -> String {
        guard !isIndeterminate else { return "usage unknown" }
        let prefix = isAssumedAfterScheduledReset ? "approximately " : ""
        if unit == .percent {
            return usedPercent.map { "\(prefix)\($0) percent used" } ?? "usage unknown"
        }
        guard let used else { return "usage unknown" }
        let unitText = accessibilityUnitText(unit)
        guard let limit else { return "\(prefix)\(used) \(unitText) used, total unknown" }
        return "\(prefix)\(used) of \(limit) \(unitText) used"
    }

    private static func remainingAccessibilityText(
        used: Int?,
        limit: Int?,
        unit: UsageUnit?,
        remainingPercent: Int?,
        isIndeterminate: Bool,
        isAssumedAfterScheduledReset: Bool
    ) -> String {
        guard !isIndeterminate else { return "remaining capacity unknown" }
        let prefix = isAssumedAfterScheduledReset ? "approximately " : ""
        if unit == .percent {
            return remainingPercent.map { "\(prefix)\($0) percent remaining" } ?? "remaining capacity unknown"
        }
        if let used, let limit {
            return "\(prefix)\(max(limit - used, 0)) of \(limit) \(accessibilityUnitText(unit)) remaining"
        }
        return remainingPercent.map { "\(prefix)\($0) percent remaining" } ?? "remaining capacity unknown"
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
        if isAssumedAfterScheduledReset { return "Scheduled reset passed." }
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
