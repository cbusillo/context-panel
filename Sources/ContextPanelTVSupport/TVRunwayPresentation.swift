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
            "Hide account names and exact values while keeping windows and reset timing."
        case .countsOnly:
            "Show provider capacity and status only."
        }
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
        now: Date = Date()
    ) {
        state = snapshot.state
        status = snapshot.status
        headline = Self.headline(state: snapshot.state, status: snapshot.status)
        detail = Self.detail(snapshot: snapshot)
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

    private static func detail(snapshot: WidgetSnapshot) -> String {
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
        let mainSummaries = snapshot.usageSnapshot.mostConstrainedMainLimitSummaries
            .filter { $0.provider == provider }
        let fallbackLimits = snapshot.mostConstrainedLimits
            .filter { $0.provider == provider && !$0.isMainLimit }

        let lanes: [TVRunwayLane]
        if !mainSummaries.isEmpty {
            lanes = mainSummaries.map { TVRunwayLane(summary: $0, mode: mode, now: now) }
        } else if !fallbackLimits.isEmpty {
            lanes = fallbackLimits.map { TVRunwayLane(limit: $0, mode: mode, now: now) }
        } else if let report = reports.first {
            lanes = [TVRunwayLane(provider: provider, report: report)]
        } else {
            return nil
        }

        self.provider = provider
        status = (lanes.map(\.status) + reports.map(\.status)).contextPanelWorstStatus
        self.lanes = lanes
    }
}

public struct TVRunwayLane: Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let title: String
    public let status: UsageStatus
    public let remainingPercent: Int?
    public let capacityRatio: Double?
    public let resetText: String?
    public let exactCapacityText: String?
    public let accountCountText: String?
    public let accountNames: [String]
    public let metrics: [TVRunwayMetric]

    public var statusText: String {
        status.tvDisplayName
    }

    init(summary: MainLimitSummary, mode: TVPresentationMode, now: Date) {
        id = summary.id
        provider = summary.provider
        title = mode == .countsOnly ? summary.compactDisplayWindowName : summary.displayWindowName
        status = summary.status
        remainingPercent = summary.roundedRemainingPercent
        capacityRatio = summary.remainingCapacityRatio
        resetText = mode == .countsOnly ? nil : summary.resetCountdownText(now: now)
        exactCapacityText = mode == .fullDetail
            ? Self.exactCapacityText(remaining: summary.remaining, limit: summary.limit, unit: summary.unit)
            : nil
        accountCountText = mode == .countsOnly ? nil : Self.accountCountText(summary.accountCount)
        accountNames = mode == .fullDetail
            ? Array(Set(summary.limits.map(\.accountName))).sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            : []
        metrics = Self.metrics(summary: summary, mode: mode, now: now)
    }

    init(limit: UsageLimit, mode: TVPresentationMode, now: Date) {
        id = limit.id
        provider = limit.provider
        title = mode == .countsOnly ? limit.provider.shortName : limit.displayLabel
        status = limit.status
        remainingPercent = limit.remainingCapacityRatio.map { Int(($0 * 100).rounded()) }
        capacityRatio = limit.remainingCapacityRatio
        resetText = mode == .countsOnly ? nil : Self.compactResetText(until: limit.resetsAt, now: now)
        exactCapacityText = mode == .fullDetail
            ? Self.exactCapacityText(remaining: limit.remaining, limit: limit.limit, unit: limit.unit)
            : nil
        accountCountText = mode == .countsOnly ? nil : Self.accountCountText(1)
        accountNames = mode == .fullDetail ? [limit.accountName] : []
        metrics = mode == .countsOnly ? [] : [TVRunwayMetric(limit: limit, mode: mode, now: now)]
    }

    init(provider: Provider, report: StoredProviderReport) {
        id = "\(provider.rawValue):status"
        self.provider = provider
        title = "No capacity data"
        status = report.status
        remainingPercent = nil
        capacityRatio = nil
        resetText = nil
        exactCapacityText = nil
        accountCountText = nil
        accountNames = []
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
