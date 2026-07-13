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
            "Hide Account Names"
        case .countsOnly:
            "Percentages Only"
        }
    }

    public var detail: String {
        switch self {
        case .fullDetail:
            "Show safe account names, exact capacity, windows, and reset timing."
        case .projectOnly:
            "Hide account names and raw totals while keeping percentages, windows, and reset timing."
        case .countsOnly:
            "Show percentages and provider or time-window status only."
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
        preferences: WidgetDisplayPreferences = .defaultPreferences,
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
                preferences: preferences,
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
    case selectionStatus
}

public struct TVProviderRunwaySection: Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let status: UsageStatus
    public let lanes: [TVRunwayLane]
    public let primaryLaneID: String?
    public let closestLane: TVRunwayLane?

    public var id: Provider { provider }

    public var primaryLane: TVRunwayLane? {
        primaryLaneID.flatMap { id in lanes.first { $0.id == id } }
            ?? lanes.first { $0.kind == .capacity }
    }

    public var secondaryLanes: [TVRunwayLane] {
        guard let primaryLane else { return lanes }
        return lanes.filter { $0.id != primaryLane.id }
    }

    public var detailPrimaryLane: TVRunwayLane? {
        if let primaryLane, primaryLane.remainingPercent != nil {
            return primaryLane
        }
        return lanes.first { $0.kind == .capacity && $0.remainingPercent != nil }
            ?? primaryLane
    }

    public var detailSecondaryLanes: [TVRunwayLane] {
        guard let detailPrimaryLane else { return lanes }
        return lanes.filter { $0.id != detailPrimaryLane.id }
    }

    public var accountNames: [String] {
        Array(Set(lanes.flatMap(\.accountNames))).sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    init?(
        provider: Provider,
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        mode: TVPresentationMode,
        now: Date
    ) {
        let reports = snapshot.reports.filter { $0.provider == provider }
        let providerLimits = snapshot.limits.filter { $0.provider == provider }
        guard !reports.isEmpty || !providerLimits.isEmpty else { return nil }
        let anonymousAccountNumbers = TVRunwayLane.anonymousAccountNumbers(for: providerLimits)

        let mainSummaries = snapshot.usageSnapshot.mainLimitSummaries
            .filter { $0.provider == provider }
        let summarizedLimitIDs = Set(mainSummaries.flatMap(\.limits).map(\.id))
        let fallbackLimits = snapshot.mostConstrainedLimits
            .filter {
                $0.provider == provider
                    && !$0.isMainLimit
                    && !summarizedLimitIDs.contains($0.id)
            }
        let selection = preferences.mainLimitAnswerSelection(
            from: mainSummaries,
            provider: provider
        )

        var capacityLanes: [TVRunwayLane] = []
        for savedLane in selection.saved {
            if let summary = savedLane.summary {
                capacityLanes.append(
                    TVRunwayLane(
                        summary: summary,
                        snapshotState: snapshot.state,
                        mode: mode,
                        anonymousAccountNumbers: anonymousAccountNumbers,
                        now: now
                    )
                )
            } else {
                capacityLanes.append(
                    TVRunwayLane(
                        preference: savedLane.preference,
                        snapshotState: snapshot.state
                    )
                )
            }
        }
        if capacityLanes.isEmpty {
            capacityLanes.append(
                TVRunwayLane(
                    unselectedProvider: provider,
                    snapshotState: snapshot.state
                )
            )
        }
        capacityLanes.append(contentsOf: fallbackLimits.map {
            TVRunwayLane(
                limit: $0,
                snapshotState: snapshot.state,
                mode: mode,
                now: now
            )
        })
        let closestLane = selection.closest.map { lane in
            if let summary = lane.summary {
                return TVRunwayLane(
                    summary: summary,
                    snapshotState: snapshot.state,
                    mode: mode,
                    anonymousAccountNumbers: anonymousAccountNumbers,
                    now: now
                )
            }
            return TVRunwayLane(
                preference: lane.preference,
                snapshotState: snapshot.state
            )
        }

        let reportLanes = reports
            .filter { report in
                !Self.hasMatchingLimit(for: report, in: providerLimits)
                    || !report.status.tvRepresentsCurrentCapacity
            }
            .sorted { lhs, rhs in
                lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
            .map {
                TVRunwayLane(
                    provider: provider,
                    report: $0,
                    snapshotState: snapshot.state,
                    mode: mode
                )
            }
        let lanes = capacityLanes + reportLanes
        guard !lanes.isEmpty else { return nil }

        self.provider = provider
        let sourceStatuses = mainSummaries.map(\.status)
            + fallbackLimits.map(\.status)
            + reports.map(\.status)
        status = snapshot.state.tvDisplayStatus(source: sourceStatuses.contextPanelWorstStatus)
        self.lanes = lanes
        primaryLaneID = selection.primary?.id
            ?? capacityLanes.first { $0.kind == .selectionStatus }?.id
        self.closestLane = closestLane
    }

    public var trackedWindowCount: Int {
        lanes.filter { $0.kind == .capacity }.count
    }

    public var trackedWindowText: String {
        switch trackedWindowCount {
        case 0:
            "No limits shown"
        case 1:
            "1 limit shown"
        default:
            "\(trackedWindowCount) limits shown"
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

    init(
        summary: MainLimitSummary,
        snapshotState: WidgetSnapshotState,
        mode: TVPresentationMode,
        anonymousAccountNumbers: [String: Int],
        now: Date
    ) {
        id = summary.id
        kind = .capacity
        provider = summary.provider
        title = summary.displayWindowName
        status = snapshotState.tvDisplayStatus(source: summary.status)
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
        metrics = Self.metrics(
            summary: summary,
            snapshotState: snapshotState,
            mode: mode,
            anonymousAccountNumbers: anonymousAccountNumbers,
            now: now
        )
    }

    init(
        limit: UsageLimit,
        snapshotState: WidgetSnapshotState,
        mode: TVPresentationMode,
        now: Date
    ) {
        id = limit.id
        kind = .capacity
        provider = limit.provider
        title = mode == .fullDetail
            ? "\(limit.accountName) · \(limit.displayLabel)"
            : limit.displayLabel
        status = snapshotState.tvDisplayStatus(source: limit.status)
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
        metrics = mode == .countsOnly
            ? []
            : [
                TVRunwayMetric(
                    limit: limit,
                    snapshotState: snapshotState,
                    mode: mode,
                    now: now
                ),
            ]
    }

    init(
        provider: Provider,
        report: StoredProviderReport,
        snapshotState: WidgetSnapshotState,
        mode: TVPresentationMode
    ) {
        id = "\(provider.rawValue):report:\(report.configuredAccountID ?? report.accountID)"
        kind = .accountStatus
        self.provider = provider
        title = mode == .fullDetail ? "\(report.accountName) status" : "Account status"
        status = snapshotState.tvDisplayStatus(source: report.status)
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

    init(preference: WidgetMainLimitPreference, snapshotState: WidgetSnapshotState) {
        id = preference.id
        kind = .capacity
        provider = preference.provider
        title = preference.window.displayName
        status = snapshotState.tvDisplayStatus(source: .unknown)
        remainingPercent = nil
        capacityRatio = nil
        resetText = nil
        accessibilityResetText = nil
        exactCapacityText = nil
        accountCountText = nil
        detailText = nil
        accountNames = []
        metrics = []
    }

    init(unselectedProvider provider: Provider, snapshotState: WidgetSnapshotState) {
        id = "\(provider.rawValue):no-selection"
        kind = .selectionStatus
        self.provider = provider
        title = "No limit selected"
        status = snapshotState.tvDisplayStatus(source: .unknown)
        remainingPercent = nil
        capacityRatio = nil
        resetText = nil
        accessibilityResetText = nil
        exactCapacityText = nil
        accountCountText = nil
        detailText = nil
        accountNames = []
        metrics = []
    }

    private static func metrics(
        summary: MainLimitSummary,
        snapshotState: WidgetSnapshotState,
        mode: TVPresentationMode,
        anonymousAccountNumbers: [String: Int],
        now: Date
    ) -> [TVRunwayMetric] {
        let sortedLimits = orderedLimits(summary.limits)
        switch mode {
        case .fullDetail:
            return sortedLimits.map {
                    TVRunwayMetric(
                        limit: $0,
                        snapshotState: snapshotState,
                        mode: mode,
                        now: now
                    )
                }
        case .projectOnly:
            let limitsByAccount = Dictionary(grouping: sortedLimits) {
                anonymousAccountIdentity(for: $0)
            }
            let resolvedAccountNumbers = anonymousAccountNumbers.isEmpty
                ? Self.anonymousAccountNumbers(for: sortedLimits)
                : anonymousAccountNumbers
            var accountLimitOrdinals: [String: Int] = [:]
            return sortedLimits.map { limit in
                let identity = anonymousAccountIdentity(for: limit)
                let limitOrdinal = accountLimitOrdinals[identity, default: 0] + 1
                accountLimitOrdinals[identity] = limitOrdinal
                let accountNumber = resolvedAccountNumbers[identity] ?? limitOrdinal
                return TVRunwayMetric(
                    id: limit.id,
                    title: anonymousMetricTitle(
                        limit: limit,
                        accountNumber: accountNumber,
                        limitOrdinal: limitOrdinal,
                        siblingLimits: limitsByAccount[identity] ?? [],
                        windowName: summary.displayWindowName
                    ),
                    status: snapshotState.tvDisplayStatus(source: limit.status),
                    remainingPercent: limit.remainingCapacityRatio.map { Int(($0 * 100).rounded()) },
                    exactCapacityText: nil,
                    resetText: compactResetText(until: limit.resetsAt, now: now),
                    accessibilityResetText: accessibilityResetText(until: limit.resetsAt, now: now)
                )
            }
        case .countsOnly:
            return []
        }
    }

    fileprivate static func anonymousAccountNumbers(for limits: [UsageLimit]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for limit in orderedLimits(limits) {
            let identity = anonymousAccountIdentity(for: limit)
            if numbers[identity] == nil {
                numbers[identity] = numbers.count + 1
            }
        }
        return numbers
    }

    private static func anonymousMetricTitle(
        limit: UsageLimit,
        accountNumber: Int,
        limitOrdinal: Int,
        siblingLimits: [UsageLimit],
        windowName: String
    ) -> String {
        var components = ["Account \(accountNumber)", windowName]
        guard siblingLimits.count > 1 else {
            return components.joined(separator: " · ")
        }

        let modelLabel = limit.modelLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingModelCount = modelLabel.map { candidate in
            siblingLimits.filter {
                $0.modelLabel?.localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }.count
        } ?? 0
        components.append(
            modelLabel.flatMap { !$0.isEmpty && matchingModelCount == 1 ? $0 : nil }
                ?? "Limit \(limitOrdinal)"
        )
        return components.joined(separator: " · ")
    }

    private static func orderedLimits(_ limits: [UsageLimit]) -> [UsageLimit] {
        limits.sorted { lhs, rhs in
            let accountComparison = lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName)
            if accountComparison != .orderedSame {
                return accountComparison == .orderedAscending
            }
            if lhs.accountName != rhs.accountName {
                return lhs.accountName < rhs.accountName
            }
            let labelComparison = lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
            if labelComparison != .orderedSame {
                return labelComparison == .orderedAscending
            }
            let leftModel = lhs.modelLabel ?? ""
            let rightModel = rhs.modelLabel ?? ""
            let modelComparison = leftModel.localizedCaseInsensitiveCompare(rightModel)
            if modelComparison != .orderedSame {
                return modelComparison == .orderedAscending
            }
            if leftModel != rightModel {
                return leftModel < rightModel
            }
            return lhs.id < rhs.id
        }
    }

    private static func anonymousAccountIdentity(for limit: UsageLimit) -> String {
        let configuredAccountID = limit.configuredAccountID ?? ""
        return "configured#\(configuredAccountID.utf8.count):\(configuredAccountID)"
            + "account#\(limit.accountID.utf8.count):\(limit.accountID)"
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

    fileprivate static func accessibilityResetText(until resetDate: Date?, now: Date) -> String? {
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
    public let accessibilityResetText: String?

    init(
        id: String,
        title: String,
        status: UsageStatus,
        remainingPercent: Int?,
        exactCapacityText: String?,
        resetText: String?,
        accessibilityResetText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.remainingPercent = remainingPercent
        self.exactCapacityText = exactCapacityText
        self.resetText = resetText
        self.accessibilityResetText = accessibilityResetText
    }

    init(
        limit: UsageLimit,
        snapshotState: WidgetSnapshotState,
        mode: TVPresentationMode,
        now: Date
    ) {
        id = limit.id
        title = mode == .fullDetail
            ? "\(limit.accountName) · \(limit.displayLabel)"
            : limit.displayLabel
        status = snapshotState.tvDisplayStatus(source: limit.status)
        remainingPercent = limit.remainingCapacityRatio.map { Int(($0 * 100).rounded()) }
        exactCapacityText = mode == .fullDetail
            ? TVRunwayLane.exactCapacityText(remaining: limit.remaining, limit: limit.limit, unit: limit.unit)
            : nil
        resetText = TVRunwayLane.compactResetText(until: limit.resetsAt, now: now)
        accessibilityResetText = TVRunwayLane.accessibilityResetText(until: limit.resetsAt, now: now)
    }
}

private extension WidgetSnapshotState {
    func tvDisplayStatus(source: UsageStatus) -> UsageStatus {
        switch self {
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
