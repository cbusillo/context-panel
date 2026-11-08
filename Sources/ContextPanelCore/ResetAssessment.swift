import Foundation

/// Will this provider run out before it refills, at the pace it is actually going (#1079)?
/// Pace is each account's measured weekly burn over about the last day. Calling a slow week heavy is the costlier
/// mistake, so a heavy call needs a margin, and once heavy it holds until an account refills or pace clearly drops.
public struct ProviderPaceForecast: Codable, Equatable, Sendable {
    public let provider: Provider
    /// A heavy week: at the measured pace every point is used before it refills.
    public let runsOutBeforeRefill: Bool
    /// Points (percent of one account's weekly window, summed over the provider's accounts) that refill unused at
    /// the measured pace, when work goes to whatever refills first.
    public let refillsUnused: Double
    /// The provider's measured pace, in points per hour.
    public let pacePerHour: Double
    /// At least one account's pace was measured; otherwise the pace is unknown and counts as zero.
    public let paceMeasured: Bool

    /// A heavy call needs every point used even at this share of the measured pace.
    static let heavyPaceShare = 0.8
    /// A heavy call ends only when points would lapse even at this multiple of the measured pace.
    static let slowPaceMultiple = 1.25
    static let usedUpPoints = 0.5

    /// Nil when the provider has no account with a current weekly reading.
    /// Any connected account without one leaves the week slow: it may hold quota nobody can see.
    static func make(provider: Provider, accounts: [AccountOverview.Account], wasHeavy: Bool, now: Date) -> Self? {
        let members = accounts.filter {
            $0.metadata.provider == provider && $0.metadata.isEnabled && $0.metadata.sourceConfigured && $0.state != .notConnected
        }
        var complete = true
        var lanes: [(remaining: Double, hours: Double)] = []
        var pace = 0.0
        var measured = false
        for account in members {
            guard [.available, .closeToLimit, .limited].contains(account.state), let main = account.mainWindow, main.isCurrent,
                  let fraction = main.remainingFraction else { complete = false; continue }
            // An unstarted OpenAI clock starts with its first use, so it has a whole week.
            let hours = provider == .openAI && account.isUnstarted(main) ? UseNextRanking.weekHours
                : main.naturalResetAt.flatMap { $0 > now ? max(UseNextRanking.minimumHours, $0.timeIntervalSince(now) / 3_600) : nil }
            guard let hours else { complete = false; continue }
            lanes.append((fraction * 100, hours))
            pace += main.burnPoints ?? 0
            measured = measured || main.burnPoints != nil
        }
        guard !lanes.isEmpty else { return nil }
        let runsOut = { (share: Double) in unused(lanes, pace: pace * share) < usedUpPoints }
        return Self(provider: provider,
                    runsOutBeforeRefill: complete && (runsOut(heavyPaceShare) || wasHeavy && runsOut(slowPaceMultiple)),
                    refillsUnused: unused(lanes, pace: pace), pacePerHour: pace, paceMeasured: measured)
    }

    /// The least that can lapse: the whole pace goes to the account that refills first, then the next.
    static func unused(_ lanes: [(remaining: Double, hours: Double)], pace: Double) -> Double {
        var clock = 0.0
        var unused = 0.0
        for lane in lanes.sorted(by: { $0.hours < $1.hours }) {
            let spent = min(lane.remaining, pace * max(0, lane.hours - clock))
            unused += lane.remaining - spent
            if pace > 0 { clock += spent / pace }
        }
        return unused
    }

    /// The heavy call carried into the newest reading (#1079): the call saved with it, or else the previous
    /// reading's call, ended for any provider whose accounts refilled in between.
    static func heavyBefore(stored: StoredUsageSnapshot, history: [StoredUsageSnapshot]) -> [Provider] {
        if let saved = stored.heavyProviders { return saved }
        guard let previous = history.filter({ $0.savedAt < stored.savedAt }).max(by: { $0.savedAt < $1.savedAt }),
              let carried = previous.heavyProviders else { return [] }
        let refilled = refilledProviders(from: previous, to: stored)
        return carried.filter { !refilled.contains($0) }
    }

    /// A weekly window that moved its reset later or gave back used quota: a natural reset or an applied banked reset.
    static func refilledProviders(from previous: StoredUsageSnapshot, to current: StoredUsageSnapshot) -> Set<Provider> {
        let before = Dictionary(previous.snapshot.limits.filter(\.isAccountCapacityLimit).map { ("\($0.provider.rawValue):\($0.accountID):\($0.id)", $0) },
                                uniquingKeysWith: { first, _ in first })
        return Set(current.snapshot.limits.filter(\.isAccountCapacityLimit).compactMap { limit in
            guard let old = before["\(limit.provider.rawValue):\(limit.accountID):\(limit.id)"] else { return nil }
            var refilled = false
            if let oldReset = old.resetsAt, let newReset = limit.resetsAt {
                refilled = newReset.timeIntervalSince(oldReset) >= ProviderRefillDetector.minimumResetJump
            }
            if let oldUsed = old.used, let newUsed = limit.used, newUsed < oldUsed { refilled = true }
            return refilled ? limit.provider : nil
        })
    }
}

/// The one banked-reset advisor (#1079). Context Panel only advises and notifies; the Director applies.
/// Heavy week: apply a reset once its account reaches 0%. Slow week: hold resets until close to expiry.
/// An OpenAI reset starts a fresh 7-day week now; a Claude reset refills quota and keeps its end date.
public struct ResetAssessment: Encodable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        case outOfQuota
        case expiring
        case notNeeded
    }

    public let accountID: String
    public let provider: Provider
    public let label: String
    public let trigger: Trigger
    /// The soonest known reset expiry.
    public let expiresAt: Date?
    /// Net usable points gained by applying now; nil when it can't be judged.
    public let value: Double?
    public private(set) var recommended: Bool
    public let unrecognizedKind: Bool
    /// OpenAI applies a banked reset only while the account has less than 80% of its weekly quota left (#1074).
    public let notYetApplicable: Bool
    /// When the expiring warning starts: a day out, plus the time to use the account below OpenAI's gate.
    public let warnFrom: Date?
    public private(set) var detail: String
    private let claudeSpendRate: Double?

    /// The one plain line shown when applying is clearly worth it; nothing otherwise.
    public var prompt: String? { recommended ? "Apply \(label)'s reset now" : nil }
    /// The expiring warning for a reset OpenAI won't apply yet: use the account first.
    public var useFirstPrompt: String? {
        trigger == .expiring && notYetApplicable ? "Use \(label) before its reset expires" : nil
    }
    private var waitingForEarlierReset = false
    public var title: String {
        if waitingForEarlierReset { return "Hold" }
        if recommended { return "Apply reset now" }
        if notYetApplicable { return "Not applicable yet" }
        return trigger == .notNeeded ? "Hold" : "Not worth applying now"
    }

    enum CodingKeys: String, CodingKey {
        case accountID, provider, label, trigger, expiresAt, value, recommended, unrecognizedKind, notYetApplicable, prompt, title, detail
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(value.map { ($0 * 10).rounded() / 10 }, forKey: .value)
        try container.encode(recommended, forKey: .recommended)
        try container.encode(unrecognizedKind, forKey: .unrecognizedKind)
        try container.encode(notYetApplicable, forKey: .notYetApplicable)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
    }

    static let outOfQuotaThreshold: Double = 15
    static let expiringThreshold: Double = 10
    static let expiringWithin: TimeInterval = 24 * 3_600
    /// Weekly points one Claude account can spend per hour when its 5-hour window is the only limit.
    static let claudeDefaultRate = 3.8
    /// Director decision on #1074 (Nov 8, 2026): OpenAI won't apply a reset at or above this much weekly quota left.
    static let openAIApplicableBelow: Double = 80
    /// The expiring warning never starts more than this long before the time it needs, even at no pace.
    static let longestUseFirstLead: TimeInterval = 7 * 24 * 3_600

    public static func assessments(for accounts: [AccountOverview.Account], forecasts: [Provider: ProviderPaceForecast],
                                   now: Date) -> [String: Self] {
        var assessments = Dictionary(accounts.compactMap { account in
            Self(account: account, forecast: forecasts[account.metadata.provider], now: now).map { (account.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        // One apply-now prompt per provider at a time, the soonest expiry first.
        var selectedByProvider: [Provider: Self] = [:]
        for assessment in assessments.values.filter({ $0.trigger == .outOfQuota && $0.recommended })
            .sorted(by: { ($0.expiresAt ?? .distantFuture, $0.accountID) < ($1.expiresAt ?? .distantFuture, $1.accountID) }) {
            if let selected = selectedByProvider[assessment.provider] {
                var held = assessment
                held.recommended = false
                held.waitingForEarlierReset = true
                held.detail += " Apply \(selected.label)'s reset first."
                assessments[held.accountID] = held
            } else {
                selectedByProvider[assessment.provider] = assessment
            }
        }
        return assessments
    }

    private init?(account: AccountOverview.Account, forecast: ProviderPaceForecast?, now: Date) {
        guard [.openAI, .anthropic].contains(account.metadata.provider),
              let banked = account.bankedResets, banked.availableCount > 0, account.bankedState == .available,
              [.available, .closeToLimit, .limited].contains(account.state),
              let main = account.mainWindow, let fraction = main.remainingFraction else { return nil }
        let left = fraction * 100
        let provider = account.metadata.provider
        let heavy = forecast?.runsOutBeforeRefill == true
        let pace = forecast?.pacePerHour ?? 0
        let soonest = account.soonestBankedExpiry(after: now)
        let unrecognized = provider == .anthropic && banked.unrecognizedKindCount > 0
        let gated = provider == .openAI && left >= Self.openAIApplicableBelow
        let toUseFirst = gated ? left - Self.openAIApplicableBelow + 1 : 0
        let lead = Self.expiringWithin + (pace > 0 ? min(Self.longestUseFirstLead, toUseFirst / pace * 3_600) : toUseFirst > 0 ? Self.longestUseFirstLead : 0)
        let warnFrom = soonest.map { $0.addingTimeInterval(-lead) }
        let trigger: Trigger = heavy && left <= 0 ? .outOfQuota : warnFrom.map { now >= $0 } == true ? .expiring : .notNeeded
        // Claude's refill is valued at the measured pace, capped by what one account can spend; an unmeasured pace uses the cap.
        let claudeCap = Self.claudeRate(main: main, gate: account.fiveHourGate)
        let claudeSpendRate = provider == .anthropic ? forecast?.paceMeasured == true ? min(pace, claudeCap) : claudeCap : nil

        let value: Double?
        let reasoning: String
        if trigger == .notNeeded {
            value = nil
            reasoning = heavy
                ? "At the current pace \(provider.displayName) runs out before it refills. Apply this reset once the account reaches 0%."
                : "At the current pace quota refills unused, so hold this reset until close to its expiry."
        } else if unrecognized {
            value = nil
            reasoning = "One of its resets isn't a full weekly refill, so Context Panel doesn't value it. Check it in Claude before applying."
        } else if provider == .openAI {
            let days = account.isUnstarted(main) ? 7 : main.naturalResetAt.map { max(0, $0.timeIntervalSince(now) / 86_400) }
            value = days.map { 100 * $0 / 7 - left }
            reasoning = days.map { days in
                "\(Self.verb(value)) about \(Self.points(value)) points: it discards the \(Int(left.rounded()))% left and starts a fresh week, which moves later refills out by \(Self.days(7 - days))."
            } ?? "The weekly reset time is unknown, so the value can't be judged."
        } else {
            let hours = main.naturalResetAt.map { max(0, $0.timeIntervalSince(now) / 3_600) }
            value = hours.map { hours in
                let usable = min(100, (claudeSpendRate ?? 0) * hours)
                return usable - min(left, usable)
            }
            reasoning = value.map { value in
                "\(Self.verb(value)) about \(Self.points(value)) points it can still spend at the current pace before its weekly refill, which doesn't move."
            } ?? "The weekly refill time is unknown, so the value can't be judged."
        }
        let gateNote = gated ? [
            "OpenAI applies a banked reset only below \(Int(Self.openAIApplicableBelow))% of the weekly quota left, and this account has \(Int(left.rounded()))%.",
            trigger == .expiring ? soonest.map {
                "Use about \(Int(toUseFirst.rounded(.up)))% more before \(ContextPanelDateFormatting.resetDeadline($0)) so it can be applied."
            } : nil,
        ].compactMap { $0 } : []
        let threshold = trigger == .outOfQuota ? Self.outOfQuotaThreshold : Self.expiringThreshold
        accountID = account.id
        self.provider = provider
        label = account.metadata.label
        expiresAt = soonest
        unrecognizedKind = unrecognized
        self.trigger = trigger
        self.value = value
        recommended = trigger != .notNeeded && !gated && (value ?? -.infinity) >= threshold
        notYetApplicable = gated
        self.warnFrom = warnFrom
        self.claudeSpendRate = claudeSpendRate
        detail = ([reasoning] + gateNote).joined(separator: " ")
    }

    /// When time alone makes the current reset value stop meeting its recommendation threshold.
    /// Held candidates also transition, because they can become the selected reset later.
    public func nextValueTransitionDate(for account: AccountOverview.Account, now: Date) -> Date? {
        let threshold = trigger == .outOfQuota ? Self.outOfQuotaThreshold : Self.expiringThreshold
        guard trigger != .notNeeded, let value, value >= threshold,
              let main = account.mainWindow, let left = main.remainingFraction.map({ $0 * 100 }) else { return nil }
        let transition: Date
        if provider == .openAI {
            transition = now.addingTimeInterval((value - threshold) * 7 * 86_400 / 100 + 1)
        } else {
            guard let refill = main.naturalResetAt, let rate = claudeSpendRate, rate > 0 else { return nil }
            transition = refill.addingTimeInterval(-(left + threshold) / rate * 3_600 + 1)
        }
        return transition > now ? transition : nil
    }

    /// Measured from this account's own 5-hour and weekly burn when both are known.
    static func claudeRate(main: AccountOverview.Window, gate: AccountOverview.Window?) -> Double {
        guard let weekly = main.burnPoints, let short = gate?.burnPoints, weekly > 0, short > 0 else { return claudeDefaultRate }
        return min(20, 20 * weekly / short)
    }

    private static func verb(_ value: Double?) -> String {
        (value ?? 0) >= 0 ? "Applying now would add" : "Applying now would lose"
    }

    private static func points(_ value: Double?) -> Int { Int(abs(value ?? 0).rounded()) }

    private static func days(_ value: Double) -> String {
        let rounded = (max(0, value) * 10).rounded() / 10
        return rounded == 1 ? "1 day" : "\(rounded.formatted(.number.precision(.fractionLength(0...1)))) days"
    }
}

public extension AccountOverview.Account {
    /// The soonest known expiry of a current banked reset.
    func soonestBankedExpiry(after now: Date) -> Date? {
        guard bankedState == .available, let banked = bankedResets, banked.availableCount > 0 else { return nil }
        let expiries = banked.knownExpiries.isEmpty ? banked.earliestKnownExpiry.map { [$0] } ?? [] : banked.knownExpiries
        return expiries.filter { $0 > now }.min()
    }
}
