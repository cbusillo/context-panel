import Foundation

/// One calendar week of capacity that went unused, read from saved snapshot history (#1080).
public struct UnusedCapacityWeek: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// Weekly quota still left when an account's week refilled at its normal reset, in percent points summed
    /// across accounts. This is the burn the Supervisor acts on.
    public var quotaPointsLeftAtReset: Double = 0
    /// Account refills at a normal reset, including those with nothing left.
    public var resetRefills = 0
    /// Weekly quota still left when a provider-wide surprise refill landed early. Context, not a burn failure.
    public var quotaPointsLeftAtSurpriseRefill: Double = 0
    /// Provider-wide surprise refills seen; one refill reaches several accounts.
    public var surpriseRefills = 0
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

/// The newest unused-capacity pass, kept with the current saved snapshot so readers never scan history for it.
public struct StoredUnusedCapacity: Codable, Equatable, Sendable {
    /// The refresh pass recomputes after this long, or when a new week starts.
    public static let maximumAge: TimeInterval = 30 * 60
    public let computedAt: Date
    public let providers: [ProviderUnusedCapacity]

    public init(computedAt: Date, providers: [ProviderUnusedCapacity]) {
        self.computedAt = computedAt
        self.providers = providers
    }

    /// Still answers for `now`: computed recently enough and in the same week.
    public func isCurrent(at now: Date, calendar: Calendar = .current) -> Bool {
        let age = now.timeIntervalSince(computedAt)
        return age >= 0 && age < Self.maximumAge && isSameWeek(as: now, calendar: calendar)
    }

    /// Safe to show at `now`: its "this week" is the week `now` falls in.
    public func isSameWeek(as now: Date, calendar: Calendar = .current) -> Bool {
        calendar.dateInterval(of: .weekOfYear, for: computedAt) == calendar.dateInterval(of: .weekOfYear, for: now)
    }
}

/// A provider's unused capacity for last week and this week so far, in numbers and the words the app shows.
public struct ProviderUnusedCapacity: Codable, Equatable, Sendable {
    public let provider: Provider
    public let lastWeek: UnusedCapacityWeek
    public let thisWeek: UnusedCapacityWeek
    /// "Last week: OpenAI let 60 points refill unused at its normal reset; a surprise refill came with 385 points still left."
    public let lastWeekLine: String
    public let thisWeekLine: String
}

/// What will refill unused at the current pace (#1080), worded from the one pace forecast (#1079),
/// with the provider's usage credits beside it. Aimed at the Supervisor: unused points mean add work.
public struct ProviderUnusedAtPace: Codable, Equatable, Sendable {
    /// The forecast's heavy call: every point is used before it refills.
    public let runsOutBeforeRefill: Bool
    /// The forecast's points that refill unused at the measured pace, summed over the provider's accounts.
    public let refillsUnusedPoints: Double
    public let pacePerHour: Double
    /// False while no account's pace is measured; the points then assume nothing more runs.
    public let paceMeasured: Bool
    /// Usage credits left across the provider's accounts in the current reading; null when none reports a balance.
    public let usageCreditsLeft: Double?
    /// Accounts holding credits whose weekly quota is at 0%. Credits are spent only there.
    public let accountsSpendingUsageCredits: Int
    /// When those credits expire: the provider's own date when it reports one, else the day entered in Settings (#1099).
    public let usageCreditsExpireAt: Date?
    /// Where `usageCreditsExpireAt` came from; null when no expiry is known.
    public let usageCreditsExpirySource: UsageCreditExpiry.Source?
    /// "OpenAI: about 140 points will refill unused at this pace. Add work."
    public let line: String
    /// "OpenAI has 179,745 usage credits left. They expire Dec 31. At this pace none will be spent: …"
    public let usageCreditsLine: String?

    /// Fewer points than this round to nothing at risk.
    static let nothingPoints = 0.5

    public init(forecast: ProviderPaceForecast, stored: StoredUsageSnapshot,
                enteredCreditExpiry: Date? = nil, calendar: Calendar = .current,
                resolve: ProviderRefillDetector.AccountResolver = ProviderRefillDetector.localAccountID) {
        let provider = forecast.provider
        let name = provider.accountDisplayName
        runsOutBeforeRefill = forecast.runsOutBeforeRefill
        refillsUnusedPoints = forecast.refillsUnused
        pacePerHour = forecast.pacePerHour
        paceMeasured = forecast.paceMeasured
        let points = Int(forecast.refillsUnused.rounded())
        let amount = "about \(points) " + (points == 1 ? "point" : "points")
        let outlook = if forecast.runsOutBeforeRefill {
            "\(name): every point gets used before it refills at this pace."
        } else if forecast.refillsUnused < Self.nothingPoints {
            "\(name): nothing will refill unused at this pace."
        } else if !forecast.paceMeasured {
            "\(name): pace isn't measured yet; \(amount) will refill unused if nothing more runs. Add work."
        } else {
            "\(name): \(amount) will refill unused at this pace. Add work."
        }
        line = outlook + (forecast.expiryNeedsMoreWork ? " Expiring resets or credits need more real work before their deadlines." : "")
        let credits = UnusedCapacityHistory.creditsLeft(provider: provider, reading: stored, resolve: resolve)
        let weekly = ProviderRefillDetector.mainLimits(provider: provider, reading: stored)
        let spending = Set(stored.reports.compactMap { report -> String? in
            guard report.provider == provider, (report.usageCredits?.balance ?? 0) > 0,
                  let left = weekly[report.accountID]?.remainingCapacityRatio, left < 0.005 else { return nil }
            return UnusedCapacityHistory.reportID(report, in: stored, resolve: resolve)
        }).count
        // Only a deadline still ahead of the reading puts credits at risk.
        let expiry = credits == nil ? nil : UsageCreditExpiry.current(provider: provider, reading: stored, entered: enteredCreditExpiry)
            .flatMap { $0.date > stored.savedAt ? $0 : nil }
        usageCreditsLeft = credits
        accountsSpendingUsageCredits = spending
        usageCreditsExpireAt = expiry?.date
        usageCreditsExpirySource = expiry?.source
        usageCreditsLine = credits.map { credits in
            let total = Int(credits.rounded()).formatted()
            guard let expiry else {
                let left = "\(name) has \(total) usage credits left"
                return spending == 0
                    ? left + ". They are not being spent: credits are used only once an account's weekly quota reaches 0%."
                    : left + ", being spent on \(spending) " + (spending == 1 ? "account" : "accounts") + " at 0% of its weekly quota."
            }
            var day = Date.FormatStyle.dateTime.month(.abbreviated).day()
            day.timeZone = calendar.timeZone
            let expires = "\(name) has \(total) usage credits left. They expire \(expiry.date.formatted(day))"
                + (expiry.source == .entered ? " (date entered in Settings)." : ".")
            return spending == 0
                ? expires + " Use next plans when quota should reach 0% to start spending these credits. "
                    + "Follow its credit workload target there; it stays unknown until spend is measured."
                : expires + " They are being spent on \(spending) " + (spending == 1 ? "account" : "accounts")
                    + " at 0% of its weekly quota."
        }
    }
}

/// When a provider's usage credits expire, and who said so (#1099).
public struct UsageCreditExpiry: Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        /// The provider reported it with the balance.
        case provider
        /// Chris entered it in Settings because the provider reports none.
        case entered
    }

    public let date: Date
    public let source: Source

    /// The account's own reported expiry wins over the entered one.
    static func of(_ credits: ProviderUsageCreditSummary, entered: Date?) -> Date? {
        credits.expiresAt ?? entered
    }

    /// The soonest provider-reported expiry among the provider's balances in `reading`, else the entered day.
    public static func current(provider: Provider, reading: StoredUsageSnapshot, entered: Date?) -> UsageCreditExpiry? {
        let reported = reading.reports.compactMap { report -> Date? in
            guard report.provider == provider, let credits = report.usageCredits, (credits.balance ?? 0) > 0 else { return nil }
            return credits.expiresAt
        }.min()
        if let reported { return UsageCreditExpiry(date: reported, source: .provider) }
        return entered.map { UsageCreditExpiry(date: $0, source: .entered) }
    }
}

public enum UnusedCapacityHistory {
    /// The first reading needed: a little before last calendar week, so a refill at its start has a reading before it.
    public static func historyStart(now: Date, calendar: Calendar = .current) -> Date {
        weeks(now: now, calendar: calendar).last.start.addingTimeInterval(-6 * 3_600)
    }

    /// Per provider seen in `readings`, last week's and this week's unused capacity. Readings may come in any order.
    public static func summaries(readings: [StoredUsageSnapshot], now: Date, calendar: Calendar = .current,
                                 enteredCreditExpiries: [Provider: Date] = [:],
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
                add(provider: provider, previous: previous, current: current, enteredCreditExpiry: enteredCreditExpiries[provider],
                    resolve: resolve, into: &weeks[index])
            }
            return ProviderUnusedCapacity(provider: provider, lastWeek: weeks[0], thisWeek: weeks[1],
                lastWeekLine: line("Last week", provider: provider, week: weeks[0]),
                thisWeekLine: line("This week so far", provider: provider, week: weeks[1]))
        }
    }

    /// Resolves history rows the way the app's shared presentation does, so two logins on one account count once.
    public static func summaries(readings: [StoredUsageSnapshot], configuration: AccountConfigurationDocument,
                                 now: Date) -> [ProviderUnusedCapacity] {
        summaries(readings: readings, now: now, enteredCreditExpiries: configuration.enteredUsageCreditExpiries,
            resolve: UseNextEvidence.accountResolver(readings: readings, configuration: configuration.accounts,
                publisherID: configuration.publisherID, shared: true))
    }

    static func weeks(now: Date, calendar: Calendar) -> (this: UnusedCapacityWeek, last: UnusedCapacityWeek) {
        let this = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        let last = calendar.dateInterval(of: .weekOfYear, for: this.start.addingTimeInterval(-1))
            ?? DateInterval(start: this.start.addingTimeInterval(-7 * 86_400), end: this.start)
        return (UnusedCapacityWeek(start: this.start, end: this.end), UnusedCapacityWeek(start: last.start, end: last.end))
    }

    static func add(provider: Provider, previous: StoredUsageSnapshot, current: StoredUsageSnapshot, enteredCreditExpiry: Date?,
                    resolve: ProviderRefillDetector.AccountResolver, into week: inout UnusedCapacityWeek) {
        week.readings += 1
        // Two logins on one account resolve to one ID and count once.
        var atReset: [String: Double] = [:]
        var atSurprise: [String: Double] = [:]
        let surprise = Set(ProviderRefillDetector.event(provider: provider, previous: previous, current: current,
                                                        resolve: resolve)?.accountIDs ?? [])
        let after = ProviderRefillDetector.mainLimits(provider: provider, reading: current)
        for (accountID, old) in ProviderRefillDetector.mainLimits(provider: provider, reading: previous) {
            guard let new = after[accountID], MainLimitWindow.infer(from: old) == .weekly,
                  let remaining = old.remainingCapacityRatio, let oldReset = old.resetsAt, let newReset = new.resetsAt,
                  newReset.timeIntervalSince(oldReset) >= ProviderRefillDetector.minimumResetJump else { continue }
            let id = resolve(new)
            // A normal refill passed the old reset; a provider-wide one is the detector's. Anything else was a banked reset.
            if oldReset <= current.savedAt {
                atReset[id] = max(atReset[id] ?? 0, remaining)
            } else if surprise.contains(id) {
                atSurprise[id] = max(atSurprise[id] ?? 0, remaining)
            }
        }
        week.resetRefills += atReset.count
        week.quotaPointsLeftAtReset += atReset.values.reduce(0, +) * 100
        week.surpriseRefills += atSurprise.isEmpty ? 0 : 1
        week.quotaPointsLeftAtSurpriseRefill += atSurprise.values.reduce(0, +) * 100

        var expiredResets: [String: Int] = [:]
        var expiredCredits: [String: Double] = [:]
        for report in previous.reports where report.provider == provider {
            let id = reportID(report, in: previous, resolve: resolve)
            if let old = report.resetCredits,
               let new = ProviderRefillDetector.banked(provider: provider, accountID: report.accountID, reading: current) {
                expiredResets[id] = max(expiredResets[id] ?? 0, old.change(to: new, at: current.savedAt).expired)
            }
            // Counted only at a known expiry, reported or entered; spending before it is never waste. The balance
            // still held at the expiry is what expired: a new grant afterward does not hide it.
            if let credits = report.usageCredits, let expiry = UsageCreditExpiry.of(credits, entered: enteredCreditExpiry) {
                week.usageCreditsExpiredUnused = week.usageCreditsExpiredUnused ?? 0
                guard let balance = credits.balance, previous.savedAt < expiry, expiry <= current.savedAt else { continue }
                expiredCredits[id] = max(expiredCredits[id] ?? 0, balance)
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
        func points(_ value: Double) -> String {
            guard value > 0 else { return "nothing" }
            let number = AccountNumbers.percent(value / 100)
            return number + (number == "1" ? " point" : " points")
        }
        var parts = ["\(name) let \(points(week.quotaPointsLeftAtReset)) refill unused at its normal reset"]
        if week.surpriseRefills > 0 {
            let refills = week.surpriseRefills == 1 ? "a surprise refill" : "\(week.surpriseRefills) surprise refills"
            let left = week.quotaPointsLeftAtSurpriseRefill > 0 ? points(week.quotaPointsLeftAtSurpriseRefill) + " still left" : "nothing left"
            parts.append("\(refills) came with \(left)")
        }
        if week.bankedResetsExpiredUnused > 0 {
            parts.append(AccountTerms.bankedResetCount(week.bankedResetsExpiredUnused) + " expired unused")
        }
        if let credits = week.usageCreditsExpiredUnused, credits > 0 {
            parts.append("\(Int(credits.rounded()).formatted()) usage credits expired unused")
        }
        return "\(lead): " + parts.joined(separator: "; ") + "."
    }
}
