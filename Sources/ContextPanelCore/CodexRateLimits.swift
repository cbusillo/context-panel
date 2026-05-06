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

public struct CodexAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let idToken: String?

    public init(accessToken: String, accountID: String?, idToken: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.idToken = idToken
    }
}

public enum CodexAuthFileParser {
    public static func tokens(from data: Data) throws -> CodexAuthTokens {
        let payload = try JSONDecoder().decode(CodexAuthFilePayload.self, from: data)
        guard let tokens = payload.tokens, !tokens.accessToken.isEmpty else {
            throw ConnectorError.invalidAuth("auth file does not contain ChatGPT token auth")
        }
        return CodexAuthTokens(
            accessToken: tokens.accessToken,
            accountID: tokens.accountID,
            idToken: tokens.idToken
        )
    }
}

public enum CodexAccountIDExtractor {
    public static func accountID(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = object["https://api.openai.com/auth"] as? [String: Any]
        else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }
}

public struct CodexAccountConfiguration: Equatable, Sendable {
    public let authPath: String
    public let accountName: String
    public let endpoint: URL

    public init(
        authPath: String,
        accountName: String? = nil,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.authPath = authPath
        self.accountName = accountName ?? ConnectorRedactor.redactedPath(authPath)
        self.endpoint = endpoint
    }
}

public struct CodexRateLimitConnector: ProviderConnector {
    public let provider: Provider = .openAI

    private let accounts: [CodexAccountConfiguration]
    private let httpClient: any ConnectorHTTPClient
    private let fileLoader: @Sendable (String) throws -> Data

    public init(
        accounts: [CodexAccountConfiguration],
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        fileLoader: @escaping @Sendable (String) throws -> Data = { path in
            try Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        }
    ) {
        self.accounts = accounts
        self.httpClient = httpClient
        self.fileLoader = fileLoader
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        var reports: [ProviderConnectorReport] = []
        reports.reserveCapacity(accounts.count)
        for account in accounts {
            reports.append(await refresh(account: account, now: now))
        }
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }

    private func refresh(account: CodexAccountConfiguration, now: Date) async -> ProviderConnectorReport {
        let localAccountID = ConnectorRedactor.localAccountID(provider: provider, path: account.authPath)

        do {
            let auth = try CodexAuthFileParser.tokens(from: try fileLoader(account.authPath))
            let data = try await fetchUsage(endpoint: account.endpoint, auth: auth)
            let snapshots = try CodexUsagePayloadParser.snapshots(from: data)
            let limits = snapshots.flatMap { snapshot in
                codexUsageLimits(
                    from: snapshot,
                    accountID: localAccountID,
                    accountName: account.accountName,
                    observedAt: now
                )
            }
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: limits
            )
        } catch {
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: [],
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func fetchUsage(endpoint: URL, auth: CodexAuthTokens) async throws -> Data {
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "User-Agent": "context-panel",
            "Accept": "application/json",
        ]
        if let accountID = auth.accountID ?? CodexAccountIDExtractor.accountID(fromIDToken: auth.idToken) {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let response = try await httpClient.data(for: ConnectorHTTPRequest(url: endpoint, method: "GET", headers: headers))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Codex usage endpoint", statusCode: response.statusCode)
        }
        return response.data
    }
}

public func codexUsageLimits(
    from snapshot: CodexRateLimitSnapshot,
    accountID: String,
    accountName: String,
    observedAt: Date
) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    if let primary = snapshot.primary {
        limits.append(codexUsageLimit(
            snapshot: snapshot,
            window: primary,
            windowName: "primary",
            accountID: accountID,
            accountName: accountName,
            observedAt: observedAt
        ))
    }
    if let secondary = snapshot.secondary {
        limits.append(codexUsageLimit(
            snapshot: snapshot,
            window: secondary,
            windowName: "secondary",
            accountID: accountID,
            accountName: accountName,
            observedAt: observedAt
        ))
    }
    return limits
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

private struct CodexAuthFilePayload: Decodable {
    let tokens: CodexAuthTokenPayload?
}

private struct CodexAuthTokenPayload: Decodable {
    let accessToken: String
    let accountID: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
        case idToken = "id_token"
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

private func codexUsageLimit(
    snapshot: CodexRateLimitSnapshot,
    window: CodexRateLimitWindow,
    windowName: String,
    accountID: String,
    accountName: String,
    observedAt: Date
) -> UsageLimit {
    let duration = window.windowMinutes.map { "\($0)m" } ?? "rolling"
    return UsageLimit(
        provider: .openAI,
        accountID: accountID,
        accountName: accountName,
        label: "\(snapshot.displayName) \(windowName) \(duration)",
        unit: .percent,
        used: Int(window.usedPercent.rounded()),
        limit: 100,
        resetsAt: window.resetsAt,
        lastUpdatedAt: observedAt,
        confidence: .observed,
        note: "plan: \(snapshot.planType)"
    )
}
