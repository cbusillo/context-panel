import Foundation

public enum CodexRateLimitReachedType: String, Codable, Equatable, Sendable {
    case rateLimitReached = "rate_limit_reached"
    case workspaceOwnerCreditsDepleted = "workspace_owner_credits_depleted"
    case workspaceMemberCreditsDepleted = "workspace_member_credits_depleted"
    case workspaceOwnerUsageLimitReached = "workspace_owner_usage_limit_reached"
    case workspaceMemberUsageLimitReached = "workspace_member_usage_limit_reached"
    case unknown
}

public struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = max(0, min(usedPercent, 100))
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct CodexCreditsSnapshot: Codable, Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let limitName: String?
    public let planType: String
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
    public let credits: CodexCreditsSnapshot?
    public let rateLimitReachedType: CodexRateLimitReachedType?

    public init(
        id: String,
        limitName: String?,
        planType: String,
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        credits: CodexCreditsSnapshot?,
        rateLimitReachedType: CodexRateLimitReachedType?
    ) {
        self.id = id
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.rateLimitReachedType = rateLimitReachedType
    }

    public var displayName: String {
        limitName ?? id
    }
}

public enum CodexUsagePayloadParser {
    public static func snapshots(from data: Data) throws -> [CodexRateLimitSnapshot] {
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        return snapshots(from: payload)
    }

    private static func snapshots(from payload: CodexUsagePayload) -> [CodexRateLimitSnapshot] {
        var snapshots = [
            CodexRateLimitSnapshot(
                id: "codex",
                limitName: nil,
                planType: payload.planType,
                primary: payload.rateLimit?.primaryWindow?.normalizedWindow,
                secondary: payload.rateLimit?.secondaryWindow?.normalizedWindow,
                credits: payload.credits?.normalizedCredits,
                rateLimitReachedType: payload.rateLimitReachedType?.normalizedKind
            )
        ]

        snapshots.append(contentsOf: payload.additionalRateLimits.map { additional in
            CodexRateLimitSnapshot(
                id: additional.meteredFeature,
                limitName: additional.limitName,
                planType: payload.planType,
                primary: additional.rateLimit?.primaryWindow?.normalizedWindow,
                secondary: additional.rateLimit?.secondaryWindow?.normalizedWindow,
                credits: nil,
                rateLimitReachedType: nil
            )
        })

        return snapshots
    }
}

private struct CodexUsagePayload: Decodable {
    let planType: String
    let rateLimit: CodexRateLimitDetails?
    let credits: CodexCreditsDetails?
    let additionalRateLimits: [CodexAdditionalRateLimitDetails]
    let rateLimitReachedType: CodexReachedType?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
        case rateLimitReachedType = "rate_limit_reached_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType) ?? "unknown"
        rateLimit = try container.decodeIfPresent(CodexRateLimitDetails.self, forKey: .rateLimit)
        credits = try container.decodeIfPresent(CodexCreditsDetails.self, forKey: .credits)
        additionalRateLimits = try container.decodeIfPresent([CodexAdditionalRateLimitDetails].self, forKey: .additionalRateLimits) ?? []
        rateLimitReachedType = try container.decodeIfPresent(CodexReachedType.self, forKey: .rateLimitReachedType)
    }
}

private struct CodexRateLimitDetails: Decodable {
    let primaryWindow: CodexWindowSnapshot?
    let secondaryWindow: CodexWindowSnapshot?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindowSnapshot: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    var normalizedWindow: CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: limitWindowSeconds.map { max(($0 + 59) / 60, 0) },
            resetsAt: resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct CodexCreditsDetails: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    var normalizedCredits: CodexCreditsSnapshot {
        CodexCreditsSnapshot(hasCredits: hasCredits, unlimited: unlimited, balance: balance)
    }
}

private struct CodexAdditionalRateLimitDetails: Decodable {
    let limitName: String
    let meteredFeature: String
    let rateLimit: CodexRateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

private struct CodexReachedType: Decodable {
    let kind: CodexRateLimitReachedType

    enum CodingKeys: String, CodingKey {
        case kind = "type"
    }

    var normalizedKind: CodexRateLimitReachedType {
        kind
    }
}

