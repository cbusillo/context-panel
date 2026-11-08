import Foundation

/// A provider refilled its accounts at once, ahead of their resets and without spending a banked reset (#791).
/// Only accounts that had used quota can show it; an unused account has nothing to refill.
/// Burn already treats a moved reset time as a new window, so a refill never counts as use.
public struct ProviderRefillEvent: Codable, Equatable, Sendable {
    public let provider: Provider
    public let detectedAt: Date
    public let previousReadingAt: Date
    public let accountIDs: [String]
}

public enum ProviderRefillDetector {
    /// The new reset must move later by at least this much.
    static let minimumResetJump: TimeInterval = 3_600

    /// Maps a stored limit to the account ID the snapshot publishes for it.
    public typealias AccountResolver = @Sendable (UsageLimit) -> String

    public static let localAccountID: AccountResolver = { AccountDisplayMetadata.safeID($0.provider, $0.accountID) }

    public static func events(readings: [StoredUsageSnapshot], resolve: AccountResolver = localAccountID) -> [ProviderRefillEvent] {
        let ordered = readings.sorted { $0.savedAt < $1.savedAt }
        return zip(ordered, ordered.dropFirst()).flatMap { previous, current -> [ProviderRefillEvent] in
            Provider.allCases.compactMap { provider in
                event(provider: provider, previous: previous, current: current, resolve: resolve)
            }
        }
    }

    static func event(provider: Provider, previous: StoredUsageSnapshot, current: StoredUsageSnapshot,
                      resolve: AccountResolver) -> ProviderRefillEvent? {
        let before = mainLimits(provider: provider, reading: previous)
        let after = mainLimits(provider: provider, reading: current)
        var refilled = Set<String>()
        var notRefilled = Set<String>()
        var present = Set<String>()
        var countsKnown = true
        for (accountID, old) in before {
            guard let new = after[accountID] else { continue }
            present.insert(resolve(new))
            // An unstarted window has nothing to refill; a natural reset or spent banked reset is not this event.
            guard let oldUsed = old.used, oldUsed > 0 else { continue }
            let oldBanked = banked(provider: provider, accountID: accountID, reading: previous)
            let newBanked = banked(provider: provider, accountID: accountID, reading: current)
            // A banked reset that expired between the readings was not spent; one granted is not spent either.
            let spent = switch (oldBanked, newBanked) {
            case (nil, nil): false
            case let (old?, new?): new.availableCount < old.presented(at: current.savedAt).availableCount
            default: true
            }
            guard !spent, let newUsed = new.used, newUsed < oldUsed,
                  let oldReset = old.resetsAt, let newReset = new.resetsAt,
                  oldReset > current.savedAt, newReset.timeIntervalSince(oldReset) >= minimumResetJump else {
                notRefilled.insert(resolve(new)); continue
            }
            refilled.insert(resolve(new))
            countsKnown = countsKnown && oldBanked != nil
        }
        // Two logins on one account resolve to one published ID and count once.
        let accounts = refilled.sorted()
        // One refilled account is enough when every other account had nothing to refill, and its banked
        // count shows no reset was spent on it.
        let lone = accounts.count == 1 && present.count >= 2 && notRefilled.subtracting(refilled).isEmpty && countsKnown
        guard accounts.count >= 2 || lone else { return nil }
        return ProviderRefillEvent(provider: provider, detectedAt: current.savedAt, previousReadingAt: previous.savedAt,
                                   accountIDs: accounts)
    }

    static func mainLimits(provider: Provider, reading: StoredUsageSnapshot) -> [String: UsageLimit] {
        Dictionary(grouping: reading.snapshot.limits.filter { $0.provider == provider }, by: \.accountID).compactMapValues { limits in
            UseNextRanking.main(of: limits, provider: provider, period: { MainLimitWindow.infer(from: $0) },
                                model: \.modelLabel, remaining: \.remainingCapacityRatio)
        }
    }

    private static func banked(provider: Provider, accountID: String, reading: StoredUsageSnapshot) -> ProviderResetCreditSummary? {
        reading.reports.first { $0.provider == provider && $0.accountID == accountID }?.resetCredits
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
