import Foundation

public struct ClaudeOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]

    public init(accessToken: String?, refreshToken: String?, expiresAt: Date?, scopes: [String] = []) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case scopes
    }
}

public struct ClaudeOAuthTokenResponse: Decodable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let scopes: [String]

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case scopes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        if let values = try container.decodeIfPresent([String].self, forKey: .scopes) {
            scopes = values
        } else if let value = try container.decodeIfPresent(String.self, forKey: .scope) {
            scopes = value.split(separator: " ").map(String.init)
        } else {
            scopes = []
        }
    }
}

public struct ClaudeOAuthAccountConfiguration: Equatable, Sendable {
    public let accountID: String
    public let accountName: String
    public let tokenEndpoint: URL
    public let usageEndpoint: URL

    public init(
        accountID: String,
        accountName: String = "Claude",
        tokenEndpoint: URL = ClaudeOAuthMetadata.tokenEndpoint,
        usageEndpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.tokenEndpoint = tokenEndpoint
        self.usageEndpoint = usageEndpoint
    }
}

public enum ClaudeOAuthUsageParser {
    public static func usageLimits(
        from data: Data,
        accountID: String,
        accountName: String,
        observedAt: Date
    ) throws -> [UsageLimit] {
        let payload = try JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthUsagePayload.self, from: data)
        return payload.limits(accountID: accountID, accountName: accountName, observedAt: observedAt)
    }
}

public struct ClaudeOAuthAuthorizationCode: Equatable, Sendable {
    public let code: String
    public let state: String?

    public init(code: String, state: String?) {
        self.code = code
        self.state = state
    }
}

public enum ClaudeOAuthFlow {
    public static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"

    public static func normalizedAuthorizationCode(from value: String) -> ClaudeOAuthAuthorizationCode {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryCode = components.queryItems?.first(where: { $0.name == "code" })?.value
            if let queryCode, !queryCode.isEmpty {
                return normalizedAuthorizationCode(from: queryCode)
            }
        }
        if let hashIndex = trimmed.firstIndex(of: "#") {
            let stateStart = trimmed.index(after: hashIndex)
            return ClaudeOAuthAuthorizationCode(
                code: String(trimmed[..<hashIndex]),
                state: String(trimmed[stateStart...])
            )
        }
        return ClaudeOAuthAuthorizationCode(code: trimmed, state: nil)
    }

    public static func authorizationURL(
        codeChallenge: String,
        state: String,
        redirectURI: String = manualRedirectURI
    ) throws -> URL {
        var components = URLComponents(url: ClaudeOAuthMetadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeOAuthMetadata.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ClaudeOAuthMetadata.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw ConnectorError.invalidAuth("Claude OAuth authorization URL could not be created.")
        }
        return url
    }

    public static func authorizationCodeTokenRequestBody(
        code: ClaudeOAuthAuthorizationCode,
        codeVerifier: String,
        state: String,
        redirectURI: String = manualRedirectURI
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "client_id": ClaudeOAuthMetadata.clientID,
            "code": code.code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "state": code.state ?? state,
        ])
    }

    public static func refreshTokenRequestBody(refreshToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeOAuthMetadata.clientID,
        ])
    }
}

public struct ClaudeOAuthUsageConnector: ProviderConnector {
    public let provider: Provider = .anthropic

    private let accounts: [ClaudeOAuthAccountConfiguration]
    private let httpClient: any ConnectorHTTPClient
    private let credentialStore: any ProviderCredentialStoring
    private let expirationSkew: TimeInterval
    private let resetHintSnapshot: ClaudeSubscriptionRateLimitSnapshot?

    public init(
        accounts: [ClaudeOAuthAccountConfiguration],
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        credentialStore: any ProviderCredentialStoring,
        expirationSkew: TimeInterval = 5 * 60,
        resetHintSnapshot: ClaudeSubscriptionRateLimitSnapshot? = nil
    ) {
        self.accounts = accounts
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.expirationSkew = expirationSkew
        self.resetHintSnapshot = resetHintSnapshot
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        var reports: [ProviderConnectorReport] = []
        reports.reserveCapacity(accounts.count)
        for account in accounts {
            reports.append(await refresh(account: account, now: now))
        }
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }

    private func refresh(account: ClaudeOAuthAccountConfiguration, now: Date) async -> ProviderConnectorReport {
        let localAccountID = ConnectorRedactor.localAccountID(provider: provider, stableID: account.accountID)

        do {
            var credentials = try loadCredentials(accountID: account.accountID)
            return try await refresh(account: account, credentials: &credentials, now: now, localAccountID: localAccountID)
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

    private func refresh(
        account: ClaudeOAuthAccountConfiguration,
        credentials: inout ClaudeOAuthCredentials,
        now: Date,
        localAccountID: String
    ) async throws -> ProviderConnectorReport {
        let currentAccessToken = try await accessToken(credentials: &credentials, account: account, now: now, forceRefresh: false)
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: account.usageEndpoint,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(currentAccessToken)",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "User-Agent": "claude-code/2.1.141",
                "anthropic-beta": "oauth-2025-04-20",
                "anthropic-version": "2023-06-01",
                "anthropic-client-platform": "context-panel",
            ]
        ))

        if response.statusCode == 401 || response.statusCode == 403 {
            let refreshedToken = try await accessToken(credentials: &credentials, account: account, now: now, forceRefresh: true)
            let retryResponse = try await httpClient.data(for: ConnectorHTTPRequest(
                url: account.usageEndpoint,
                method: "GET",
                headers: [
                    "Authorization": "Bearer \(refreshedToken)",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "User-Agent": "claude-code/2.1.141",
                    "anthropic-beta": "oauth-2025-04-20",
                    "anthropic-version": "2023-06-01",
                    "anthropic-client-platform": "context-panel",
                ]
            ))
            guard (200..<300).contains(retryResponse.statusCode) else {
                throw ConnectorError.httpFailure(operation: "Claude usage", statusCode: retryResponse.statusCode)
            }
            let retryLimits = fillMissingResetTimes(try ClaudeOAuthUsageParser.usageLimits(
                from: retryResponse.data,
                accountID: localAccountID,
                accountName: account.accountName,
                observedAt: now
            ))
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: retryLimits,
                status: retryLimits.isEmpty ? .unknown : nil
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Claude usage", statusCode: response.statusCode)
        }
        let limits = fillMissingResetTimes(try ClaudeOAuthUsageParser.usageLimits(
            from: response.data,
            accountID: localAccountID,
            accountName: account.accountName,
            observedAt: now
        ))
        return ProviderConnectorReport(
            provider: provider,
            accountID: localAccountID,
            accountName: account.accountName,
            generatedAt: now,
            limits: limits,
            status: limits.isEmpty ? .unknown : nil
        )
    }

    private func fillMissingResetTimes(_ limits: [UsageLimit]) -> [UsageLimit] {
        guard let resetHintSnapshot else { return limits }
        let resetHints = Dictionary(uniqueKeysWithValues: resetHintSnapshot.windows.compactMap { window in
            window.resetsAt.map { (Self.normalizedWindowLabel(window.label), $0) }
        })
        guard !resetHints.isEmpty else { return limits }

        return limits.map { limit in
            guard limit.resetsAt == nil else { return limit }
            guard let reset = resetHints[Self.normalizedWindowLabel(limit.windowLabel ?? limit.label)] else {
                return limit
            }
            return UsageLimit(
                id: limit.id,
                provider: limit.provider,
                accountID: limit.accountID,
                configuredAccountID: limit.configuredAccountID,
                accountName: limit.accountName,
                label: limit.label,
                windowLabel: limit.windowLabel,
                modelLabel: limit.modelLabel,
                unit: limit.unit,
                used: limit.used,
                limit: limit.limit,
                resetsAt: reset,
                lastUpdatedAt: limit.lastUpdatedAt,
                confidence: limit.confidence,
                statusOverride: limit.statusOverride,
                note: [limit.note, "reset from Claude Code statusline"].compactMap { $0 }.joined(separator: "; ")
            )
        }
    }

    private static func normalizedWindowLabel(_ value: String) -> String {
        let lowercased = value.lowercased()
        if lowercased.contains("5-hour") || lowercased.contains("5 hour") {
            return "5-hour"
        }
        if lowercased.contains("weekly") || lowercased.contains("week") || lowercased.contains("7-day") || lowercased.contains("7 day") {
            return "weekly"
        }
        return lowercased
    }

    private func loadCredentials(accountID: String) throws -> ClaudeOAuthCredentials {
        guard let data = try credentialStore.load(accountID: accountID) else {
            throw ConnectorError.missingAuth("Claude is not connected. Sign in to Claude from Settings.")
        }
        return try JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: data)
    }

    private func saveCredentials(_ credentials: ClaudeOAuthCredentials, accountID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try credentialStore.save(try encoder.encode(credentials), accountID: accountID)
    }

    private func accessToken(
        credentials: inout ClaudeOAuthCredentials,
        account: ClaudeOAuthAccountConfiguration,
        now: Date,
        forceRefresh: Bool
    ) async throws -> String {
        if
            !forceRefresh,
            let accessToken = credentials.accessToken,
            !accessToken.isEmpty,
            credentials.expiresAt.map({ $0.timeIntervalSince(now) > expirationSkew }) ?? false
        {
            return accessToken
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw ConnectorError.invalidAuth("Claude OAuth credentials do not contain a refresh token. Sign in again from Settings.")
        }

        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: account.tokenEndpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: try ClaudeOAuthFlow.refreshTokenRequestBody(refreshToken: refreshToken)
        ))
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                throw ConnectorError.invalidAuth("Claude OAuth session has expired. Sign in again from Settings.")
            }
            throw ConnectorError.httpFailure(operation: "Claude OAuth refresh", statusCode: response.statusCode)
        }
        let token = try JSONDecoder().decode(ClaudeOAuthTokenResponse.self, from: response.data)
        credentials = ClaudeOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            scopes: token.scopes.isEmpty ? credentials.scopes : token.scopes
        )
        try saveCredentials(credentials, accountID: account.accountID)
        return token.accessToken
    }
}

public enum ClaudeOAuthMetadata {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizationEndpoint = URL(string: "https://claude.com/cai/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let scopes = [
        "org:create_api_key",
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]
}

private struct ClaudeOAuthUsagePayload: Decodable {
    let fiveHour: ClaudeOAuthUsageWindow?
    let sevenDay: ClaudeOAuthUsageWindow?
    let sevenDayOpus: ClaudeOAuthUsageWindow?
    let sevenDaySonnet: ClaudeOAuthUsageWindow?
    let sevenDayOAuthApps: ClaudeOAuthUsageWindow?
    let extraUsage: ClaudeOAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case extraUsage = "extra_usage"
    }

    func limits(accountID: String, accountName: String, observedAt: Date) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        append(window: fiveHour, label: "Claude 5-hour", windowLabel: "5-hour", modelLabel: "Claude", to: &limits, accountID: accountID, accountName: accountName, observedAt: observedAt)
        append(window: sevenDay, label: "Claude weekly", windowLabel: "Weekly", modelLabel: "Claude", to: &limits, accountID: accountID, accountName: accountName, observedAt: observedAt)
        append(window: sevenDayOpus, label: "Claude weekly Opus", windowLabel: "Weekly", modelLabel: "Opus", to: &limits, accountID: accountID, accountName: accountName, observedAt: observedAt)
        append(window: sevenDaySonnet, label: "Claude weekly Sonnet", windowLabel: "Weekly", modelLabel: "Sonnet", to: &limits, accountID: accountID, accountName: accountName, observedAt: observedAt)
        append(window: sevenDayOAuthApps, label: "Claude weekly OAuth apps", windowLabel: "Weekly", modelLabel: "OAuth apps", to: &limits, accountID: accountID, accountName: accountName, observedAt: observedAt)
        return limits
    }

    private func append(
        window: ClaudeOAuthUsageWindow?,
        label: String,
        windowLabel: String,
        modelLabel: String,
        to limits: inout [UsageLimit],
        accountID: String,
        accountName: String,
        observedAt: Date
    ) {
        guard let window, let utilization = window.utilization else { return }
        limits.append(UsageLimit(
            provider: .anthropic,
            accountID: accountID,
            accountName: accountName,
            label: label,
            windowLabel: windowLabel,
            modelLabel: modelLabel,
            unit: .percent,
            used: Int(max(0, min(utilization, 100)).rounded()),
            limit: 100,
            resetsAt: window.resetsAt,
            lastUpdatedAt: observedAt,
            confidence: .observed,
            note: extraUsage?.note
        ))
    }
}

private struct ClaudeOAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct ClaudeOAuthExtraUsage: Decodable {
    let isEnabled: Bool?
    let disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case disabledReason = "disabled_reason"
    }

    var note: String? {
        if isEnabled == true { return "source: Claude OAuth usage; extra usage enabled" }
        if let disabledReason, !disabledReason.isEmpty {
            return "source: Claude OAuth usage; extra usage disabled: \(disabledReason)"
        }
        return "source: Claude OAuth usage"
    }
}
