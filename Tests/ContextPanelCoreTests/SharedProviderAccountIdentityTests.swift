import Foundation
import Testing
@testable import ContextPanelCore

private let identityTestKey = ProviderAccountIdentityKey(keyID: UUID(), secret: Data(repeating: 17, count: 32))!

@Test func providerAccountPseudonymIsStablePerUserAndSeparatesScopes() throws {
    let material = try #require(ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID,
        identifier: "provider-account", scope: "seat-one"))
    let a = identityTestKey.identity(for: material)
    let reloadedKey = try #require(ProviderAccountIdentityKey(encryptedStorePayload: identityTestKey.encryptedStorePayload()))
    #expect(reloadedKey.identity(for: material) == a)
    let otherUser = ProviderAccountIdentityKey.generate()
    #expect(otherUser.identity(for: material).digest != a.digest)
    let otherSeat = try #require(ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID,
        identifier: "provider-account", scope: "seat-two"))
    #expect(identityTestKey.identity(for: otherSeat).digest != a.digest)
    let encoded = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
    #expect(!encoded.contains("provider-account"))
    #expect(!encoded.contains("seat-one"))
    #expect(SharedProviderAccountIdentity.isSharedAccountID(a.accountID))
    #expect(String(describing: material).contains("redacted"))
    #expect(String(describing: identityTestKey).contains("redacted"))
}

@Test func identityParserRejectsEmailsInvalidNamespacesAndMalformedProfiles() {
    #expect(ProviderAccountIdentityMaterial(provider: .google, kind: .googleSubject, identifier: "person@example.invalid") == nil)
    #expect(ProviderAccountIdentityMaterial(provider: .google, kind: .claudeAccountUUID, identifier: "account") == nil)
    #expect(ProviderAccountIdentityKey(keyID: UUID(), secret: Data(repeating: 0, count: 31)) == nil)
    #expect(ClaudeOAuthAccountIdentityParser.material(from: Data(#"{"account":{"email":"person@example.invalid"}}"#.utf8)) == nil)
    #expect(ClaudeOAuthAccountIdentityParser.material(from: Data(#"{"account":{"uuid":"invalid"}}"#.utf8)) == nil)
    #expect(!SharedProviderAccountIdentity.isSharedAccountID("cp-account-v1:openai:not-a-uuid:invalid"))
}

@Test func claudeAuthenticatedProfileUsesAccountUUIDAndOrganizationScopeOnly() throws {
    let account = UUID(); let organization = UUID()
    let profile = try JSONSerialization.data(withJSONObject: ["account": ["uuid": account.uuidString,
        "email": "private@example.invalid", "display_name": "Private name"], "organization": ["uuid": organization.uuidString]])
    let material = try #require(ClaudeOAuthAccountIdentityParser.material(from: profile))
    let expected = try #require(ProviderAccountIdentityMaterial(provider: .anthropic, kind: .claudeAccountUUID,
        identifier: account.uuidString.lowercased(), scope: organization.uuidString.lowercased()))
    let actual = identityTestKey.identity(for: material)
    #expect(actual == identityTestKey.identity(for: expected))
    let json = String(decoding: try JSONEncoder().encode(actual), as: UTF8.self)
    #expect(!json.contains(account.uuidString))
    #expect(!json.contains(organization.uuidString))
    #expect(!json.contains("private@example.invalid"))
}

private actor IdentityKeyRaceStore {
    var key: ProviderAccountIdentityKey?
    var proposedKeyIDs: [UUID] = []
    func insert(_ candidate: ProviderAccountIdentityKey) -> ProviderAccountIdentityKey {
        proposedKeyIDs.append(candidate.keyID)
        if let key { return key }
        key = candidate
        return candidate
    }
}

@Test func concurrentFirstPublishersConvergeOnOneConditionalKey() async throws {
    let store = IdentityKeyRaceStore()
    async let first = ProviderIdentityKeyBootstrap.resolve(load: { .absent }, insertIfAbsent: { await store.insert($0) })
    async let second = ProviderIdentityKeyBootstrap.resolve(load: { .absent }, insertIfAbsent: { await store.insert($0) })
    let a = try #require(await first); let b = try #require(await second)
    let material = try #require(ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID, identifier: "account"))
    #expect(a.identity(for: material) == b.identity(for: material))
    let proposals = await store.proposedKeyIDs
    #expect(Set(proposals).count == 2)
}

@Test func unavailableKeyStoreDoesNotInventASecondNamespace() async {
    let store = IdentityKeyRaceStore()
    let key = await ProviderIdentityKeyBootstrap.resolve(load: { .unavailable }, insertIfAbsent: { await store.insert($0) })
    #expect(key == nil)
    #expect(await store.proposedKeyIDs.isEmpty)
}

@Test func sharedProviderIDIgnoresHostSetupMembershipAndKeepsDifferentAccountsSeparate() throws {
    let material = try #require(ProviderAccountIdentityMaterial(provider: .anthropic, kind: .claudeAccountUUID,
        identifier: UUID().uuidString.lowercased()))
    let identity = identityTestKey.identity(for: material)
    func document(configuration: String, remaining: Int, observedAt: Date, otherIdentity: SharedProviderAccountIdentity? = nil) -> CompanionSyncDocument {
        let identity = otherIdentity ?? identity
        let limit = UsageLimit(provider: .anthropic, accountID: identity.accountID, configuredAccountID: configuration,
            accountName: "Local label", label: "Weekly", unit: .percent, used: 100 - remaining, limit: 100,
            resetsAt: observedAt.addingTimeInterval(3600), lastUpdatedAt: observedAt)
        let report = StoredProviderReport(provider: .anthropic, accountID: identity.accountID,
            configuredAccountID: configuration, accountName: "Local label", generatedAt: observedAt,
            status: .healthy, errorMessage: nil, sharedAccountIdentity: identity)
        let stored = StoredUsageSnapshot(savedAt: observedAt, snapshot: UsageSnapshot(generatedAt: observedAt, limits: [limit]), reports: [report])
        return CompanionSyncDocument(storedSnapshot: stored, publishedAt: observedAt)
    }
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let old = document(configuration: "mac-one", remaining: 90, observedAt: now.addingTimeInterval(-30))
    let new = document(configuration: "mac-two", remaining: 75, observedAt: now)
    #expect(old.snapshot.limits.first?.companionAccountID == new.snapshot.limits.first?.companionAccountID)
    let merged = new.mergingForRemotePublish(existing: old, now: now)
    #expect(merged.snapshot.limits.count == 1)
    #expect(merged.snapshot.providerStatuses.count == 1)
    #expect(merged.snapshot.limits.first?.used == 25)
    #expect(merged.snapshot.providerStatuses.first?.sharedAccountIdentity == identity)
    let secondMaterial = try #require(ProviderAccountIdentityMaterial(provider: .anthropic, kind: .claudeAccountUUID, identifier: UUID().uuidString.lowercased()))
    let second = document(configuration: "mac-three", remaining: 60, observedAt: now, otherIdentity: identityTestKey.identity(for: secondMaterial))
    #expect(second.mergingForRemotePublish(existing: merged, now: now).snapshot.limits.count == 2)
    let encoded = try CompanionSyncPayloadCodec.encode(merged)
    let decoded = try CompanionSyncPayloadCodec.decode(encoded)
    #expect(decoded.snapshot.providerStatuses.first?.storedProviderReport.sharedAccountIdentity == identity)
}

@Test func mismatchedIdentityCannotClaimVerifiedAccount() throws {
    let material = try #require(ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID, identifier: "fake-account"))
    let identity = identityTestKey.identity(for: material)
    let report = StoredProviderReport(provider: .anthropic, accountID: identity.accountID,
        accountName: "Label", generatedAt: Date(timeIntervalSince1970: 0), status: .healthy,
        errorMessage: nil, sharedAccountIdentity: identity, accountIdentityStatus: .verified)
    #expect(report.sharedAccountIdentity == nil)
    #expect(report.accountIdentityStatus == .unverified)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    object["accountIdentityStatus"] = ProviderAccountIdentityStatus.verified.rawValue
    let decoded = try JSONDecoder().decode(StoredProviderReport.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.accountIdentityStatus == .unverified)
    #expect(!SharedProviderAccountIdentity.isSharedAccountID(identity.accountID, provider: .anthropic))
}

@Test func missingRemoteKeyReusesEstablishedNamespaceOnConditionalRestore() async throws {
    let store = IdentityKeyRaceStore()
    let restored = try #require(await ProviderIdentityKeyBootstrap.resolve(load: { .absent },
        establishedKey: identityTestKey, insertIfAbsent: { await store.insert($0) }))
    #expect(restored.keyID == identityTestKey.keyID)
}

@Test func encryptedIdentityKeyRejectsForeignICloudScope() throws {
    let a = CompanionCloudKitUserScope.derive(containerIdentifier: "test-container", userRecordName: "user-a")
    let b = CompanionCloudKitUserScope.derive(containerIdentifier: "test-container", userRecordName: "user-b")
    let payload = try ScopedProviderAccountIdentityKey.encode(identityTestKey, scope: a)
    #expect(ScopedProviderAccountIdentityKey.decode(payload, scope: a)?.keyID == identityTestKey.keyID)
    #expect(ScopedProviderAccountIdentityKey.decode(payload, scope: b) == nil)
}

@Test func futureIdentityMetadataDoesNotBreakStoredQuota() throws {
    let report = StoredProviderReport(provider: .anthropic, accountID: "local", accountName: "Label",
        generatedAt: Date(timeIntervalSince1970: 0), status: .healthy, errorMessage: nil)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    object["sharedAccountIdentity"] = ["provider": "anthropic", "kind": "future-kind",
        "keyID": UUID().uuidString, "digest": String(repeating: "a", count: 64)]
    object["accountIdentityStatus"] = "future-status"
    let decoded = try JSONDecoder().decode(StoredProviderReport.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.status == .healthy)
    #expect(decoded.sharedAccountIdentity == nil)
    #expect(decoded.accountIdentityStatus == .unverified)
}
