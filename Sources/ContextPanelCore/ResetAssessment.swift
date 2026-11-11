import Foundation

/// The measured workload and the capacity available until the provider's next natural refill.
/// Percentage points are an index across accounts, not a claim that their paid plans have equal size.
public struct ProviderPaceForecast: Codable, Equatable, Sendable {
    public let provider: Provider
    public let runsOutBeforeRefill: Bool
    public let refillsUnused: Double
    public let pacePerHour: Double
    public let paceMeasured: Bool
    public let sustainablePointsPerHour: Double
    public let capacityUntilRefillPoints: Double
    public let creditRunwayUnknown: Bool
    public let minimumExpiryPace: Double
    public let expiryNeedsMoreWork: Bool
    /// The forecast includes banked capacity conditionally: only the Director can make it available.
    public let requiresBankedReset: Bool

    init?(provider: Provider, plans: [SpendPlan], pace: Double, measured: Bool, complete: Bool, now: Date) {
        guard let refill = plans.map(\.refill).min() else { return nil }
        let hours = max(UseNextRanking.minimumHours, refill.timeIntervalSince(now) / 3_600)
        let quota = plans.reduce(0) { $0 + max(0, $1.remaining - ($1.reserve ?? 0)) }
        let banked = plans.reduce(0) { $0 + $1.bankedPoints }
        let credits = plans.reduce(0) { $0 + ($1.creditPoints ?? 0) }
        self.provider = provider
        pacePerHour = pace
        paceMeasured = measured
        capacityUntilRefillPoints = quota + banked + credits
        sustainablePointsPerHour = capacityUntilRefillPoints / hours
        creditRunwayUnknown = plans.contains { $0.credits != nil && $0.creditPoints == nil }
        minimumExpiryPace = Self.expiryPace(plans, now: now)
        expiryNeedsMoreWork = minimumExpiryPace > pace
        requiresBankedReset = complete && (plans.allSatisfy { $0.remaining <= 0 } || pace * hours > quota + credits)
        runsOutBeforeRefill = complete && pace * hours > capacityUntilRefillPoints
        refillsUnused = Self.unused(plans.map { ($0.remaining, max(0, $0.refill.timeIntervalSince(now) / 3_600)) }, pace: pace)
    }

    private static func expiryPace(_ plans: [SpendPlan], now: Date) -> Double {
        let expiries = Set(plans.flatMap { plan in
            plan.row.bankedExpiries(after: now) + [plan.credits?.expiresAt].compactMap { $0 }
        }).filter { $0 > now }
        return expiries.map { expiry in
            let protected = plans.contains { ($0.reserve ?? 0) > 0
                && ($0.credits?.expiresAt.map { $0 <= expiry } == true || $0.row.bankedExpiries(after: now).contains { $0 <= expiry }) }
            let needed = plans.reduce(0.0) { sum, plan in
                let resets = plan.row.bankedExpiries(after: now).filter { $0 <= expiry }.count
                let creditDue = plan.credits?.expiresAt.map { $0 <= expiry } == true
                let period = UseNextRanking.windowHours(plan.row.mainWindow?.period) * 3_600
                let completed = max(0, floor(expiry.timeIntervalSince(plan.refill) / period))
                let needsEmpty = protected || creditDue || resets > 0
                let latest = needsEmpty && plan.refill < expiry ? 1.0 : 0
                let current = plan.refill <= expiry || needsEmpty ? plan.creditOnly ? 0 : plan.remaining : 0
                return sum + current + (completed + latest + Double(max(0, resets - 1))) * 100
                    + (creditDue ? plan.creditPoints ?? 0 : 0)
            }
            return needed / max(UseNextRanking.minimumHours, expiry.timeIntervalSince(now) / 3_600)
        }.max() ?? 0
    }

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
}

/// The one banked-reset advisor (#1079). Context Panel only advises and notifies; the Director applies.
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
    /// A scheduled warning boundary; the shared depletion plan can ask for work earlier.
    public let warnFrom: Date?
    public private(set) var detail: String
    private let claudeSpendRate: Double?

    /// The one plain line shown when applying is clearly worth it; nothing otherwise.
    public var prompt: String? { recommended ? "Apply \(label)'s reset now" : nil }
    /// The expiring warning for a reset OpenAI won't apply yet: use the account first.
    public var useFirstPrompt: String? {
        trigger == .expiring && !recommended && !unrecognizedKind ? "Use \(label) before its reset expires" : nil
    }
    private var waitingForEarlierReset = false
    private var waitingForCredits = false
    public var title: String {
        if waitingForEarlierReset || waitingForCredits { return "Hold" }
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

    public static func assessments(for accounts: [AccountOverview.Account], rankings: [Provider: UseNextRanking],
                                   now: Date) -> [String: Self] {
        var assessments = Dictionary(accounts.compactMap { account in
            Self(account: account, ranking: rankings[account.metadata.provider], now: now).map { (account.id, $0) }
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

    private init?(account: AccountOverview.Account, ranking: UseNextRanking?, now: Date) {
        guard [.openAI, .anthropic].contains(account.metadata.provider),
              let banked = account.bankedResets, banked.availableCount > 0, account.bankedState == .available,
              [.available, .closeToLimit, .limited].contains(account.state),
              let main = account.mainWindow, let fraction = main.remainingFraction else { return nil }
        let forecast = ranking?.forecast
        let plan = ranking?.entries.first { $0.accountID == account.id }
        let left = fraction * 100
        let provider = account.metadata.provider
        let needsReset = forecast?.requiresBankedReset == true
        let pace = forecast?.pacePerHour ?? 0
        let soonest = account.soonestBankedExpiry(after: now)
        let unrecognized = provider == .anthropic && !banked.generalWeeklyOnly
        let gated = provider == .openAI && left >= Self.openAIApplicableBelow
        let toUseFirst = gated ? left - Self.openAIApplicableBelow + 1 : 0
        let warnFrom = soonest.map { $0.addingTimeInterval(-Self.expiringWithin) }
        let expiring = plan?.bankedResetExpiresAt != nil || warnFrom.map { now >= $0 } == true
        let trigger: Trigger = left <= 0 && (needsReset || expiring) ? .outOfQuota : expiring ? .expiring : .notNeeded
        // Claude's refill is valued at the measured pace, capped by what one account can spend; an unmeasured pace uses the cap.
        let claudeCap = Self.claudeRate(main: main, gate: account.fiveHourGate)
        let claudeSpendRate = provider == .anthropic ? forecast?.paceMeasured == true ? min(pace, claudeCap) : claudeCap : nil

        let value: Double?
        let reasoning: String
        if trigger == .notNeeded {
            value = nil
            reasoning = needsReset
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
        waitingForCredits = plan?.spendsCreditsBeforeReset == true
        recommended = trigger != .notNeeded && left <= 0 && !unrecognized && !waitingForCredits && (value ?? -.infinity) >= threshold
        notYetApplicable = gated
        self.warnFrom = warnFrom
        self.claudeSpendRate = claudeSpendRate
        detail = ([plan?.reason, reasoning] + gateNote).compactMap { $0 }.joined(separator: " ")
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
    func bankedExpiries(after now: Date) -> [Date] {
        guard bankedState == .available, let banked = bankedResets, banked.availableCount > 0,
              metadata.provider != .anthropic || banked.generalWeeklyOnly else { return [] }
        return banked.expiries(after: now)
    }

    /// The soonest known expiry of a current general-week banked reset.
    func soonestBankedExpiry(after now: Date) -> Date? { bankedExpiries(after: now).first }
}
