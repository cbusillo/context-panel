import Foundation

public enum MainLimitWindow: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case fiveHour
    case weekly
    case daily

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fiveHour:
            "5-hour"
        case .weekly:
            "Weekly"
        case .daily:
            "Daily"
        }
    }

    public var shortName: String {
        switch self {
        case .fiveHour:
            "5h"
        case .weekly:
            "1w"
        case .daily:
            "1d"
        }
    }

    fileprivate var sortRank: Int {
        switch self {
        case .fiveHour:
            0
        case .weekly:
            1
        case .daily:
            2
        }
    }

    static func infer(from limit: UsageLimit) -> MainLimitWindow? {
        let searchable = [
            limit.windowLabel,
            limit.label,
            limit.modelLabel,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if searchable.contains("spark") {
            return nil
        }
        if searchable.contains("5-hour")
            || searchable.contains("5 hour")
            || searchable.contains("five_hour")
            || searchable.contains("five hour") {
            return .fiveHour
        }
        if searchable.contains("weekly")
            || searchable.contains("week")
            || searchable.contains("7-day")
            || searchable.contains("7 day")
            || searchable.contains("seven_day")
            || searchable.contains("seven day") {
            return .weekly
        }
        if searchable.contains("daily") || searchable.contains("day") {
            return .daily
        }
        return nil
    }
}

public struct MainLimitSummary: Codable, Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let window: MainLimitWindow
    public let limits: [UsageLimit]
    public let generatedAt: Date
    public let providerMainLimits: [UsageLimit]

    public var id: String {
        "\(provider.rawValue):\(window.rawValue)"
    }

    public var primaryLimit: UsageLimit? {
        UsageSnapshot(generatedAt: Date(), limits: limits).mostConstrainedLimits.first
    }

    public var capacityPool: CapacityPool {
        CapacityPool(limits: liveNumericLimits)
    }

    public var unit: UsageUnit? {
        guard let firstUnit = liveNumericLimits.first?.unit else { return nil }
        guard liveNumericLimits.allSatisfy({ $0.unit == firstUnit }) else { return nil }
        return firstUnit
    }

    public var used: Int? {
        guard unit != nil else { return nil }
        let numericLimits = liveNumericLimits
        guard !numericLimits.isEmpty else { return nil }
        return numericLimits.reduce(0) { total, limit in total + (limit.used ?? 0) }
    }

    public var limit: Int? {
        guard unit != nil else { return nil }
        let numericLimits = liveNumericLimits
        guard !numericLimits.isEmpty else { return nil }
        return numericLimits.reduce(0) { total, limit in total + (limit.limit ?? 0) }
    }

    public var accountCount: Int {
        Set(limits.map(\.accountID)).count
    }

    public var status: UsageStatus {
        if limits.contains(where: { $0.status == .failure }) {
            return .failure
        }
        guard let usageRatio else {
            return limits.map(\.status).contextPanelWorstStatus
        }
        if usageRatio >= 1 {
            return .limited
        }
        if usageRatio >= 0.8 {
            return .close
        }
        if limits.contains(where: { $0.status == .stale }) {
            return .stale
        }
        return .healthy
    }

    public var usageRatio: Double? {
        guard let used, let limit else { return nil }
        return min(Double(used) / Double(limit), 1)
    }

    public var capacityRatio: Double {
        guard let usageRatio else { return 0 }
        return max(1 - usageRatio, 0)
    }

    public var remaining: Int? {
        guard let used, let limit else { return nil }
        return max(limit - used, 0)
    }

    public var resetsAt: Date? {
        nextReset(after: generatedAt) ?? firstKnownReset
    }

    public var firstKnownReset: Date? {
        limits.compactMap(\.resetsAt).sorted().first
    }

    public func nextReset(after date: Date) -> Date? {
        capacityPool.nextReset(after: date)
    }

    public var lastUpdatedAt: Date? {
        limits.compactMap(\.lastUpdatedAt).sorted().last
    }

    public var confidence: UsageConfidence {
        let confidences = limits.map(\.confidence)
        if confidences.contains(.unknown) { return .unknown }
        if confidences.contains(.estimated) { return .estimated }
        if confidences.contains(.manual) { return .manual }
        if confidences.contains(.observed) { return .observed }
        return confidences.first ?? .unknown
    }

    public var pooledLimit: UsageLimit? {
        guard
            let used,
            let limit,
            let unit
        else {
            return nil
        }
        return UsageLimit(
            id: "\(id):pooled",
            provider: provider,
            accountID: "\(provider.rawValue)-\(window.rawValue)-pool",
            accountName: "\(provider.displayName) \(window.displayName) pool",
            label: "\(provider.displayName) \(window.displayName)",
            windowLabel: window.displayName,
            unit: unit,
            used: used,
            limit: limit,
            resetsAt: resetsAt,
            lastUpdatedAt: lastUpdatedAt,
            confidence: confidence,
            statusOverride: status
        )
    }

    public init(
        provider: Provider,
        window: MainLimitWindow,
        limits: [UsageLimit],
        generatedAt: Date = Date(),
        providerMainLimits: [UsageLimit]? = nil
    ) {
        self.provider = provider
        self.window = window
        self.limits = limits
        self.generatedAt = generatedAt
        self.providerMainLimits = providerMainLimits ?? limits
    }

    private var numericLimits: [UsageLimit] {
        limits.filter { $0.used != nil && $0.limit != nil }
    }

    public var liveLimits: [UsageLimit] {
        limits.filter { limit in
            limit.isLiveCapacityBucket(at: generatedAt)
                && !hasExhaustedLongerWindow(for: limit)
        }
    }

    private var liveNumericLimits: [UsageLimit] {
        liveLimits.filter { $0.used != nil && $0.limit != nil }
    }

    private func hasExhaustedLongerWindow(for limit: UsageLimit) -> Bool {
        providerMainLimits.contains { candidate in
            guard candidate.accountID == limit.accountID else { return false }
            guard candidate.id != limit.id else { return false }
            guard candidate.status == .limited else { return false }
            guard let candidateWindow = candidate.mainLimitWindow else { return false }
            return candidateWindow.capacityGateRank > window.capacityGateRank
        }
    }
}

public extension UsageLimit {
    var mainLimitWindow: MainLimitWindow? {
        guard let window = MainLimitWindow.infer(from: self) else { return nil }
        switch provider {
        case .openAI, .anthropic:
            return window == .daily ? nil : window
        case .google:
            return window
        }
    }

    var isMainLimit: Bool {
        mainLimitWindow != nil
    }
}

public extension UsageSnapshot {
    var mainLimitSummaries: [MainLimitSummary] {
        let mainLimits = limits.filter { $0.mainLimitWindow != nil }
        let grouped = Dictionary(grouping: mainLimits) { limit in
            limit.mainLimitWindow.map { "\(limit.provider.rawValue):\($0.rawValue)" } ?? ""
        }

        return grouped.values.compactMap { limits in
            guard
                let first = limits.first,
                let window = first.mainLimitWindow
            else {
                return nil
            }
            return MainLimitSummary(
                provider: first.provider,
                window: window,
                limits: limits,
                generatedAt: generatedAt,
                providerMainLimits: mainLimits.filter { $0.provider == first.provider }
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider != rhs.provider {
                let lhsIndex = Provider.allCases.firstIndex(of: lhs.provider) ?? 0
                let rhsIndex = Provider.allCases.firstIndex(of: rhs.provider) ?? 0
                return lhsIndex < rhsIndex
            }
            return lhs.window.sortRank < rhs.window.sortRank
        }
    }

    var mostConstrainedMainLimitSummaries: [MainLimitSummary] {
        mainLimitSummaries.sorted { lhs, rhs in
            let lhsScore = lhs.status.summarySortRank + (lhs.usageRatio ?? 0)
            let rhsScore = rhs.status.summarySortRank + (rhs.usageRatio ?? 0)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return lhs.window.sortRank < rhs.window.sortRank
        }
    }
}

extension MainLimitWindow {
    fileprivate var capacityGateRank: Int {
        switch self {
        case .fiveHour:
            0
        case .daily:
            1
        case .weekly:
            2
        }
    }
}

public extension UsageLimit {
    func isLiveCapacityBucket(at date: Date) -> Bool {
        if status == .failure || status == .stale || status == .unknown {
            return false
        }
        if let resetsAt, resetsAt <= date.addingTimeInterval(-60) {
            return false
        }
        return true
    }
}

extension UsageStatus {
    fileprivate var summarySortRank: Double {
        switch self {
        case .limited:
            2
        case .failure:
            1.3
        case .close:
            1
        case .stale:
            0.4
        case .unknown:
            0.3
        case .loading:
            0.2
        case .healthy:
            0
        }
    }
}
