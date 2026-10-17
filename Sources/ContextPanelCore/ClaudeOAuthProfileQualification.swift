import CoreFoundation
import Foundation

/// A value-free view of candidate display fields. These paths are probes, not
/// a claim that the provider supports them. Unknown keys and all values are dropped.
public struct ClaudeOAuthProfileShape: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case email = "account.email"
        case name = "account.full_name"
        case displayName = "account.display_name"
        case organizationName = "organization.name"
        case organizationType = "organization.organization_type"
        case rateLimitTier = "organization.rate_limit_tier"
    }

    public enum Kind: String, Sendable {
        case missing, null, string, number, boolean, object, array
    }

    public let fields: [Field: Kind]

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClaudeOAuthProfileQualification.Failure.invalidResponse }
        var fields: [Field: Kind] = [:]
        for field in Field.allCases {
            let path = field.rawValue.split(separator: ".").map(String.init)
            let value = (root[path[0]] as? [String: Any])?[path[1]]
            fields[field] = kind(of: value)
        }
        return Self(fields: fields)
    }

    public var summary: String {
        Field.allCases.map { "\($0.rawValue): \(fields[$0]?.rawValue ?? Kind.missing.rawValue)" }
            .joined(separator: "\n")
    }

    private static func kind(of value: Any?) -> Kind {
        guard let value else { return .missing }
        if value is NSNull { return .null }
        if value is String { return .string }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number
        }
        if value is [String: Any] { return .object }
        if value is [Any] { return .array }
        return .missing
    }
}

/// Uses only Context Panel's saved OAuth credential. Never refreshes a token,
/// persists a profile, logs a response or reads another client's storage.
public struct ClaudeOAuthProfileQualification: Sendable {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case signInRequired, credentialUnavailable, refreshRequired, profileConsentRequired, requestFailed, invalidResponse

        public var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in to Claude in Context Panel before checking profile fields."
            case .credentialUnavailable: "Saved Claude sign-in could not be read. Open the signed Context Panel app and retry."
            case .refreshRequired: "Open Context Panel or run --refresh-now, then retry the profile check."
            case .profileConsentRequired: "The saved Claude sign-in does not include profile consent."
            case .requestFailed: "Claude profile fields could not be checked. Try again later."
            case .invalidResponse: "Claude returned an unsupported profile response."
            }
        }
    }

    private let credentialStore: any ProviderCredentialLoading
    private let httpClient: any ConnectorHTTPClient

    public init(credentialStore: any ProviderCredentialLoading,
                httpClient: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.credentialStore = credentialStore
        self.httpClient = httpClient
    }

    public func check(accountID: String, now: Date = Date()) async throws -> ClaudeOAuthProfileShape {
        let data: Data?
        do { data = try credentialStore.load(accountID: accountID) }
        catch { throw Failure.credentialUnavailable }
        guard let data, let credentials = try? JSONDecoder.contextPanelISO8601.decode(ClaudeOAuthCredentials.self, from: data),
              let token = credentials.accessToken, !token.isEmpty else { throw Failure.signInRequired }
        guard let expiresAt = credentials.expiresAt, expiresAt > now else { throw Failure.refreshRequired }
        guard credentials.scopes.contains("user:profile") else { throw Failure.profileConsentRequired }
        let response: ConnectorHTTPResponse
        do {
            response = try await httpClient.data(for: ConnectorHTTPRequest(
                url: ClaudeOAuthMetadata.profileEndpoint, method: "GET",
                headers: ["Authorization": "Bearer \(token)", "Accept": "application/json",
                          "User-Agent": ClaudeOAuthMetadata.usageUserAgent,
                          "anthropic-beta": ClaudeOAuthMetadata.oauthBetaHeader]))
        } catch { throw Failure.requestFailed }
        guard response.statusCode == 200 else { throw Failure.requestFailed }
        return try ClaudeOAuthProfileShape.parse(response.data)
    }
}
