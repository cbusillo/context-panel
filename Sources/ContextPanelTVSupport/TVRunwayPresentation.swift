import ContextPanelCore
import Foundation

public enum TVPresentationMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case fullDetail
    case projectOnly
    case countsOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fullDetail:
            "Full Detail"
        case .projectOnly:
            "Project Only"
        case .countsOnly:
            "Counts Only"
        }
    }

    public var detail: String {
        switch self {
        case .fullDetail:
            "Show safe account names, exact capacity, windows, and reset timing."
        case .projectOnly:
            "Hide account names and raw totals while keeping percentages, windows, and reset timing."
        case .countsOnly:
            "Show percentages and provider or window status only."
        }
    }
}

public enum TVSyncNoticePolicy {
    public static func shouldShowCloudUnavailable(for remoteLoad: CompanionRemoteSyncLoadResult) -> Bool {
        !remoteLoad.outcome.succeeded
    }
}

public struct TVRunwayPresentation: Equatable, Sendable {
    public let state: WidgetSnapshotState
    public let status: UsageStatus
    public let headline: String
    public let detail: String
    public let generatedAt: Date
    public let sections: [TVProviderRunwaySection]

    public init(
        snapshot: WidgetSnapshot,
        mode: TVPresentationMode,
        isRefreshing: Bool = false,
        now: Date = Date()
    ) {
        state = snapshot.state
        status = isRefreshing ? .loading : snapshot.status
        headline = isRefreshing
            ? "Checking runway"
            : Self.headline(state: snapshot.state, status: snapshot.status)
        detail = Self.detail(snapshot: snapshot, isRefreshing: isRefreshing)
        generatedAt = snapshot.generatedAt
        sections = Provider.allCases.compactMap { provider in
            TVProviderRunwaySection(
                provider: provider,
                snapshot: snapshot,
                mode: mode,
                now: now
            )
        }
    }

    public var isEmpty: Bool {
        sections.isEmpty
    }

    private static func headline(state: WidgetSnapshotState, status: UsageStatus) -> String {
        switch state {
        case .setupNeeded:
            return "Waiting for Mac sync"
        case .stale:
            return "Showing saved runway"
        case .failure:
            return "Runway needs attention"
        case .ready:
            break
        }

        return switch status {
        case .healthy:
            "Agents have runway"
        case .close:
            "Runway is getting tight"
        case .limited:
            "Capacity is limited"
        case .stale:
            "Showing saved runway"
        case .unknown:
            "Some runway is unknown"
        case .failure:
            "A provider needs attention"
        case .loading:
            "Checking runway"
        }
    }

    private static func detail(snapshot: WidgetSnapshot, isRefreshing: Bool) -> String {
        if isRefreshing {
            return snapshot.state == .setupNeeded
                ? "Contacting CloudKit for the first Mac-published snapshot."
                : "Refreshing provider capacity published by your Mac."
        }
        if snapshot.state == .setupNeeded {
            return "Open Context Panel on your Mac to publish the first companion snapshot."
        }
        if snapshot.state == .stale {
            return "The last Mac snapshot is still available, but it may no longer reflect current usage."
        }
        if snapshot.state == .failure {
            return snapshot.message
        }
        return "Provider capacity published by your Mac."
    }
}

public enum TVRunwayLaneKind: String, Codable, Equatable, Sendable {
    case capacity
    case accountStatus
}

public struct TVProviderRunwaySection: Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let status: UsageStatus
    public let lanes: [TVRunwayLane]

    public var id: Provider { provider }

    init?(
        provider: Provider,
        snapshot: WidgetSnapshot,
        mode: TVPresentationMode,
        now: Date
    ) {
        let reports = snapshot.reports.filter { $0.provider == provider }
        let providerLimits = snapshot.limits.filter { $0.provider == provider }
        let mainSummaries = snapshot.usageSnapshot.mostConstrainedMainLimitSummaries
            .filter { $0.provider == provider }
        let fallbackLimits = snapshot.mostConstrainedLimits
            .filter { $0.provider == provider && !$0.isMainLimit }

        let capacityLanes: [TVRunwayLane]
        if !mainSummaries.isEmpty {
            capacityLanes = mainSummaries.map { TVRunwayLane(summary: $0, mode: mode, now: now) }
        } else if !fallbackLimits.isEmpty {
            capacityLanes = fallbackLimits.map { TVRunwayLane(limit: $0, mode: mode, now: now) }
        } else {
            capacityLanes = []
        }

        let reportLanes = reports
            .filter { report in
                !Self.hasMatchingLimit(for: report, in: providerLimits)
                    || !report.status.tvRepresentsCurrentCapacity
            }
            .sorted { lhs, rhs in
                lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
            .map { TVRunwayLane(provider: provider, report: $0, mode: mode) }
        let lanes = capacityLanes + reportLanes
        guard !lanes.isEmpty else { return nil }

        self.provider = provider
        status = (lanes.map(\.status) + reports.map(\.status)).contextPanelWorstStatus
        self.lanes = lanes
    }

    public var trackedWindowCount: Int {
        lanes.filter { $0.kind == .capacity }.count
    }

    public var trackedWindowText: String {
        switch trackedWindowCount {
        case 0:
            "No capacity windows"
        case 1:
            "1 window tracked"
        default:
            "\(trackedWindowCount) windows tracked"
        }
    }

    private static func hasMatchingLimit(
        for report: StoredProviderReport,
        in limits: [UsageLimit]
    ) -> Bool {
        limits.contains { limit in
            if let configuredAccountID = report.configuredAccountID {
                return limit.configuredAccountID == configuredAccountID || limit.accountID == report.accountID
            }
            return limit.accountID == report.accountID
        }
    }
}

public struct TVRunwayLane: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: TVRunwayLaneKind
    public let provider: Provider
    public let title: String
    public let status: UsageStatus
    public let remainingPercent: Int?
    public let capacityRatio: Double?
    public let resetText: String?
    public let accessibilityResetText: String?
    public let exactCapacityText: String?
    public let accountCountText: String?
    public let detailText: String?
    public let accountNames: [String]
    public let metrics: [TVRunwayMetric]

    public var statusText: String {
        status.tvDisplayName
    }

    init(summary: MainLimitSummary, mode: TVPresentationMode, now: Date) {
        id = summary.id
        kind = .capacity
        provider = summary.provider
        title = mode == .countsOnly ? summary.compactDisplayWindowName : summary.displayWindowName
        status = summary.status
        remainingPercent = summary.roundedRemainingPercent
        capacityRatio = summary.remainingCapacityRatio
        resetText = mode == .countsOnly ? nil : summary.resetCountdownText(now: now)
        accessibilityResetText = mode == .countsOnly
            ? nil
            : Self.accessibilityResetText(until: summary.resetsAt, now: now)
        exactCapacityText = mode == .fullDetail
            ? Self.exactCapacityText(remaining: summary.remaining, limit: summary.limit, unit: summary.unit)
            : nil
        accountCountText = mode == .countsOnly ? nil : Self.accountCountText(summary.accountCount)
        detailText = nil
        accountNames = mode == .fullDetail
            ? Array(Set(summary.limits.map(\.accountName))).sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            : []
        metrics = Self.metrics(summary: summary, mode: mode, now: now)
    }

    init(limit: UsageLimit, mode: TVPresentationMode, now: Date) {
        id = limit.id
        kind = .capacity
        provider = limit.provider
        title = mode == .fullDetail
            ? "\(limit.accountName) · \(limit.displayLabel)"
            : limit.displayLabel
        status = limit.status
        remainingPercent = limit.remainingCapacityRatio.map { Int(($0 * 100).rounded()) }
        capacityRatio = limit.remainingCapacityRatio
        resetText = mode == .countsOnly ? nil : Self.compactResetText(until: limit.resetsAt, now: now)
        accessibilityResetText = mode == .countsOnly
            ? nil
            : Self.accessibilityResetText(until: limit.resetsAt, now: now)
        exactCapacityText = mode == .fullDetail
            ? Self.exactCapacityText(remaining: limit.remaining, limit: limit.limit, unit: limit.unit)
            : nil
        accountCountText = mode == .countsOnly ? nil : Self.accountCountText(1)
        detailText = nil
        accountNames = mode == .fullDetail ? [limit.accountName] : []
        metrics = mode == .countsOnly ? [] : [TVRunwayMetric(limit: limit, mode: mode, now: now)]
    }

    init(provider: Provider, report: StoredProviderReport, mode: TVPresentationMode) {
        id = "\(provider.rawValue):report:\(report.configuredAccountID ?? report.accountID)"
        kind = .accountStatus
        self.provider = provider
        title = mode == .fullDetail ? "\(report.accountName) status" : "Account status"
        status = report.status
        remainingPercent = nil
        capacityRatio = nil
        resetText = nil
        accessibilityResetText = nil
        exactCapacityText = nil
        accountCountText = nil
        detailText = "No fresh capacity data"
        accountNames = mode == .fullDetail ? [report.accountName] : []
        metrics = []
    }

    private static func metrics(
        summary: MainLimitSummary,
        mode: TVPresentationMode,
        now: Date
    ) -> [TVRunwayMetric] {
        switch mode {
        case .fullDetail:
            return summary.limits
                .sorted { lhs, rhs in
                    if lhs.accountName != rhs.accountName {
                        return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
                    }
                    return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
                }
                .map { TVRunwayMetric(limit: $0, mode: mode, now: now) }
        case .projectOnly:
            return [
                TVRunwayMetric(
                    id: summary.id,
                    title: summary.displayWindowName,
                    status: summary.status,
                    remainingPercent: summary.roundedRemainingPercent,
                    exactCapacityText: nil,
                    resetText: summary.resetCountdownText(now: now)
                ),
            ]
        case .countsOnly:
            return []
        }
    }

    private static func accountCountText(_ count: Int) -> String {
        count == 1 ? "1 account" : "\(count) accounts"
    }

    fileprivate static func exactCapacityText(
        remaining: Int?,
        limit: Int?,
        unit: UsageUnit?
    ) -> String? {
        guard let remaining, let limit else { return nil }
        let unitText = unit?.tvDisplayName ?? "units"
        return "\(remaining) of \(limit) \(unitText) remaining"
    }

    fileprivate static func compactResetText(until resetDate: Date?, now: Date) -> String? {
        guard let resetDate, resetDate >= now.addingTimeInterval(-60) else { return nil }
        let minutes = max(Int(ceil(resetDate.timeIntervalSince(now) / 60)), 0)
        if minutes < 60 {
            return "Resets in \(minutes)m"
        }
        let hours = Int(ceil(Double(minutes) / 60))
        if hours < 24 {
            return "Resets in \(hours)h"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "Resets in \(days)d" : "Resets in \(days)d \(remainingHours)h"
    }

    private static func accessibilityResetText(until resetDate: Date?, now: Date) -> String? {
        guard let resetDate, resetDate >= now.addingTimeInterval(-60) else { return nil }
        let minutes = max(Int(ceil(resetDate.timeIntervalSince(now) / 60)), 0)
        if minutes < 60 {
            return "Resets in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        let hours = Int(ceil(Double(minutes) / 60))
        if hours < 24 {
            return "Resets in \(hours) \(hours == 1 ? "hour" : "hours")"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        let dayText = "\(days) \(days == 1 ? "day" : "days")"
        guard remainingHours > 0 else { return "Resets in \(dayText)" }
        let hourText = "\(remainingHours) \(remainingHours == 1 ? "hour" : "hours")"
        return "Resets in \(dayText), \(hourText)"
    }
}

public struct TVRunwayMetric: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: UsageStatus
    public let remainingPercent: Int?
    public let exactCapacityText: String?
    public let resetText: String?

    init(
        id: String,
        title: String,
        status: UsageStatus,
        remainingPercent: Int?,
        exactCapacityText: String?,
        resetText: String?
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.remainingPercent = remainingPercent
        self.exactCapacityText = exactCapacityText
        self.resetText = resetText
    }

    init(limit: UsageLimit, mode: TVPresentationMode, now: Date) {
        id = limit.id
        title = mode == .fullDetail
            ? "\(limit.accountName) · \(limit.displayLabel)"
            : limit.displayLabel
        status = limit.status
        remainingPercent = limit.remainingCapacityRatio.map { Int(($0 * 100).rounded()) }
        exactCapacityText = mode == .fullDetail
            ? TVRunwayLane.exactCapacityText(remaining: limit.remaining, limit: limit.limit, unit: limit.unit)
            : nil
        resetText = TVRunwayLane.compactResetText(until: limit.resetsAt, now: now)
    }
}

private extension UsageStatus {
    var tvRepresentsCurrentCapacity: Bool {
        switch self {
        case .healthy, .close, .limited:
            true
        case .failure, .loading, .stale, .unknown:
            false
        }
    }

    var tvDisplayName: String {
        switch self {
        case .healthy:
            "Available"
        case .close:
            "Close to limit"
        case .limited:
            "Limited"
        case .stale:
            "Stale"
        case .unknown:
            "Unknown"
        case .failure:
            "Needs attention"
        case .loading:
            "Refreshing"
        }
    }
}

private extension UsageUnit {
    var tvDisplayName: String {
        switch self {
        case .percent:
            "points"
        case .tokens:
            "tokens"
        case .requests:
            "requests"
        case .credits:
            "credits"
        case .units:
            "units"
        case .unknown:
            "units"
        }
    }
}
