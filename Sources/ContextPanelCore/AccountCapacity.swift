import Foundation

/// Account membership comes from local setup, not successful provider responses.
public struct AccountCapacity: Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let name: String
    public let isEnabled: Bool
    public let limits: [UsageLimit]
    public let report: StoredProviderReport?
    public let status: UsageStatus

    public static func rows(
        configuration: [LocalProviderAccountConfiguration],
        snapshot: UsageSnapshot,
        reports: [StoredProviderReport],
        now: Date
    ) -> [Self] {
        var seen = Set<String>()
        return configuration.filter { !$0.isRetiredSource && $0.provider != .google }.flatMap { account -> [Self] in
            let matchingReports = reports.filter { account.matchesProviderReport($0) }
            let matchingLimits = snapshot.limits.filter {
                $0.provider == account.provider && ($0.configuredAccountID == account.id || account.providerReportAccountIDs.contains($0.accountID))
            }
            let sourceFailure = matchingReports.first { $0.status == .failure && account.providerReportAccountIDs.contains($0.accountID) }
            // A failed source read is not an additional logical account. Apply its
            // failure to the last-known members instead of inventing another lane.
            let memberReports = matchingLimits.isEmpty ? matchingReports : matchingReports.filter { $0.accountID != sourceFailure?.accountID }
            let ids = Set(memberReports.map(\.accountID) + matchingLimits.map(\.accountID))
            return (ids.isEmpty ? [account.id] : ids.sorted()).compactMap { id in
                guard seen.insert("\(account.provider.rawValue):\(id)").inserted else { return nil }
                let limits = matchingLimits.filter { $0.accountID == id }
                let report = matchingReports.filter { $0.accountID == id }.max { $0.generatedAt < $1.generatedAt } ?? sourceFailure
                let expired = limits.contains { ($0.resetsAt ?? .distantFuture) <= now }
                let stale = report.map { now.timeIntervalSince($0.generatedAt) > 10 * 60 } ?? false
                let status: UsageStatus = !account.isEnabled ? .unknown
                    : report?.status == .failure ? .failure
                    : stale || expired ? .stale
                    : limits.isEmpty ? .unknown
                    : ([report?.status ?? .unknown] + limits.map(\.status)).contextPanelWorstStatus
                return Self(
                    id: id, provider: account.provider,
                    name: account.accountAliases?[id] ?? (ids.count > 1 ? "\(account.displayName) \(id.suffix(6))" : account.displayName),
                    isEnabled: account.isEnabled, limits: limits, report: report, status: status
                )
            }
        }
    }
}

public enum AccountBurnRateEstimator {
    /// Filter both sides of the estimate. A busy sibling must never supply this account's pace.
    public static func observedBurnRates(
        current: UsageSnapshot, history: [StoredUsageSnapshot], now: Date
    ) -> [String: [String: ObservedBurnRate]] {
        var result: [String: [String: ObservedBurnRate]] = [:]
        for limit in current.limits {
            let accountID = limit.accountID
            let accountHistory = history.compactMap { stored -> StoredUsageSnapshot? in
                let reports = stored.reports.filter { $0.accountID == accountID && $0.provider == limit.provider }
                guard !reports.contains(where: { [.failure, .stale, .unknown].contains($0.status) }) else { return nil }
                return StoredUsageSnapshot(
                    savedAt: stored.savedAt,
                    snapshot: UsageSnapshot(generatedAt: stored.snapshot.generatedAt,
                        limits: stored.snapshot.limits.filter { $0.id == limit.id && $0.accountID == accountID && $0.provider == limit.provider }),
                    reports: reports
                )
            }
            let rates = MainLimitBurnRateEstimator.observedBurnRates(
                current: UsageSnapshot(generatedAt: current.generatedAt, limits: [limit]),
                history: accountHistory, now: now
            )
            if let rate = rates.values.first {
                result[accountID, default: [:]][limit.id] = rate
            }
        }
        return result
    }
}

public extension LocalProviderAccountConfiguration {
    /// The legacy credential belongs only to the migrated default Claude account.
    var oauthCredentialAccountIDs: [String] {
        connectorKind == .claudeOAuthUsage && ["claude-local-default", "claude-oauth-default"].contains(id)
            ? ["claude-local-default", "claude-oauth-default"] : [id]
    }
}
