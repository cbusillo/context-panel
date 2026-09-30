import Foundation

/// Account membership comes from configuration and reports, never successful limits alone.
public struct ProviderAccountQuota: Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let displayName: String
    public let limits: [UsageLimit]
    public let report: StoredProviderReport?
    public let isEnabled: Bool

    public var status: UsageStatus {
        if !isEnabled { return .unknown }
        if let report, report.status == .failure || report.status == .stale || report.status == .unknown {
            return report.status
        }
        return limits.filter { $0.unit != .credits }.map(\.status).max(by: { rank($0) < rank($1) }) ?? .unknown
    }

    private func rank(_ status: UsageStatus) -> Int {
        switch status {
        case .healthy: 0
        case .close: 1
        case .limited: 2
        case .loading: 3
        case .unknown: 4
        case .stale: 5
        case .failure: 6
        }
    }

    public static func accounts(configurations: [LocalProviderAccountConfiguration],
                                snapshot: UsageSnapshot, reports: [StoredProviderReport]) -> [Self] {
        var rows: [Self] = []
        var seen = Set<String>()
        for configuration in configurations where !configuration.isRetiredSource && configuration.provider != .google {
            let matches = reports.filter(configuration.matchesProviderReport)
            let matchingLimits = snapshot.limits.filter {
                $0.provider == configuration.provider && ($0.configuredAccountID == configuration.id
                    || configuration.providerReportAccountIDs.contains($0.accountID))
            }
            let accountIDs = Set(matches.map(\.accountID)).union(matchingLimits.map(\.accountID))
            if accountIDs.isEmpty {
                rows.append(Self(id: configuration.id, provider: configuration.provider,
                                 displayName: configuration.displayName, limits: [], report: nil,
                                 isEnabled: configuration.isEnabled))
            } else {
                for (ordinal, accountID) in accountIDs.sorted().enumerated() {
                    let key = "\(configuration.provider.rawValue):\(accountID)"
                    guard seen.insert(key).inserted else { continue }
                    let report = matches.filter { $0.accountID == accountID }.max { $0.generatedAt < $1.generatedAt }
                    let limits = matchingLimits.filter { $0.accountID == accountID }
                    let name = accountIDs.count == 1 ? configuration.displayName : "\(configuration.displayName) \(ordinal + 1)"
                    rows.append(Self(id: key, provider: configuration.provider, displayName: name,
                                     limits: limits, report: report, isEnabled: configuration.isEnabled))
                }
            }
        }
        return rows.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.id < $1.id
        }
    }
}

public enum AccountQuotaBurnRateEstimator {
    /// Reuse the reset-aware estimator separately for each account; pooled rates
    /// must never be assigned to every contributing account.
    public static func rates(current: UsageSnapshot, history: [StoredUsageSnapshot], now: Date) -> [String: ObservedBurnRate] {
        var result: [String: ObservedBurnRate] = [:]
        for accountID in Set(current.limits.map(\.accountID)) {
            let snapshot = UsageSnapshot(generatedAt: current.generatedAt,
                                         limits: current.limits.filter { $0.accountID == accountID })
            let accountHistory = history.map {
                StoredUsageSnapshot(savedAt: $0.savedAt, snapshot: UsageSnapshot(
                    generatedAt: $0.snapshot.generatedAt,
                    limits: $0.snapshot.limits.filter { $0.accountID == accountID }
                ))
            }
            let rates = MainLimitBurnRateEstimator.observedBurnRates(current: snapshot, history: accountHistory, now: now)
            for limit in snapshot.limits {
                guard let window = limit.mainLimitWindow,
                      let rate = rates["\(limit.provider.rawValue):\(window.rawValue)"] else { continue }
                result[limit.id] = rate
            }
        }
        return result
    }
}
