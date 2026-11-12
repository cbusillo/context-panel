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
        var offers = 0
        for grant in grants {
            guard grant.id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  grant.resetsTotal.isFinite, grant.resetsLeft.isFinite,
                  grant.resetsTotal >= 1, grant.resetsLeft >= 0,
                  grant.resetsTotal.rounded(.down) == grant.resetsTotal,
                  grant.resetsLeft.rounded(.down) == grant.resetsLeft else { return nil }
            guard seen.insert(grant.id).inserted else { continue }
            guard grant.paused != true, grant.endsAt > observedAt else { continue }
            let count = Int(min(grant.resetsLeft, grant.resetsTotal))
            guard count <= 10_000, expiries.count + unrecognized + count <= 10_000 else { return nil }
            if count == 0 { offers += 1; continue }
            guard grant.clears?.contains("seven_day") == true else { unrecognized += count; continue }
            expiries.append(contentsOf: repeatElement(grant.endsAt, count: count))
        }
        return ProviderResetCreditSummary(
            availableCount: expiries.count, observedAt: observedAt,
            coverage: .complete, knownExpiries: expiries, unrecognizedKindCount: unrecognized,
            excludedOfferCount: offers, generalWeeklyOnly: true
        )
    }

    private struct Payload: Decodable {
        let cedarEmber: Status?
        enum CodingKeys: String, CodingKey { case cedarEmber = "cedar_ember" }
    }

    private struct Status: Decodable {
        let eligible: Bool
        let grants: [Grant]?
        enum CodingKeys: String, CodingKey {
            case eligible, grants
        }
    }

    private struct Grant: Decodable {
        let id: String
        let resetsTotal: Double
        let resetsLeft: Double
        let endsAt: Date
        let paused: Bool?
        let clears: [String]?
        enum CodingKeys: String, CodingKey {
            case id, paused, clears
            case resetsTotal = "resets_total"
            case resetsLeft = "resets_left"
            case endsAt = "ends_at"
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
