import Foundation

/// A provider refilled several accounts at once, ahead of their resets and without spending a banked reset (#791).
/// Burn already treats a moved reset time as a new window, so a refill never counts as use.
public struct ProviderRefillEvent: Codable, Equatable, Sendable {
    public let provider: Provider
    public let detectedAt: Date
    public let previousReadingAt: Date
    public let accountIDs: [String]
}

public enum ProviderRefillDetector {
    /// Readings further apart than this can't place a refill.
    static let maximumGap: TimeInterval = 2 * 3_600
    /// The new reset must move later by at least this much.
    static let minimumResetJump: TimeInterval = 3_600

    /// Maps a stored limit to the account ID the snapshot publishes for it.
    public typealias AccountResolver = @Sendable (UsageLimit) -> String

    public static let localAccountID: AccountResolver = { AccountDisplayMetadata.safeID($0.provider, $0.accountID) }

    public static func events(readings: [StoredUsageSnapshot], resolve: AccountResolver = localAccountID) -> [ProviderRefillEvent] {
        let ordered = readings.sorted { $0.savedAt < $1.savedAt }
        return zip(ordered, ordered.dropFirst()).flatMap { previous, current -> [ProviderRefillEvent] in
            guard current.savedAt.timeIntervalSince(previous.savedAt) <= maximumGap else { return [] }
            return Provider.allCases.compactMap { provider in
                event(provider: provider, previous: previous, current: current, resolve: resolve)
            }
        }
    }

    static func event(provider: Provider, previous: StoredUsageSnapshot, current: StoredUsageSnapshot,
                      resolve: AccountResolver) -> ProviderRefillEvent? {
        let before = mainLimits(provider: provider, reading: previous)
        let after = mainLimits(provider: provider, reading: current)
        var refilled: [String] = []
        for (accountID, old) in before {
            // An unstarted window has nothing to refill.
            guard let new = after[accountID], let oldUsed = old.used, oldUsed > 0 else { continue }
            guard let newUsed = new.used, newUsed < oldUsed,
                  let oldReset = old.resetsAt, let newReset = new.resetsAt,
                  oldReset > current.savedAt, newReset.timeIntervalSince(oldReset) >= minimumResetJump,
                  bankedCount(provider: provider, accountID: accountID, reading: previous)
                    == bankedCount(provider: provider, accountID: accountID, reading: current) else { return nil }
            refilled.append(resolve(new))
        }
        guard refilled.count >= 2 else { return nil }
        return ProviderRefillEvent(provider: provider, detectedAt: current.savedAt, previousReadingAt: previous.savedAt,
                                   accountIDs: refilled.sorted())
    }

    static func mainLimits(provider: Provider, reading: StoredUsageSnapshot) -> [String: UsageLimit] {
        Dictionary(grouping: reading.snapshot.limits.filter { $0.provider == provider }, by: \.accountID).compactMapValues { limits in
            UseNextRanking.main(of: limits, provider: provider, period: { MainLimitWindow.infer(from: $0) },
                                model: \.modelLabel, remaining: \.remainingCapacityRatio)
        }
    }

    private static func bankedCount(provider: Provider, accountID: String, reading: StoredUsageSnapshot) -> Int? {
        reading.reports.first { $0.provider == provider && $0.accountID == accountID }?.resetCredits?.availableCount
    }

    /// For each unstarted OpenAI account, the first reading of its current unstarted run, newest readings first.
    public static func unstartedSince(readings: [StoredUsageSnapshot], resolve: AccountResolver = localAccountID) -> [String: Date] {
        var since: [String: Date] = [:]
        var ended = Set<String>()
        for reading in readings.sorted(by: { $0.savedAt > $1.savedAt }) {
            for limit in mainLimits(provider: .openAI, reading: reading).values {
                let id = resolve(limit)
                guard !ended.contains(id) else { continue }
                if UseNextRanking.isUnstarted(used: limit.used, resetsAt: limit.resetsAt, observedAt: limit.lastUpdatedAt) {
                    since[id] = reading.savedAt
                } else {
                    ended.insert(id)
                }
            }
        }
        return since
    }
}
