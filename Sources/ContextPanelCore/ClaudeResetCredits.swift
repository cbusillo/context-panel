import Foundation

/// Read-only cedar_ember inventory. Grant identities are used transiently for deduplication only.
/// The OAuth surface is unofficial; absent or malformed inventory is unknown, never an invented zero.
public enum ClaudeResetCreditParser {
    public static func summary(from data: Data, observedAt: Date) -> ProviderResetCreditSummary? {
        guard let payload = try? JSONDecoder.contextPanelISO8601.decode(Payload.self, from: data),
              let status = payload.cedarEmber, status.eligible, let grants = status.grants,
              grants.count <= 1_000 else { return nil }
        var seen = Set<String>()
        var expiries: [Date] = []
        var unrecognized = 0
        for grant in grants {
            guard grant.id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  grant.resetsTotal.isFinite, grant.resetsLeft.isFinite,
                  grant.resetsTotal >= 1, grant.resetsLeft >= 0,
                  grant.resetsTotal.rounded(.down) == grant.resetsTotal,
                  grant.resetsLeft.rounded(.down) == grant.resetsLeft else { return nil }
            guard seen.insert(grant.id).inserted else { continue }
            guard grant.paused != true, grant.endsAt > observedAt else { continue }
            // The vendor settings UI includes an available claimable offer even when left is zero.
            let windows: Set<String> = ["five_hour", "seven_day", "seven_day_overage_included", "seven_day_opus",
                                        "seven_day_sonnet", "seven_day_cowork", "seven_day_omelette", "seven_day_oauth_apps"]
            let clears = (grant.clears ?? []).filter { windows.contains($0) }
            let blocking = (grant.blocking ?? []).filter { !clears.contains($0) }
            let exhausted = status.atLimit == true ? (status.exhausted ?? []).filter { windows.contains($0) } : []
            let claimable = grant.usableNow == true && blocking.isEmpty && status.cooldownUntil == nil
                && (grant.useRequiresLimit == false || clears.contains { exhausted.contains($0) })
            let remaining = min(grant.resetsLeft, grant.resetsTotal)
            let count = remaining > 0 ? remaining : (claimable ? 1 : 0)
            guard count <= 10_000, Double(expiries.count) + count <= 10_000 else { return nil }
            expiries.append(contentsOf: repeatElement(grant.endsAt, count: Int(count)))
            // Every Claude reset so far refills the general weekly window; flag any grant that doesn't,
            // including one that clears only a model's weekly window such as seven_day_opus.
            let named = grant.clears ?? []
            if !named.isEmpty && !named.contains("seven_day") { unrecognized += Int(count) }
        }
        return ProviderResetCreditSummary(
            availableCount: expiries.count, observedAt: observedAt,
            coverage: .complete, knownExpiries: expiries, unrecognizedKindCount: unrecognized
        )
    }

    private struct Payload: Decodable {
        let cedarEmber: Status?
        enum CodingKeys: String, CodingKey { case cedarEmber = "cedar_ember" }
    }

    private struct Status: Decodable {
        let eligible: Bool
        let grants: [Grant]?
        let atLimit: Bool?
        let exhausted: [String]?
        let cooldownUntil: Date?
        enum CodingKeys: String, CodingKey {
            case eligible, grants, exhausted
            case atLimit = "at_limit"
            case cooldownUntil = "cooldown_until"
        }
    }

    private struct Grant: Decodable {
        let id: String
        let resetsTotal: Double
        let resetsLeft: Double
        let endsAt: Date
        let paused: Bool?
        let usableNow: Bool?
        let useRequiresLimit: Bool?
        let clears: [String]?
        let blocking: [String]?
        enum CodingKeys: String, CodingKey {
            case id, paused, clears, blocking
            case resetsTotal = "resets_total"
            case resetsLeft = "resets_left"
            case endsAt = "ends_at"
            case usableNow = "usable_now"
            case useRequiresLimit = "use_requires_limit"
        }
    }
}

/// Process-local cooldown shared by newly constructed connectors. No tokens or provider rows are stored.
/// Restarting the publisher permits one new probe; an unsupported source is not permanently disabled.
public actor ClaudeResetCreditReadCooldown {
    public static let shared = ClaudeResetCreditReadCooldown()
    private var retryDates: [String: Date] = [:]

    public init() {}

    func begin(accountID: String, endpoint: URL, now: Date) -> Bool {
        let key = accountID + "|" + endpoint.absoluteString
        if let next = retryDates[key], next > now { return false }
        retryDates[key] = now.addingTimeInterval(6 * 60 * 60)
        return true
    }

    func succeeded(accountID: String, endpoint: URL) {
        retryDates.removeValue(forKey: accountID + "|" + endpoint.absoluteString)
    }
}
