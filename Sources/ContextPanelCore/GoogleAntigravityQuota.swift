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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? GoogleAntigravityOAuthMetadata.scopes
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)

        let hasAccessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasRefreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasAccessToken || hasRefreshToken else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Google Antigravity credentials do not contain an access or refresh token."
            ))
        }
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
        clientID: String = GoogleAntigravityOAuthMetadata.clientID ?? "",
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
    public static let callbackPath = "/oauth-callback"
    public static let fallbackLoopbackPort: UInt16 = 51121
    public static let manualRedirectURI = loopbackRedirectURI(port: fallbackLoopbackPort)

    public static func loopbackRedirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

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
        clientID: String? = GoogleAntigravityOAuthMetadata.clientID,
        scopes: [String] = GoogleAntigravityOAuthMetadata.scopes
    ) throws -> URL {
        guard let clientID, !clientID.isEmpty else {
            throw ConnectorError.invalidAuth("Google Antigravity OAuth client ID is not configured.")
        }
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
        clientID: String? = GoogleAntigravityOAuthMetadata.clientID,
        clientSecret: String? = GoogleAntigravityOAuthMetadata.clientSecret
    ) throws -> Data {
        guard let clientID, !clientID.isEmpty else {
            throw ConnectorError.invalidAuth("Google Antigravity OAuth client ID is not configured.")
        }
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
        clientID: String? = GoogleAntigravityOAuthMetadata.clientID,
        clientSecret: String? = GoogleAntigravityOAuthMetadata.clientSecret
    ) throws -> Data {
        guard let clientID, !clientID.isEmpty else {
            throw ConnectorError.invalidAuth("Google Antigravity OAuth client ID is not configured.")
        }
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
        observedAt: Date,
        statusOverride: UsageStatus? = nil
    ) throws -> [UsageLimit] {
        let payload = try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityAvailableModelsPayload.self, from: data)
        return payload.limits(
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            observedAt: observedAt,
            statusOverride: statusOverride
        )
    }

    public static func usageLimitsFromSummary(
        from data: Data,
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) throws -> [UsageLimit] {
        let payload = try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityQuotaSummaryPayload.self, from: data)
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

    private enum RequestMetadata {
        static let apiClient = "gl-mac/1.0.0 antigravity-context-panel/1.0.0"
        static let clientMetadata = #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#
    }

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
        if credentials.projectID != projectID {
            try? saveCredentials(credentials.withProjectID(projectID), accountID: account.accountID)
        }
        let summaryResponse = try await httpClient.data(for: ConnectorHTTPRequest(
            url: codeAssistURL(path: "v1internal:retrieveUserQuotaSummary", baseURL: account.codeAssistBaseURL),
            method: "POST",
            headers: requestHeaders(accessToken: accessToken, account: account),
            body: try JSONSerialization.data(withJSONObject: ["project": projectID])
        ))
        guard (200..<300).contains(summaryResponse.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Google Antigravity quota summary", statusCode: summaryResponse.statusCode)
        }
        let summaryLimits = try GoogleAntigravityQuotaParser.usageLimitsFromSummary(
            from: summaryResponse.data,
            accountID: localAccountID,
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            observedAt: now
        )
        let limits: [UsageLimit]
        let status: UsageStatus?
        let errorMessage: String?
        if summaryLimits.isEmpty {
            let availabilityResponse = try await httpClient.data(for: ConnectorHTTPRequest(
                url: codeAssistURL(path: "v1internal:fetchAvailableModels", baseURL: account.codeAssistBaseURL),
                method: "POST",
                headers: requestHeaders(accessToken: accessToken, account: account),
                body: try JSONSerialization.data(withJSONObject: ["project": projectID])
            ))
            guard (200..<300).contains(availabilityResponse.statusCode) else {
                throw ConnectorError.httpFailure(operation: "Google Antigravity model availability", statusCode: availabilityResponse.statusCode)
            }
            limits = try GoogleAntigravityQuotaParser.usageLimits(
                from: availabilityResponse.data,
                accountID: localAccountID,
                configuredAccountID: account.accountID,
                accountName: account.accountName,
                observedAt: now,
                statusOverride: .unknown
            )
            status = .unknown
            errorMessage = limits.isEmpty
                ? "Google Antigravity did not report quota summary or model availability."
                : "Google Antigravity did not report quota summary; showing model availability only."
        } else {
            limits = summaryLimits
            status = nil
            errorMessage = nil
        }
        return ProviderConnectorReport(
            provider: provider,
            accountID: localAccountID,
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            generatedAt: now,
            limits: limits,
            status: status,
            errorMessage: errorMessage
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
        do {
            return try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityOAuthCredentials.self, from: data)
        } catch is DecodingError {
            throw ConnectorError.invalidAuth("Google Antigravity credentials are in an unexpected format. Sign in again from Settings.")
        }
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
            body: try GoogleAntigravityOAuthFlow.refreshTokenRequestBody(
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
            "X-Goog-Api-Client": RequestMetadata.apiClient,
            "X-Goog-QuotaUser": account.accountID,
            "User-Agent": account.userAgent,
            "Client-Metadata": RequestMetadata.clientMetadata,
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
            let detail = nonEmpty(payload?.errorDescription).map { " \($0)" } ?? ""
            if payload?.errorDescription?.localizedCaseInsensitiveContains("client_secret") == true {
                return ConnectorError.invalidAuth("Google Antigravity OAuth client secret is not configured.\(detail)")
            }
            if error == "invalid_request" || error == "invalid_client" || error == "unauthorized_client" {
                return ConnectorError.invalidAuth("Google Antigravity OAuth refresh failed with \(error).\(detail) Sign in again from Settings to refresh the OAuth client session.")
            }
            return ConnectorError.invalidAuth("Google Antigravity OAuth refresh failed with \(error).\(detail) Sign in again from Settings.")
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

private extension GoogleAntigravityOAuthCredentials {
    func withProjectID(_ projectID: String) -> GoogleAntigravityOAuthCredentials {
        GoogleAntigravityOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            projectID: projectID
        )
    }
}

public enum GoogleAntigravityOAuthMetadata {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let codeAssistBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    public static let userAgent = "antigravity/macos/context-panel"
    public static let defaultClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"

    public static var clientID: String? {
        configuredValue(named: "CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID")
            ?? defaultClientID
    }
    public static var clientSecret: String? {
        configuredValue(named: "CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET")
    }
    public static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]

    private static func configuredValue(named key: String) -> String? {
        let environmentValue = ProcessInfo.processInfo.environment[key]
        let bundleValue = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return [environmentValue, bundleValue]
            .compactMap { normalizedConfiguredValue($0) }
            .first { !$0.isEmpty && !$0.hasPrefix("$(") }
    }

    static func normalizedConfiguredValue(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while value.count >= 2, value.first == "\"", value.last == "\"" {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}

private struct GoogleOAuthErrorPayload: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
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

private struct GoogleAntigravityQuotaSummaryPayload: Decodable {
    let buckets: [GoogleAntigravityQuotaSummaryBucket]
    let groups: [GoogleAntigravityQuotaSummaryGroup]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try container.decodeIfPresent([GoogleAntigravityQuotaSummaryBucket].self, forKey: .buckets) ?? []
        groups = try container.decodeIfPresent([GoogleAntigravityQuotaSummaryGroup].self, forKey: .groups) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case buckets
        case groups
    }

    func limits(
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) -> [UsageLimit] {
        let groupedLimits = groups.flatMap { group in
            group.buckets.compactMap { bucket in
                bucket.usageLimit(
                    group: group,
                    accountID: accountID,
                    configuredAccountID: configuredAccountID,
                    accountName: accountName,
                    observedAt: observedAt
                )
            }
        }
        if !groupedLimits.isEmpty { return groupedLimits }
        return buckets.compactMap { bucket in
            bucket.usageLimit(
                group: nil,
                accountID: accountID,
                configuredAccountID: configuredAccountID,
                accountName: accountName,
                observedAt: observedAt
            )
        }
    }
}

private struct GoogleAntigravityQuotaSummaryGroup: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [GoogleAntigravityQuotaSummaryBucket]

    enum CodingKeys: String, CodingKey {
        case displayName
        case displayNameSnake = "display_name"
        case description
        case buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeFirstPresent(String.self, forKeys: [.displayName, .displayNameSnake])
        description = try container.decodeIfPresent(String.self, forKey: .description)
        buckets = try container.decodeIfPresent([GoogleAntigravityQuotaSummaryBucket].self, forKey: .buckets) ?? []
    }
}

private struct GoogleAntigravityQuotaSummaryBucket: Decodable {
    let bucketID: String?
    let displayName: String?
    let description: String?
    let window: String?
    let remainingFraction: Double?
    let remainingAmount: Int?
    let disabled: Bool?
    let resetTime: Date?

    enum CodingKeys: String, CodingKey {
        case bucketID = "bucketId"
        case bucketIDSnake = "bucket_id"
        case displayName
        case displayNameSnake = "display_name"
        case description
        case window
        case remainingFraction
        case remainingFractionSnake = "remaining_fraction"
        case remainingAmount
        case remainingAmountSnake = "remaining_amount"
        case disabled
        case resetTime
        case resetTimeSnake = "reset_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketID = try container.decodeFirstPresent(String.self, forKeys: [.bucketID, .bucketIDSnake])
        displayName = try container.decodeFirstPresent(String.self, forKeys: [.displayName, .displayNameSnake])
        description = try container.decodeIfPresent(String.self, forKey: .description)
        window = try container.decodeIfPresent(String.self, forKey: .window)
        remainingFraction = try Self.decodeFlexibleDouble(container: container, keys: [.remainingFraction, .remainingFractionSnake])
        remainingAmount = try Self.decodeFlexibleInt(container: container, keys: [.remainingAmount, .remainingAmountSnake])
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        resetTime = try container.decodeFirstPresent(Date.self, forKeys: [.resetTime, .resetTimeSnake])
    }

    func usageLimit(
        group: GoogleAntigravityQuotaSummaryGroup?,
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) -> UsageLimit? {
        guard disabled != true else { return nil }
        let clampedRemainingFraction = remainingFraction.map { max(0, min($0, 1)) }
        let used: Int?
        let limit: Int
        let unit: UsageUnit
        if let clampedRemainingFraction {
            used = Int(((1 - clampedRemainingFraction) * 100).rounded())
            limit = 100
            unit = .percent
        } else if let remainingAmount {
            if remainingAmount <= 0 {
                used = 1
                limit = 1
            } else {
                used = nil
                limit = remainingAmount
            }
            unit = .requests
        } else {
            return nil
        }

        let groupName = normalized(group?.displayName)
        let bucketName = normalized(displayName) ?? normalized(bucketID) ?? "Quota"
        let label = groupName.map { "\($0) \(bucketName)" } ?? bucketName
        let noteParts = [
            "source: Google Antigravity quota summary",
            normalized(description),
            normalized(group?.description),
        ]
        return UsageLimit(
            provider: .google,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            label: label,
            windowLabel: normalized(window) ?? bucketName,
            modelLabel: groupName,
            unit: unit,
            used: used,
            limit: limit,
            resetsAt: resetTime,
            lastUpdatedAt: observedAt,
            confidence: .observed,
            note: noteParts.compactMap { $0 }.joined(separator: "; ")
        )
    }

    private static func decodeFlexibleDouble<Key: CodingKey>(container: KeyedDecodingContainer<Key>, keys: [Key]) throws -> Double? {
        try container.decodeFirstPresent(FlexibleDouble.self, forKeys: keys)?.value
    }

    private static func decodeFlexibleInt<Key: CodingKey>(container: KeyedDecodingContainer<Key>, keys: [Key]) throws -> Int? {
        try container.decodeFirstPresent(FlexibleInt.self, forKeys: keys)?.value
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension KeyedDecodingContainer {
    func decodeFirstPresent<Value: Decodable>(_ type: Value.Type, forKeys keys: [Key]) throws -> Value? {
        for key in keys {
            if let value = try decodeIfPresent(type, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = Double(stringValue)
        } else {
            value = nil
        }
    }
}

private struct FlexibleInt: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self) {
            value = Int(stringValue)
        } else {
            value = nil
        }
    }
}

private struct GoogleAntigravityAvailableModelsPayload: Decodable {
    let models: [String: GoogleAntigravityModelInfo]

    func limits(
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date,
        statusOverride: UsageStatus? = nil
    ) -> [UsageLimit] {
        let groups = groupedQuotas()
        return groups.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }).map { group, quota in
            UsageLimit(
                provider: .google,
                accountID: accountID,
                configuredAccountID: configuredAccountID,
                accountName: accountName,
                label: "\(group.displayName) capacity",
                windowLabel: group.windowLabel,
                modelLabel: group.displayName,
                unit: .percent,
                used: Int(((1 - quota.remainingFraction) * 100).rounded()),
                limit: 100,
                resetsAt: quota.resetTime,
                lastUpdatedAt: observedAt,
                confidence: .observed,
                statusOverride: statusOverride,
                note: "source: Google Antigravity model availability"
            )
        }
    }

    private func groupedQuotas() -> [GoogleAntigravityModelGroup: GoogleAntigravityQuotaAggregate] {
        models.reduce(into: [:]) { groups, entry in
            guard let group = GoogleAntigravityModelGroup(modelName: entry.key, displayName: entry.value.displayName) else { return }
            guard let quotaInfo = entry.value.quotaInfo else { return }
            let remainingFraction = quotaInfo.remainingFraction ?? 0
            let clamped = max(0, min(remainingFraction, 1))
            groups[group, default: GoogleAntigravityQuotaAggregate(remainingFraction: clamped, resetTime: quotaInfo.resetTime)]
                .merge(remainingFraction: clamped, resetTime: quotaInfo.resetTime)
        }
    }
}

private struct GoogleAntigravityModelInfo: Decodable {
    let displayName: String?
    let quotaInfo: GoogleAntigravityQuotaInfo?
}

private struct GoogleAntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: Date?

    enum CodingKeys: String, CodingKey {
        case remainingFraction
        case resetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
            remainingFraction = doubleValue
        } else if
            let stringValue = try? container.decodeIfPresent(String.self, forKey: .remainingFraction),
            let doubleValue = Double(stringValue)
        {
            remainingFraction = doubleValue
        } else {
            remainingFraction = nil
        }
        resetTime = try container.decodeIfPresent(Date.self, forKey: .resetTime)
    }
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

    init?(modelName: String, displayName: String? = nil) {
        let lower = [modelName, displayName].compactMap { $0 }.joined(separator: " ").lowercased()
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

    var windowLabel: String {
        "Model capacity"
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
