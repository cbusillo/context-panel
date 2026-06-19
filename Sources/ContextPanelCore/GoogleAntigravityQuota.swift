import Foundation
import os

private let googleAntigravityLogger = Logger(subsystem: "com.shinycomputers.contextpanel", category: "google-antigravity")

private let googleAntigravityKeychainApprovalMessage = "Google Antigravity quota needs macOS Keychain approval. Click Refresh for Google in Context Panel, then choose Always Allow when macOS asks to access the \"gemini\" keychain item."

public struct GoogleAntigravityAccountConfiguration: Equatable, Sendable {
    public let accountID: String
    public let accountName: String
    public let credentialAccountID: String
    public let codeAssistBaseURL: URL
    public let userAgent: String

    public init(
        accountID: String,
        accountName: String = "Antigravity",
        credentialAccountID: String = GoogleAntigravityLocalAuthMetadata.credentialAccountID,
        codeAssistBaseURL: URL = GoogleAntigravityLocalAuthMetadata.codeAssistBaseURL,
        userAgent: String = GoogleAntigravityLocalAuthMetadata.userAgent
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.credentialAccountID = credentialAccountID
        self.codeAssistBaseURL = codeAssistBaseURL
        self.userAgent = userAgent
    }
}

public enum GoogleAntigravityLocalAuthMetadata {
    public static let credentialService = "gemini"
    public static let credentialAccountID = "antigravity"
    public static let codeAssistBaseURL = URL(string: "https://daily-cloudcode-pa.googleapis.com")!
    public static let userAgent = "antigravity/macos/context-panel"
}

public struct GoogleAntigravityForegroundRequiredCredentialLoader: ProviderCredentialLoading, Sendable {
    public init() {}

    public func load(accountID _: String) throws -> Data? {
        throw ConnectorError.foregroundRefreshRequired(googleAntigravityKeychainApprovalMessage)
    }
}

public struct GoogleAntigravityLocalCredentials: Equatable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let authMethod: String?

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        authMethod: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.authMethod = authMethod
    }

    public static func decode(from data: Data) throws -> GoogleAntigravityLocalCredentials {
        let payloadData = try decodedPayloadData(from: data)
        do {
            return try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityKeychainPayload.self, from: payloadData).credentials
        } catch {
            throw ConnectorError.invalidAuth("Google Antigravity local login is in an unexpected format. Open Antigravity and sign in again.")
        }
    }

    private static func decodedPayloadData(from data: Data) throws -> Data {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        guard trimmed.hasPrefix(prefix) else { return data }

        let encoded = String(trimmed.dropFirst(prefix.count))
        guard let decoded = Data(base64Encoded: encoded) else {
            throw ConnectorError.invalidAuth("Google Antigravity local login could not be decoded. Open Antigravity and sign in again.")
        }
        return decoded
    }

    public func validAccessToken(now: Date, expirationSkew: TimeInterval) throws -> String {
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorError.missingAuth("Google Antigravity local login is missing an access token. Open Antigravity and sign in again.")
        }
        if let expiresAt, expiresAt.timeIntervalSince(now) <= expirationSkew {
            throw ConnectorError.foregroundRefreshRequired("Google Antigravity local login has expired. Open Antigravity and let it refresh its Google session, then refresh Google in Context Panel.")
        }
        return accessToken
    }
}

private struct GoogleAntigravityKeychainPayload: Decodable {
    let token: Token
    let authMethod: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authMethod = "auth_method"
    }

    var credentials: GoogleAntigravityLocalCredentials {
        GoogleAntigravityLocalCredentials(
            accessToken: token.accessToken,
            tokenType: token.tokenType ?? "Bearer",
            refreshToken: token.refreshToken,
            expiresAt: token.expiry,
            authMethod: authMethod
        )
    }

    struct Token: Decodable {
        let accessToken: String
        let tokenType: String?
        let refreshToken: String?
        let expiry: Date?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiry
        }
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
        let payload = try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityUserQuotaPayload.self, from: data)
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

        static var loadBody: [String: Any] {
            ["metadata": ["ideType": "ANTIGRAVITY"]]
        }

        static func quotaBody(projectID: String) -> [String: Any] {
            ["project": projectID]
        }
    }

    private let accounts: [GoogleAntigravityAccountConfiguration]
    private let httpClient: any ConnectorHTTPClient
    private let credentialLoader: any ProviderCredentialLoading
    private let expirationSkew: TimeInterval

    public init(
        accounts: [GoogleAntigravityAccountConfiguration],
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        credentialLoader: any ProviderCredentialLoading = GenericPasswordCredentialLoader(service: GoogleAntigravityLocalAuthMetadata.credentialService),
        expirationSkew: TimeInterval = 0
    ) {
        self.accounts = accounts
        self.httpClient = httpClient
        self.credentialLoader = credentialLoader
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
            let credentials = try loadCredentials(account: account)
            let accessToken = try credentials.validAccessToken(now: now, expirationSkew: expirationSkew)
            return try await quotaReport(
                accessToken: accessToken,
                account: account,
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

    private func quotaReport(
        accessToken: String,
        account: GoogleAntigravityAccountConfiguration,
        now: Date,
        localAccountID: String
    ) async throws -> ProviderConnectorReport {
        let projectID = try await projectID(accessToken: accessToken, account: account)
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: codeAssistURL(path: "v1internal:retrieveUserQuota", baseURL: account.codeAssistBaseURL),
            method: "POST",
            headers: requestHeaders(accessToken: accessToken, account: account),
            body: try JSONSerialization.data(withJSONObject: RequestMetadata.quotaBody(projectID: projectID), options: [.sortedKeys])
        ))
        googleAntigravityLogger.notice("quota response status=\(response.statusCode, privacy: .public)")
        guard (200..<300).contains(response.statusCode) else {
            logCodeAssistFailure(operation: "quota", statusCode: response.statusCode, data: response.data)
            throw codeAssistAuthorizationError(operation: "Google Antigravity quota", statusCode: response.statusCode)
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
            errorMessage: limits.isEmpty ? "Google Antigravity did not report quota buckets." : nil
        )
    }

    private func projectID(accessToken: String, account: GoogleAntigravityAccountConfiguration) async throws -> String {
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: codeAssistURL(path: "v1internal:loadCodeAssist", baseURL: account.codeAssistBaseURL),
            method: "POST",
            headers: requestHeaders(accessToken: accessToken, account: account),
            body: try JSONSerialization.data(withJSONObject: RequestMetadata.loadBody, options: [.sortedKeys])
        ))
        googleAntigravityLogger.notice("project discovery response status=\(response.statusCode, privacy: .public)")
        guard (200..<300).contains(response.statusCode) else {
            logCodeAssistFailure(operation: "project discovery", statusCode: response.statusCode, data: response.data)
            throw codeAssistAuthorizationError(operation: "Google Antigravity project discovery", statusCode: response.statusCode)
        }
        let payload = try JSONDecoder().decode(GoogleAntigravityLoadCodeAssistPayload.self, from: response.data)
        guard let projectID = payload.projectID else {
            throw ConnectorError.decodingFailure("Google Antigravity did not return an active project for quota lookup.")
        }
        googleAntigravityLogger.notice("project discovery succeeded")
        return projectID
    }

    private func loadCredentials(account: GoogleAntigravityAccountConfiguration) throws -> GoogleAntigravityLocalCredentials {
        guard let data = try loadCredentialData(accountID: account.credentialAccountID) else {
            throw ConnectorError.missingAuth("Google Antigravity local login was not found. Open Antigravity and sign in, then refresh Google in Context Panel. If macOS asks for Keychain access, choose Always Allow.")
        }
        return try GoogleAntigravityLocalCredentials.decode(from: data)
    }

    private func loadCredentialData(accountID: String) throws -> Data? {
        do {
            return try credentialLoader.load(accountID: accountID)
        } catch GenericPasswordCredentialLoader.LoadError.unhandledStatus(let status) where status == -128 {
            throw ConnectorError.foregroundRefreshRequired(googleAntigravityKeychainApprovalMessage)
        }
    }

    private func requestHeaders(
        accessToken: String,
        account: GoogleAntigravityAccountConfiguration
    ) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Goog-Api-Client": RequestMetadata.apiClient,
            "User-Agent": account.userAgent,
        ]
    }

    private func codeAssistURL(path: String, baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/\(path)"
        return components.url!
    }

    private func codeAssistAuthorizationError(operation: String, statusCode: Int) -> ConnectorError {
        if statusCode == 401 {
            return ConnectorError.foregroundRefreshRequired("Google Antigravity local login was rejected. Open Antigravity to refresh it, then refresh Context Panel.")
        }
        if statusCode == 403 {
            return ConnectorError.invalidAuth("Google Antigravity local login is valid, but Code Assist rejected quota access for this account.")
        }
        return ConnectorError.httpFailure(operation: operation, statusCode: statusCode)
    }

    private func logCodeAssistFailure(operation: String, statusCode: Int, data: Data) {
        let payload = try? JSONDecoder().decode(GoogleAPIErrorPayload.self, from: data)
        let message = ConnectorRedactor.redact(payload?.error.message ?? "")
        let status = ConnectorRedactor.redact(payload?.error.status ?? "")
        let code = payload?.error.code.map(String.init) ?? ""
        googleAntigravityLogger.error(
            "Code Assist failure operation=\(operation, privacy: .public) status=\(statusCode, privacy: .public) errorCode=\(code, privacy: .public) errorStatus=\(status, privacy: .public) errorMessage=\(message, privacy: .public)"
        )
    }
}

private struct GoogleAPIErrorPayload: Decodable {
    let error: ErrorPayload

    struct ErrorPayload: Decodable {
        let code: Int?
        let message: String?
        let status: String?
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

private struct GoogleAntigravityUserQuotaPayload: Decodable {
    let buckets: [GoogleAntigravityQuotaBucket]

    enum CodingKeys: String, CodingKey {
        case buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try container.decodeIfPresent([GoogleAntigravityQuotaBucket].self, forKey: .buckets) ?? []
    }

    func limits(
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) -> [UsageLimit] {
        buckets.compactMap { bucket in
            bucket.usageLimit(
                accountID: accountID,
                configuredAccountID: configuredAccountID,
                accountName: accountName,
                observedAt: observedAt
            )
        }
    }
}

private struct GoogleAntigravityQuotaBucket: Decodable {
    let bucketID: String?
    let displayName: String?
    let description: String?
    let window: String?
    let model: String?
    let modelName: String?
    let modelID: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remainingAmount: Int?
    let limit: Int?
    let used: Int?
    let disabled: Bool?
    let resetTime: Date?

    enum CodingKeys: String, CodingKey {
        case bucketID = "bucketId"
        case bucketIDSnake = "bucket_id"
        case displayName
        case displayNameSnake = "display_name"
        case description
        case window
        case model
        case modelName
        case modelNameSnake = "model_name"
        case modelID = "modelId"
        case modelIDSnake = "model_id"
        case tokenType
        case tokenTypeSnake = "token_type"
        case remainingFraction
        case remainingFractionSnake = "remaining_fraction"
        case remainingAmount
        case remainingAmountSnake = "remaining_amount"
        case limit
        case used
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
        model = try container.decodeIfPresent(String.self, forKey: .model)
        modelName = try container.decodeFirstPresent(String.self, forKeys: [.modelName, .modelNameSnake])
        modelID = try container.decodeFirstPresent(String.self, forKeys: [.modelID, .modelIDSnake])
        tokenType = try container.decodeFirstPresent(String.self, forKeys: [.tokenType, .tokenTypeSnake])
        remainingFraction = try Self.decodeFlexibleDouble(container: container, keys: [.remainingFraction, .remainingFractionSnake])
        remainingAmount = try Self.decodeFlexibleInt(container: container, keys: [.remainingAmount, .remainingAmountSnake])
        limit = try Self.decodeFlexibleInt(container: container, keys: [.limit])
        used = try Self.decodeFlexibleInt(container: container, keys: [.used])
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        resetTime = try container.decodeFirstPresent(Date.self, forKeys: [.resetTime, .resetTimeSnake])
    }

    func usageLimit(
        accountID: String,
        configuredAccountID: String?,
        accountName: String,
        observedAt: Date
    ) -> UsageLimit? {
        guard disabled != true else { return nil }

        let normalizedLimit: (used: Int?, limit: Int, unit: UsageUnit)?
        if let remainingFraction {
            let clamped = max(0, min(remainingFraction, 1))
            normalizedLimit = (Int(((1 - clamped) * 100).rounded()), 100, .percent)
        } else if let used, let limit, limit > 0 {
            normalizedLimit = (max(0, used), limit, .requests)
        } else if let remainingAmount {
            if remainingAmount <= 0 {
                normalizedLimit = (1, 1, .requests)
            } else {
                normalizedLimit = (nil, remainingAmount, .requests)
            }
        } else {
            return nil
        }
        guard let normalizedLimit else { return nil }

        let inferredWindow = inferredWindow(observedAt: observedAt)
        let bucketName = normalized(displayName)
            ?? normalized(window)
            ?? inferredWindow?.displayName
            ?? normalized(tokenType).map { "\($0) quota" }
            ?? "Quota"
        let modelLabel = normalized(modelName) ?? normalized(model) ?? normalized(modelID).map(Self.displayModelName(from:))
        let noteParts = [
            "source: Google Antigravity local auth quota",
            normalized(description),
        ]
        return UsageLimit(
            provider: .google,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: accountName,
            label: modelLabel.map { "\($0) \(bucketName)" } ?? bucketName,
            windowLabel: normalized(window) ?? inferredWindow?.displayName ?? bucketName,
            modelLabel: modelLabel,
            unit: normalizedLimit.unit,
            used: normalizedLimit.used,
            limit: normalizedLimit.limit,
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

    private func inferredWindow(observedAt: Date) -> MainLimitWindow? {
        guard let resetTime else { return nil }
        let interval = resetTime.timeIntervalSince(observedAt)
        guard interval > -60 else { return nil }
        if interval <= 6 * 60 * 60 { return .fiveHour }
        if interval <= 36 * 60 * 60 { return .daily }
        if interval <= 9 * 24 * 60 * 60 { return .weekly }
        return nil
    }

    private static func displayModelName(from rawValue: String) -> String {
        let normalized = rawValue
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        guard !normalized.isEmpty else { return rawValue }
        return normalized.map { part in
            let lower = part.lowercased()
            switch lower {
            case "gpt":
                return "GPT"
            case "oss":
                return "OSS"
            case "ai":
                return "AI"
            case "claude":
                return "Claude"
            case "gemini":
                return "Gemini"
            case "flash":
                return "Flash"
            case "lite":
                return "Lite"
            case "pro":
                return "Pro"
            case "opus":
                return "Opus"
            case "sonnet":
                return "Sonnet"
            case "thinking":
                return "Thinking"
            case "agent":
                return "Agent"
            case "high":
                return "High"
            case "medium":
                return "Medium"
            case "low":
                return "Low"
            case "extra":
                return "Extra"
            case "preview":
                return "Preview"
            case "tab":
                return "Tab"
            case "jump":
                return "Jump"
            case "chat":
                return "Chat"
            default:
                return part
            }
        }.joined(separator: " ")
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
