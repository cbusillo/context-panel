import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelApp

private actor ProfileHTTP: ConnectorHTTPClient {
    var requests: [ConnectorHTTPRequest] = []
    let status: Int
    let data: Data
    init(status: Int = 200, data: Data) { self.status = status; self.data = data }
    func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse {
        requests.append(request)
        return ConnectorHTTPResponse(statusCode: status, data: data)
    }
}
private struct ProfileCredentials: ProviderCredentialLoading {
    let data: Data?
    func load(accountID: String) throws -> Data? { data }
}
private func profileCredentials(scopes: [String] = ["user:profile"], expiry: Date? = .distantFuture) throws -> Data {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(ClaudeOAuthCredentials(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: expiry, scopes: scopes))
}

@Test func claudeProfileShapeDropsValuesAndUnknownKeys() throws {
    let secret = UUID().uuidString
    let data = try JSONSerialization.data(withJSONObject: [
        "account": ["email": secret, "full_name": NSNull(), "display_name": [secret: secret]],
        "organization": ["name": [secret], "organization_type": true, "rate_limit_tier": 7], secret: secret])
    let shape = try ClaudeOAuthProfileShape.parse(data)
    #expect(shape.fields[.email] == .string)
    #expect(shape.fields[.name] == .null)
    #expect(shape.fields[.displayName] == .object)
    #expect(shape.fields[.organizationName] == .array)
    #expect(shape.fields[.organizationType] == .boolean)
    #expect(shape.fields[.rateLimitTier] == .number)
    #expect(!shape.summary.contains(secret))
    #expect(try ClaudeOAuthProfileShape.parse(Data("{}".utf8)).fields.values.allSatisfy { $0 == .missing })
    #expect(throws: ClaudeOAuthProfileQualification.Failure.self) { try ClaudeOAuthProfileShape.parse(Data("[]".utf8)) }
    #expect(throws: ClaudeOAuthProfileQualification.Failure.self) { try ClaudeOAuthProfileShape.parse(JSONSerialization.data(withJSONObject: ["account": ["email": String(repeating: "x", count: 300_000)]])) }
}

@Test func claudeProfileCheckUsesExistingAppCredentialAndReturnsOnlyShape() async throws {
    let http = ProfileHTTP(data: Data(#"{"account":{"email":"private@example.invalid"}}"#.utf8))
    let service = ClaudeOAuthProfileQualification(credentialStore: ProfileCredentials(data: try profileCredentials()), httpClient: http)
    let shape = try await service.check(accountID: "configured", now: Date(timeIntervalSince1970: 100))
    #expect(shape.fields[.email] == .string)
    #expect(!shape.summary.contains("private@example.invalid"))
    let requests = await http.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url == ClaudeOAuthMetadata.profileEndpoint)
    #expect(requests.first?.method == "GET")
    #expect(requests.first?.headers["Authorization"] == "Bearer synthetic-access")
    #expect(requests.first?.body == nil)
}

@Test func claudeProfileCheckRefusesMissingExpiredOrUnconsentedCredentialWithoutHTTP() async throws {
    let cases: [(Data?, ClaudeOAuthProfileQualification.Failure)] = [
        (nil, .signInRequired), (Data("bad credential".utf8), .signInRequired),
        (try profileCredentials(expiry: .distantPast), .refreshRequired),
        (try profileCredentials(expiry: nil), .refreshRequired),
        (try profileCredentials(scopes: []), .profileConsentRequired)]
    for (data, expected) in cases {
        let http = ProfileHTTP(data: Data())
        let service = ClaudeOAuthProfileQualification(credentialStore: ProfileCredentials(data: data), httpClient: http)
        do { _ = try await service.check(accountID: "configured"); Issue.record("Expected failure") }
        catch let failure as ClaudeOAuthProfileQualification.Failure { #expect(failure == expected) }
        #expect(await http.requests.isEmpty)
    }
}

@Test func claudeProfileCheckDoesNotSurfaceProviderErrorBodies() async throws {
    let secret = UUID().uuidString
    for status in [401, 403, 429, 500] {
        let http = ProfileHTTP(status: status, data: Data(secret.utf8))
        let service = ClaudeOAuthProfileQualification(credentialStore: ProfileCredentials(data: try profileCredentials()), httpClient: http)
        do { _ = try await service.check(accountID: "configured"); Issue.record("Expected failure") }
        catch { #expect(!error.localizedDescription.contains(secret)) }
        #expect(await http.requests.count == 1)
    }
}

private actor ProfileAccountRecorder {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

@Test func claudeProfileCommandSelectsEnabledClaudeEntriesAndOmitsIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    let privateID = UUID().uuidString
    try store.save(AccountConfigurationDocument(updatedAt: .distantPast, accounts: [
        LocalProviderAccountConfiguration(id: privateID, provider: .anthropic, connectorKind: .claudeOAuthUsage, displayName: "Private name"),
        LocalProviderAccountConfiguration(id: "disabled", provider: .anthropic, connectorKind: .claudeOAuthUsage, displayName: "Disabled", isEnabled: false),
        LocalProviderAccountConfiguration(id: "openai", provider: .openAI, connectorKind: .codexRateLimits, displayName: "Other")]))
    let recorder = ProfileAccountRecorder()
    let result = await ClaudeOAuthProfileQualificationCommand.run(arguments: [], accountStore: store) { id in
        await recorder.record(id)
        return try ClaudeOAuthProfileShape.parse(Data("{}".utf8))
    }
    #expect(result.exitCode == 0)
    #expect(await recorder.ids == [privateID])
    let output = String(decoding: result.standardOutput, as: UTF8.self)
    #expect(!output.contains(privateID))
    #expect(!output.contains("Private name"))
    #expect(result.standardError.isEmpty)
    let invalid = await ClaudeOAuthProfileQualificationCommand.run(arguments: ["--other"], accountStore: store) { _ in
        Issue.record("Invalid arguments must not read profile"); return try ClaudeOAuthProfileShape.parse(Data("{}".utf8))
    }
    #expect(invalid.exitCode == 64)
}

@Test func claudeProfileCommandKeepsUnavailableSeparateFromMissingFields() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try store.save(AccountConfigurationDocument(updatedAt: .distantPast, accounts: [
        LocalProviderAccountConfiguration(id: "claude", provider: .anthropic, connectorKind: .claudeOAuthUsage, displayName: "Private")]))
    let result = await ClaudeOAuthProfileQualificationCommand.run(arguments: [], accountStore: store) { _ in
        throw ClaudeOAuthProfileQualification.Failure.requestFailed
    }
    #expect(result.exitCode == 1)
    #expect(result.standardOutput.isEmpty)
    #expect(!result.standardError.isEmpty)
}

@Test func claudeProfileCommandRoutesHelpWithoutOpeningAccounts() async throws {
    #expect(await ContextPanelEntryPoint.profileShapeResult(arguments: []) == nil)
    #expect(await ContextPanelEntryPoint.profileShapeResult(arguments: ["--refresh-now"]) == nil)
    let help = try #require(await ContextPanelEntryPoint.profileShapeResult(arguments: ["--claude-profile-shape", "--help"]))
    #expect(help.exitCode == 0)
    #expect(!help.standardOutput.isEmpty)
}

private struct UnavailableProfileCredentials: ProviderCredentialLoading {
    func load(accountID: String) throws -> Data? { throw CocoaError(.fileReadNoPermission) }
}

@Test func claudeProfileCredentialReadFailureDoesNotRequestNewConsent() async throws {
    let http = ProfileHTTP(data: Data())
    let service = ClaudeOAuthProfileQualification(credentialStore: UnavailableProfileCredentials(), httpClient: http)
    do { _ = try await service.check(accountID: "configured"); Issue.record("Expected failure") }
    catch let failure as ClaudeOAuthProfileQualification.Failure { #expect(failure == .credentialUnavailable) }
    #expect(await http.requests.isEmpty)
}

@Test func claudeProfileCommandReadsLegacyConfigurationWithoutMigratingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appending(path: "legacy.json")
    let canonical = root.appending(path: "current.json")
    let data = Data(#"{"schemaVersion":1,"updatedAt":"2026-10-01T00:00:00Z","accounts":[{"id":"claude-local-default","provider":"anthropic","connectorKind":"claudeLocalStatus","displayName":"Private","isEnabled":true}]}"#.utf8)
    try data.write(to: legacy)
    let recorder = ProfileAccountRecorder()
    let result = await ClaudeOAuthProfileQualificationCommand.run(arguments: [], accountStore: AccountConfigurationStore(configurationURL: canonical, fallbackConfigurationURL: legacy)) { id in
        await recorder.record(id)
        return try ClaudeOAuthProfileShape.parse(Data("{}".utf8))
    }
    #expect(result.exitCode == 0)
    #expect(await recorder.ids == ["claude-local-default"])
    #expect(!FileManager.default.fileExists(atPath: canonical.path))
    #expect(try Data(contentsOf: legacy) == data)
}
