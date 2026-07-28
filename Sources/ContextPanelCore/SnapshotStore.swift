import Foundation

public struct StoredUsageSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let savedAt: Date
    public let snapshot: UsageSnapshot
    public let reports: [StoredProviderReport]
    public let promptCacheObservations: [PromptCacheObservation]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case savedAt
        case snapshot
        case reports
        case promptCacheObservations
    }

    public init(
        savedAt: Date,
        snapshot: UsageSnapshot,
        reports: [StoredProviderReport] = [],
        promptCacheObservations: [PromptCacheObservation] = []
    ) {
        self.schemaVersion = 1
        self.savedAt = savedAt
        self.snapshot = snapshot
        self.reports = Self.normalizedReports(reports, limits: snapshot.limits)
        self.promptCacheObservations = promptCacheObservations
    }

    public init(savedAt: Date, refreshResult: ConnectorRefreshResult) {
        self.init(
            savedAt: savedAt,
            snapshot: refreshResult.snapshot,
            reports: refreshResult.reports.map(StoredProviderReport.init(report:)),
            promptCacheObservations: refreshResult.promptCacheObservations
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        snapshot = try container.decode(UsageSnapshot.self, forKey: .snapshot)
        let decodedReports = try container.decodeIfPresent([StoredProviderReport].self, forKey: .reports) ?? []
        reports = Self.normalizedReports(decodedReports, limits: snapshot.limits)
        promptCacheObservations = try container.decodeIfPresent(
            [PromptCacheObservation].self,
            forKey: .promptCacheObservations
        ) ?? []
    }

    private static func normalizedReports(
        _ reports: [StoredProviderReport],
        limits: [UsageLimit]
    ) -> [StoredProviderReport] {
        reports.map { report in
            guard report.status.coversProviderFreshness else { return report }
            let hasMatchingLimit = limits.contains { limit in
                guard limit.provider == report.provider else { return false }
                if let configuredAccountID = report.configuredAccountID {
                    return limit.configuredAccountID == configuredAccountID || limit.accountID == report.accountID
                }
                return limit.accountID == report.accountID
            }
            guard !hasMatchingLimit else { return report }
            return report.withStatus(.unknown)
        }
    }
}

public extension StoredUsageSnapshot {
    func providerAccessAlerts(
        stalenessPolicy: SnapshotStoreStalenessPolicy,
        now: Date
    ) -> [ProviderAccessAlert] {
        let attention = stalenessPolicy.refreshAttentionSummary(for: self, now: now)
        return reports.providerAccessPresentationReports(
            snapshotIsStale: attention?.isSnapshotAgeStale == true,
            expiredResetLimits: attention?.expiredResetLimits ?? []
        ).providerAccessAlerts
    }
}

public struct StoredProviderReport: Codable, Equatable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let generatedAt: Date
    public let resetCredits: ProviderResetCreditSummary?
    public let status: UsageStatus
    public let accessState: ProviderAccessState
    public let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case accountID
        case configuredAccountID
        case accountName
        case generatedAt
        case resetCredits
        case status
        case accessState
        case errorMessage
    }

    public init(
        provider: Provider,
        accountID: String,
        configuredAccountID: String? = nil,
        accountName: String,
        generatedAt: Date,
        resetCredits: ProviderResetCreditSummary? = nil,
        status: UsageStatus,
        accessState: ProviderAccessState = .unknown,
        errorMessage: String?
    ) {
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
        self.accountName = accountName
        self.generatedAt = generatedAt
        self.resetCredits = resetCredits
        self.status = status
        self.accessState = accessState.retainingCurrentProviderObservation(for: status)
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(Provider.self, forKey: .provider)
        accountID = try container.decode(String.self, forKey: .accountID)
        configuredAccountID = try container.decodeIfPresent(String.self, forKey: .configuredAccountID)
        accountName = try container.decode(String.self, forKey: .accountName)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        resetCredits = try container.decodeIfPresent(ProviderResetCreditSummary.self, forKey: .resetCredits)
        status = try container.decode(UsageStatus.self, forKey: .status)
        accessState = try container.decodeIfPresent(ProviderAccessState.self, forKey: .accessState)?
            .retainingCurrentProviderObservation(for: status) ?? .unknown
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            .map(ConnectorRedactor.safeErrorDescription)
    }

    public init(report: ProviderConnectorReport) {
        self.init(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID,
            accountName: report.accountName,
            generatedAt: report.generatedAt,
            resetCredits: report.resetCredits,
            status: report.status,
            accessState: report.accessState,
            errorMessage: report.errorMessage
        )
    }

    public var configuredOrResolvedAccountID: String {
        configuredAccountID ?? accountID
    }

    func withStatus(_ replacementStatus: UsageStatus) -> StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            resetCredits: resetCredits,
            status: replacementStatus,
            accessState: accessState,
            errorMessage: errorMessage
        )
    }

    func withAccessState(_ replacementAccessState: ProviderAccessState) -> StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            resetCredits: resetCredits,
            status: status,
            accessState: replacementAccessState,
            errorMessage: errorMessage
        )
    }

    func withResetCredits(_ replacementResetCredits: ProviderResetCreditSummary?) -> StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            resetCredits: replacementResetCredits,
            status: status,
            accessState: accessState,
            errorMessage: errorMessage
        )
    }

    public var providerAccessAlert: ProviderAccessAlert? {
        guard accessState.requiresProminentPresentation else { return nil }
        return ProviderAccessAlert(
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            accessState: accessState
        )
    }

    public func matchesAccount(of limit: UsageLimit) -> Bool {
        matchesAccount(
            provider: limit.provider,
            accountID: limit.accountID,
            configuredAccountID: limit.configuredAccountID
        )
    }

    func matchesAccount(of report: ProviderConnectorReport) -> Bool {
        matchesAccount(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID
        )
    }

    private func matchesAccount(
        provider otherProvider: Provider,
        accountID otherAccountID: String,
        configuredAccountID otherConfiguredAccountID: String?
    ) -> Bool {
        guard provider == otherProvider else { return false }
        if let configuredAccountID {
            return otherConfiguredAccountID == configuredAccountID || otherAccountID == accountID
        }
        return otherAccountID == accountID
    }
}

public struct ProviderAccessAlert: Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let generatedAt: Date
    public let accessState: ProviderAccessState

    public var id: String {
        let accountIdentity = ProviderAccountIdentity.unique(
            accountID: accountID,
            configuredAccountID: configuredAccountID
        )
        return "\(provider.rawValue):\(accountIdentity)"
    }

    public var title: String {
        switch accessState.kind {
        case .blockedUntilReset:
            "\(provider.accessProductName) limited"
        case .paidFallbackActive:
            "\(provider.accessProductName) using paid fallback"
        case .degraded:
            "\(provider.accessProductName) availability uncertain"
        case .pressure:
            "\(provider.accessProductName) close to limit"
        case .available:
            "\(provider.accessProductName) available"
        case .unknown:
            "\(provider.accessProductName) availability unknown"
        }
    }

    public var detail: String {
        switch accessState.kind {
        case .blockedUntilReset:
            "Usage credits unavailable"
        case .paidFallbackActive:
            "Plan limit reached; usage credits available"
        case .degraded:
            "Provider access could not be confirmed"
        case .pressure:
            "Provider capacity is close to a limit"
        case .available:
            "Provider access is available"
        case .unknown:
            "Provider access is unknown"
        }
    }

    public var status: UsageStatus {
        switch accessState.kind {
        case .degraded:
            .close
        case .available, .pressure, .blockedUntilReset, .paidFallbackActive, .unknown:
            accessState.statusContribution ?? .unknown
        }
    }

    public func resetDisplayText(now: Date = Date()) -> String? {
        guard let resetsAt = accessState.resetsAt else { return nil }
        if Calendar.current.isDate(resetsAt, inSameDayAs: now) {
            return resetsAt.formatted(date: .omitted, time: .shortened)
        }
        return resetsAt.formatted(date: .abbreviated, time: .shortened)
    }

    public func resetAccessibilityText(now: Date = Date()) -> String? {
        accessState.resetsAt?.formatted(date: .abbreviated, time: .shortened)
    }
}

public extension Collection where Element == StoredProviderReport {
    var providerAccessAlerts: [ProviderAccessAlert] {
        compactMap(\.providerAccessAlert)
        .sorted { lhs, rhs in
            let lhsRank = lhs.accessState.kind.alertSortRank
            let rhsRank = rhs.accessState.kind.alertSortRank
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if lhs.provider != rhs.provider { return lhs.provider.displayName < rhs.provider.displayName }
            return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
        }
    }

    var primaryProviderAccessAlert: ProviderAccessAlert? {
        providerAccessAlerts.first
    }
}

extension Array where Element == StoredProviderReport {
    func providerAccessPresentationReports(
        snapshotIsStale: Bool,
        expiredResetLimits: [UsageLimit]
    ) -> [StoredProviderReport] {
        map { report in
            let matchingExpiredLimits = expiredResetLimits.filter { report.matchesAccount(of: $0) }
            let resetRefreshIsDue = switch report.accessState.kind {
            case .blockedUntilReset, .paidFallbackActive:
                if let accessReset = report.accessState.resetsAt {
                    matchingExpiredLimits.contains { $0.resetsAt == accessReset }
                } else {
                    !matchingExpiredLimits.isEmpty
                }
            case .degraded:
                !matchingExpiredLimits.isEmpty
            case .available, .pressure, .unknown:
                false
            }
            return snapshotIsStale || resetRefreshIsDue
                ? report.withAccessState(.unknown)
                : report
        }
    }
}

private extension Provider {
    var accessProductName: String {
        switch self {
        case .anthropic:
            "Claude"
        case .openAI, .google:
            displayName
        }
    }
}

private extension ProviderAccessState.Kind {
    var alertSortRank: Int {
        switch self {
        case .blockedUntilReset:
            3
        case .paidFallbackActive:
            2
        case .degraded:
            1
        case .available, .pressure, .unknown:
            0
        }
    }
}

private extension UsageStatus {
    var coversProviderFreshness: Bool {
        switch self {
        case .healthy, .close, .limited:
            true
        case .failure, .loading, .stale, .unknown:
            false
        }
    }
}

public extension Collection where Element == StoredProviderReport {
    var reconnectBlockingFailures: [StoredProviderReport] {
        reconnectBlockingFailures(coveredBy: [])
    }

    func reconnectBlockingFailures(coveredBy limits: [UsageLimit]) -> [StoredProviderReport] {
        let workingGroups = Set(
            filter(\.coversReconnectFailure).map(\.reconnectGroupKey)
        )
        return filter { report in
            report.status == .failure
                && !workingGroups.contains(report.reconnectGroupKey)
                && !limits.contains { $0.coversReconnectFailure(report) }
        }
    }

    var hasReconnectBlockingFailure: Bool {
        !reconnectBlockingFailures.isEmpty
    }
}

public extension StoredProviderReport {
    var requiresCredentialReconnect: Bool {
        guard status == .failure else { return false }
        return switch RefreshFailureCategory(errorMessage: errorMessage) {
        case .oauthInvalidClient, .oauthExpired, .oauthMissingRefreshToken, .credentialFormat, .missingAuth:
            true
        case .none, .providerAuthorization, .httpFailure, .rateLimited, .decoding, .processFailure, .filePermission, .unknown:
            false
        }
    }

    var userFacingErrorMessage: String? {
        guard let errorMessage else { return nil }
        return errorMessage
    }
}

private extension StoredProviderReport {
    var reconnectGroupKey: ProviderReportReconnectGroupKey {
        ProviderReportReconnectGroupKey(
            provider: provider,
            accountID: accountID
        )
    }

    var coversReconnectFailure: Bool {
        switch status {
        case .healthy, .close, .limited:
            true
        case .failure, .loading, .stale, .unknown:
            false
        }
    }
}

private extension UsageLimit {
    func markingPreservedFailure() -> UsageLimit {
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
            freshnessMode: .polling,
            presentationAssumption: presentationAssumption,
            statusOverride: .stale,
            note: note
        )
    }

    func coversReconnectFailure(_ report: StoredProviderReport) -> Bool {
        guard provider == report.provider,
              accountID == report.accountID,
              status.coversProviderFreshness,
              let lastUpdatedAt,
              lastUpdatedAt >= report.generatedAt
        else { return false }
        return true
    }
}

private struct ProviderReportReconnectGroupKey: Hashable {
    let provider: Provider
    let accountID: String
}

public enum SnapshotStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(version: Int)
    case corruptStore(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported snapshot schema version \(version)"
        case let .corruptStore(message):
            message
        }
    }
}

public struct SnapshotStoreLoadResult: Equatable, Sendable {
    public let snapshot: StoredUsageSnapshot?
    public let status: UsageStatus
    public let errorMessage: String?

    public init(snapshot: StoredUsageSnapshot?, status: UsageStatus, errorMessage: String? = nil) {
        self.snapshot = snapshot
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.safeErrorDescription)
    }
}

public struct RefreshAttentionSummary: Codable, Equatable, Sendable {
    public let providers: [Provider]
    public let reports: [StoredProviderReport]
    public let expiredResetLimits: [UsageLimit]
    public let isSnapshotAgeStale: Bool

    public init(
        providers: [Provider],
        reports: [StoredProviderReport],
        expiredResetLimits: [UsageLimit],
        isSnapshotAgeStale: Bool
    ) {
        self.providers = providers
        self.reports = reports
        self.expiredResetLimits = expiredResetLimits
        self.isSnapshotAgeStale = isSnapshotAgeStale
    }

    public var singleProvider: Provider? {
        providers.count == 1 ? providers.first : nil
    }

    public var refreshNeededTitle: String {
        if let singleProvider {
            return "\(singleProvider.displayName) refresh needed"
        }
        if providers.count > 1 {
            return "Provider refresh needed"
        }
        return "Refresh needed"
    }

    public var refreshNeededDetail: String {
        if let report = reports.first {
            let target = "\(report.provider.displayName) · \(report.accountName)"
            switch report.status {
            case .stale:
                return "\(target) returned stale data. Refresh now, then check that provider if it persists."
            case .unknown:
                if let errorMessage = report.userFacingErrorMessage,
                   !errorMessage.isEmpty {
                    return "\(target) needs attention: \(errorMessage)"
                }
                return "\(target) did not return a complete refresh report. Refresh now, then check that provider if it persists."
            case .failure:
                if let errorMessage = report.userFacingErrorMessage,
                   !errorMessage.isEmpty {
                    return "\(target) needs attention: \(errorMessage)"
                }
                return "\(target) needs attention. Reconnect this account, then refresh."
            case .healthy, .close, .limited, .loading:
                break
            }
        }

        if let limit = expiredResetLimits.first {
            let target = "\(limit.provider.displayName) · \(limit.accountName)"
            let window = limit.windowLabel ?? limit.label
            return "\(target) still reports an expired \(window) reset window. Refresh now, then check that provider if it persists."
        }

        if isSnapshotAgeStale {
            return "The latest data is old. Refresh Context Panel to update provider data."
        }

        return "Refresh Context Panel to update provider data."
    }
}

public struct SnapshotStoreQuery: Equatable, Sendable {
    public let provider: Provider?
    public let accountID: String?
    public let since: Date?
    public let limit: Int?

    public init(provider: Provider? = nil, accountID: String? = nil, since: Date? = nil, limit: Int? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.since = since
        self.limit = limit
    }
}

public struct SnapshotStoreStalenessPolicy: Equatable, Sendable {
    public let maximumAge: TimeInterval
    public let resetExpiryRefreshState: ResetExpiryRefreshState?

    public init(
        maximumAge: TimeInterval = 15 * 60,
        resetExpiryRefreshState: ResetExpiryRefreshState? = nil
    ) {
        precondition(maximumAge >= 0, "maximumAge must not be negative")
        self.maximumAge = maximumAge
        self.resetExpiryRefreshState = resetExpiryRefreshState
    }

    public static func appDefault(maximumAge: TimeInterval) -> SnapshotStoreStalenessPolicy {
        SnapshotStoreStalenessPolicy(
            maximumAge: maximumAge,
            resetExpiryRefreshState: ResetExpiryRefreshStateStore.appDefault().load()
        )
    }

    public func status(for storedSnapshot: StoredUsageSnapshot?, now: Date) -> UsageStatus {
        guard let storedSnapshot else { return .unknown }
        if ageIsStale(in: storedSnapshot.snapshot, now: now) {
            return .stale
        }
        if !presentationResetRefreshDueLimits(in: storedSnapshot.snapshot, now: now).isEmpty {
            return .stale
        }
        return storedSnapshot.snapshot.aggregateStatus
    }

    public func needsResetRefresh(for storedSnapshot: StoredUsageSnapshot?, now: Date) -> Bool {
        guard let storedSnapshot else { return false }
        return !resetRefreshDueLimits(in: storedSnapshot.snapshot, now: now).isEmpty
    }

    public func nextStaleTransitionDate(for snapshot: UsageSnapshot, now: Date) -> Date? {
        let ageTransition = hasAgeSensitiveLimits(in: snapshot)
            ? snapshot.generatedAt.addingTimeInterval(maximumAge + 1)
            : nil
        let resetTransition = resetExpiryRefreshState?.nextRefreshCheckDate(for: snapshot, now: now)
            ?? snapshot.nextResetRefreshDate(now: now)
        return [ageTransition, resetTransition]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }

    public func refreshAttentionSummary(for storedSnapshot: StoredUsageSnapshot?, now: Date) -> RefreshAttentionSummary? {
        guard let storedSnapshot else { return nil }
        let snapshotAgeIsStale = ageIsStale(in: storedSnapshot.snapshot, now: now)
        let expiredResetLimits = presentationResetRefreshDueLimits(in: storedSnapshot.snapshot, now: now)
        let reconnectFailures = storedSnapshot.reports.reconnectBlockingFailures(coveredBy: storedSnapshot.snapshot.limits)
        let reports = storedSnapshot.reports.filter { report in
            if report.status == .failure {
                return reconnectFailures.contains(report)
            }
            return report.status == .stale || (report.status == .unknown && report.errorMessage != nil)
        }

        guard snapshotAgeIsStale || !expiredResetLimits.isEmpty || !reports.isEmpty else { return nil }
        var providerSet = Set(reports.map(\.provider) + expiredResetLimits.map(\.provider))
        if providerSet.isEmpty, snapshotAgeIsStale {
            providerSet = Set(storedSnapshot.snapshot.limits.map(\.provider))
        }
        let providers = Provider.allCases.filter { providerSet.contains($0) }
        return RefreshAttentionSummary(
            providers: providers,
            reports: reports.sortedByRefreshAttention,
            expiredResetLimits: expiredResetLimits.sortedByRefreshAttention,
            isSnapshotAgeStale: snapshotAgeIsStale
        )
    }

    private func ageIsStale(in snapshot: UsageSnapshot, now: Date) -> Bool {
        hasAgeSensitiveLimits(in: snapshot)
            && now.timeIntervalSince(snapshot.generatedAt) > maximumAge
    }

    private func hasAgeSensitiveLimits(in snapshot: UsageSnapshot) -> Bool {
        snapshot.limits.isEmpty || snapshot.limits.contains { !$0.usesEventDrivenFreshness }
    }

    private func presentationResetRefreshDueLimits(in snapshot: UsageSnapshot, now: Date) -> [UsageLimit] {
        snapshot.limits.filter { presentationResetRefreshIsDue(for: $0, now: now) }
    }

    private func resetRefreshDueLimits(in snapshot: UsageSnapshot, now: Date) -> [UsageLimit] {
        snapshot.limits.filter { resetRefreshIsDue(for: $0, now: now) }
    }

    func presentationResetRefreshIsDue(for limit: UsageLimit, now: Date) -> Bool {
        !limit.usesEventDrivenFreshness && resetRefreshIsDue(for: limit, now: now)
    }

    private func resetRefreshIsDue(for limit: UsageLimit, now: Date) -> Bool {
        guard limit.isResetRefreshDue(now: now) else { return false }
        guard let resetExpiryRefreshState else { return true }
        guard let key = ResetExpiryRefreshKey(limit: limit) else { return false }
        guard let record = resetExpiryRefreshState.record(for: key) else { return true }
        guard let nextRetryAt = record.nextRetryAt else { return limit.usesEventDrivenFreshness }
        return nextRetryAt <= now
    }
}

public final class SnapshotStoreStalenessPolicyCache {
    public private(set) var policy: SnapshotStoreStalenessPolicy
    private let loadPolicy: () -> SnapshotStoreStalenessPolicy

    public init(
        initialPolicy: SnapshotStoreStalenessPolicy,
        loadPolicy: @escaping () -> SnapshotStoreStalenessPolicy
    ) {
        policy = initialPolicy
        self.loadPolicy = loadPolicy
    }

    @discardableResult
    public func reload() -> SnapshotStoreStalenessPolicy {
        let policy = loadPolicy()
        self.policy = policy
        return policy
    }
}

private extension Array where Element == StoredProviderReport {
    var sortedByRefreshAttention: [StoredProviderReport] {
        sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status.refreshAttentionSortRank > rhs.status.refreshAttentionSortRank }
            if lhs.provider != rhs.provider { return lhs.provider.displayName < rhs.provider.displayName }
            return lhs.accountName < rhs.accountName
        }
    }
}

private extension Array where Element == UsageLimit {
    var sortedByRefreshAttention: [UsageLimit] {
        sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider.displayName < rhs.provider.displayName }
            if lhs.accountName != rhs.accountName { return lhs.accountName < rhs.accountName }
            if lhs.resetsAt != rhs.resetsAt { return (lhs.resetsAt ?? .distantFuture) < (rhs.resetsAt ?? .distantFuture) }
            return lhs.label < rhs.label
        }
    }
}

private extension UsageStatus {
    var refreshAttentionSortRank: Int {
        switch self {
        case .failure: 3
        case .unknown: 2
        case .stale: 1
        case .healthy, .close, .limited, .loading: 0
        }
    }
}

public struct JSONSnapshotStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var currentSnapshotURL: URL {
        rootDirectory.appending(path: "current-snapshot.json")
    }

    public var historyDirectoryURL: URL {
        rootDirectory.appending(path: "history", directoryHint: .isDirectory)
    }

    public func save(_ storedSnapshot: StoredUsageSnapshot) throws {
        try ensureDirectories()
        let data = try Self.makeEncoder().encode(storedSnapshot)
        try data.write(to: currentSnapshotURL, options: [.atomic])
        let historyURL = historyURL(for: storedSnapshot.savedAt)
        try data.write(to: historyURL, options: [.atomic])
    }

    public func saveMerged(refreshResult: ConnectorRefreshResult, savedAt: Date) throws {
        try saveMerged(refreshResult: refreshResult, savedAt: savedAt, preservesUnreportedAccounts: true)
    }

    public func saveMerged(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date,
        preservesUnreportedAccounts: Bool
    ) throws {
        let reportedAccounts = Set(
            refreshResult.reports.map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) }
        )
        let replacementAccounts = Set(
            refreshResult.reports
                .filter { !$0.limits.isEmpty }
                .map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) }
        )
        let authoritativeEmptyAccounts = Set(
            refreshResult.reports
                .filter { $0.limits.isEmpty && $0.status != .failure }
                .map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) }
        )
        let current = loadCurrent().snapshot
        let legacyGoogleDefaultAccountIDs = Self.legacyGoogleDefaultAccountIDs(in: current)
        let preservedLimits: [UsageLimit]
        let preservedReports: [StoredProviderReport]
        if preservesUnreportedAccounts {
            preservedLimits = current?.snapshot.limits.filter { limit in
                let key = ProviderAccountKey(provider: limit.provider, accountID: limit.accountID)
                return !authoritativeEmptyAccounts.contains(key)
                    && !replacementAccounts.contains(key)
                    && !refreshResult.reports.contains { report in
                        report.provider == .google
                            && report.configuredAccountID == "google-antigravity-default"
                            && report.accountID != limit.accountID
                            && limit.provider == .google
                            && Self.isLegacyGoogleDefault(
                                accountID: limit.accountID,
                                configuredAccountID: limit.configuredAccountID,
                                legacyAccountIDs: legacyGoogleDefaultAccountIDs
                            )
                    }
            } ?? []
            preservedReports = current?.reports.filter { report in
                let key = ProviderAccountKey(provider: report.provider, accountID: report.accountID)
                return !authoritativeEmptyAccounts.contains(key)
                    && !reportedAccounts.contains(key)
                    && !refreshResult.reports.contains { refreshed in
                        refreshed.provider == .google
                            && refreshed.configuredAccountID == "google-antigravity-default"
                            && refreshed.accountID != report.accountID
                            && report.provider == .google
                            && Self.isLegacyGoogleDefault(
                                accountID: report.accountID,
                                configuredAccountID: report.configuredAccountID,
                                legacyAccountIDs: legacyGoogleDefaultAccountIDs
                            )
                    }
            } ?? []
        } else {
            preservedLimits = current?.snapshot.limits.filter { limit in
                let key = ProviderAccountKey(provider: limit.provider, accountID: limit.accountID)
                return reportedAccounts.contains(key)
                    && !replacementAccounts.contains(key)
                    && refreshResult.reports.contains { report in
                        report.status == .failure
                            && report.limits.isEmpty
                            && report.provider == limit.provider
                            && report.accountID == limit.accountID
                    }
            } ?? []
            preservedReports = []
        }

        let currentAccountKeys = Set(
            current?.snapshot.limits.map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) } ?? []
        )
        let successfulProviders = Set(refreshResult.reports.filter { !$0.limits.isEmpty }.map(\.provider))
        let preservedFailureLimits = current?.snapshot.limits.filter { limit in
            let limitKey = ProviderAccountKey(provider: limit.provider, accountID: limit.accountID)
            guard !replacementAccounts.contains(limitKey) else { return false }
            return refreshResult.reports.contains { report in
                guard report.status == .failure, report.limits.isEmpty, report.provider == limit.provider else {
                    return false
                }
                let reportKey = ProviderAccountKey(provider: report.provider, accountID: report.accountID)
                if currentAccountKeys.contains(reportKey) {
                    return report.accountID == limit.accountID
                }
                if report.provider == .google,
                   report.configuredAccountID == "google-antigravity-default",
                   report.accountID != limit.accountID,
                   Self.isLegacyGoogleDefault(
                       accountID: limit.accountID,
                       configuredAccountID: limit.configuredAccountID,
                       legacyAccountIDs: legacyGoogleDefaultAccountIDs
                ) {
                    return false
                }
                if let configuredAccountID = report.configuredAccountID {
                    if limit.configuredAccountID == configuredAccountID {
                        return true
                    }
                    if report.provider == .google,
                       configuredAccountID == "google-antigravity-default",
                       limit.configuredAccountID == nil {
                        return true
                    }
                    return false
                }
                return !successfulProviders.contains(report.provider)
            }
        } ?? []

        let isPromptCacheOnlySnapshot = refreshResult.reports.isEmpty
            && (current?.snapshot.limits.isEmpty ?? true)
            && (current?.reports.isEmpty ?? true)
        let isAuthoritativeEmptySnapshot = refreshResult.reports.isEmpty
            && !preservesUnreportedAccounts
        let mergedGeneratedAt: Date
        if isAuthoritativeEmptySnapshot {
            mergedGeneratedAt = refreshResult.generatedAt
        } else if refreshResult.reports.isEmpty && !isPromptCacheOnlySnapshot {
            mergedGeneratedAt = current?.snapshot.generatedAt ?? refreshResult.generatedAt
        } else {
            mergedGeneratedAt = refreshResult.generatedAt
        }
        let mergedSnapshot = UsageSnapshot(
            generatedAt: mergedGeneratedAt,
            limits: (preservedFailureLimits.map { $0.markingPreservedFailure() } + preservedLimits + refreshResult.snapshot.limits)
                .deduplicatedByID()
        )
        let refreshedReports = refreshResult.reports.map { report in
            let storedReport = StoredProviderReport(report: report)
            let previousResetCredits = current?.reports.lazy
                .filter { $0.matchesAccount(of: report) }
                .compactMap(\.resetCredits)
                .reduce(nil as ProviderResetCreditSummary?, ProviderResetCreditSummary.preferred)
            guard report.status == .failure,
                  report.resetCredits == nil,
                  let previousResetCredits
            else {
                return storedReport
            }
            return storedReport.withResetCredits(previousResetCredits.preservingCountAfterRefreshFailure)
        }
        let mergedReports = preservedReports + refreshedReports
        let preservedPromptCacheObservations = current?.promptCacheObservations.filter { observation in
            savedAt.timeIntervalSince(observation.observedAt) <= PromptCacheSummary.defaultMaximumAge
                && !refreshResult.promptCacheObservations.contains { refreshed in refreshed.id == observation.id }
        } ?? []

        try save(StoredUsageSnapshot(
            savedAt: savedAt,
            snapshot: mergedSnapshot,
            reports: mergedReports,
            promptCacheObservations: (refreshResult.promptCacheObservations + preservedPromptCacheObservations)
                .filter { savedAt.timeIntervalSince($0.observedAt) <= PromptCacheSummary.defaultMaximumAge }
                .deduplicatedPromptCacheObservations()
        ))
    }

    private static func legacyGoogleDefaultAccountIDs(in snapshot: StoredUsageSnapshot?) -> Set<String> {
        Set(
            (snapshot?.snapshot.limits.compactMap { limit -> String? in
                guard isLegacyGoogleDefault(limit) else { return nil }
                return limit.accountID
            } ?? [])
                + (snapshot?.reports.compactMap { report -> String? in
                    guard isLegacyGoogleDefault(report) else { return nil }
                    return report.accountID
                } ?? [])
        )
    }

    private static func isLegacyGoogleDefault(
        accountID: String,
        configuredAccountID: String?,
        legacyAccountIDs: Set<String>
    ) -> Bool {
        isLegacyGoogleDefault(configuredAccountID: configuredAccountID)
            || (configuredAccountID == nil && legacyAccountIDs.contains(accountID))
    }

    private static func isLegacyGoogleDefault(configuredAccountID: String?) -> Bool {
        configuredAccountID == "gemini-code-assist-default"
    }

    private static func isLegacyGoogleDefault(_ limit: UsageLimit) -> Bool {
        guard limit.provider == .google else { return false }
        if isLegacyGoogleDefault(configuredAccountID: limit.configuredAccountID) { return true }
        guard limit.configuredAccountID == nil, limit.accountName == "Gemini" else { return false }
        let modelText = [limit.label, limit.modelLabel].compactMap { $0 }.joined(separator: " ").lowercased()
        return modelText.contains("gemini")
    }

    private static func isLegacyGoogleDefault(_ report: StoredProviderReport) -> Bool {
        guard report.provider == .google else { return false }
        if isLegacyGoogleDefault(configuredAccountID: report.configuredAccountID) { return true }
        return report.configuredAccountID == nil && report.accountName == "Gemini"
    }

    public func loadCurrent() -> SnapshotStoreLoadResult {
        guard FileManager.default.fileExists(atPath: currentSnapshotURL.path) else {
            return SnapshotStoreLoadResult(snapshot: nil, status: .unknown)
        }

        do {
            let snapshot = try loadSnapshot(from: currentSnapshotURL)
            return SnapshotStoreLoadResult(snapshot: snapshot, status: snapshot.snapshot.aggregateStatus)
        } catch {
            return SnapshotStoreLoadResult(
                snapshot: nil,
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    public func loadCurrent(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> SnapshotStoreLoadResult {
        let result = loadCurrent()
        guard result.status != .failure else { return result }
        return SnapshotStoreLoadResult(
            snapshot: result.snapshot,
            status: policy.status(for: result.snapshot, now: now),
            errorMessage: result.errorMessage
        )
    }

    public func historyCount() -> Int {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: historyDirectoryURL.path) else {
            return 0
        }
        return fileNames.lazy.filter { ($0 as NSString).pathExtension == "json" }.count
    }

    public func loadHistory(query: SnapshotStoreQuery = SnapshotStoreQuery()) -> [StoredUsageSnapshot] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let snapshots = urls
            .filter { $0.pathExtension == "json" }
            .filter { url in
                guard let since = query.since else { return true }
                let fileName = url.deletingPathExtension().lastPathComponent
                guard Self.isHistoryFileTimestamp(fileName) else { return true }
                return fileName >= ContextPanelDateFormatting.historyFileTimestamp(from: since)
            }
            .compactMap { try? loadSnapshot(from: $0) }
            .filter { snapshot in
                if let since = query.since, snapshot.savedAt < since { return false }
                if let provider = query.provider, !snapshot.snapshot.limits.contains(where: { $0.provider == provider }) {
                    return false
                }
                if let accountID = query.accountID, !snapshot.snapshot.limits.contains(where: { $0.accountID == accountID }) {
                    return false
                }
                return true
            }
            .sorted { $0.savedAt > $1.savedAt }

        if let limit = query.limit {
            return Array(snapshots.prefix(max(limit, 0)))
        }
        return snapshots
    }

    private static func isHistoryFileTimestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 20 else { return false }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 45, 16: 45, 19: 90]
        for (index, byte) in bytes.enumerated() {
            if let separator = separators[index] {
                guard byte == separator else { return false }
            } else if !(48 ... 57).contains(byte) {
                return false
            }
        }
        return true
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadSnapshot(from url: URL) throws -> StoredUsageSnapshot {
        let data = try Data(contentsOf: url)
        let snapshot = try Self.makeDecoder().decode(StoredUsageSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else {
            throw SnapshotStoreError.unsupportedSchema(version: snapshot.schemaVersion)
        }
        return snapshot
    }

    private func historyURL(for date: Date) -> URL {
        let timestamp = ContextPanelDateFormatting.historyFileTimestamp(from: date)
        return historyDirectoryURL.appending(path: "\(timestamp).json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Array where Element == PromptCacheObservation {
    func deduplicatedPromptCacheObservations() -> [PromptCacheObservation] {
        var seen = Set<String>()
        return sorted { lhs, rhs in
            lhs.observedAt > rhs.observedAt
        }.filter { observation in
            seen.insert(observation.id).inserted
        }
    }
}

private struct ProviderAccountKey: Hashable {
    let provider: Provider
    let accountID: String
}

private extension Array where Element == UsageLimit {
    func deduplicatedByID() -> [UsageLimit] {
        var seen = Set<String>()
        return filter { limit in
            seen.insert(limit.id).inserted
        }
    }
}

extension ContextPanelDateFormatting {
    static func historyFileTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
