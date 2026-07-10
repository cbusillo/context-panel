import Foundation

public enum MainLimitWindow: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case fiveHour
    case weekly
    case daily
    case availability

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fiveHour:
            "5-hour"
        case .weekly:
            "Weekly"
        case .daily:
            "Daily"
        case .availability:
            "Model capacity"
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
        case .availability:
            "Cap"
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
        case .availability:
            3
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
        if limit.windowLabel?.isModelCapacityWindowLabel == true {
            return .availability
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

    public var displayWindowName: String {
        window.displayName
    }

    public var compactDisplayWindowName: String {
        window.shortName
    }

    public func displayWindowName(now: Date) -> String {
        displayWindowName
    }

    public func compactDisplayWindowName(now: Date) -> String {
        compactDisplayWindowName
    }

    public var resetCountdownText: String? {
        resetCountdownText(now: Date())
    }

    public func resetCountdownText(now: Date) -> String? {
        guard let resetsAt, resetsAt >= now.addingTimeInterval(-60) else { return nil }
        return Self.compactResetDistance(until: resetsAt, now: now)
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

    public var remainingCapacityRatio: Double? {
        usageRatio.map { max(1 - $0, 0) }
    }

    public var capacityRatio: Double {
        remainingCapacityRatio ?? 0
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
        let sourceLimits = liveLimits.isEmpty ? limits : liveLimits
        let confidences = sourceLimits.map(\.confidence)
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

    private static func compactResetDistance(until date: Date, now: Date) -> String {
        let seconds = max(Int(date.timeIntervalSince(now)), 0)
        if seconds < 60 { return "now" }
        let minutes = max((seconds + 59) / 60, 1)
        if minutes < 60 { return "\(minutes)m" }
        let hours = max((minutes + 59) / 60, 1)
        if hours <= 24 { return "\(hours)h" }
        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours == 0 { return "\(days)d" }
        return "\(days)d \(remainingHours)h"
    }

    private var numericLimits: [UsageLimit] {
        limits.filter { $0.used != nil && $0.limit != nil }
    }

    public var liveLimits: [UsageLimit] {
        limits.compactMap { limit in
            guard limit.isLiveCapacityBucket(at: generatedAt) else { return nil }
            guard !hasExhaustedLongerWindow(for: limit) else { return nil }
            return limit
        }
    }

    public var nextAccountToUse: AccountResetRecommendation? {
        liveLimits.compactMap { limit -> AccountResetRecommendation? in
            guard let resetsAt = limit.resetsAt, resetsAt > generatedAt else { return nil }
            return AccountResetRecommendation(
                provider: limit.provider,
                accountID: limit.accountID,
                configuredAccountID: limit.configuredAccountID,
                accountName: limit.accountName,
                window: window,
                resetsAt: resetsAt,
                limit: limit
            )
        }
        .sorted { lhs, rhs in
            if lhs.resetsAt != rhs.resetsAt {
                return lhs.resetsAt < rhs.resetsAt
            }
            if lhs.accountName != rhs.accountName {
                return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
            return lhs.accountID < rhs.accountID
        }
        .first
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

public struct AccountResetRecommendation: Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let window: MainLimitWindow
    public let resetsAt: Date
    public let limit: UsageLimit

    public var id: String {
        let accountIdentity = ProviderAccountIdentity.unique(
            accountID: accountID,
            configuredAccountID: configuredAccountID
        )
        return "\(provider.rawValue):\(accountIdentity):\(window.rawValue):\(Int(resetsAt.timeIntervalSince1970))"
    }
}

public extension UsageLimit {
    var mainLimitWindow: MainLimitWindow? {
        guard let window = MainLimitWindow.infer(from: self) else { return nil }
        switch provider {
        case .openAI, .anthropic:
            return window == .daily || window == .availability ? nil : window
        case .google:
            if window == .availability, !isGoogleAntigravityGeminiAvailability {
                return nil
            }
            return window
        }
    }

    var isMainLimit: Bool {
        mainLimitWindow != nil
    }

    private var isGoogleAntigravityGeminiAvailability: Bool {
        guard provider == .google else { return false }
        guard note?.localizedCaseInsensitiveContains("source: Google Antigravity model availability") == true else {
            return false
        }
        let modelText = [label, modelLabel]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return modelText.contains("gemini")
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

    func nextAccountToUse(provider: Provider, window: MainLimitWindow? = nil) -> AccountResetRecommendation? {
        mainLimitSummaries
            .filter { summary in
                summary.provider == provider && (window == nil || summary.window == window)
            }
            .compactMap(\.nextAccountToUse)
            .sorted { lhs, rhs in
                if lhs.resetsAt != rhs.resetsAt {
                    return lhs.resetsAt < rhs.resetsAt
                }
                if lhs.window != rhs.window {
                    return lhs.window.sortRank < rhs.window.sortRank
                }
                if lhs.accountName != rhs.accountName {
                    return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
                }
                return lhs.accountID < rhs.accountID
            }
            .first
    }
}

private extension String {
    var isModelCapacityWindowLabel: Bool {
        localizedCaseInsensitiveCompare("Model capacity") == .orderedSame
            || localizedCaseInsensitiveCompare("Availability") == .orderedSame
    }
}

extension MainLimitWindow {
    fileprivate var capacityGateRank: Int {
        switch self {
        case .fiveHour:
            0
        case .daily:
            1
        case .availability:
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
