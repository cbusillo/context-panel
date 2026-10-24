import Foundation
import Testing
@testable import ContextPanelCore

private func profile(email: String? = "pat@example.test", type: String? = "claude_max", tier: String? = "default_claude_max_20x",
    organization: String? = "pat@example.test's Organization") -> Data {
    let object: [String: Any] = [
        "account": ["uuid": UUID().uuidString, "email": email as Any, "full_name": "Pat Q", "display_name": "Pat"],
        "organization": ["uuid": UUID().uuidString, "name": organization as Any,
            "organization_type": type as Any, "rate_limit_tier": tier as Any],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

@Test func claudeProfileDisplayKeepsOnlyLoginAndRecognisedPlan() throws {
    let display = try #require(ClaudeOAuthProfileDisplay.parse(profile()))
    #expect(display == ClaudeOAuthProfileDisplay(email: "pat@example.test", planLabel: "Max 20x"))
    let encoded = String(decoding: try JSONEncoder().encode(display), as: UTF8.self)
    #expect(!encoded.contains("Pat Q") && !encoded.contains("Organization"))
    #expect(!String(describing: display).contains("pat@"))
}

@Test func claudeProfilePlanUsesClosedVocabularyAndNamesOnlyWorkOrganizations() {
    func plan(_ type: String?, _ tier: String? = nil, _ organization: String? = "Acme") -> String? {
        ClaudeOAuthProfileDisplay.parse(profile(type: type, tier: tier, organization: organization))?.planLabel
    }
    #expect(plan("claude_pro") == "Pro")
    #expect(plan("claude_max", "default_claude_max_5x") == "Max 5x")
    #expect(plan("claude_max", "future_tier") == "Max")
    #expect(plan("claude_team") == "Team · Acme")
    #expect(plan("claude_enterprise", nil, nil) == "Enterprise")
    #expect(plan("claude_free") == nil)
    #expect(plan(nil) == nil)
}

@Test func claudeProfileDisplayRejectsMalformedLoginsAndOversizedResponses() {
    #expect(ClaudeOAuthProfileDisplay.parse(profile(email: "not an email"))?.email == nil)
    #expect(ClaudeOAuthProfileDisplay.parse(profile(email: "@example.test"))?.email == nil)
    #expect(ClaudeOAuthProfileDisplay.parse(profile(email: nil, type: "unknown")) == nil)
    #expect(ClaudeOAuthProfileDisplay.parse(Data(repeating: 0x20, count: 256 * 1024 + 1)) == nil)
}
