import Foundation

/// Whether applying a banked reset is clearly worth it (#791). Context Panel only prompts; the Director applies.
/// An OpenAI reset restarts the weekly clock and moves later refills out; a Claude reset never moves its refill.
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
    public let eligibilityNote: String?
    public let detail: String

    /// The one plain line shown when applying is clearly worth it; nothing otherwise.
    public var prompt: String? { recommended ? "Apply \(label)'s reset now" : nil }
    private var waitingForEarlierReset = false
    public var title: String {
        if waitingForEarlierReset { return "Hold" }
        return recommended ? "Apply reset now" : trigger == .notNeeded ? "Hold" : "Not worth applying now"
    }

    enum CodingKeys: String, CodingKey {
        case accountID, provider, label, trigger, expiresAt, value, recommended, unrecognizedKind, prompt, title, detail
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
        try container.encode(prompt, forKey: .prompt)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
    }

    static let outOfQuotaThreshold: Double = 15
    static let expiringThreshold: Double = 10
    static let expiringWithin: TimeInterval = 24 * 3_600
    /// Weekly points one Claude account can spend per hour when its 5-hour window is the only limit.
    static let claudeDefaultRate = 3.8
    /// OpenAI refused resets at 16% used and accepted them at 32%.
    static let openAIAcceptedUsed: Double = 32

    /// Judge the complete provider before choosing one out-of-quota reset, soonest expiry first.
    public static func assessments(for accounts: [AccountOverview.Account], now: Date) -> [String: Self] {
        let emptyProviders = Set(Provider.allCases.filter { provider in
            let members = accounts.filter {
                $0.metadata.provider == provider && $0.metadata.isEnabled && $0.metadata.sourceConfigured
            }
            return !members.isEmpty && members.allSatisfy { account in
                guard [.available, .closeToLimit, .limited].contains(account.state),
                      let main = account.mainWindow, main.assumption == nil, main.confidence != .unknown,
                      let fraction = main.remainingFraction else { return false }
                return fraction <= 0
            }
        })
        var assessments = Dictionary(accounts.compactMap { account in
            Self(account: account, providerOutOfQuota: emptyProviders.contains(account.metadata.provider), now: now)
                .map { (account.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var selectedProviders = Set<Provider>()
        for assessment in assessments.values.filter({ $0.trigger == .outOfQuota && $0.recommended })
            .sorted(by: { ($0.expiresAt ?? .distantFuture, $0.accountID) < ($1.expiresAt ?? .distantFuture, $1.accountID) }) {
            if !selectedProviders.insert(assessment.provider).inserted {
                var held = assessment
                held.recommended = false
                held.waitingForEarlierReset = true
                assessments[held.accountID] = held
            }
        }
        return assessments
    }

    private init?(account: AccountOverview.Account, providerOutOfQuota: Bool, now: Date) {
        guard [.openAI, .anthropic].contains(account.metadata.provider),
              let banked = account.bankedResets, banked.availableCount > 0, account.bankedState == .available,
              [.available, .closeToLimit, .limited].contains(account.state),
              let main = account.mainWindow, let fraction = main.remainingFraction else { return nil }
        let left = fraction * 100
        let provider = account.metadata.provider
        let expiries = banked.knownExpiries.isEmpty ? banked.earliestKnownExpiry.map { [$0] } ?? [] : banked.knownExpiries
        let soonest = expiries.filter { $0 > now }.min()
        let unrecognized = provider == .anthropic && banked.unrecognizedKindCount > 0
        let trigger: Trigger = providerOutOfQuota && left <= 0 ? .outOfQuota
            : soonest.map { $0.timeIntervalSince(now) <= Self.expiringWithin } == true ? .expiring : .notNeeded

        let value: Double?
        let reasoning: String
        if trigger == .notNeeded {
            value = nil
            reasoning = "Apply a reset only when every account of the provider is out of quota or the reset is about to expire."
        } else if unrecognized {
            value = nil
            reasoning = "One of its resets isn't a full weekly refill, so Context Panel doesn't value it. Check it in Claude before applying."
        } else if provider == .openAI {
            let days = account.isUnstarted(main) ? 7 : main.naturalResetAt.map { max(0, $0.timeIntervalSince(now) / 86_400) }
            value = days.map { 100 * $0 / 7 - left }
            reasoning = days.map { days in
                "\(Self.verb(value)) about \(Self.points(value)) points: it discards the \(Int(left.rounded()))% left and restarts the weekly clock, which moves later refills out by \(Self.days(7 - days))."
            } ?? "The weekly reset time is unknown, so the value can't be judged."
        } else {
            let hours = main.naturalResetAt.map { max(0, $0.timeIntervalSince(now) / 3_600) }
            let rate = Self.claudeRate(main: main, gate: account.fiveHourGate)
            value = hours.map { hours in
                let usable = min(100, rate * hours)
                return usable - min(left, usable)
            }
            reasoning = value.map { value in
                "\(Self.verb(value)) about \(Self.points(value)) points it can still spend before its weekly refill, which doesn't move."
            } ?? "The weekly refill time is unknown, so the value can't be judged."
        }
        let threshold = trigger == .outOfQuota ? Self.outOfQuotaThreshold : Self.expiringThreshold
        let note = provider == .openAI && trigger == .expiring && 100 - left < Self.openAIAcceptedUsed
            ? "OpenAI has refused resets on accounts under about a third used; a refused try costs nothing." : nil
        accountID = account.id
        self.provider = provider
        label = account.metadata.label
        expiresAt = soonest
        unrecognizedKind = unrecognized
        self.trigger = trigger
        self.value = value
        recommended = trigger != .notNeeded && (value ?? -.infinity) >= threshold
        eligibilityNote = note
        detail = [reasoning, note].compactMap { $0 }.joined(separator: " ")
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
