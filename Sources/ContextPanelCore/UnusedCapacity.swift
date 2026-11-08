import Foundation

/// One calendar week of capacity that went unused, read from saved snapshot history (#1080). Nothing new is stored.
public struct UnusedCapacityWeek: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// Weekly quota still left when an account's week refilled, naturally or in a provider-wide refill,
    /// in percent points summed across accounts. A banked reset applied early is not counted here.
    public var quotaPointsRefilledUnused: Double = 0
    /// Account refills seen, including those with nothing left.
    public var refills = 0
    /// Banked resets whose count dropped at their expiry rather than by being applied.
    public var bankedResetsExpiredUnused = 0
    /// Usage credits that disappeared at a reported expiry. Null while no balance in the week has a known expiry.
    public var usageCreditsExpiredUnused: Double?
    /// Consecutive saved readings that ended in this week; zero means the week is unknown, not clean.
    public var readings = 0

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// A provider's unused capacity for last week and this week so far, in numbers and the words the app shows.
public struct ProviderUnusedCapacity: Codable, Equatable, Sendable {
    public let provider: Provider
    public let lastWeek: UnusedCapacityWeek
    public let thisWeek: UnusedCapacityWeek
    /// "Last week: OpenAI let 85 points refill unused; 1 banked reset expired unused."
    public let lastWeekLine: String
    public let thisWeekLine: String
    /// Usage credits left across the provider's accounts in the newest reading; null when none reports a balance.
    public let usageCreditsLeft: Double?
    /// "OpenAI has 179,750 usage credits left." It makes no claim about when they expire.
    public let usageCreditsLine: String?
}

public enum UnusedCapacityHistory {
    /// The first reading needed: a little before last calendar week, so a refill at its start has a reading before it.
    public static func historyStart(now: Date, calendar: Calendar = .current) -> Date {
        weeks(now: now, calendar: calendar).last.start.addingTimeInterval(-6 * 3_600)
    }

    /// Per provider seen in `readings`, last week's and this week's unused capacity. Readings may come in any order.
    public static func summaries(readings: [StoredUsageSnapshot], now: Date, calendar: Calendar = .current,
                                 resolve: ProviderRefillDetector.AccountResolver = ProviderRefillDetector.localAccountID)
        -> [ProviderUnusedCapacity] {
        let ordered = readings.filter { $0.savedAt <= now }.sorted { $0.savedAt < $1.savedAt }
        let (this, last) = weeks(now: now, calendar: calendar)
        let providers = Provider.allCases.filter { provider in
            ordered.contains { $0.snapshot.limits.contains { $0.provider == provider } }
        }
        return providers.map { provider in
            var weeks = [last, this]
            for (previous, current) in zip(ordered, ordered.dropFirst()) {
                guard let index = weeks.firstIndex(where: { $0.start <= current.savedAt && current.savedAt < $0.end }) else { continue }
                add(provider: provider, previous: previous, current: current, resolve: resolve, into: &weeks[index])
            }
            let credits = ordered.last.map { creditsLeft(provider: provider, reading: $0, resolve: resolve) } ?? nil
            return ProviderUnusedCapacity(provider: provider, lastWeek: weeks[0], thisWeek: weeks[1],
                lastWeekLine: line("Last week", provider: provider, week: weeks[0]),
                thisWeekLine: line("This week so far", provider: provider, week: weeks[1]),
                usageCreditsLeft: credits,
                usageCreditsLine: credits.map { "\(provider.accountDisplayName) has \(Int($0.rounded()).formatted()) usage credits left." })
        }
    }

    /// Resolves history rows the way the app's shared presentation does, so two logins on one account count once.
    public static func summaries(readings: [StoredUsageSnapshot], configuration: [LocalProviderAccountConfiguration],
                                 publisherID: String?, now: Date) -> [ProviderUnusedCapacity] {
        summaries(readings: readings, now: now, resolve: UseNextEvidence.accountResolver(readings: readings,
            configuration: configuration, publisherID: publisherID, shared: true))
    }

    static func weeks(now: Date, calendar: Calendar) -> (this: UnusedCapacityWeek, last: UnusedCapacityWeek) {
        let this = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        let last = calendar.dateInterval(of: .weekOfYear, for: this.start.addingTimeInterval(-1))
            ?? DateInterval(start: this.start.addingTimeInterval(-7 * 86_400), end: this.start)
        return (UnusedCapacityWeek(start: this.start, end: this.end), UnusedCapacityWeek(start: last.start, end: last.end))
    }

    static func add(provider: Provider, previous: StoredUsageSnapshot, current: StoredUsageSnapshot,
                    resolve: ProviderRefillDetector.AccountResolver, into week: inout UnusedCapacityWeek) {
        week.readings += 1
        // Two logins on one account resolve to one ID and count once.
        var left: [String: Double] = [:]
        let surprise = Set(ProviderRefillDetector.event(provider: provider, previous: previous, current: current,
                                                        resolve: resolve)?.accountIDs ?? [])
        let after = ProviderRefillDetector.mainLimits(provider: provider, reading: current)
        for (accountID, old) in ProviderRefillDetector.mainLimits(provider: provider, reading: previous) {
            guard let new = after[accountID], MainLimitWindow.infer(from: old) == .weekly,
                  let remaining = old.remainingCapacityRatio, let oldReset = old.resetsAt, let newReset = new.resetsAt,
                  newReset.timeIntervalSince(oldReset) >= ProviderRefillDetector.minimumResetJump else { continue }
            let id = resolve(new)
            // A natural refill passed the old reset; a provider-wide one is the detector's. Anything else was a banked reset.
            guard oldReset <= current.savedAt || surprise.contains(id) else { continue }
            left[id] = max(left[id] ?? 0, remaining)
        }
        week.refills += left.count
        week.quotaPointsRefilledUnused += left.values.reduce(0, +) * 100

        var expiredResets: [String: Int] = [:]
        var expiredCredits: [String: Double] = [:]
        for report in previous.reports where report.provider == provider {
            let id = reportID(report, in: previous, resolve: resolve)
            if let old = report.resetCredits,
               let new = ProviderRefillDetector.banked(provider: provider, accountID: report.accountID, reading: current) {
                expiredResets[id] = max(expiredResets[id] ?? 0, old.change(to: new, at: current.savedAt).expired)
            }
            // The seam for credit expiry: counted only when an adapter reports a date; spending is never waste.
            if let credits = report.usageCredits, let expiry = credits.expiresAt {
                week.usageCreditsExpiredUnused = week.usageCreditsExpiredUnused ?? 0
                guard let balance = credits.balance, previous.savedAt < expiry, expiry <= current.savedAt else { continue }
                let after = current.reports.first { $0.provider == provider && $0.accountID == report.accountID }?.usageCredits?.balance ?? 0
                expiredCredits[id] = max(expiredCredits[id] ?? 0, max(0, balance - after))
            }
        }
        week.bankedResetsExpiredUnused += expiredResets.values.reduce(0, +)
        if !expiredCredits.isEmpty { week.usageCreditsExpiredUnused = (week.usageCreditsExpiredUnused ?? 0) + expiredCredits.values.reduce(0, +) }
    }

    static func creditsLeft(provider: Provider, reading: StoredUsageSnapshot, resolve: ProviderRefillDetector.AccountResolver) -> Double? {
        let balances = Dictionary(reading.reports.compactMap { report -> (String, Double)? in
            guard report.provider == provider, let credits = report.usageCredits, !credits.unlimited, let balance = credits.balance
            else { return nil }
            return (reportID(report, in: reading, resolve: resolve), balance)
        }, uniquingKeysWith: max)
        return balances.isEmpty ? nil : balances.values.reduce(0, +)
    }

    static func reportID(_ report: StoredProviderReport, in reading: StoredUsageSnapshot,
                         resolve: ProviderRefillDetector.AccountResolver) -> String {
        reading.snapshot.limits.first { $0.provider == report.provider && $0.accountID == report.accountID }.map(resolve)
            ?? AccountDisplayMetadata.safeID(report.provider, report.accountID)
    }

    static func line(_ lead: String, provider: Provider, week: UnusedCapacityWeek) -> String {
        let name = provider.accountDisplayName
        guard week.readings > 0 else { return "\(lead): no saved readings for \(name)." }
        let points = AccountNumbers.percent(week.quotaPointsRefilledUnused / 100)
        var parts = [week.quotaPointsRefilledUnused > 0
            ? "\(name) let \(points) \(points == "1" ? "point" : "points") refill unused"
            : "\(name) let nothing refill unused"]
        if week.bankedResetsExpiredUnused > 0 {
            parts.append(AccountTerms.bankedResetCount(week.bankedResetsExpiredUnused) + " expired unused")
        }
        if let credits = week.usageCreditsExpiredUnused, credits > 0 {
            parts.append("\(Int(credits.rounded()).formatted()) usage credits expired unused")
        }
        return "\(lead): " + parts.joined(separator: "; ") + "."
    }
}
