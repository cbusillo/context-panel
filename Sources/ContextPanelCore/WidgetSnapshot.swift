import Foundation

public enum WidgetSnapshotState: String, Codable, Equatable, Sendable {
    case ready
    case setupNeeded
    case stale
    case failure
}

public enum PromptCacheWidgetState: String, Codable, Equatable, Sendable {
    case unavailable
    case needsAuthorization
    case available
    case stale
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let state: WidgetSnapshotState
    public let generatedAt: Date
    public let limits: [UsageLimit]
    public let reports: [StoredProviderReport]
    public let promptCacheObservations: [PromptCacheObservation]
    public let promptCacheWidgetState: PromptCacheWidgetState
    public let observedBurnRates: [String: ObservedBurnRate]
    public let fastModeForecastSettings: FastModeForecastSettings
    public let status: UsageStatus
    public let message: String
    public let refreshAttentionSummary: RefreshAttentionSummary?

    public init(
        state: WidgetSnapshotState,
        generatedAt: Date,
        limits: [UsageLimit],
        reports: [StoredProviderReport] = [],
        promptCacheObservations: [PromptCacheObservation] = [],
        promptCacheWidgetState: PromptCacheWidgetState = .unavailable,
        observedBurnRates: [String: ObservedBurnRate] = [:],
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings,
        status: UsageStatus,
        message: String,
        refreshAttentionSummary: RefreshAttentionSummary? = nil
    ) {
        self.state = state
        self.generatedAt = generatedAt
        self.limits = limits
        self.reports = reports
        self.promptCacheObservations = promptCacheObservations
        self.promptCacheWidgetState = promptCacheWidgetState
        self.observedBurnRates = observedBurnRates
        self.fastModeForecastSettings = fastModeForecastSettings
        self.status = status
        self.message = message
        self.refreshAttentionSummary = refreshAttentionSummary
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
            let statuses = provider == .anthropic && !mainSummaries.isEmpty
                ? mainSummaries.map(\.status)
                : mainSummaries.map(\.status) + nonMainStatuses
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
        fastModeForecastSettings: FastModeForecastSettings = .defaultSettings,
        promptCacheWidgetState: PromptCacheWidgetState? = nil,
        stalenessPolicy: SnapshotStoreStalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge)
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

        let status = widgetStatus(for: stored.snapshot, fallback: result.status)
        let refreshAttentionSummary = stalenessPolicy.refreshAttentionSummary(for: stored, now: now)

        let recentPromptCacheObservations = PromptCacheTelemetryReader.filteredRecentObservations(
            stored.promptCacheObservations,
            now: now
        )
        let resolvedPromptCacheState = promptCacheWidgetState ?? Self.promptCacheWidgetState(
            observations: recentPromptCacheObservations
        )

        return WidgetSnapshot(
            state: state,
            generatedAt: stored.snapshot.generatedAt,
            limits: stored.snapshot.limits,
            reports: stored.reports,
            promptCacheObservations: recentPromptCacheObservations,
            promptCacheWidgetState: resolvedPromptCacheState,
            observedBurnRates: MainLimitBurnRateEstimator.observedBurnRates(
                current: stored.snapshot,
                history: history,
                now: now
            ),
            fastModeForecastSettings: fastModeForecastSettings,
            status: status,
            message: message(state: state, stored: stored, refreshAttentionSummary: refreshAttentionSummary),
            refreshAttentionSummary: refreshAttentionSummary
        )
    }

    public static func fromCompanionSync(
        _ result: CompanionSyncLoadResult,
        now: Date = Date(),
        stalenessPolicy: SnapshotStoreStalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge)
    ) -> WidgetSnapshot {
        guard let document = result.document else {
            return WidgetSnapshot(
                state: result.status == .failure ? .failure : .setupNeeded,
                generatedAt: now,
                limits: [],
                fastModeForecastSettings: .defaultSettings,
                status: result.status,
                message: result.errorMessage ?? "Sync Context Panel from your Mac."
            )
        }

        let companion = document.snapshot
        let state: WidgetSnapshotState = switch result.status {
        case .failure:
            .failure
        case .stale:
            .stale
        default:
            .ready
        }
        let limits = companion.limits.map(\.usageLimit)
        let reports = companion.providerStatuses.map(\.storedProviderReport)
        let promptCacheObservations = companion.promptCacheSummaries.map(\.promptCacheObservation)
        let stored = StoredUsageSnapshot(
            savedAt: companion.publishedAt,
            snapshot: UsageSnapshot(generatedAt: companion.generatedAt, limits: limits),
            reports: reports,
            promptCacheObservations: promptCacheObservations
        )
        let status = widgetStatus(for: stored.snapshot, fallback: result.status)
        let refreshAttentionSummary = stalenessPolicy.refreshAttentionSummary(for: stored, now: now)
        let syncDeliveryDelayed = result.transportMetadata?.deliveryStatus == .delayed && result.status != .stale
        let providerDataStale = result.status == .stale
        let promptCacheState: PromptCacheWidgetState = promptCacheObservations.isEmpty
            ? .unavailable
            : (providerDataStale || result.status == .failure ? .stale : .available)

        return WidgetSnapshot(
            state: syncDeliveryDelayed && result.status != .failure ? .ready : state,
            generatedAt: companion.generatedAt,
            limits: limits,
            reports: reports,
            promptCacheObservations: promptCacheObservations,
            promptCacheWidgetState: promptCacheState,
            fastModeForecastSettings: document.fastModeForecastSettings,
            status: status,
            message: message(
                state: syncDeliveryDelayed && result.status != .failure ? .ready : state,
                stored: stored,
                refreshAttentionSummary: syncDeliveryDelayed ? nil : refreshAttentionSummary
            ),
            refreshAttentionSummary: syncDeliveryDelayed ? nil : refreshAttentionSummary
        )
    }

    public var hasProviderReconnectIssue: Bool {
        reports.reconnectBlockingFailures(coveredBy: limits).isEmpty == false
    }

    public var needsProviderConnection: Bool {
        usageSnapshot.mainLimitSummaries.isEmpty && reports.contains { $0.status == .failure }
    }

    public var promptCacheSummary: PromptCacheSummary {
        PromptCacheSummary(observations: promptCacheObservations)
    }

    public static func promptCacheWidgetState(
        accountStore: AccountConfigurationStore,
        bookmarkStore: SecureFileBookmarkStore,
        now: Date = Date()
    ) -> PromptCacheWidgetState? {
        let accounts = accountStore.load(now: now).document.accounts
        let usagePaths = accounts.compactMap { account -> String? in
            guard account.isEnabled, account.connectorKind == .codexRateLimits else { return nil }
            return promptCacheTelemetryDirectoryPath(for: account)
        }
        guard !usagePaths.isEmpty else { return nil }
        let hasMissingBookmark = usagePaths.contains { path in
            !bookmarkStore.hasCurrentBookmark(for: path)
        }
        return hasMissingBookmark ? .needsAuthorization : nil
    }

    private static func message(
        state: WidgetSnapshotState,
        stored: StoredUsageSnapshot,
        refreshAttentionSummary: RefreshAttentionSummary?
    ) -> String {
        switch state {
        case .ready:
            if stored.snapshot.mainLimitSummaries.isEmpty, stored.reports.contains(where: { $0.status == .failure }) {
                return "Connect an account to show limits."
            }
            return "Usage data is current."
        case .setupNeeded:
            return "Set up Context Panel in the app."
        case .stale:
            if let refreshNeededDetail = refreshAttentionSummary?.refreshNeededDetail {
                return refreshNeededDetail
            }
            return "Refresh Context Panel to update data."
        case .failure:
            return "Reconnect account to update data."
        }
    }

    private static func widgetStatus(for snapshot: UsageSnapshot, fallback: UsageStatus) -> UsageStatus {
        switch fallback {
        case .failure, .stale:
            return fallback
        case .healthy, .close, .limited, .unknown, .loading:
            break
        }

        let summaries = snapshot.mainLimitSummaries
        let nonMainStatuses = snapshot.limits.compactMap { limit -> UsageStatus? in
            guard !limit.isMainLimit else { return nil }
            if limit.provider == .anthropic,
               limit.isAnthropicStatuslinePlaceholder
            {
                return nil
            }
            return limit.status
        }
        let statuses = summaries.map(\.status) + nonMainStatuses
        guard !statuses.isEmpty else { return fallback }
        return statuses.contextPanelWorstStatus
    }

    private static func promptCacheWidgetState(
        observations: [PromptCacheObservation]
    ) -> PromptCacheWidgetState {
        if !PromptCacheSummary(observations: observations).isAvailable {
            return .unavailable
        }
        return .available
    }

    private static func promptCacheTelemetryDirectoryPath(for account: LocalProviderAccountConfiguration) -> String? {
        guard let usageDirectory = ContextPanelLocations.promptCacheUsageDirectory(
            forAuthPath: account.effectiveAuthPath
        ) else { return nil }
        return ContextPanelLocations.normalizedPath(usageDirectory.path)
    }

    private func capacityRatio(for limits: [UsageLimit]) -> Double {
        let ratios = limits.compactMap(\.usageRatio)
        guard !ratios.isEmpty else { return 0 }
        return max(1 - (ratios.max() ?? 0), 0)
    }
}

private extension UsageLimit {
    var isAnthropicStatuslinePlaceholder: Bool {
        provider == .anthropic
            && label.localizedCaseInsensitiveContains("status")
            && unit == .unknown
            && used == nil
            && limit == nil
            && resetsAt == nil
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
