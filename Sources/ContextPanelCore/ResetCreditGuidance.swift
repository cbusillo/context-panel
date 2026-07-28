import Foundation

public enum ResetCreditHoldReason: Equatable, Sendable {
    case weeklyCapacityHealthy
    case fiveHourOnlyPressure
    case naturalResetImminent
    case naturalResetBeforeExpiry
}

public enum ResetCreditRefreshReason: Equatable, Sendable {
    case staleObservation
    case inconsistentObservation
    case expiryUnknown
    case expiryElapsed
    case weeklyLimitUnknown
    case naturalResetUnknown
}

public enum ResetCreditGuidanceState: Equatable, Sendable {
    case hold(ResetCreditHoldReason)
    case considerUsingNow
    case considerBefore(Date)
    case refresh(ResetCreditRefreshReason)

    public var isActionable: Bool {
        switch self {
        case .considerUsingNow, .considerBefore:
            true
        case .hold, .refresh:
            false
        }
    }
}

public struct ProviderResetCreditGuidance: Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let resetCredits: ProviderResetCreditSummary
    public let weeklyResetsAt: Date?
    public let state: ResetCreditGuidanceState

    public var id: String {
        let accountIdentity = ProviderAccountIdentity.unique(
            accountID: accountID,
            configuredAccountID: configuredAccountID
        )
        return "\(provider.rawValue):\(accountIdentity):reset-credits"
    }

    public var countText: String {
        let noun = resetCredits.availableCount == 1 ? "reset credit" : "reset credits"
        return "\(resetCredits.availableCount) \(noun)"
    }

    public var recommendationTitle: String {
        switch state {
        case .hold:
            "Hold for now"
        case .considerUsingNow:
            "Consider using now"
        case let .considerBefore(expiry):
            "Consider before \(Self.dateText(expiry))"
        case let .refresh(reason):
            reason == .expiryUnknown ? "Timing unknown" : "Refresh"
        }
    }

    public func recommendationDetail(now: Date) -> String {
        switch state {
        case .hold(.weeklyCapacityHealthy):
            "Weekly capacity is available."
        case .hold(.fiveHourOnlyPressure):
            "The 5-hour window should reset naturally while weekly capacity remains available."
        case .hold(.naturalResetImminent):
            weeklyResetsAt.map { "The weekly limit resets \(Self.relativeText($0, now: now))." }
                ?? "The weekly limit resets soon."
        case .hold(.naturalResetBeforeExpiry):
            "The weekly limit resets before the earliest known credit expiry."
        case .considerUsingNow:
            "The weekly limit is reached and its natural reset is not imminent."
        case let .considerBefore(expiry):
            "Weekly capacity is close to the limit and a credit may expire \(Self.relativeText(expiry, now: now))."
        case .refresh(.staleObservation):
            "Credit availability is stale."
        case .refresh(.inconsistentObservation):
            "Credit timing does not match the latest account refresh."
        case .refresh(.expiryUnknown):
            "The count is current, but expiry timing is unknown."
        case .refresh(.expiryElapsed):
            "The known expiry has passed; refresh before relying on this count."
        case .refresh(.weeklyLimitUnknown):
            "Weekly limit pressure is unknown."
        case .refresh(.naturalResetUnknown):
            "The weekly reset time is unknown."
        }
    }

    public var compactActionText: String? {
        switch state {
        case .considerUsingNow:
            "consider using now"
        case let .considerBefore(expiry):
            "consider before \(Self.compactDateText(expiry))"
        case .hold, .refresh:
            nil
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func compactDateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func relativeText(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 60 { return "now" }
        if interval < 60 * 60 {
            return "in \(max(Int(interval / 60), 1))m"
        }
        if interval < 24 * 60 * 60 {
            return "in \(max(Int(interval / (60 * 60)), 1))h"
        }
        return "on \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

public enum ResetCreditGuidanceAdvisor {
    public static let imminentNaturalResetInterval: TimeInterval = 60 * 60

    public static func guidance(
        reports: [StoredProviderReport],
        limits: [UsageLimit],
        now: Date,
        maximumAge: TimeInterval = SnapshotFreshness.appMaximumAge
    ) -> [ProviderResetCreditGuidance] {
        precondition(maximumAge >= 0, "maximumAge must not be negative")
        let reportsByAccount = reports.reduce(into: [ResetCreditAccountKey: StoredProviderReport]()) { result, report in
            let key = ResetCreditAccountKey(
                provider: report.provider,
                accountID: ProviderAccountIdentity.unique(
                    accountID: report.accountID,
                    configuredAccountID: report.configuredAccountID
                )
            )
            if let current = result[key], !prefers(report, over: current) {
                return
            }
            result[key] = report
        }
        return reportsByAccount.values.compactMap { report in
            guidance(report: report, limits: limits, now: now, maximumAge: maximumAge)
        }.sorted { lhs, rhs in
            let nameOrder = lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    public static func primaryActionableGuidance(
        reports: [StoredProviderReport],
        limits: [UsageLimit],
        now: Date,
        maximumAge: TimeInterval = SnapshotFreshness.widgetMaximumAge
    ) -> ProviderResetCreditGuidance? {
        guidance(reports: reports, limits: limits, now: now, maximumAge: maximumAge)
            .filter { $0.state.isActionable }
            .sorted(by: actionableSort)
            .first
    }

    public static func guidance(
        report: StoredProviderReport,
        limits: [UsageLimit],
        now: Date,
        maximumAge: TimeInterval = SnapshotFreshness.appMaximumAge
    ) -> ProviderResetCreditGuidance? {
        precondition(maximumAge >= 0, "maximumAge must not be negative")
        guard report.provider == .openAI,
              let resetCredits = report.resetCredits,
              resetCredits.availableCount > 0
        else {
            return nil
        }

        let accountLimits = limits.filter {
            $0.provider == report.provider && $0.accountID == report.accountID
        }
        let weeklyLimits = accountLimits.filter { $0.mainLimitWindow == .weekly }
        let fiveHourLimits = accountLimits.filter { $0.mainLimitWindow == .fiveHour }
        let state: ResetCreditGuidanceState
        let weeklyResetsAt: Date?

        if let refreshReason = refreshReason(
            report: report,
            resetCredits: resetCredits,
            now: now,
            maximumAge: maximumAge
        ) {
            state = .refresh(refreshReason)
            weeklyResetsAt = nil
        } else if resetCredits.coverage == .countOnly || resetCredits.earliestKnownExpiry == nil {
            state = .refresh(.expiryUnknown)
            weeklyResetsAt = nil
        } else if resetCredits.earliestKnownExpiry.map({ $0 <= now }) == true {
            state = .refresh(.expiryElapsed)
            weeklyResetsAt = nil
        } else if weeklyLimits.isEmpty || weeklyLimits.contains(where: { !$0.status.supportsResetCreditGuidance }) {
            state = .refresh(.weeklyLimitUnknown)
            weeklyResetsAt = nil
        } else {
            let weeklyLimit = mostPressuredLimit(in: weeklyLimits)
            weeklyResetsAt = weeklyLimit?.resetsAt
            state = recommendation(
                weeklyLimit: weeklyLimit,
                fiveHourLimits: fiveHourLimits,
                earliestKnownExpiry: resetCredits.earliestKnownExpiry,
                now: now
            )
        }

        return ProviderResetCreditGuidance(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID,
            accountName: report.accountName,
            resetCredits: resetCredits,
            weeklyResetsAt: weeklyResetsAt,
            state: state
        )
    }

    private static func refreshReason(
        report: StoredProviderReport,
        resetCredits: ProviderResetCreditSummary,
        now: Date,
        maximumAge: TimeInterval
    ) -> ResetCreditRefreshReason? {
        if report.status == .failure || report.status == .stale || report.status == .loading {
            return .staleObservation
        }
        if resetCredits.observedAt > now.addingTimeInterval(60) {
            return .inconsistentObservation
        }
        if abs(resetCredits.observedAt.timeIntervalSince(report.generatedAt)) > 1 {
            return .inconsistentObservation
        }
        if now.timeIntervalSince(resetCredits.observedAt) > maximumAge {
            return .staleObservation
        }
        return nil
    }

    private static func recommendation(
        weeklyLimit: UsageLimit?,
        fiveHourLimits: [UsageLimit],
        earliestKnownExpiry: Date?,
        now: Date
    ) -> ResetCreditGuidanceState {
        guard let weeklyLimit else { return .refresh(.weeklyLimitUnknown) }
        switch weeklyLimit.status {
        case .healthy:
            let fiveHourPressure = fiveHourLimits.contains { $0.status == .close || $0.status == .limited }
            return .hold(fiveHourPressure ? .fiveHourOnlyPressure : .weeklyCapacityHealthy)
        case .close, .limited:
            guard let weeklyReset = weeklyLimit.resetsAt, weeklyReset > now else {
                return .refresh(.naturalResetUnknown)
            }
            if weeklyReset.timeIntervalSince(now) <= imminentNaturalResetInterval {
                return .hold(.naturalResetImminent)
            }
            if weeklyLimit.status == .limited {
                return .considerUsingNow
            }
            guard let earliestKnownExpiry else { return .refresh(.expiryUnknown) }
            return earliestKnownExpiry < weeklyReset
                ? .considerBefore(earliestKnownExpiry)
                : .hold(.naturalResetBeforeExpiry)
        case .stale, .unknown, .failure, .loading:
            return .refresh(.weeklyLimitUnknown)
        }
    }

    private static func mostPressuredLimit(in limits: [UsageLimit]) -> UsageLimit? {
        limits.max { lhs, rhs in
            let lhsRank = lhs.status.resetCreditPressureRank
            let rhsRank = rhs.status.resetCreditPressureRank
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsRatio = lhs.usageRatio ?? -1
            let rhsRatio = rhs.usageRatio ?? -1
            if lhsRatio != rhsRatio { return lhsRatio < rhsRatio }
            return lhs.id > rhs.id
        }
    }

    private static func actionableSort(
        lhs: ProviderResetCreditGuidance,
        rhs: ProviderResetCreditGuidance
    ) -> Bool {
        let lhsRank = lhs.state.actionableRank
        let rhsRank = rhs.state.actionableRank
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsExpiry = lhs.state.actionableExpiry ?? .distantFuture
        let rhsExpiry = rhs.state.actionableExpiry ?? .distantFuture
        if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
        return lhs.id < rhs.id
    }

    private static func prefers(_ candidate: StoredProviderReport, over current: StoredProviderReport) -> Bool {
        if candidate.generatedAt != current.generatedAt {
            return candidate.generatedAt > current.generatedAt
        }
        let candidateObservedAt = candidate.resetCredits?.observedAt ?? .distantPast
        let currentObservedAt = current.resetCredits?.observedAt ?? .distantPast
        if candidateObservedAt != currentObservedAt {
            return candidateObservedAt > currentObservedAt
        }
        return candidate.accountID < current.accountID
    }
}

private struct ResetCreditAccountKey: Hashable {
    let provider: Provider
    let accountID: String
}

private extension UsageStatus {
    var supportsResetCreditGuidance: Bool {
        self == .healthy || self == .close || self == .limited
    }

    var resetCreditPressureRank: Int {
        switch self {
        case .limited: 2
        case .close: 1
        case .healthy: 0
        case .stale, .unknown, .failure, .loading: -1
        }
    }
}

private extension ResetCreditGuidanceState {
    var actionableRank: Int {
        switch self {
        case .considerUsingNow: 0
        case .considerBefore: 1
        case .hold, .refresh: 2
        }
    }

    var actionableExpiry: Date? {
        guard case let .considerBefore(expiry) = self else { return nil }
        return expiry
    }
}
