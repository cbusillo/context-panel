import Foundation

public enum WidgetSnapshotState: String, Codable, Equatable, Sendable {
    case ready
    case setupNeeded
    case stale
    case failure
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let state: WidgetSnapshotState
    public let generatedAt: Date
    public let limits: [UsageLimit]
    public let reports: [StoredProviderReport]
    public let promptCacheObservations: [PromptCacheObservation]
    public let observedBurnRates: [String: ObservedBurnRate]
    public let fastModeForecastSettings: FastModeForecastSettings
    public let status: UsageStatus
    public let message: String

    public init(
        state: WidgetSnapshotState,
        generatedAt: Date,
        limits: [UsageLimit],
        reports: [StoredProviderReport] = [],
        promptCacheObservations: [PromptCacheObservation] = [],
        observedBurnRates: [String: ObservedBurnRate] = [:],
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings,
        status: UsageStatus,
        message: String
    ) {
        self.state = state
        self.generatedAt = generatedAt
        self.limits = limits
        self.reports = reports
        self.promptCacheObservations = promptCacheObservations
        self.observedBurnRates = observedBurnRates
        self.fastModeForecastSettings = fastModeForecastSettings
        self.status = status
        self.message = message
    }

    public var usageSnapshot: UsageSnapshot {
        UsageSnapshot(generatedAt: generatedAt, limits: limits)
    }

    public var mostConstrainedLimits: [UsageLimit] {
        usageSnapshot.mostConstrainedLimits
    }

    public var nextOpenAIAccountToUse: AccountResetRecommendation? {
        usageSnapshot.nextAccountToUse(provider: .openAI, window: .weekly)
            ?? usageSnapshot.nextAccountToUse(provider: .openAI, window: .fiveHour)
            ?? usageSnapshot.nextAccountToUse(provider: .openAI)
    }

    public var aggregateCapacityRatio: Double {
        usageSnapshot.aggregateCapacityRatio
    }

    public var providerSummaries: [ProviderSummary] {
        Provider.allCases.map { provider in
            let providerLimits = limits.filter { $0.provider == provider }
            let mainSummaries = usageSnapshot.mainLimitSummaries.filter { $0.provider == provider }
            let nonMainStatuses = providerLimits.filter { !$0.isMainLimit }.map(\.status)
            let statuses = mainSummaries.map(\.status) + nonMainStatuses
            let tightestLimit = UsageSnapshot(generatedAt: generatedAt, limits: providerLimits).mostConstrainedLimits.first
            return ProviderSummary(
                provider: provider,
                limitCount: providerLimits.count,
                status: statuses.contextPanelWorstStatus,
                capacityRatio: capacityRatio(for: providerLimits),
                tightestLimit: tightestLimit
            )
        }
    }

    public static func fromStore(
        _ result: SnapshotStoreLoadResult,
        now: Date = Date(),
        history: [StoredUsageSnapshot] = [],
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings
    ) -> WidgetSnapshot {
        guard let stored = result.snapshot else {
            return WidgetSnapshot(
                state: result.status == .failure ? .failure : .setupNeeded,
                generatedAt: now,
                limits: [],
                fastModeForecastSettings: fastModeForecastSettings,
                status: result.status,
                message: result.errorMessage ?? "Set up Context Panel in the app."
            )
        }

        let state: WidgetSnapshotState = switch result.status {
        case .failure:
            .failure
        case .stale:
            .stale
        default:
            .ready
        }

        return WidgetSnapshot(
            state: state,
            generatedAt: stored.snapshot.generatedAt,
            limits: stored.snapshot.limits,
            reports: stored.reports,
            promptCacheObservations: PromptCacheTelemetryReader.filteredRecentObservations(
                stored.promptCacheObservations,
                now: now
            ),
            observedBurnRates: MainLimitBurnRateEstimator.observedBurnRates(
                current: stored.snapshot,
                history: history,
                now: now
            ),
            fastModeForecastSettings: fastModeForecastSettings,
            status: result.status,
            message: message(state: state, stored: stored)
        )
    }

    public var hasProviderReconnectIssue: Bool {
        reports.hasReconnectBlockingFailure
    }

    public var promptCacheSummary: PromptCacheSummary {
        PromptCacheSummary(observations: promptCacheObservations)
    }

    private static func message(state: WidgetSnapshotState, stored: StoredUsageSnapshot) -> String {
        switch state {
        case .ready:
            let limitedCount = stored.snapshot.mainLimitSummaries.filter { $0.status == .limited }.count
                + stored.snapshot.limits.filter { !$0.isMainLimit && $0.status == .limited }.count
            if limitedCount > 0 {
                return "\(limitedCount) limit needs attention."
            }
            return "You're good to keep working."
        case .setupNeeded:
            return "Set up Context Panel in the app."
        case .stale:
            return stored.reports.hasReconnectBlockingFailure
                ? "Reconnect account to update data."
                : "Refresh Context Panel to update data."
        case .failure:
            return "Reconnect account to update data."
        }
    }

    private func capacityRatio(for limits: [UsageLimit]) -> Double {
        let ratios = limits.compactMap(\.usageRatio)
        guard !ratios.isEmpty else { return 0 }
        return max(1 - (ratios.max() ?? 0), 0)
    }
}

public struct ProviderSummary: Codable, Equatable, Sendable {
    public let provider: Provider
    public let limitCount: Int
    public let status: UsageStatus
    public let capacityRatio: Double
    public let tightestLimit: UsageLimit?

    public init(
        provider: Provider,
        limitCount: Int,
        status: UsageStatus,
        capacityRatio: Double,
        tightestLimit: UsageLimit? = nil
    ) {
        self.provider = provider
        self.limitCount = limitCount
        self.status = status
        self.capacityRatio = capacityRatio
        self.tightestLimit = tightestLimit
    }
}

extension Array where Element == UsageStatus {
    public var contextPanelWorstStatus: UsageStatus {
        if contains(.limited) { return .limited }
        if contains(.failure) { return .failure }
        if contains(.close) { return .close }
        if contains(.stale) { return .stale }
        if contains(.unknown) { return .unknown }
        if contains(.loading) { return .loading }
        return .healthy
    }
}
