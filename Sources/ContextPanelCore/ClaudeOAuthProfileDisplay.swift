import CryptoKit
import Foundation

/// Display values from Context Panel's own `user:profile` read (#760). Only the login
/// email and a recognised plan label are kept; account and organization IDs, names and
/// unknown plan values are dropped. Values never enter logs.
public struct ClaudeOAuthProfileDisplay: Codable, Equatable, Sendable, CustomStringConvertible {
    public let email: String?
    public let planLabel: String?

    public init(email: String?, planLabel: String?) {
        self.email = email
        self.planLabel = planLabel
    }

    public var description: String { "ClaudeOAuthProfileDisplay(redacted)" }

    public static func parse(_ data: Data) -> Self? {
        struct Profile: Decodable {
            let account: Account?
            let organization: Organization?
            struct Account: Decodable { let email: String? }
            struct Organization: Decodable {
                let name: String?
                let organizationType: String?
                let rateLimitTier: String?
                enum CodingKeys: String, CodingKey {
                    case name
                    case organizationType = "organization_type"
                    case rateLimitTier = "rate_limit_tier"
                }
            }
        }
        guard data.count <= 256 * 1024, let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return nil }
        let display = Self(
            email: profile.account?.email.flatMap(email(from:)),
            planLabel: planLabel(organizationType: profile.organization?.organizationType,
                rateLimitTier: profile.organization?.rateLimitTier, organizationName: profile.organization?.name))
        return display.email == nil && display.planLabel == nil ? nil : display
    }

    /// Closed vocabulary: an unrecognised plan shows nothing rather than a raw provider string.
    /// The organization name is shown only for work plans, where it names the company.
    static func planLabel(organizationType: String?, rateLimitTier: String?, organizationName: String?) -> String? {
        let plan: String
        var isWorkPlan = false
        switch organizationType {
        case "claude_pro": plan = "Pro"
        case "claude_max":
            switch rateLimitTier {
            case "default_claude_max_5x": plan = "Max 5x"
            case "default_claude_max_20x": plan = "Max 20x"
            default: plan = "Max"
            }
        case "claude_team": plan = "Team"; isWorkPlan = true
        case "claude_enterprise": plan = "Enterprise"; isWorkPlan = true
        default: return nil
        }
        guard isWorkPlan, let name = organizationName.flatMap(boundedText) else { return plan }
        return "\(plan) · \(name)"
    }

    private static func email(from value: String) -> String? {
        guard let email = boundedText(value, limit: 254), !email.contains(where: \.isWhitespace),
              email.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              !email.hasPrefix("@"), !email.hasSuffix("@") else { return nil }
        return email
    }

    private static func boundedText(_ value: String) -> String? { boundedText(value, limit: 80) }

    private static func boundedText(_ value: String, limit: Int) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}

/// Profile display values are cached in the app-owned Keychain, bound to the exact access
/// credential, so the profile is read once per token rather than on every refresh.
public struct ClaudeOAuthProfileDisplayStore: Sendable {
    private struct CachePayload: Codable {
        let display: ClaudeOAuthProfileDisplay
        let credentialDigest: String
    }

    private let store: any ProviderCredentialStoring
    public init(store: any ProviderCredentialStoring) { self.store = store }

    private func key(_ configurationID: String) -> String { "anthropic-profile:" + configurationID }
    private func digest(_ credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func load(configurationID: String, credential: String) -> ClaudeOAuthProfileDisplay? {
        guard let data = try? store.load(accountID: key(configurationID)), data.count <= 8192,
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.credentialDigest == digest(credential) else { return nil }
        return payload.display
    }

    public func save(_ display: ClaudeOAuthProfileDisplay, configurationID: String, credential: String) {
        guard let data = try? JSONEncoder().encode(CachePayload(display: display, credentialDigest: digest(credential))) else { return }
        try? store.save(data, accountID: key(configurationID))
    }
}
