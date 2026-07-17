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
    public let syncErrorMessage: String?

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
        refreshAttentionSummary: RefreshAttentionSummary? = nil,
        syncErrorMessage: String? = nil
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
        self.syncErrorMessage = syncErrorMessage.map(ConnectorRedactor.redact)
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

        let refreshAttentionSummary = stalenessPolicy.refreshAttentionSummary(for: stored, now: now)
        let state: WidgetSnapshotState = if result.status == .failure, result.errorMessage != nil {
            .failure
        } else if refreshAttentionSummary?.isSnapshotAgeStale == true {
            .stale
        } else {
            .ready
        }
        let presentationSnapshot = stored.snapshot.presented(at: now)
        let status = widgetStatus(
            for: presentationSnapshot,
            fallback: snapshotWideStatus(for: state, snapshot: presentationSnapshot)
        )

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
            limits: presentationSnapshot.limits,
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
                message: result.errorMessage == nil
                    ? "Open Context Panel on your Mac to share usage."
                    : "Could not load usage from your Mac.",
                syncErrorMessage: result.errorMessage
            )
        }

        let companion = document.snapshot
        let companionUsage = CompanionUsagePresentation(
            snapshot: companion,
            now: now,
            maximumAge: stalenessPolicy.maximumAge
        )
        let limits = companionUsage.limits
        let reports = companionUsage.reports
        let promptCacheObservations = PromptCacheTelemetryReader.filteredRecentObservations(
            companion.promptCacheSummaries.map(\.promptCacheObservation),
            now: now
        )
        let stored = StoredUsageSnapshot(
            savedAt: companion.publishedAt,
            snapshot: UsageSnapshot(generatedAt: companion.generatedAt, limits: limits),
            reports: reports,
            promptCacheObservations: promptCacheObservations
        )
        let refreshAttentionSummary = stalenessPolicy.refreshAttentionSummary(for: stored, now: now)
        let usesStaleLocalCache = result.status == .stale
            && result.transportMetadata?.source == .localCache
        let state: WidgetSnapshotState = if usesStaleLocalCache
            || refreshAttentionSummary?.isSnapshotAgeStale == true {
            .stale
        } else {
            .ready
        }
        let presentationSnapshot = stored.snapshot.presented(at: now)
        let status = widgetStatus(
            for: presentationSnapshot,
            fallback: snapshotWideStatus(for: state, snapshot: presentationSnapshot)
        )
        let hasProviderRefreshAttention = refreshAttentionSummary.map {
            !$0.providers.isEmpty && !$0.isSnapshotAgeStale
        } ?? false
        let syncDeliveryDelayed = result.transportMetadata?.deliveryStatus == .delayed
            && state == .ready
            && !hasProviderRefreshAttention
        let promptCacheState: PromptCacheWidgetState = promptCacheObservations.isEmpty
            ? .unavailable
            : .available

        return WidgetSnapshot(
            state: state,
            generatedAt: companion.generatedAt,
            limits: presentationSnapshot.limits,
            reports: reports,
            promptCacheObservations: promptCacheObservations,
            promptCacheWidgetState: promptCacheState,
            observedBurnRates: compatibleObservedBurnRates(
                document.observedBurnRates,
                sourceLimits: companion.limits.map(\.usageLimit),
                presentedLimits: limits,
                generatedAt: companion.generatedAt
            ),
            fastModeForecastSettings: document.fastModeForecastSettings,
            status: status,
            message: result.errorMessage == nil
                ? message(
                    state: state,
                    stored: stored,
                    refreshAttentionSummary: syncDeliveryDelayed ? nil : refreshAttentionSummary
                )
                : "Showing saved usage because the latest update failed.",
            refreshAttentionSummary: syncDeliveryDelayed ? nil : refreshAttentionSummary,
            syncErrorMessage: result.errorMessage
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
            if let refreshNeededDetail = refreshAttentionSummary?.refreshNeededDetail {
                return refreshNeededDetail
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

    private static func snapshotWideStatus(
        for state: WidgetSnapshotState,
        snapshot: UsageSnapshot
    ) -> UsageStatus {
        switch state {
        case .failure:
            .failure
        case .stale:
            .stale
        case .ready, .setupNeeded:
            snapshot.aggregateStatus
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

    private static func compatibleObservedBurnRates(
        _ observedBurnRates: [String: ObservedBurnRate],
        sourceLimits: [UsageLimit],
        presentedLimits: [UsageLimit],
        generatedAt: Date
    ) -> [String: ObservedBurnRate] {
        let sourceSnapshot = UsageSnapshot(generatedAt: generatedAt, limits: sourceLimits)
        let presentedSnapshot = UsageSnapshot(generatedAt: generatedAt, limits: presentedLimits)
        return observedBurnRates.filter { rateID, _ in
            let sourcePool = burnRatePool(for: rateID, in: sourceSnapshot)
            return !sourcePool.isEmpty && sourcePool == burnRatePool(for: rateID, in: presentedSnapshot)
        }
    }

    private static func burnRatePool(for rateID: String, in snapshot: UsageSnapshot) -> Set<String> {
        guard let summary = snapshot.mainLimitSummaries.first(where: { $0.id == rateID }) else {
            return []
        }
        return Set(summary.liveLimits.map(\.id))
    }

    private func capacityRatio(for limits: [UsageLimit]) -> Double {
        let ratios = limits.compactMap(\.usageRatio)
        guard !ratios.isEmpty else { return 0 }
        return max(1 - (ratios.max() ?? 0), 0)
    }
}

private struct CompanionUsagePresentation {
    let limits: [UsageLimit]
    let reports: [StoredProviderReport]

    init(snapshot: CompanionSnapshot, now: Date, maximumAge: TimeInterval) {
        var accountStates: [CompanionUsageAccountKey: CompanionUsageAccountState] = [:]
        for limit in snapshot.limits {
            let key = CompanionUsageAccountKey(limit: limit)
            var state = accountStates[key, default: CompanionUsageAccountState()]
            state.hasLimits = true
            state.hasAgeSensitiveLimits = state.hasAgeSensitiveLimits || !limit.usageLimit.usesEventDrivenFreshness
            state.observe(limit.lastUpdatedAt)
            accountStates[key] = state
        }
        for status in snapshot.providerStatuses {
            let key = CompanionUsageAccountKey(status: status)
            var state = accountStates[key, default: CompanionUsageAccountState()]
            state.observe(status.generatedAt)
            accountStates[key] = state
        }

        let staleAccounts = Set(accountStates.compactMap { key, state in
            let isAgeSensitive = !state.hasLimits || state.hasAgeSensitiveLimits
            let observedAt = state.observedAt ?? snapshot.generatedAt
            return isAgeSensitive && now.timeIntervalSince(observedAt) > maximumAge ? key : nil
        })

        limits = snapshot.limits.map { companionLimit in
            let limit = companionLimit.usageLimit
            let key = CompanionUsageAccountKey(limit: companionLimit)
            guard staleAccounts.contains(key), limit.status.canAgeToStale else { return limit }
            return limit.replacingStatusOverride(with: .stale)
        }
        reports = snapshot.providerStatuses.map { companionStatus in
            let report = companionStatus.storedProviderReport
            let key = CompanionUsageAccountKey(status: companionStatus)
            guard staleAccounts.contains(key), report.status.canAgeToStale else { return report }
            return report.replacingStatus(with: .stale)
        }
    }
}

private struct CompanionUsageAccountState {
    var observedAt: Date?
    var hasLimits = false
    var hasAgeSensitiveLimits = false

    mutating func observe(_ date: Date?) {
        guard let date else { return }
        observedAt = observedAt.map { max($0, date) } ?? date
    }
}

private struct CompanionUsageAccountKey: Hashable {
    let provider: Provider
    let companionAccountID: String

    init(limit: CompanionLimit) {
        provider = limit.provider
        companionAccountID = limit.companionAccountID
    }

    init(status: CompanionProviderStatus) {
        provider = status.provider
        companionAccountID = status.companionAccountID
    }
}

private extension UsageLimit {
    func replacingStatusOverride(with status: UsageStatus) -> UsageLimit {
        UsageLimit(
            id: id,
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            label: label,
            windowLabel: windowLabel,
            modelLabel: modelLabel,
            unit: unit,
            used: used,
            limit: limit,
            resetsAt: resetsAt,
            lastUpdatedAt: lastUpdatedAt,
            confidence: confidence,
            freshnessMode: freshnessMode,
            presentationAssumption: presentationAssumption,
            statusOverride: status,
            note: note
        )
    }

    var isAnthropicStatuslinePlaceholder: Bool {
        provider == .anthropic
            && label.localizedCaseInsensitiveContains("status")
            && unit == .unknown
            && used == nil
            && limit == nil
            && resetsAt == nil
    }
}

private extension StoredProviderReport {
    func replacingStatus(with status: UsageStatus) -> StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            status: status,
            errorMessage: errorMessage
        )
    }
}

private extension UsageStatus {
    var canAgeToStale: Bool {
        switch self {
        case .healthy, .close, .limited, .loading:
            true
        case .failure, .stale, .unknown:
            false
        }
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
