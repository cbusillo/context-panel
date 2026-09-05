import Foundation

public enum CodexRateLimitReachedType: String, Codable, Equatable, Sendable {
    case rateLimitReached = "rate_limit_reached"
    case workspaceOwnerCreditsDepleted = "workspace_owner_credits_depleted"
    case workspaceMemberCreditsDepleted = "workspace_member_credits_depleted"
    case workspaceOwnerUsageLimitReached = "workspace_owner_usage_limit_reached"
    case workspaceMemberUsageLimitReached = "workspace_member_usage_limit_reached"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let rawValue = try? container.decode(String.self) else {
            self = .unknown
            return
        }
        self = Self(rawValue: rawValue) ?? .unknown
    }
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
        limitName ?? (id == "codex" ? "Codex" : id)
    }
}

public struct CodexModelAvailability: Equatable, Sendable {
    private let normalizedIdentifiers: Set<String>
    private let standaloneGPTFamilies: Set<GPTFamily>

    public init(identifiers: some Sequence<String>) {
        let identifierValues = Array(identifiers)
        normalizedIdentifiers = Set(identifierValues.map(Self.normalize).filter { !$0.isEmpty })
        standaloneGPTFamilies = Set(identifierValues.compactMap(Self.standaloneGPTFamily))
    }

    public var isEmpty: Bool {
        normalizedIdentifiers.isEmpty
    }

    public func contains(identifier: String) -> Bool {
        normalizedIdentifiers.contains(Self.normalize(identifier))
    }

    public func contains(limitName: String) -> Bool {
        contains(identifier: limitName)
    }

    fileprivate func containsAdditionalLimit(limitName: String, meteredFeature: String) -> Bool {
        if contains(identifier: limitName) || contains(identifier: meteredFeature) {
            return true
        }
        guard let family = Self.codexGPTFamily(limitName: limitName, meteredFeature: meteredFeature)
        else { return false }
        return standaloneGPTFamilies.contains(family)
    }

    fileprivate static func isModelSpecificLimitName(_ value: String) -> Bool {
        let normalized = normalize(value)
        return normalized.contains("gpt")
            || normalized.contains("codex")
            || normalized.range(of: #"^o[0-9]"#, options: .regularExpression) != nil
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func codexGPTFamily(limitName: String, meteredFeature: String) -> GPTFamily? {
        if let family = explicitlyCodexGPTFamily(in: limitName) {
            return family
        }
        if let family = explicitlyCodexGPTFamily(in: meteredFeature) {
            return family
        }
        let featureTokens = tokens(in: meteredFeature)
        guard featureTokens.first == "codex" else { return nil }
        return leadingGPTFamily(in: limitName)
    }

    private static func explicitlyCodexGPTFamily(in value: String) -> GPTFamily? {
        let components = tokens(in: value)
        guard components.count >= 4,
              components[3] == "codex"
        else { return nil }
        return gptFamily(from: Array(components.prefix(3)))
    }

    private static func standaloneGPTFamily(_ value: String) -> GPTFamily? {
        let components = tokens(in: value)
        guard components.count == 3 else { return nil }
        return gptFamily(from: components)
    }

    private static func leadingGPTFamily(in value: String) -> GPTFamily? {
        let components = tokens(in: value)
        guard components.count >= 3 else { return nil }
        return gptFamily(from: Array(components.prefix(3)))
    }

    private static func gptFamily(from components: [String]) -> GPTFamily? {
        guard components.count == 3,
              components[0] == "gpt",
              isASCIIDigits(components[1]),
              isASCIIDigits(components[2])
        else { return nil }
        return GPTFamily(major: components[1], minor: components[2])
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character >= "0" && character <= "9"
        }
    }

    private static func tokens(in value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private struct GPTFamily: Hashable {
        let major: String
        let minor: String
    }
}

public struct CodexAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let idToken: String?
    public let refreshToken: String?

    public init(accessToken: String, accountID: String?, idToken: String?, refreshToken: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.idToken = idToken
        self.refreshToken = refreshToken
    }
}

private struct CodexAuthRecord: Equatable, Sendable {
    let tokens: CodexAuthTokens
    let accountName: String
    let stableID: String?
    let planType: String?
}

public enum CodexAuthFileParser {
    public static func tokens(from data: Data) throws -> CodexAuthTokens {
        let payload = try JSONDecoder().decode(CodexAuthFilePayload.self, from: data)
        guard let tokens = payload.tokens, !tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorError.invalidAuth("auth file does not contain ChatGPT token auth")
        }
        return CodexAuthTokens(
            accessToken: tokens.accessToken,
            accountID: tokens.accountID,
            idToken: tokens.idToken,
            refreshToken: tokens.refreshToken
        )
    }

    fileprivate static func authRecords(from data: Data, accountName: String) throws -> [CodexAuthRecord] {
        if let accountList = try? JSONDecoder().decode(CodexAuthAccountsFilePayload.self, from: data) {
            let chatGPTAccounts = accountList.accounts.filter { account in
                (account.mode == nil || account.mode == "chatgpt")
                    && !account.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && account.tokens?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            let records = chatGPTAccounts.enumerated().compactMap { index, account -> CodexAuthRecord? in
                guard let tokens = account.tokens else { return nil }
                let tokenIdentity = CodexTokenIdentity.extract(fromIDToken: tokens.idToken)
                let name = Self.accountDisplayName(
                    configuredName: accountName,
                    accountLabel: account.label,
                    tokenIdentity: tokenIdentity,
                    fallbackSuffix: chatGPTAccounts.count == 1 ? nil : "\(index + 1)"
                )
                return CodexAuthRecord(
                    tokens: CodexAuthTokens(
                        accessToken: tokens.accessToken,
                        accountID: tokens.accountID,
                        idToken: tokens.idToken,
                        refreshToken: tokens.refreshToken
                    ),
                    accountName: name,
                    stableID: account.id,
                    planType: tokenIdentity.planType
                )
            }
            if !records.isEmpty {
                return records
            }
        }

        let authTokens = try tokens(from: data)
        let tokenIdentity = CodexTokenIdentity.extract(fromIDToken: authTokens.idToken)
        return [CodexAuthRecord(
            tokens: authTokens,
            accountName: Self.accountDisplayName(
                configuredName: accountName,
                accountLabel: nil,
                tokenIdentity: tokenIdentity,
                fallbackSuffix: nil
            ),
            stableID: nil,
            planType: tokenIdentity.planType
        )]
    }

    private static func accountDisplayName(
        configuredName: String,
        accountLabel: String?,
        tokenIdentity: CodexTokenIdentity,
        fallbackSuffix: String?
    ) -> String {
        let baseName = [accountLabel, tokenIdentity.email, tokenIdentity.name]
            .compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return value
            }
            .first ?? fallbackSuffix.map { "\(configuredName) \($0)" } ?? configuredName
        guard let planType = tokenIdentity.planType?.trimmingCharacters(in: .whitespacesAndNewlines), !planType.isEmpty else {
            return baseName
        }
        return "\(baseName) · \(planType)"
    }
}

public enum CodexAccountIDExtractor {
    public static func accountID(fromIDToken token: String?) -> String? {
        CodexTokenIdentity.extract(fromIDToken: token).chatGPTAccountID
    }
}

public struct CodexTokenIdentity: Equatable, Sendable {
    public let chatGPTAccountID: String?
    public let email: String?
    public let name: String?
    public let planType: String?

    public init(chatGPTAccountID: String?, email: String?, name: String?, planType: String?) {
        self.chatGPTAccountID = chatGPTAccountID
        self.email = email
        self.name = name
        self.planType = planType
    }

    public static func extract(fromIDToken token: String?) -> CodexTokenIdentity {
        let empty = CodexTokenIdentity(chatGPTAccountID: nil, email: nil, name: nil, planType: nil)
        guard let token else { return empty }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return empty }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = object["https://api.openai.com/auth"] as? [String: Any]
        else {
            return empty
        }
        return CodexTokenIdentity(
            chatGPTAccountID: auth["chatgpt_account_id"] as? String,
            email: object["email"] as? String,
            name: object["name"] as? String,
            planType: auth["chatgpt_plan_type"] as? String
        )
    }
}

public struct CodexAccountConfiguration: Equatable, Sendable {
    public let configuredAccountID: String?
    public let authPath: String
    public let accountName: String
    public let endpoint: URL
    public let modelAvailabilityEndpoint: URL?

    public init(
        configuredAccountID: String? = nil,
        authPath: String,
        accountName: String? = nil,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        modelAvailabilityEndpoint: URL? = nil
    ) {
        self.configuredAccountID = configuredAccountID
        self.authPath = authPath
        self.accountName = accountName ?? ConnectorRedactor.redactedPath(authPath)
        self.endpoint = endpoint
        self.modelAvailabilityEndpoint = modelAvailabilityEndpoint ?? Self.defaultModelAvailabilityEndpoint(for: endpoint)
    }

    private static func defaultModelAvailabilityEndpoint(for endpoint: URL) -> URL? {
        guard endpoint.host == "chatgpt.com" else { return nil }
        return URL(string: "https://chatgpt.com/backend-api/models")
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
            reports.append(contentsOf: await refresh(account: account, now: now))
        }
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }

    private func refresh(account: CodexAccountConfiguration, now: Date) async -> [ProviderConnectorReport] {
        do {
            let records = try CodexAuthFileParser.authRecords(
                from: try fileLoader(account.authPath),
                accountName: account.accountName
            )
            var reports: [ProviderConnectorReport] = []
            reports.reserveCapacity(records.count)
            for record in records {
                reports.append(try await refresh(authRecord: record, account: account, now: now))
            }
            return reports
        } catch {
            let localAccountID = ConnectorRedactor.localAccountID(provider: provider, path: account.authPath)
            return [ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                configuredAccountID: account.configuredAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: [],
                status: .failure,
                errorMessage: error.localizedDescription
            )]
        }
    }

    private func refresh(
        authRecord: CodexAuthRecord,
        account: CodexAccountConfiguration,
        now: Date
    ) async throws -> ProviderConnectorReport {
        let auth = authRecord.tokens
        let providerAccountID = canonicalProviderAccountID(from: auth)
        let localAccountID = providerAccountID.map {
            ConnectorRedactor.localAccountID(provider: provider, stableID: "chatgpt:\($0)")
        } ?? authRecord.stableID.map {
            ConnectorRedactor.localAccountID(provider: provider, stableID: "local:\($0)")
        } ?? ConnectorRedactor.localAccountID(provider: provider, path: account.authPath)

        var observedResetCredits: ProviderResetCreditSummary?
        do {
            let data = try await fetchUsage(endpoint: account.endpoint, auth: auth)
            observedResetCredits = await resetCredits(
                for: account,
                auth: auth,
                usageData: data,
                observedAt: now
            )
            let availability = await modelAvailability(for: account, auth: auth, usageData: data)
            let snapshots = try CodexUsagePayloadParser.snapshots(from: data, modelAvailability: availability)
            let limits = snapshots.flatMap { snapshot in
                codexUsageLimits(
                    from: snapshot,
                    accountID: localAccountID,
                    configuredAccountID: account.configuredAccountID,
                    accountName: authRecord.accountName,
                    observedAt: now
                )
            }
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                configuredAccountID: account.configuredAccountID,
                accountName: authRecord.accountName,
                generatedAt: now,
                limits: limits,
                resetCredits: observedResetCredits
            )
        } catch {
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                configuredAccountID: account.configuredAccountID,
                accountName: authRecord.accountName,
                generatedAt: now,
                limits: [],
                resetCredits: observedResetCredits?.preservingCountAfterRefreshFailure,
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func resetCredits(
        for account: CodexAccountConfiguration,
        auth: CodexAuthTokens,
        usageData: Data,
        observedAt: Date
    ) async -> ProviderResetCreditSummary? {
        guard let availableCount = CodexUsagePayloadParser.resetCreditAvailableCount(from: usageData) else {
            return nil
        }
        let countOnly = ProviderResetCreditSummary(
            availableCount: availableCount,
            observedAt: observedAt,
            coverage: .countOnly
        )
        guard availableCount > 0, let endpoint = resetCreditDetailsEndpoint(for: account.endpoint) else {
            return countOnly
        }
        do {
            let data = try await fetchResetCreditDetails(endpoint: endpoint, auth: auth)
            return try CodexResetCreditDetailsParser.summary(
                from: data,
                observedAt: observedAt
            )
        } catch {
            return countOnly
        }
    }

    private func resetCreditDetailsEndpoint(for usageEndpoint: URL) -> URL? {
        switch usageEndpoint.path {
        case "/backend-api/wham/usage", "/api/codex/usage":
            return usageEndpoint.deletingLastPathComponent().appendingPathComponent("rate-limit-reset-credits")
        default:
            return nil
        }
    }

    private func modelAvailability(
        for account: CodexAccountConfiguration,
        auth: CodexAuthTokens,
        usageData: Data
    ) async -> CodexModelAvailability? {
        guard CodexUsagePayloadParser.hasAdditionalRateLimits(in: usageData), let endpoint = account.modelAvailabilityEndpoint else {
            return nil
        }
        do {
            let availability = try await fetchModelAvailability(endpoint: endpoint, auth: auth)
            return availability.isEmpty ? nil : availability
        } catch {
            return nil
        }
    }

    private func fetchUsage(endpoint: URL, auth: CodexAuthTokens) async throws -> Data {
        let response = try await httpClient.data(for: ConnectorHTTPRequest(url: endpoint, method: "GET", headers: authorizedHeaders(auth: auth)))
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw codexUsageAuthorizationError(auth: auth)
            }
            throw ConnectorError.httpFailure(operation: "Codex usage endpoint", statusCode: response.statusCode)
        }
        return response.data
    }

    private func codexUsageAuthorizationError(auth: CodexAuthTokens) -> ConnectorError {
        if auth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return ConnectorError.foregroundRefreshRequired("This ChatGPT account is no longer authorized for Codex usage. Sign in again from the configured Codex or Codex Lab client, then refresh Context Panel.")
        }
        return ConnectorError.invalidAuth("Auth for this ChatGPT account cannot be refreshed. Sign in again from the configured Codex or Codex Lab client, then refresh Context Panel.")
    }

    private func fetchModelAvailability(endpoint: URL, auth: CodexAuthTokens) async throws -> CodexModelAvailability {
        let response = try await httpClient.data(for: ConnectorHTTPRequest(url: endpoint, method: "GET", headers: authorizedHeaders(auth: auth)))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "ChatGPT models endpoint", statusCode: response.statusCode)
        }
        return try CodexModelAvailabilityParser.availability(from: response.data)
    }

    private func fetchResetCreditDetails(endpoint: URL, auth: CodexAuthTokens) async throws -> Data {
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: endpoint,
            method: "GET",
            headers: authorizedHeaders(auth: auth)
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Codex reset-credit details endpoint", statusCode: response.statusCode)
        }
        return response.data
    }

    private func authorizedHeaders(auth: CodexAuthTokens) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "User-Agent": "context-panel",
            "Accept": "application/json",
        ]
        if let accountID = canonicalProviderAccountID(from: auth) {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }
}

private func canonicalProviderAccountID(from auth: CodexAuthTokens) -> String? {
    CodexAccountIDExtractor.accountID(fromIDToken: auth.idToken) ?? auth.accountID
}

public func codexUsageLimits(
    from snapshot: CodexRateLimitSnapshot,
    accountID: String,
    configuredAccountID: String? = nil,
    accountName: String,
    observedAt: Date
) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    if let primary = snapshot.primary {
        limits.append(codexUsageLimit(
            snapshot: snapshot,
            window: primary,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            observedAt: observedAt
        ))
    }
    if let secondary = snapshot.secondary {
        limits.append(codexUsageLimit(
            snapshot: snapshot,
            window: secondary,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            observedAt: observedAt
        ))
    }
    return limits
}

public enum CodexUsagePayloadParser {
    public static func snapshots(from data: Data) throws -> [CodexRateLimitSnapshot] {
        try snapshots(from: data, modelAvailability: nil)
    }

    public static func snapshots(from data: Data, modelAvailability: CodexModelAvailability?) throws -> [CodexRateLimitSnapshot] {
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        return snapshots(from: payload, modelAvailability: modelAvailability)
    }

    public static func hasAdditionalRateLimits(in data: Data) -> Bool {
        guard let payload = try? JSONDecoder().decode(CodexUsagePayload.self, from: data) else { return false }
        return !payload.additionalRateLimits.isEmpty
    }

    static func resetCreditAvailableCount(from data: Data) -> Int? {
        guard let payload = try? JSONDecoder().decode(CodexResetCreditCountEnvelope.self, from: data) else { return nil }
        return payload.summary.map { max(0, $0.availableCount) }
    }

    private static func snapshots(from payload: CodexUsagePayload, modelAvailability: CodexModelAvailability?) -> [CodexRateLimitSnapshot] {
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

        let additionalRateLimits = payload.additionalRateLimits.filter { additional in
            guard let modelAvailability else { return true }
            guard CodexModelAvailability.isModelSpecificLimitName(additional.limitName)
                || CodexModelAvailability.isModelSpecificLimitName(additional.meteredFeature)
            else { return true }
            return modelAvailability.containsAdditionalLimit(
                limitName: additional.limitName,
                meteredFeature: additional.meteredFeature
            )
        }

        snapshots.append(contentsOf: additionalRateLimits.map { additional in
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

public enum CodexModelAvailabilityParser {
    public static func availability(from data: Data) throws -> CodexModelAvailability {
        let payload = try JSONDecoder().decode(CodexModelsPayload.self, from: data)
        return CodexModelAvailability(identifiers: payload.models.flatMap(\.identifiers))
    }
}

enum CodexResetCreditDetailsParser {
    static func summary(
        from data: Data,
        observedAt: Date
    ) throws -> ProviderResetCreditSummary {
        let payload = try JSONDecoder().decode(CodexResetCreditDetailsPayload.self, from: data)
        let availableCount = max(0, payload.availableCount)
        let expiries = payload.credits.compactMap { $0.trustworthyExpiry(observedAt: observedAt) }
        let coverage: ProviderResetCreditCoverage
        if expiries.isEmpty || expiries.count > availableCount {
            coverage = .countOnly
        } else if expiries.count == availableCount {
            coverage = .complete
        } else {
            coverage = .partial
        }
        return ProviderResetCreditSummary(
            availableCount: availableCount,
            observedAt: observedAt,
            coverage: coverage,
            earliestKnownExpiry: coverage == .countOnly ? nil : expiries.min()
        )
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

private struct CodexResetCreditCountEnvelope: Decodable {
    let summary: CodexResetCreditCountDetails?

    enum CodingKeys: String, CodingKey {
        case summary = "rate_limit_reset_credits"
    }
}

private struct CodexResetCreditCountDetails: Decodable {
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

private struct CodexResetCreditDetailsPayload: Decodable {
    let credits: [CodexResetCreditDetail]
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
}

private struct CodexResetCreditDetail: Decodable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        resetType = try container.decode(String.self, forKey: .resetType)
        status = try container.decode(String.self, forKey: .status)
        grantedAt = try container.decode(String.self, forKey: .grantedAt)
        guard ContextPanelDateFormatting.date(from: grantedAt) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .grantedAt,
                in: container,
                debugDescription: "Expected an RFC 3339 reset-credit grant timestamp."
            )
        }
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
    }

    func trustworthyExpiry(observedAt: Date) -> Date? {
        guard resetType == "codex_rate_limits",
              status == "available",
              let expiresAt,
              let expiry = ContextPanelDateFormatting.date(from: expiresAt),
              expiry > observedAt
        else {
            return nil
        }
        return expiry
    }
}

private struct CodexAuthFilePayload: Decodable {
    let tokens: CodexAuthTokenPayload?
}

private struct CodexAuthAccountsFilePayload: Decodable {
    let accounts: [CodexAuthListedAccountPayload]

    private enum CodingKeys: String, CodingKey {
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed or unsupported row must not hide valid sibling accounts.
        accounts = try container.decode([Entry].self, forKey: .accounts).compactMap(\.account)
    }

    private struct Entry: Decodable {
        let account: CodexAuthListedAccountPayload?

        init(from decoder: Decoder) throws {
            account = try? CodexAuthListedAccountPayload(from: decoder)
        }
    }
}

private struct CodexAuthListedAccountPayload: Decodable {
    let id: String
    let mode: String?
    let label: String?
    let tokens: CodexAuthTokenPayload?
}

private struct CodexAuthTokenPayload: Decodable {
    let accessToken: String
    let accountID: String?
    let idToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
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

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            kind = .unknown
            return
        }
        kind = (try? container.decodeIfPresent(CodexRateLimitReachedType.self, forKey: .kind)) ?? .unknown
    }

    var normalizedKind: CodexRateLimitReachedType {
        kind
    }
}

private struct CodexModelsPayload: Decodable {
    let models: [CodexAvailableModelDetails]

    enum CodingKeys: String, CodingKey {
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([CodexAvailableModelDetails].self, forKey: .models) ?? []
    }
}

private struct CodexAvailableModelDetails: Decodable {
    let slug: String?
    let id: String?
    let title: String?
    let name: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case slug
        case id
        case title
        case name
        case displayName = "display_name"
    }

    var identifiers: [String] {
        [slug, id, title, name, displayName].compactMap { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }
}

private func codexUsageLimit(
    snapshot: CodexRateLimitSnapshot,
    window: CodexRateLimitWindow,
    accountID: String,
    configuredAccountID: String?,
    accountName: String,
    observedAt: Date
) -> UsageLimit {
    let windowLabel = window.windowMinutes.map(codexWindowLabel(minutes:)) ?? "Rolling"
    return UsageLimit(
        provider: .openAI,
        accountID: accountID,
        configuredAccountID: configuredAccountID,
        accountName: accountName,
        label: "\(snapshot.displayName) \(windowLabel)",
        windowLabel: windowLabel,
        modelLabel: snapshot.displayName,
        unit: .percent,
        used: Int(window.usedPercent.rounded()),
        limit: 100,
        resetsAt: window.resetsAt,
        lastUpdatedAt: observedAt,
        confidence: .observed,
        note: "plan: \(snapshot.planType)"
    )
}

private func codexWindowLabel(minutes: Int) -> String {
    switch minutes {
    case 0..<60:
        return "\(minutes)m"
    case 60:
        return "Hourly"
    case 300:
        return "5-hour"
    case 1_440:
        return "Daily"
    case 7_200:
        return "5-day"
    case 10_080:
        return "Weekly"
    default:
        if minutes.isMultiple(of: 10_080) {
            return "\(minutes / 10_080)-week"
        }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)-day"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)-hour"
        }
        return "\(minutes)m"
    }
}
