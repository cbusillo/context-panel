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

public struct StoredProviderReport: Codable, Equatable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let generatedAt: Date
    public let status: UsageStatus
    public let errorMessage: String?

    public init(
        provider: Provider,
        accountID: String,
        configuredAccountID: String? = nil,
        accountName: String,
        generatedAt: Date,
        status: UsageStatus,
        errorMessage: String?
    ) {
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
        self.accountName = accountName
        self.generatedAt = generatedAt
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }

    public init(report: ProviderConnectorReport) {
        self.init(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID,
            accountName: report.accountName,
            generatedAt: report.generatedAt,
            status: report.status,
            errorMessage: report.errorMessage
        )
    }

    func withStatus(_ replacementStatus: UsageStatus) -> StoredProviderReport {
        StoredProviderReport(
            provider: provider,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            generatedAt: generatedAt,
            status: replacementStatus,
            errorMessage: errorMessage
        )
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
    var userFacingErrorMessage: String? {
        guard let errorMessage else { return nil }
        if provider == .google {
            if errorMessage.isGoogleKeychainApprovalError {
                return "Google Antigravity quota needs macOS Keychain approval. Click Refresh for Google, then choose Always Allow for the \"gemini\" keychain item."
            }
            if errorMessage.isGoogleAntigravityAccessTokenExpiredError {
                return "Google Antigravity access token expired. Open Antigravity so it can refresh its Google session, then refresh Google in Context Panel."
            }
            if errorMessage.isGoogleCodeAssistRejectedQuotaAccessError {
                return "Google Code Assist rejected quota access for this Antigravity account. Check the Antigravity or Google account, then refresh Google in Context Panel."
            }
        }
        return errorMessage
    }
}

private extension String {
    var isGoogleKeychainApprovalError: Bool {
        let lowercasedMessage = lowercased()
        guard lowercasedMessage.contains("keychain") else { return false }
        return lowercasedMessage.contains("status -128")
            || lowercasedMessage.contains("status -25308")
            || lowercasedMessage.contains("interaction is not allowed")
            || lowercasedMessage.contains("user interaction")
            || lowercasedMessage.contains("always allow")
    }

    var isGoogleAntigravityAccessTokenExpiredError: Bool {
        let lowercasedMessage = lowercased()
        return lowercasedMessage.contains("google antigravity access token has expired")
            || lowercasedMessage.contains("open antigravity so it can refresh its google session")
    }

    var isGoogleCodeAssistRejectedQuotaAccessError: Bool {
        let lowercasedMessage = lowercased()
        return lowercasedMessage.contains("code assist rejected quota access")
            || lowercasedMessage.contains("google antigravity local login was rejected")
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
    func coversReconnectFailure(_ report: StoredProviderReport) -> Bool {
        guard provider == report.provider else { return false }
        if let configuredAccountID = report.configuredAccountID {
            return self.configuredAccountID == configuredAccountID || accountID == report.accountID
        }
        return accountID == report.accountID
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
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
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
                return "\(target) did not return a complete refresh report. Refresh now, then check that provider if it persists."
            case .failure:
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
            return "The latest snapshot is old. Refresh Context Panel to update provider data."
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
        if now.timeIntervalSince(storedSnapshot.snapshot.generatedAt) > maximumAge {
            return .stale
        }
        if hasDueResetExpiry(in: storedSnapshot.snapshot, now: now) {
            return .stale
        }
        return storedSnapshot.snapshot.aggregateStatus
    }

    public func refreshAttentionSummary(for storedSnapshot: StoredUsageSnapshot?, now: Date) -> RefreshAttentionSummary? {
        guard let storedSnapshot else { return nil }
        let ageIsStale = now.timeIntervalSince(storedSnapshot.snapshot.generatedAt) > maximumAge
        let expiredResetLimits = resetRefreshDueLimits(in: storedSnapshot.snapshot, now: now)
        let reconnectFailures = storedSnapshot.reports.reconnectBlockingFailures(coveredBy: storedSnapshot.snapshot.limits)
        let reports = storedSnapshot.reports.filter { report in
            if report.status == .failure {
                return reconnectFailures.contains(report)
            }
            return report.status == .stale || (report.status == .unknown && report.errorMessage != nil)
        }

        guard ageIsStale || !expiredResetLimits.isEmpty || !reports.isEmpty else { return nil }
        var providerSet = Set(reports.map(\.provider) + expiredResetLimits.map(\.provider))
        if providerSet.isEmpty, ageIsStale {
            providerSet = Set(storedSnapshot.snapshot.limits.map(\.provider))
        }
        let providers = Provider.allCases.filter { providerSet.contains($0) }
        return RefreshAttentionSummary(
            providers: providers,
            reports: reports.sortedByRefreshAttention,
            expiredResetLimits: expiredResetLimits.sortedByRefreshAttention,
            isSnapshotAgeStale: ageIsStale
        )
    }

    private func hasDueResetExpiry(in snapshot: UsageSnapshot, now: Date) -> Bool {
        !resetRefreshDueLimits(in: snapshot, now: now).isEmpty
    }

    private func resetRefreshDueLimits(in snapshot: UsageSnapshot, now: Date) -> [UsageLimit] {
        let dueLimits = snapshot.limits.filter { $0.isResetRefreshDue(now: now) }
        guard !dueLimits.isEmpty else { return [] }
        guard let resetExpiryRefreshState else { return dueLimits }
        return dueLimits.filter { limit in
            guard let key = ResetExpiryRefreshKey(limit: limit) else { return false }
            guard let record = resetExpiryRefreshState.record(for: key) else { return true }
            guard let nextRetryAt = record.nextRetryAt else { return false }
            return nextRetryAt <= now
        }
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
            refreshResult.reports.contains { report in
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
                return !successfulProviders.contains(report.provider)
            }
        } ?? []

        let isPromptCacheOnlySnapshot = refreshResult.reports.isEmpty
            && (current?.snapshot.limits.isEmpty ?? true)
            && (current?.reports.isEmpty ?? true)
        let mergedSnapshot = UsageSnapshot(
            generatedAt: refreshResult.reports.isEmpty && !isPromptCacheOnlySnapshot
                ? (current?.snapshot.generatedAt ?? refreshResult.generatedAt)
                : refreshResult.generatedAt,
            limits: (preservedLimits + preservedFailureLimits + refreshResult.snapshot.limits).deduplicatedByID()
        )
        let mergedReports = preservedReports + refreshResult.reports.map(StoredProviderReport.init(report:))
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

    public func loadHistory(query: SnapshotStoreQuery = SnapshotStoreQuery()) -> [StoredUsageSnapshot] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let snapshots = urls
            .filter { $0.pathExtension == "json" }
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
