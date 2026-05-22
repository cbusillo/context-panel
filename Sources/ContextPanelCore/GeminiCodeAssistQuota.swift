import Foundation

public struct GeminiQuotaBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let modelID: String
    public let bucketLabel: String?
    public let windowLabel: String?
    public let remainingFraction: Double?
    public let remainingAmount: Int?
    public let resetsAt: Date?

    public init(
        id: String? = nil,
        modelID: String,
        bucketLabel: String? = nil,
        windowLabel: String? = nil,
        remainingFraction: Double?,
        remainingAmount: Int?,
        resetsAt: Date?
    ) {
        self.id = id ?? Self.identity(
            modelID: modelID,
            bucketLabel: bucketLabel,
            windowLabel: windowLabel
        )
        self.modelID = modelID
        self.bucketLabel = bucketLabel?.nilIfBlank
        self.windowLabel = windowLabel?.nilIfBlank
        self.remainingFraction = remainingFraction.map { max(0, min($0, 1)) }
        self.remainingAmount = remainingAmount
        self.resetsAt = resetsAt
    }

    public var usedPercent: Double? {
        remainingFraction.map { max(0, min((1 - $0) * 100, 100)) }
    }

    public func usageLimit(accountID: String, accountName: String, observedAt: Date) -> UsageLimit {
        let inferredWindowLabel = resetWindowLabel(observedAt: observedAt)
        let label = bucketLabel?.nilIfBlank ?? modelID
        var notes: [String] = []
        if let bucketLabel, bucketLabel != label, bucketLabel != modelID {
            notes.append("quota bucket: \(bucketLabel)")
        }
        if let remainingAmount {
            notes.append("remaining amount: \(remainingAmount)")
        }

        return UsageLimit(
            id: "google:\(accountID):\(limitIdentity(label: label, inferredWindowLabel: inferredWindowLabel))",
            provider: .google,
            accountID: accountID,
            accountName: accountName,
            label: label,
            windowLabel: inferredWindowLabel,
            modelLabel: modelID,
            unit: .percent,
            used: usedPercent.map { Int($0.rounded()) },
            limit: usedPercent == nil ? nil : 100,
            resetsAt: resetsAt,
            lastUpdatedAt: observedAt,
            confidence: .observed,
            statusOverride: usedPercent == nil ? .unknown : nil,
            note: notes.isEmpty ? nil : notes.joined(separator: "; ")
        )
    }

    private func resetWindowLabel(observedAt: Date) -> String? {
        if let normalized = Self.normalizedWindowLabel(from: windowLabel) {
            return normalized
        }
        if let normalized = Self.normalizedWindowLabel(from: bucketLabel) {
            return normalized
        }
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(observedAt))
        if seconds <= 0 { return nil }
        let hours = max(Int((Double(seconds) / 3_600).rounded()), 1)
        if hours <= 2 { return "Hourly" }
        if hours <= 7 { return "5-hour" }
        if hours <= 30 { return "Daily" }
        if hours <= 132 { return "5-day" }
        if hours <= 180 { return "Weekly" }
        return nil
    }

    private static func identity(
        modelID: String,
        bucketLabel: String?,
        windowLabel: String?
    ) -> String {
        let parts = [
            modelID,
            bucketLabel?.nilIfBlank,
            normalizedWindowLabel(from: windowLabel),
        ].compactMap { $0?.nilIfBlank }
        return parts.joined(separator: ":")
    }

    private func limitIdentity(label: String, inferredWindowLabel: String?) -> String {
        [id.nilIfBlank, label.nilIfBlank, inferredWindowLabel?.nilIfBlank]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    private static func normalizedWindowLabel(from value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        let searchable = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if searchable.contains("5-hour")
            || searchable.contains("5 hour")
            || searchable.contains("five-hour")
            || searchable.contains("five hour")
        {
            return "5-hour"
        }
        if searchable.contains("weekly")
            || searchable.contains("week")
            || searchable.contains("7-day")
            || searchable.contains("7 day")
            || searchable.contains("seven-day")
            || searchable.contains("seven day")
        {
            return "Weekly"
        }
        if searchable.contains("daily")
            || searchable.contains("per-day")
            || searchable.contains("per day")
            || searchable.contains("1-day")
            || searchable.contains("1 day")
        {
            return "Daily"
        }
        return nil
    }
}

public enum GeminiQuotaPayloadParser {
    public static func buckets(from data: Data) throws -> [GeminiQuotaBucket] {
        do {
            let payload = try JSONDecoder.contextPanelISO8601.decode(GeminiQuotaPayload.self, from: data)
            guard !payload.buckets.isEmpty else {
                throw ConnectorError.decodingFailure("Gemini Code Assist quota payload did not include quota buckets; raw body redacted")
            }
            return payload.buckets.map(\.normalizedBucket)
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.decodingFailure(
                "Gemini Code Assist quota payload shape changed (\(Self.diagnosticDescription(for: error))); raw body redacted"
            )
        }
    }

    private static func diagnosticDescription(for error: Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context):
            context.debugDescription
        case let DecodingError.keyNotFound(key, _):
            "missing key \(key.stringValue)"
        case let DecodingError.typeMismatch(type, context):
            "expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.valueNotFound(type, context):
            "missing \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            "unrecognized JSON"
        }
    }
}

public struct GeminiOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String?, refreshToken: String?, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expiry"
    }
}

public struct AntigravityCredentialDecoder: Sendable {
    private struct StoredCredential: Decodable {
        let token: StoredToken
    }

    private struct StoredToken: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expiry"
        }
    }

    public init() {}

    public func geminiOAuthCredentials(from data: Data) throws -> GeminiOAuthCredentials {
        let payload = try decodedPayload(from: data)
        let stored = try JSONDecoder.contextPanelISO8601.decode(StoredCredential.self, from: payload)
        return GeminiOAuthCredentials(
            accessToken: stored.token.accessToken,
            refreshToken: stored.token.refreshToken,
            expiresAt: stored.token.expiresAt
        )
    }

    private func decodedPayload(from data: Data) throws -> Data {
        let marker = Data("go-keyring-base64:".utf8)
        if data.starts(with: marker) {
            let encoded = data.dropFirst(marker.count)
            guard let decoded = Data(base64Encoded: encoded) else {
                throw ConnectorError.decodingFailure("Antigravity credential payload was not valid base64")
            }
            return decoded
        }
        return data
    }
}

public enum GeminiOAuthCredentialDecoder {
    public static func credentials(from data: Data) throws -> GeminiOAuthCredentials {
        try JSONDecoder.contextPanelISO8601.decode(GeminiOAuthCredentials.self, from: data)
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

private extension GeminiAccountConfiguration {
    var hasOAuthClientMetadata: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }
}

public struct AntigravityKeychainCredentialSource: Sendable {
    public static let service = "gemini"
    public static let accountID = "antigravity"

    private let credentialLoader: any ProviderCredentialLoading
    private let decoder: AntigravityCredentialDecoder

    public init(
        credentialLoader: any ProviderCredentialLoading = GenericPasswordCredentialLoader(service: Self.service),
        decoder: AntigravityCredentialDecoder = AntigravityCredentialDecoder()
    ) {
        self.credentialLoader = credentialLoader
        self.decoder = decoder
    }

    public func loadCredentials() throws -> GeminiOAuthCredentials? {
        guard let data = try credentialLoader.load(accountID: Self.accountID) else { return nil }
        return try decoder.geminiOAuthCredentials(from: data)
    }

    public func hasCredentials() -> Bool {
        (try? loadCredentials()) != nil
    }
}

public struct GeminiOAuthClientMetadata: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static func credentialAccountID(for accountID: String) -> String {
        "\(accountID).gemini-oauth-client-metadata"
    }
}

public enum GeminiOAuthClientMetadataDiscoveryError: LocalizedError, Equatable {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Gemini OAuth client metadata was not found in the selected CLI bundle."
        }
    }
}

public enum GeminiOAuthClientMetadataDiscovery {
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandPath: String? = nil,
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
            commandPath: commandPath,
            useBundledFallback: useBundledFallback,
            fileExists: fileExists,
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

    public static func discover(
        fromUserSelectedURL url: URL,
        fileLoader: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
        },
        directoryLister: @escaping @Sendable (String) -> [String] = { path in
            let expanded = NSString(string: path).expandingTildeInPath
            return (try? FileManager.default.contentsOfDirectory(atPath: expanded).map { "\(expanded)/\($0)" }) ?? []
        }
    ) throws -> GeminiOAuthClientMetadata {
        for path in userSelectedBundlePaths(url: url, directoryLister: directoryLister) {
            guard
                let source = try? fileLoader(path),
                let metadata = parseClientMetadata(from: source)
            else { continue }
            return metadata
        }
        throw GeminiOAuthClientMetadataDiscoveryError.notFound
    }

    static func parseClientMetadata(from source: String) -> GeminiOAuthClientMetadata? {
        guard
            let clientID = stringLiteral(named: "OAUTH_CLIENT_ID", in: source),
            let clientSecret = stringLiteral(named: "OAUTH_CLIENT_SECRET", in: source)
        else { return nil }
        return GeminiOAuthClientMetadata(clientID: clientID, clientSecret: clientSecret)
    }

    private static func stringLiteral(named variableName: String, in source: String) -> String? {
        let pattern = #"(?:var|let|const)\s+\#(variableName)\s*=\s*['\"]([^'\"]+)['\"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard
            let match = regex.firstMatch(in: source, range: range),
            match.numberOfRanges >= 2,
            let valueRange = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[valueRange])
    }

    private static func userSelectedBundlePaths(
        url: URL,
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        let path = url.path
        if url.hasDirectoryPath {
            return bundleChunkPaths(root: path, directoryLister: directoryLister)
        }
        let directory = url.deletingLastPathComponent().path
        return orderedUnique([path] + bundleChunkPaths(root: directory, directoryLister: directoryLister))
    }

    private static func candidateBundlePaths(
        environment: [String: String],
        commandPath: String?,
        useBundledFallback: Bool,
        fileExists: @Sendable (String) -> Bool,
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        var paths: [String] = []
        if let path = environment["GEMINI_CLI_BUNDLE_PATH"], !path.isEmpty {
            paths.append(contentsOf: bundleCandidates(
                near: path,
                fileExists: fileExists,
                directoryLister: directoryLister
            ))
        }
        if let commandPath, !commandPath.isEmpty {
            paths.append(contentsOf: bundleCandidates(
                near: commandPath,
                fileExists: fileExists,
                directoryLister: directoryLister
            ))
        }
        paths.append(contentsOf: executableBundleCandidates(
            executableName: "gemini",
            environment: environment,
            fileExists: fileExists,
            directoryLister: directoryLister
        ))
        if useBundledFallback {
            for root in commonGeminiBundleRoots() {
                paths.append(contentsOf: bundleChunkPaths(root: root, directoryLister: directoryLister))
            }
        }
        return orderedUnique(paths)
    }

    private static func bundleCandidates(
        near path: String,
        fileExists: @Sendable (String) -> Bool,
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved = resolvingSymbolicLinks(expanded)
        if resolved != expanded {
            return orderedUnique(
                bundleCandidates(nearResolvedPath: expanded, fileExists: fileExists, directoryLister: directoryLister)
                    + bundleCandidates(nearResolvedPath: resolved, fileExists: fileExists, directoryLister: directoryLister)
            )
        }
        return bundleCandidates(nearResolvedPath: expanded, fileExists: fileExists, directoryLister: directoryLister)
    }

    private static func bundleCandidates(
        nearResolvedPath expanded: String,
        fileExists: @Sendable (String) -> Bool,
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        if !expanded.hasSuffix(".js"), fileExists("\(expanded)/gemini.js") || !bundleChunkPaths(root: expanded, directoryLister: directoryLister).isEmpty {
            return bundleChunkPaths(root: expanded, directoryLister: directoryLister)
        }
        let url = URL(fileURLWithPath: expanded)
        var paths = [expanded]
        paths.append(contentsOf: bundleChunkPaths(
            root: url.deletingLastPathComponent().path,
            directoryLister: directoryLister
        ))
        if url.lastPathComponent == "gemini" || url.lastPathComponent == "gemini.js" {
            let packageBundle = url
                .deletingLastPathComponent()
                .appendingPathComponent("../lib/node_modules/@google/gemini-cli/bundle")
                .standardizedFileURL
                .path
            paths.append(contentsOf: bundleChunkPaths(root: packageBundle, directoryLister: directoryLister))
        }
        return paths
    }

    private static func resolvingSymbolicLinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func executableBundleCandidates(
        executableName: String,
        environment: [String: String],
        fileExists: @Sendable (String) -> Bool,
        directoryLister: @Sendable (String) -> [String]
    ) -> [String] {
        let pathValue = environment["PATH"] ?? ""
        let pathDirectories = pathValue.split(separator: ":").map(String.init)
        return orderedUnique(pathDirectories + commonExecutableDirectories()).flatMap { directory -> [String] in
            let executablePath = "\(directory)/\(executableName)"
            guard fileExists(executablePath) else { return [] }
            return bundleCandidates(
                near: executablePath,
                fileExists: fileExists,
                directoryLister: directoryLister
            )
        }
    }

    private static func commonExecutableDirectories() -> [String] {
        let home = ContextPanelLocations.realUserHomeDirectory().path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "\(home)/.pnpm-global/bin",
            "\(home)/.yarn/bin",
            "\(home)/.config/yarn/global/node_modules/.bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    private static func commonGeminiBundleRoots() -> [String] {
        let home = ContextPanelLocations.realUserHomeDirectory().path
        return [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            "/usr/local/lib/node_modules/@google/gemini-cli/bundle",
            "\(home)/.npm-global/lib/node_modules/@google/gemini-cli/bundle",
            "\(home)/.local/lib/node_modules/@google/gemini-cli/bundle",
            "\(home)/.config/yarn/global/node_modules/@google/gemini-cli/bundle",
        ]
    }

    private static func orderedUnique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(paths.count)
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        return unique
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
    private let antigravityCredentialSource: AntigravityKeychainCredentialSource?

    public init(
        accounts: [GeminiAccountConfiguration],
        httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        fileLoader: @escaping @Sendable (String) throws -> Data = { path in
            try Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        },
        credentialStore: (any ProviderCredentialLoading)? = nil,
        credentialAccountID: String? = nil,
        antigravityCredentialSource: AntigravityKeychainCredentialSource? = AntigravityKeychainCredentialSource()
    ) {
        self.accounts = accounts
        self.httpClient = httpClient
        self.fileLoader = fileLoader
        self.credentialStore = credentialStore
        self.credentialAccountID = credentialAccountID
        self.antigravityCredentialSource = antigravityCredentialSource
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
            let credentials = try credentials(for: account)
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

    private func credentials(for account: GeminiAccountConfiguration) throws -> GeminiOAuthCredentials {
        let localCredentialResult = Result { try credentialData(for: account) }
        let localCredentials = localCredentialResult.successValue
            .flatMap { try? GeminiOAuthCredentialDecoder.credentials(from: $0) }

        if account.hasOAuthClientMetadata,
           let localCredentials,
           localCredentials.refreshToken?.isEmpty == false
        {
            return localCredentials
        }
        if let antigravityCredentialSource {
            do {
                if let credentials = try antigravityCredentialSource.loadCredentials(), credentials.hasUsableToken {
                    return credentials
                }
            } catch {
                throw ConnectorError.invalidAuth("Antigravity credential could not be read. Open Antigravity to refresh Google authentication, then refresh Context Panel again.")
            }
        }
        if let localCredentials, localCredentials.refreshToken?.isEmpty == false {
            return localCredentials
        }
        switch localCredentialResult {
        case .success(let data):
            return try GeminiOAuthCredentialDecoder.credentials(from: data)
        case .failure(let error):
            throw error
        }
    }

    private func refreshedAccessToken(credentials: GeminiOAuthCredentials, account: GeminiAccountConfiguration) async throws -> String {
        if let accessToken = credentials.validAccessToken() {
            return accessToken
        }
        guard !account.clientID.isEmpty, !account.clientSecret.isEmpty else {
            throw ConnectorError.invalidAuth("Antigravity access token is expired. Open Antigravity to refresh Google authentication, then refresh Context Panel again.")
        }
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
        let container = try decoder.container(keyedBy: GeminiDynamicCodingKey.self)
        for keyName in ["buckets", "quotaBuckets", "quota_buckets", "limits", "quotas"] {
            let key = GeminiDynamicCodingKey(keyName)
            if let decoded = try container.decodeIfPresent([GeminiQuotaBucketPayload].self, forKey: key) {
                buckets = decoded
                return
            }
        }
        buckets = []
    }
}

private struct GeminiQuotaBucketPayload: Decodable {
    let id: String?
    let modelID: String
    let bucketLabel: String?
    let windowLabel: String?
    let remainingFraction: Double?
    let remainingAmount: Int?
    let resetTime: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GeminiDynamicCodingKey.self)
        id = container.firstString(for: ["id", "bucketId", "bucketID", "limitId", "quotaId"])
        bucketLabel = container.firstString(for: [
            "bucketLabel",
            "quotaLabel",
            "limitLabel",
            "label",
            "displayName",
            "name",
            "bucket",
            "limitType",
        ])
        modelID = container.firstString(for: [
            "modelId",
            "modelID",
            "model",
            "modelName",
            "modelLabel",
        ]) ?? bucketLabel ?? "Gemini quota"
        windowLabel = container.firstString(for: [
            "windowLabel",
            "resetWindow",
            "resetWindowLabel",
            "timeWindow",
            "period",
            "duration",
        ])
        remainingFraction = container.firstDouble(for: [
            "remainingFraction",
            "remaining_fraction",
            "remainingRatio",
            "remaining_ratio",
        ]) ?? Self.remainingFraction(fromUsedValue: container.firstDouble(for: [
            "usedFraction",
            "used_fraction",
            "usageFraction",
            "usage_fraction",
            "utilizationFraction",
            "utilization_fraction",
            "usedPercent",
            "used_percent",
            "usagePercent",
            "usage_percent",
            "utilization",
        ]))
        remainingAmount = container.firstInt(for: [
            "remainingAmount",
            "remaining_amount",
            "remainingRequests",
            "remaining_requests",
            "remaining",
        ])
        resetTime = container.firstDate(for: [
            "resetTime",
            "reset_time",
            "resetAt",
            "reset_at",
            "resetsAt",
            "resets_at",
        ])

        if remainingFraction == nil, remainingAmount == nil, resetTime == nil, windowLabel == nil {
            throw DecodingError.dataCorruptedError(
                forKey: GeminiDynamicCodingKey("remainingFraction"),
                in: container,
                debugDescription: "bucket did not contain remaining, reset, or window fields"
            )
        }
    }

    private static func remainingFraction(fromUsedValue value: Double?) -> Double? {
        guard var value else { return nil }
        if value > 1 {
            value /= 100
        }
        return 1 - value
    }

    var normalizedBucket: GeminiQuotaBucket {
        GeminiQuotaBucket(
            id: id,
            modelID: modelID,
            bucketLabel: bucketLabel,
            windowLabel: windowLabel,
            remainingFraction: remainingFraction,
            remainingAmount: remainingAmount,
            resetsAt: resetTime
        )
    }
}

private struct GeminiDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == GeminiDynamicCodingKey {
    func firstString(for names: [String]) -> String? {
        for name in names {
            let key = GeminiDynamicCodingKey(name)
            if let value = try? decodeIfPresent(String.self, forKey: key), let value = value.nilIfBlank {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func firstDouble(for names: [String]) -> Double? {
        for name in names {
            let key = GeminiDynamicCodingKey(name)
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key), let double = Double(value) {
                return double
            }
        }
        return nil
    }

    func firstInt(for names: [String]) -> Int? {
        for name in names {
            let key = GeminiDynamicCodingKey(name)
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let value = try? decodeIfPresent(String.self, forKey: key), let int = Int(value) {
                return int
            }
        }
        return nil
    }

    func firstDate(for names: [String]) -> Date? {
        for name in names {
            let key = GeminiDynamicCodingKey(name)
            if let value = try? decodeIfPresent(String.self, forKey: key), let date = ContextPanelDateFormatting.date(from: value) {
                return date
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: value)
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Date(timeIntervalSince1970: TimeInterval(value))
            }
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension GeminiOAuthCredentials {
    var hasUsableToken: Bool {
        validAccessToken() != nil || refreshToken?.isEmpty == false
    }

    func validAccessToken(now: Date = Date()) -> String? {
        guard let accessToken, !accessToken.isEmpty else { return nil }
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSince(now) > 60 ? accessToken : nil
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
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
