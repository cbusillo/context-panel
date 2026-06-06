import Foundation

public struct GoogleAntigravityOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let projectID: String?

    public init(
        accessToken: String?,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String] = [],
        projectID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case scopes
        case projectID
    }
}

public struct GoogleAntigravityOAuthTokenResponse: Decodable, Equatable, Sendable {
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

public struct GoogleAntigravityAccountConfiguration: Equatable, Sendable {
    public let accountID: String
    public let accountName: String
    public let tokenEndpoint: URL
    public let codeAssistBaseURL: URL
    public let clientID: String
    public let clientSecret: String?
    public let projectID: String?
    public let userAgent: String

    public init(
        accountID: String,
        accountName: String = "Antigravity",
        tokenEndpoint: URL = GoogleAntigravityOAuthMetadata.tokenEndpoint,
        codeAssistBaseURL: URL = GoogleAntigravityOAuthMetadata.codeAssistBaseURL,
        clientID: String = GoogleAntigravityOAuthMetadata.clientID,
        clientSecret: String? = GoogleAntigravityOAuthMetadata.clientSecret,
        projectID: String? = nil,
        userAgent: String = GoogleAntigravityOAuthMetadata.userAgent
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.tokenEndpoint = tokenEndpoint
        self.codeAssistBaseURL = codeAssistBaseURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.projectID = projectID
        self.userAgent = userAgent
    }
}

public enum GoogleAntigravityOAuthFlow {
    public static let manualRedirectURI = "http://localhost:51121/oauth-callback"

    public static func normalizedAuthorizationCode(from value: String) -> GoogleAntigravityAuthorizationCode {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryCode = components.queryItems?.first(where: { $0.name == "code" })?.value
            let queryState = components.queryItems?.first(where: { $0.name == "state" })?.value
            if let queryCode, !queryCode.isEmpty {
                return GoogleAntigravityAuthorizationCode(code: queryCode, state: queryState)
            }
        }
        return GoogleAntigravityAuthorizationCode(code: trimmed, state: nil)
    }

    public static func authorizationURL(
        codeChallenge: String,
        state: String,
        redirectURI: String = manualRedirectURI,
        clientID: String = GoogleAntigravityOAuthMetadata.clientID,
        scopes: [String] = GoogleAntigravityOAuthMetadata.scopes
    ) throws -> URL {
        var components = URLComponents(url: GoogleAntigravityOAuthMetadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else {
            throw ConnectorError.invalidAuth("Google Antigravity OAuth authorization URL could not be created.")
        }
        return url
    }

    public static func authorizationCodeTokenRequestBody(
        code: GoogleAntigravityAuthorizationCode,
        codeVerifier: String,
        redirectURI: String = manualRedirectURI,
        clientID: String = GoogleAntigravityOAuthMetadata.clientID,
        clientSecret: String? = GoogleAntigravityOAuthMetadata.clientSecret
    ) -> Data {
        var values = [
            "grant_type": "authorization_code",
            "code": code.code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ]
        if let clientSecret, !clientSecret.isEmpty {
            values["client_secret"] = clientSecret
        }
        return formURLEncoded(values)
    }

    public static func refreshTokenRequestBody(
        refreshToken: String,
        clientID: String = GoogleAntigravityOAuthMetadata.clientID,
        clientSecret: String? = GoogleAntigravityOAuthMetadata.clientSecret
    ) -> Data {
        var values = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let clientSecret, !clientSecret.isEmpty {
            values["client_secret"] = clientSecret
        }
        return formURLEncoded(values)
    }

    private static func formURLEncoded(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map { key, value in
            URLQueryItem(name: key, value: value)
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

public struct GoogleAntigravityAuthorizationCode: Equatable, Sendable {
    public let code: String
    public let state: String?

    public init(code: String, state: String?) {
        self.code = code
        self.state = state
    }
}

public enum GoogleAntigravityQuotaParser {
    public static func usageLimits(
        from data: Data,
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) throws -> [UsageLimit] {
        let payload = try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityAvailableModelsPayload.self, from: data)
        return payload.limits(
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            observedAt: observedAt
        )
    }
}

public struct GoogleAntigravityQuotaConnector: ProviderConnector {
    public let provider: Provider = .google

    private let accounts: [GoogleAntigravityAccountConfiguration]
    private let httpClient: any ConnectorHTTPClient
    private let credentialStore: any ProviderCredentialStoring
    private let expirationSkew: TimeInterval

    public init(
        accounts: [GoogleAntigravityAccountConfiguration],
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

    private func refresh(account: GoogleAntigravityAccountConfiguration, now: Date) async -> ProviderConnectorReport {
        let localAccountID = ConnectorRedactor.localAccountID(provider: provider, stableID: account.accountID)

        do {
            var credentials = try loadCredentials(accountID: account.accountID)
            return try await refresh(
                account: account,
                credentials: &credentials,
                now: now,
                localAccountID: localAccountID
            )
        } catch {
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                configuredAccountID: account.accountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: [],
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func refresh(
        account: GoogleAntigravityAccountConfiguration,
        credentials: inout GoogleAntigravityOAuthCredentials,
        now: Date,
        localAccountID: String
    ) async throws -> ProviderConnectorReport {
        do {
            let accessToken = try await accessToken(credentials: &credentials, account: account, now: now, forceRefresh: false)
            return try await quotaReport(
                accessToken: accessToken,
                account: account,
                credentials: credentials,
                now: now,
                localAccountID: localAccountID
            )
        } catch ConnectorError.httpFailure(_, let statusCode) where statusCode == 401 || statusCode == 403 {
            let refreshedToken = try await accessToken(credentials: &credentials, account: account, now: now, forceRefresh: true)
            do {
                return try await quotaReport(
                    accessToken: refreshedToken,
                    account: account,
                    credentials: credentials,
                    now: now,
                    localAccountID: localAccountID
                )
            } catch ConnectorError.httpFailure(_, let retryStatusCode) where retryStatusCode == 401 || retryStatusCode == 403 {
                throw ConnectorError.invalidAuth("Google Antigravity OAuth session is not authorized for quota access. Sign in again from Settings.")
            } catch {
                throw error
            }
        } catch {
            throw error
        }
    }

    private func quotaReport(
        accessToken: String,
        account: GoogleAntigravityAccountConfiguration,
        credentials: GoogleAntigravityOAuthCredentials,
        now: Date,
        localAccountID: String
    ) async throws -> ProviderConnectorReport {
        let projectID = try await projectID(accessToken: accessToken, account: account, credentials: credentials)
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: codeAssistURL(path: "v1internal:fetchAvailableModels", baseURL: account.codeAssistBaseURL),
            method: "POST",
            headers: requestHeaders(accessToken: accessToken, account: account),
            body: try JSONSerialization.data(withJSONObject: ["project": projectID])
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Google Antigravity model availability", statusCode: response.statusCode)
        }
        let limits = try GoogleAntigravityQuotaParser.usageLimits(
            from: response.data,
            accountID: localAccountID,
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            observedAt: now
        )
        return ProviderConnectorReport(
            provider: provider,
            accountID: localAccountID,
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            generatedAt: now,
            limits: limits,
            status: limits.isEmpty ? .unknown : nil,
            errorMessage: limits.isEmpty ? "Google Antigravity did not report model quota availability." : nil
        )
    }

    private func projectID(
        accessToken: String,
        account: GoogleAntigravityAccountConfiguration,
        credentials: GoogleAntigravityOAuthCredentials
    ) async throws -> String {
        if let configured = nonEmpty(account.projectID) ?? nonEmpty(credentials.projectID) {
            return configured
        }
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: codeAssistURL(path: "v1internal:loadCodeAssist", baseURL: account.codeAssistBaseURL),
            method: "POST",
            headers: requestHeaders(accessToken: accessToken, account: account),
            body: try JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Google Antigravity project discovery", statusCode: response.statusCode)
        }
        let payload = try JSONDecoder().decode(GoogleAntigravityLoadCodeAssistPayload.self, from: response.data)
        guard let projectID = payload.projectID else {
            throw ConnectorError.decodingFailure("Google Antigravity did not return an active project for quota lookup.")
        }
        return projectID
    }

    private func loadCredentials(accountID: String) throws -> GoogleAntigravityOAuthCredentials {
        guard let data = try credentialStore.load(accountID: accountID) else {
            throw ConnectorError.missingAuth("Google Antigravity is not connected. Sign in to Google from Settings.")
        }
        return try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityOAuthCredentials.self, from: data)
    }

    private func saveCredentials(_ credentials: GoogleAntigravityOAuthCredentials, accountID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try credentialStore.save(try encoder.encode(credentials), accountID: accountID)
    }

    private func accessToken(
        credentials: inout GoogleAntigravityOAuthCredentials,
        account: GoogleAntigravityAccountConfiguration,
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
            throw ConnectorError.invalidAuth("Google Antigravity OAuth credentials do not contain a refresh token. Sign in again from Settings.")
        }
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: account.tokenEndpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: GoogleAntigravityOAuthFlow.refreshTokenRequestBody(
                refreshToken: refreshToken,
                clientID: account.clientID,
                clientSecret: account.clientSecret
            )
        ))
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                throw googleOAuthRefreshError(statusCode: response.statusCode, data: response.data)
            }
            throw ConnectorError.httpFailure(operation: "Google Antigravity OAuth refresh", statusCode: response.statusCode)
        }
        let token = try JSONDecoder().decode(GoogleAntigravityOAuthTokenResponse.self, from: response.data)
        credentials = GoogleAntigravityOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            scopes: token.scopes.isEmpty ? credentials.scopes : token.scopes,
            projectID: credentials.projectID
        )
        try saveCredentials(credentials, accountID: account.accountID)
        return token.accessToken
    }

    private func requestHeaders(accessToken: String, account: GoogleAntigravityAccountConfiguration) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": account.userAgent,
            "Client-Metadata": #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#,
        ]
    }

    private func codeAssistURL(path: String, baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/\(path)"
        return components.url!
    }

    private func googleOAuthRefreshError(statusCode: Int, data: Data) -> ConnectorError {
        let payload = try? JSONDecoder().decode(GoogleOAuthErrorPayload.self, from: data)
        if payload?.error == "invalid_grant" {
            return ConnectorError.invalidAuth("Google Antigravity OAuth session has expired. Sign in again from Settings.")
        }
        if let error = payload?.error, !error.isEmpty {
            return ConnectorError.invalidAuth("Google Antigravity OAuth refresh failed with \(error). Check the OAuth client configuration and sign in again.")
        }
        if statusCode == 401 || statusCode == 403 {
            return ConnectorError.invalidAuth("Google Antigravity OAuth session is not authorized. Sign in again from Settings.")
        }
        return ConnectorError.httpFailure(operation: "Google Antigravity OAuth refresh", statusCode: statusCode)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public enum GoogleAntigravityOAuthMetadata {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let codeAssistBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    public static let userAgent = "antigravity/macos/context-panel"

    public static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    public static let clientSecret: String? = nil
    public static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]
}

private struct GoogleOAuthErrorPayload: Decodable {
    let error: String?
}

private struct GoogleAntigravityLoadCodeAssistPayload: Decodable {
    let cloudaicompanionProject: GoogleAntigravityProjectValue?

    var projectID: String? {
        cloudaicompanionProject?.id
    }
}

private enum GoogleAntigravityProjectValue: Decodable, Equatable {
    case string(String)
    case object(String)

    var id: String? {
        switch self {
        case .string(let value), .object(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let object = try container.decode(GoogleAntigravityProjectObject.self)
        self = .object(object.id)
    }
}

private struct GoogleAntigravityProjectObject: Decodable, Equatable {
    let id: String
}

private struct GoogleAntigravityAvailableModelsPayload: Decodable {
    let models: [String: GoogleAntigravityModelInfo]

    func limits(
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) -> [UsageLimit] {
        let groups = groupedQuotas()
        return groups.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }).map { group, quota in
            UsageLimit(
                provider: .google,
                accountID: accountID,
                configuredAccountID: configuredAccountID,
                accountName: accountName,
                label: "\(group.displayName) availability",
                windowLabel: "Availability",
                modelLabel: group.displayName,
                unit: .percent,
                used: Int(((1 - quota.remainingFraction) * 100).rounded()),
                limit: 100,
                resetsAt: quota.resetTime,
                lastUpdatedAt: observedAt,
                confidence: .observed,
                note: "source: Google Antigravity model availability"
            )
        }
    }

    private func groupedQuotas() -> [GoogleAntigravityModelGroup: GoogleAntigravityQuotaAggregate] {
        models.reduce(into: [:]) { groups, entry in
            guard let group = GoogleAntigravityModelGroup(modelName: entry.key) else { return }
            guard let quotaInfo = entry.value.quotaInfo, let remainingFraction = quotaInfo.remainingFraction else { return }
            let clamped = max(0, min(remainingFraction, 1))
            groups[group, default: GoogleAntigravityQuotaAggregate(remainingFraction: clamped, resetTime: quotaInfo.resetTime)]
                .merge(remainingFraction: clamped, resetTime: quotaInfo.resetTime)
        }
    }
}

private struct GoogleAntigravityModelInfo: Decodable {
    let quotaInfo: GoogleAntigravityQuotaInfo?
}

private struct GoogleAntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: Date?
}

private struct GoogleAntigravityQuotaAggregate: Equatable {
    private(set) var remainingFraction: Double
    private(set) var resetTime: Date?

    mutating func merge(remainingFraction: Double, resetTime: Date?) {
        self.remainingFraction = min(self.remainingFraction, remainingFraction)
        if let resetTime {
            if let current = self.resetTime {
                self.resetTime = min(current, resetTime)
            } else {
                self.resetTime = resetTime
            }
        }
    }
}

private enum GoogleAntigravityModelGroup: Hashable {
    case geminiPro
    case geminiFlash
    case gemini
    case claude
    case gptOSS
    case other(String)

    init?(modelName: String) {
        let lower = modelName.lowercased()
        if lower.contains("claude") {
            self = .claude
        } else if lower.contains("gpt-oss") || lower.contains("gptoss") {
            self = .gptOSS
        } else if lower.contains("gemini") && lower.contains("flash") {
            self = .geminiFlash
        } else if lower.contains("gemini") && lower.contains("pro") {
            self = .geminiPro
        } else if lower.contains("gemini") {
            self = .gemini
        } else {
            self = .other(Self.displayName(for: modelName))
        }
    }

    var displayName: String {
        switch self {
        case .geminiPro:
            "Gemini Pro"
        case .geminiFlash:
            "Gemini Flash"
        case .gemini:
            "Gemini"
        case .claude:
            "Claude"
        case .gptOSS:
            "GPT-OSS"
        case .other(let value):
            value
        }
    }

    var sortOrder: Int {
        switch self {
        case .geminiPro: 0
        case .geminiFlash: 1
        case .gemini: 2
        case .claude: 3
        case .gptOSS: 4
        case .other: 5
        }
    }

    private static func displayName(for modelName: String) -> String {
        let base = modelName
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .prefix(3)
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: " ")
        return base.isEmpty ? "Other Model" : base
    }
}
