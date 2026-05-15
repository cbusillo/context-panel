import Foundation

public struct GeminiQuotaBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let modelID: String
    public let remainingFraction: Double?
    public let remainingAmount: Int?
    public let resetsAt: Date?

    public init(modelID: String, remainingFraction: Double?, remainingAmount: Int?, resetsAt: Date?) {
        self.id = modelID
        self.modelID = modelID
        self.remainingFraction = remainingFraction.map { max(0, min($0, 1)) }
        self.remainingAmount = remainingAmount
        self.resetsAt = resetsAt
    }

    public var usedPercent: Double? {
        remainingFraction.map { max(0, min((1 - $0) * 100, 100)) }
    }

    public func usageLimit(accountID: String, accountName: String, observedAt: Date) -> UsageLimit {
        UsageLimit(
            provider: .google,
            accountID: accountID,
            accountName: accountName,
            label: modelID,
            windowLabel: resetWindowLabel,
            modelLabel: modelID,
            unit: .percent,
            used: usedPercent.map { Int($0.rounded()) },
            limit: usedPercent == nil ? nil : 100,
            resetsAt: resetsAt,
            lastUpdatedAt: observedAt,
            confidence: .observed,
            note: remainingAmount.map { "remaining amount: \($0)" }
        )
    }

    private var resetWindowLabel: String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(Date()))
        if seconds <= 0 { return nil }
        let hours = max(Int((Double(seconds) / 3_600).rounded()), 1)
        if hours <= 2 { return "Hourly" }
        if hours <= 7 { return "5-hour" }
        if hours <= 30 { return "Daily" }
        if hours <= 132 { return "5-day" }
        if hours <= 180 { return "Weekly" }
        return nil
    }
}

public enum GeminiQuotaPayloadParser {
    public static func buckets(from data: Data) throws -> [GeminiQuotaBucket] {
        let payload = try JSONDecoder.contextPanelISO8601.decode(GeminiQuotaPayload.self, from: data)
        return payload.buckets.map(\.normalizedBucket)
    }
}

public struct GeminiOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?

    public init(accessToken: String?, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

public struct GeminiRefreshResponse: Decodable, Equatable, Sendable {
    public let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

public struct GeminiCodeAssistTier: Decodable, Equatable, Sendable {
    public let name: String?
}

public struct GeminiLoadCodeAssistResponse: Decodable, Equatable, Sendable {
    public let cloudaicompanionProject: String?
    public let currentTier: GeminiCodeAssistTier?
    public let paidTier: GeminiCodeAssistTier?
}

public struct GeminiAccountConfiguration: Equatable, Sendable {
    public let authPath: String
    public let accountName: String
    public let tokenEndpoint: URL
    public let codeAssistEndpoint: URL
    public let clientID: String
    public let clientSecret: String

    public init(
        authPath: String,
        accountName: String? = nil,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        codeAssistEndpoint: URL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal")!,
        clientID: String,
        clientSecret: String
    ) {
        self.authPath = authPath
        self.accountName = accountName ?? ConnectorRedactor.redactedPath(authPath)
        self.tokenEndpoint = tokenEndpoint
        self.codeAssistEndpoint = codeAssistEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct GeminiOAuthClientMetadata: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public enum GeminiOAuthClientMetadataDiscovery {
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        useBundledFallback: Bool = true,
        fileLoader: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
        },
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
        },
        directoryLister: @escaping @Sendable (String) -> [String] = { path in
            let expanded = NSString(string: path).expandingTildeInPath
            return (try? FileManager.default.contentsOfDirectory(atPath: expanded).map { "\(expanded)/\($0)" }) ?? []
        }
    ) -> GeminiOAuthClientMetadata? {
        if
            let clientID = environment["GEMINI_OAUTH_CLIENT_ID"], !clientID.isEmpty,
            let clientSecret = environment["GEMINI_OAUTH_CLIENT_SECRET"], !clientSecret.isEmpty
        {
            return GeminiOAuthClientMetadata(clientID: clientID, clientSecret: clientSecret)
        }

        for path in candidateBundlePaths(
            environment: environment,
            directoryLister: directoryLister
        ) where fileExists(path) {
            guard
                let source = try? fileLoader(path),
                let metadata = parseClientMetadata(from: source)
            else { continue }
            return metadata
        }
        return nil
    }

    static func parseClientMetadata(from source: String) -> GeminiOAuthClientMetadata? {
        guard
            let clientID = stringLiteral(named: "OAUTH_CLIENT_ID", in: source),
            let clientSecret = stringLiteral(named: "OAUTH_CLIENT_SECRET", in: source)
        else { return nil }
        return GeminiOAuthClientMetadata(clientID: clientID, clientSecret: clientSecret)
    }

    private static func stringLiteral(named variableName: String, in source: String) -> String? {
        let pattern = #"var\s+\#(variableName)\s*=\s*\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard
            let match = regex.firstMatch(in: source, range: range),
            match.numberOfRanges >= 2,
            let valueRange = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[valueRange])
    }

    private static func candidateBundlePaths(
        environment: [String: String],
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        var paths: [String] = []
        if let path = environment["GEMINI_CLI_BUNDLE_PATH"], !path.isEmpty {
            paths.append(path)
        }
        paths.append(contentsOf: bundleChunkPaths(
            root: "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            directoryLister: directoryLister
        ))
        paths.append(contentsOf: bundleChunkPaths(
            root: "/usr/local/lib/node_modules/@google/gemini-cli/bundle",
            directoryLister: directoryLister
        ))
        return paths
    }

    private static func bundleChunkPaths(
        root: String,
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        directoryLister(root)
            .filter { $0.hasSuffix(".js") }
            .sorted()
    }
}

public struct GeminiCodeAssistConnector: ProviderConnector {
    public let provider: Provider = .google

    private let accounts: [GeminiAccountConfiguration]
    private let httpClient: any ConnectorHTTPClient
    private let fileLoader: @Sendable (String) throws -> Data
    private let credentialStore: (any ProviderCredentialLoading)?
    private let credentialAccountID: String?

    public init(
        accounts: [GeminiAccountConfiguration],
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        fileLoader: @escaping @Sendable (String) throws -> Data = { path in
            try Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        },
        credentialStore: (any ProviderCredentialLoading)? = nil,
        credentialAccountID: String? = nil
    ) {
        self.accounts = accounts
        self.httpClient = httpClient
        self.fileLoader = fileLoader
        self.credentialStore = credentialStore
        self.credentialAccountID = credentialAccountID
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        var reports: [ProviderConnectorReport] = []
        reports.reserveCapacity(accounts.count)
        for account in accounts {
            reports.append(await refresh(account: account, now: now))
        }
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }

    private func refresh(account: GeminiAccountConfiguration, now: Date) async -> ProviderConnectorReport {
        let localAccountID = ConnectorRedactor.localAccountID(provider: provider, path: account.authPath)

        do {
            let credentials = try JSONDecoder().decode(GeminiOAuthCredentials.self, from: try credentialData(for: account))
            let accessToken = try await refreshedAccessToken(credentials: credentials, account: account)
            let loadResponse = try await loadCodeAssist(accessToken: accessToken, endpoint: account.codeAssistEndpoint)
            guard let project = loadResponse.cloudaicompanionProject, !project.isEmpty else {
                throw ConnectorError.decodingFailure("Code Assist did not return an active project; raw body redacted")
            }
            let quotaData = try await retrieveUserQuota(
                accessToken: accessToken,
                project: project,
                endpoint: account.codeAssistEndpoint
            )
            let buckets = try GeminiQuotaPayloadParser.buckets(from: quotaData)
            let limits = buckets.map {
                $0.usageLimit(accountID: localAccountID, accountName: account.accountName, observedAt: now)
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

    private func credentialData(for account: GeminiAccountConfiguration) throws -> Data {
        if let credentialStore, let credentialAccountID {
            do {
                if let data = try credentialStore.load(accountID: credentialAccountID) {
                    return data
                }
            } catch {
                // Keychain cache failures should not block the original user-authorized file path.
            }
        }
        return try fileLoader(account.authPath)
    }

    private func refreshedAccessToken(credentials: GeminiOAuthCredentials, account: GeminiAccountConfiguration) async throws -> String {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw ConnectorError.invalidAuth("Gemini OAuth file does not contain a refresh token")
        }
        let body = formEncoded([
            "client_id": account.clientID,
            "client_secret": account.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: account.tokenEndpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: body
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Gemini OAuth refresh", statusCode: response.statusCode)
        }
        return try JSONDecoder().decode(GeminiRefreshResponse.self, from: response.data).accessToken
    }

    private func loadCodeAssist(accessToken: String, endpoint: URL) async throws -> GeminiLoadCodeAssistResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "cloudaicompanionProject": NSNull(),
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
                "duetProject": NSNull(),
            ],
        ])
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: endpoint.appending(path: ":loadCodeAssist"),
            method: "POST",
            headers: jsonHeaders(accessToken: accessToken),
            body: body
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Gemini Code Assist load", statusCode: response.statusCode)
        }
        return try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: response.data)
    }

    private func retrieveUserQuota(accessToken: String, project: String, endpoint: URL) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["project": project])
        let response = try await httpClient.data(for: ConnectorHTTPRequest(
            url: endpoint.appending(path: ":retrieveUserQuota"),
            method: "POST",
            headers: jsonHeaders(accessToken: accessToken),
            body: body
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.httpFailure(operation: "Gemini Code Assist quota", statusCode: response.statusCode)
        }
        return response.data
    }
}

private struct GeminiQuotaPayload: Decodable {
    let buckets: [GeminiQuotaBucketPayload]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try container.decodeIfPresent([GeminiQuotaBucketPayload].self, forKey: .buckets) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case buckets
    }
}

private struct GeminiQuotaBucketPayload: Decodable {
    let modelID: String
    let remainingFraction: Double?
    let remainingAmount: Int?
    let resetTime: Date?

    enum CodingKeys: String, CodingKey {
        case modelID = "modelId"
        case remainingFraction
        case remainingAmount
        case resetTime
    }

    var normalizedBucket: GeminiQuotaBucket {
        GeminiQuotaBucket(
            modelID: modelID,
            remainingFraction: remainingFraction,
            remainingAmount: remainingAmount,
            resetsAt: resetTime
        )
    }
}

extension JSONDecoder {
    static var contextPanelISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ContextPanelDateFormatting.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date string"
            )
        }
        return decoder
    }
}

public enum ContextPanelDateFormatting {
    public static func string(from date: Date) -> String {
        internetDateFormatter().string(from: date)
    }

    public static func date(from value: String) -> Date? {
        internetDateFormatterWithFractionalSeconds().date(from: value)
            ?? internetDateFormatter().date(from: value)
            ?? dateOnlyFormatter().date(from: value)
    }

    private static func internetDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func internetDateFormatterWithFractionalSeconds() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func dateOnlyFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }
}

public func formEncoded(_ values: [String: String]) -> Data {
    values
        .map { key, value in
            "\(urlFormEscape(key))=\(urlFormEscape(value))"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
}

public func urlFormEscape(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func jsonHeaders(accessToken: String) -> [String: String] {
    [
        "Authorization": "Bearer \(accessToken)",
        "Content-Type": "application/json",
        "Accept": "application/json",
    ]
}
