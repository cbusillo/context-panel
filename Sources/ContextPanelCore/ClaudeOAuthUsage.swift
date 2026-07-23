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

public struct ClaudeOAuthUsageResult: Equatable, Sendable {
    public let limits: [UsageLimit]
    public let accessState: ProviderAccessState

    public init(limits: [UsageLimit], accessState: ProviderAccessState) {
        self.limits = limits
        self.accessState = accessState
    }
}

public enum ClaudeOAuthUsageParser {
    public static func usageResult(
        from data: Data,
        accountID: String,
        accountName: String,
        observedAt: Date
    ) throws -> ClaudeOAuthUsageResult {
        let payload = try JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthUsagePayload.self, from: data)
        return payload.result(accountID: accountID, accountName: accountName, observedAt: observedAt)
    }

    public static func usageLimits(
        from data: Data,
        accountID: String,
        accountName: String,
        observedAt: Date
    ) throws -> [UsageLimit] {
        try usageResult(
            from: data,
            accountID: accountID,
            accountName: accountName,
            observedAt: observedAt
        ).limits
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

public struct ClaudeOAuthCodeExchangeService: Sendable {
    private let httpClient: any ConnectorHTTPClient
    private let credentialStore: any ProviderCredentialStoring
    private let lock: SnapshotRefreshLock

    public init(
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        credentialStore: any ProviderCredentialStoring,
        lock: SnapshotRefreshLock = .appDefault()
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.lock = lock
    }

    public func exchangeAndSave(
        authorizationCode: ClaudeOAuthAuthorizationCode,
        codeVerifier: String,
        state: String,
        redirectURI: String = ClaudeOAuthFlow.manualRedirectURI,
        accountID: String,
        now: Date = Date()
    ) async throws -> ClaudeOAuthCredentials {
        try await exchangeAndCommit(
            authorizationCode: authorizationCode,
            codeVerifier: codeVerifier,
            state: state,
            redirectURI: redirectURI,
            now: now
        ) { encodedCredentials in
            try credentialStore.save(encodedCredentials, accountID: accountID)
        }
    }

    public func exchangeAndCommit(
        authorizationCode: ClaudeOAuthAuthorizationCode,
        codeVerifier: String,
        state: String,
        redirectURI: String = ClaudeOAuthFlow.manualRedirectURI,
        now: Date = Date(),
        commit: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> ClaudeOAuthCredentials {
        try Task.checkCancellation()
        guard let credentials = try await lock.withLock({
            try Task.checkCancellation()
            let response = try await httpClient.data(for: ConnectorHTTPRequest(
                url: ClaudeOAuthMetadata.tokenEndpoint,
                method: "POST",
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "anthropic-beta": ClaudeOAuthMetadata.oauthBetaHeader,
                    "User-Agent": "context-panel",
                ],
                body: try ClaudeOAuthFlow.authorizationCodeTokenRequestBody(
                    code: authorizationCode,
                    codeVerifier: codeVerifier,
                    state: state,
                    redirectURI: redirectURI
                )
            ))
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                throw ConnectorError.redactedHTTPFailure(
                    operation: "Claude OAuth token exchange",
                    statusCode: response.statusCode
                )
            }
            let token = try JSONDecoder().decode(ClaudeOAuthTokenResponse.self, from: response.data)
            let credentials = ClaudeOAuthCredentials(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
                scopes: token.scopes
            )
            try Task.checkCancellation()
            try await commit(encodeClaudeOAuthCredentials(credentials))
            return credentials
        }) else {
            throw ConnectorError.foregroundRefreshRequired(
                "Claude usage is already refreshing. Try signing in again in a moment."
            )
        }
        return credentials
    }
}

public struct ClaudeOAuthUsageConnector: ProviderConnector {
    public let provider: Provider = .anthropic

    private let accounts: [ClaudeOAuthAccountConfiguration]
    private let httpClient: any ConnectorHTTPClient
    private let credentialStore: any ProviderCredentialStoring
    private let expirationSkew: TimeInterval

    public init(
        accounts: [ClaudeOAuthAccountConfiguration],
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        credentialStore: any ProviderCredentialStoring,
        expirationSkew: TimeInterval = 5 * 60
    ) {
        self.accounts = accounts
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.expirationSkew = expirationSkew
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
                "anthropic-beta": ClaudeOAuthMetadata.oauthBetaHeader,
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
                    "anthropic-beta": ClaudeOAuthMetadata.oauthBetaHeader,
                    "anthropic-version": "2023-06-01",
                    "anthropic-client-platform": "context-panel",
                ]
            ))
            guard (200..<300).contains(retryResponse.statusCode) else {
                throw ConnectorError.httpFailure(operation: "Claude usage", statusCode: retryResponse.statusCode)
            }
            let retryUsage = try ClaudeOAuthUsageParser.usageResult(
                from: retryResponse.data,
                accountID: localAccountID,
                accountName: account.accountName,
                observedAt: now
            )
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: retryUsage.limits,
                status: retryUsage.limits.isEmpty ? .unknown : nil,
                accessState: retryUsage.accessState
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Claude usage", statusCode: response.statusCode)
        }
        let usage = try ClaudeOAuthUsageParser.usageResult(
            from: response.data,
            accountID: localAccountID,
            accountName: account.accountName,
            observedAt: now
        )
        return ProviderConnectorReport(
            provider: provider,
            accountID: localAccountID,
            accountName: account.accountName,
            generatedAt: now,
            limits: usage.limits,
            status: usage.limits.isEmpty ? .unknown : nil,
            accessState: usage.accessState
        )
    }

    private func loadCredentials(accountID: String) throws -> ClaudeOAuthCredentials {
        guard let data = try credentialStore.load(accountID: accountID) else {
            throw ConnectorError.missingAuth("Claude is not connected. Sign in to Claude from Settings.")
        }
        return try JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: data)
    }

    private func saveCredentials(_ credentials: ClaudeOAuthCredentials, accountID: String) throws {
        try credentialStore.save(try encodeClaudeOAuthCredentials(credentials), accountID: accountID)
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
                "anthropic-beta": ClaudeOAuthMetadata.oauthBetaHeader,
                "User-Agent": "context-panel",
            ],
            body: try ClaudeOAuthFlow.refreshTokenRequestBody(refreshToken: refreshToken)
        ))
        guard (200..<300).contains(response.statusCode) else {
            if refreshResponseRequiresReauthorization(response) {
                throw ConnectorError.invalidAuth("Claude OAuth session has expired. Sign in again from Settings.")
            }
            throw ConnectorError.redactedHTTPFailure(
                operation: "Claude OAuth refresh",
                statusCode: response.statusCode
            )
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

    private func refreshResponseRequiresReauthorization(_ response: ConnectorHTTPResponse) -> Bool {
        guard response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403,
              let payload = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else { return false }

        var errorCodes: [String] = []
        var errorMessages: [String] = []
        if let error = payload["error"] as? String {
            errorCodes.append(error)
        } else if let error = payload["error"] as? [String: Any] {
            if let type = error["type"] as? String { errorCodes.append(type) }
            if let message = error["message"] as? String { errorMessages.append(message) }
        }
        if let type = payload["type"] as? String { errorCodes.append(type) }
        if let description = payload["error_description"] as? String { errorMessages.append(description) }
        if let message = payload["message"] as? String { errorMessages.append(message) }

        let normalizedCodes = Set(errorCodes.map { $0.lowercased() })
        if !normalizedCodes.isDisjoint(with: ["invalid_grant", "invalid_token", "refresh_token_expired"]) {
            return true
        }

        let message = errorMessages.joined(separator: " ").lowercased()
        return message.contains("refresh token")
            && (message.contains("invalid") || message.contains("expired") || message.contains("revoked"))
    }
}

private func encodeClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(credentials)
}

public enum ClaudeOAuthMetadata {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizationEndpoint = URL(string: "https://claude.com/cai/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let oauthBetaHeader = "oauth-2025-04-20"
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
    let structuredLimits: [ClaudeOAuthStructuredLimit]
    let fiveHour: ClaudeOAuthUsageWindow?
    let sevenDay: ClaudeOAuthUsageWindow?
    let sevenDayOpus: ClaudeOAuthUsageWindow?
    let sevenDaySonnet: ClaudeOAuthUsageWindow?
    let sevenDayOAuthApps: ClaudeOAuthUsageWindow?
    let spend: ClaudeOAuthSpend?
    let extraUsage: ClaudeOAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case structuredLimits = "limits"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case spend
        case extraUsage = "extra_usage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        structuredLimits = (try? container.decode(
            [LossyDecodable<ClaudeOAuthStructuredLimit>].self,
            forKey: .structuredLimits
        ))?.compactMap(\.value) ?? []
        fiveHour = try container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: .sevenDaySonnet)
        sevenDayOAuthApps = try container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: .sevenDayOAuthApps)
        spend = try? container.decode(ClaudeOAuthSpend.self, forKey: .spend)
        extraUsage = try? container.decode(ClaudeOAuthExtraUsage.self, forKey: .extraUsage)
    }

    func result(accountID: String, accountName: String, observedAt: Date) -> ClaudeOAuthUsageResult {
        var windowsByID: [ClaudeOAuthLimitID: ClaudeOAuthUsageWindow] = [:]
        for structuredLimit in structuredLimits {
            guard let id = structuredLimit.canonicalID,
                  windowsByID[id] == nil,
                  let window = structuredLimit.usageWindow
            else { continue }
            windowsByID[id] = window
        }

        let legacyWindows: [ClaudeOAuthLimitID: ClaudeOAuthUsageWindow?] = [
            .fiveHour: fiveHour,
            .sevenDay: sevenDay,
            .sevenDayOpus: sevenDayOpus,
            .sevenDaySonnet: sevenDaySonnet,
            .sevenDayOAuthApps: sevenDayOAuthApps,
        ]
        for id in ClaudeOAuthLimitID.allCases where windowsByID[id] == nil {
            if let window = legacyWindows[id] ?? nil, window.utilization != nil {
                windowsByID[id] = window
            }
        }

        let limits = ClaudeOAuthLimitID.allCases.compactMap { id -> UsageLimit? in
            guard let window = windowsByID[id], let utilization = window.utilization else { return nil }
            return UsageLimit(
                provider: .anthropic,
                accountID: accountID,
                accountName: accountName,
                label: id.label,
                windowLabel: id.windowLabel,
                modelLabel: id.modelLabel,
                unit: .percent,
                used: Int(max(0, min(utilization, 100)).rounded()),
                limit: 100,
                resetsAt: window.resetsAt,
                lastUpdatedAt: observedAt,
                confidence: .observed
            )
        }

        let accountWindows = ClaudeOAuthLimitID.accountWide.compactMap { windowsByID[$0] }
        let accessState = Self.accessState(
            accountWindows: accountWindows,
            paidFallbackEnabled: spend?.enabled ?? extraUsage?.isEnabled,
            observedAt: observedAt
        )
        return ClaudeOAuthUsageResult(limits: limits, accessState: accessState)
    }

    private static func accessState(
        accountWindows: [ClaudeOAuthUsageWindow],
        paidFallbackEnabled: Bool?,
        observedAt: Date
    ) -> ProviderAccessState {
        let validWindows = accountWindows.filter { $0.utilization != nil }
        guard !validWindows.isEmpty else { return .unknown }

        let saturatedWindows = validWindows.filter { ($0.utilization ?? 0) >= 100 }
        guard !saturatedWindows.isEmpty else {
            return ProviderAccessState(
                kind: validWindows.contains { ($0.utilization ?? 0) >= 80 } ? .pressure : .available
            )
        }

        let resetCandidates = saturatedWindows.compactMap(\.resetsAt)
        let resetIsComplete = resetCandidates.count == saturatedWindows.count
            && resetCandidates.allSatisfy { $0 > observedAt }
        let resetsAt = resetIsComplete ? resetCandidates.max() : nil

        return switch paidFallbackEnabled {
        case true:
            ProviderAccessState(kind: .paidFallbackActive, resetsAt: resetsAt)
        case false:
            ProviderAccessState(kind: .blockedUntilReset, resetsAt: resetsAt)
        case nil:
            ProviderAccessState(kind: .degraded)
        }
    }
}

private enum ClaudeOAuthLimitID: String, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDayOpus = "seven_day_opus"
    case sevenDaySonnet = "seven_day_sonnet"
    case sevenDayOAuthApps = "seven_day_oauth_apps"

    static let accountWide: [ClaudeOAuthLimitID] = [.fiveHour, .sevenDay]

    var label: String {
        switch self {
        case .fiveHour:
            "Claude 5-hour"
        case .sevenDay:
            "Claude weekly"
        case .sevenDayOpus:
            "Claude weekly Opus"
        case .sevenDaySonnet:
            "Claude weekly Sonnet"
        case .sevenDayOAuthApps:
            "Claude weekly OAuth apps"
        }
    }

    var windowLabel: String {
        self == .fiveHour ? "5-hour" : "Weekly"
    }

    var modelLabel: String {
        switch self {
        case .fiveHour, .sevenDay:
            "Claude"
        case .sevenDayOpus:
            "Opus"
        case .sevenDaySonnet:
            "Sonnet"
        case .sevenDayOAuthApps:
            "OAuth apps"
        }
    }
}

private struct ClaudeOAuthStructuredLimit: Decodable {
    let id: String?
    let rateLimitType: String?
    let metric: String?
    let currentValue: Double?
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case rateLimitType = "rate_limit_type"
        case metric
        case currentValue = "current_value"
        case utilization
        case resetAt = "reset_at"
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        rateLimitType = try? container.decode(String.self, forKey: .rateLimitType)
        metric = try? container.decode(String.self, forKey: .metric)
        currentValue = container.lossyDouble(forKey: .currentValue)
        utilization = container.lossyDouble(forKey: .utilization)
        resetsAt = (try? container.decode(Date.self, forKey: .resetAt))
            ?? (try? container.decode(Date.self, forKey: .resetsAt))
    }

    var canonicalID: ClaudeOAuthLimitID? {
        [id, rateLimitType]
            .compactMap { value -> ClaudeOAuthLimitID? in
                guard let value else { return nil }
                return ClaudeOAuthLimitID(rawValue: value.lowercased())
            }
            .first
    }

    var usageWindow: ClaudeOAuthUsageWindow? {
        if let metric {
            let normalizedMetric = metric.lowercased()
            guard normalizedMetric.contains("percent") || normalizedMetric.contains("utilization") else {
                return nil
            }
        }
        guard let value = currentValue ?? utilization else { return nil }
        return ClaudeOAuthUsageWindow(utilization: value, resetsAt: resetsAt)
    }
}

private struct ClaudeOAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double?, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.lossyDouble(forKey: .utilization)
        resetsAt = try? container.decode(Date.self, forKey: .resetsAt)
    }
}

private struct ClaudeOAuthExtraUsage: Decodable {
    let isEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.lossyBool(forKey: .isEnabled)
    }
}

private struct ClaudeOAuthSpend: Decodable {
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled
        case isEnabled = "is_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lossyBool(forKey: .enabled) ?? container.lossyBool(forKey: .isEnabled)
    }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func lossyDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func lossyBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
