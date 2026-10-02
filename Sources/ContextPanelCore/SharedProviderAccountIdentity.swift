import CryptoKit
import Foundation

public enum ProviderAccountIdentifierKind: String, Codable, Sendable {
    case chatGPTAccountID = "chatgpt_account_id"
    case claudeAccountUUID = "account.uuid"
    case googleSubject = "oidc.iss+sub"
}

/// Raw provider identifiers are input material, never a snapshot payload.
public struct ProviderAccountIdentityMaterial: Sendable, CustomStringConvertible {
    public let provider: Provider
    public let kind: ProviderAccountIdentifierKind
    private let identifier: String
    private let scope: String

    public init?(provider: Provider, kind: ProviderAccountIdentifierKind, identifier: String, scope: String = "") {
        guard !identifier.isEmpty, identifier.utf8.count <= 512, scope.utf8.count <= 512,
              !identifier.contains("@"), !identifier.contains(where: { $0.isWhitespace || $0.isNewline }),
              (provider == .openAI && kind == .chatGPTAccountID)
                || (provider == .anthropic && kind == .claudeAccountUUID)
                || (provider == .google && kind == .googleSubject) else { return nil }
        self.provider = provider
        self.kind = kind
        self.identifier = identifier
        self.scope = scope
    }

    public var description: String { "Provider account identity material [redacted]" }

    public func localHistoryID(configurationID: String) -> String {
        var value = message
        value.append(Data(("source:" + configurationID).utf8))
        return provider.rawValue + "-history-" + SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate struct CachePayload: Codable {
        let provider: Provider; let kind: ProviderAccountIdentifierKind
        let identifier: String; let scope: String; let credentialDigest: String
    }
    fileprivate func cachePayload(credentialDigest: String) throws -> Data {
        try JSONEncoder().encode(CachePayload(provider: provider, kind: kind, identifier: identifier,
            scope: scope, credentialDigest: credentialDigest))
    }
    fileprivate static func cached(_ data: Data, credentialDigest: String) -> Self? {
        guard data.count <= 8192, let value = try? JSONDecoder().decode(CachePayload.self, from: data),
              value.credentialDigest == credentialDigest else { return nil }
        return Self(provider: value.provider, kind: value.kind, identifier: value.identifier, scope: value.scope)
    }

    fileprivate var message: Data {
        // Length-delimited components distinguish account, organization and provider.
        Data(["context-panel-account-v1", provider.rawValue, kind.rawValue, identifier, scope]
            .map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }
}

/// Contains only a keyed pseudonym; the key and raw identity stay outside snapshots.
public struct SharedProviderAccountIdentity: Codable, Equatable, Sendable {
    public let provider: Provider
    public let kind: ProviderAccountIdentifierKind
    public let keyID: UUID
    public let digest: String
    /// Local membership binding is stripped from the shared transport.
    public let boundLocalAccountID: String?
    public let userScope: CompanionCloudKitUserScope?

    fileprivate init(provider: Provider, kind: ProviderAccountIdentifierKind, keyID: UUID, digest: String, boundLocalAccountID: String? = nil, userScope: CompanionCloudKitUserScope? = nil) {
        self.provider = provider; self.kind = kind; self.keyID = keyID; self.digest = digest
        self.boundLocalAccountID = boundLocalAccountID
        self.userScope = userScope
    }

    public var accountID: String {
        "cp-account-v1:\(provider.rawValue):\(keyID.uuidString.lowercased()):\(digest)"
    }

    public static func isSharedAccountID(_ value: String, provider: Provider? = nil) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "cp-account-v1"
            && Provider(rawValue: String(parts[1])) != nil
            && (provider.map { $0.rawValue == String(parts[1]) } ?? true) && UUID(uuidString: String(parts[2])) != nil
            && parts[3].count == 64 && parts[3].allSatisfy { "0123456789abcdef".contains($0) }
    }

    public func matches(provider: Provider, accountID: String) -> Bool {
        self.provider == provider && (self.accountID == accountID || boundLocalAccountID == accountID)
    }

    public func bound(toLocalAccountID id: String?) -> Self {
        Self(provider: provider, kind: kind, keyID: keyID, digest: digest, boundLocalAccountID: id, userScope: userScope)
    }

    public func bound(toUserScope scope: CompanionCloudKitUserScope?) -> Self {
        Self(provider: provider, kind: kind, keyID: keyID, digest: digest, boundLocalAccountID: boundLocalAccountID, userScope: scope)
    }

    public static func status(_ proposed: ProviderAccountIdentityStatus, identity: SharedProviderAccountIdentity?) -> ProviderAccountIdentityStatus {
        identity != nil ? .verified : (proposed == .verified ? .unverified : proposed)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(Provider.self, forKey: .provider)
        kind = try c.decode(ProviderAccountIdentifierKind.self, forKey: .kind)
        keyID = try c.decode(UUID.self, forKey: .keyID)
        digest = try c.decode(String.self, forKey: .digest)
        boundLocalAccountID = try c.decodeIfPresent(String.self, forKey: .boundLocalAccountID)
        userScope = try c.decodeIfPresent(CompanionCloudKitUserScope.self, forKey: .userScope)
        guard Self.isSharedAccountID(accountID),
              (provider == .openAI && kind == .chatGPTAccountID)
                || (provider == .anthropic && kind == .claudeAccountUUID)
                || (provider == .google && kind == .googleSubject) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid shared account identity"))
        }
    }
}

public struct ProviderAccountIdentityKey: Sendable, CustomStringConvertible {
    public let keyID: UUID
    private let secret: Data
    public init?(keyID: UUID, secret: Data) {
        guard secret.count == 32 else { return nil }
        self.keyID = keyID; self.secret = secret
    }
    public var description: String { "Provider account identity key [redacted]" }
    private struct EncryptedKeyPayload: Codable { let keyID: UUID; let secret: Data }
    public init?(encryptedStorePayload: Data) {
        guard encryptedStorePayload.count <= 4096,
              let value = try? JSONDecoder().decode(EncryptedKeyPayload.self, from: encryptedStorePayload) else { return nil }
        self.init(keyID: value.keyID, secret: value.secret)
    }
    /// Only for encrypted CloudKit fields and the local Keychain cache, never usage payloads.
    public func encryptedStorePayload() throws -> Data {
        try JSONEncoder().encode(EncryptedKeyPayload(keyID: keyID, secret: secret))
    }
    public func identity(for material: ProviderAccountIdentityMaterial) -> SharedProviderAccountIdentity {
        let hash = HMAC<SHA256>.authenticationCode(for: material.message, using: SymmetricKey(data: secret))
        return SharedProviderAccountIdentity(provider: material.provider, kind: material.kind, keyID: keyID,
            digest: hash.map { String(format: "%02x", $0) }.joined())
    }
    public static func generate() -> Self {
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return Self(keyID: UUID(), secret: data)!
    }
}

public enum ProviderIdentityKeyLoad: Sendable {
    case available(ProviderAccountIdentityKey)
    case absent
    case unavailable
}

public enum ProviderIdentityKeyBootstrap {
    /// The store's insertion must be conditional; conflict readback returns the winning key.
    public static func resolve(
        load: @Sendable () async -> ProviderIdentityKeyLoad,
        establishedKey: ProviderAccountIdentityKey? = nil,
        insertIfAbsent: @Sendable (ProviderAccountIdentityKey) async -> ProviderAccountIdentityKey?
    ) async -> ProviderAccountIdentityKey? {
        switch await load() {
        case let .available(key): return key
        case .absent: return await insertIfAbsent(establishedKey ?? .generate())
        case .unavailable: return nil
        }
    }
}

public enum ProviderAccountIdentityStatus: String, Codable, Sendable {
    case verified
    case resolutionNotEnabled
    case waitingForSharedKey
    case providerIdentityUnavailable
    case notExposedByConnector
    case unverified
}

public struct ProviderAccountIdentityResolver: Sendable {
    private let resolveIdentity: @Sendable (ProviderAccountIdentityMaterial) async -> SharedProviderAccountIdentity?
    public init(resolve: @escaping @Sendable (ProviderAccountIdentityMaterial) async -> SharedProviderAccountIdentity?) {
        resolveIdentity = resolve
    }
    public func resolve(_ material: ProviderAccountIdentityMaterial) async -> SharedProviderAccountIdentity? {
        await resolveIdentity(material)
    }
}

public enum ClaudeOAuthAccountIdentityParser {
    public static func material(from data: Data) -> ProviderAccountIdentityMaterial? {
        struct Profile: Decodable { let account: Account; let organization: Organization
            struct Account: Decodable { let uuid: UUID }
            struct Organization: Decodable { let uuid: UUID }
        }
        guard data.count <= 256 * 1024, let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return nil }
        return ProviderAccountIdentityMaterial(provider: .anthropic, kind: .claudeAccountUUID,
            identifier: profile.account.uuid.uuidString.lowercased(),
            scope: profile.organization.uuid.uuidString.lowercased())
    }
}

/// Raw CloudKit user IDs stay private; only a derived scope digest accompanies identity provenance.
public enum ScopedProviderAccountIdentityKey {
    private struct Payload: Codable {
        let userScope: CompanionCloudKitUserScope
        let key: Data
    }
    public static func encode(_ key: ProviderAccountIdentityKey, scope: CompanionCloudKitUserScope) throws -> Data {
        try JSONEncoder().encode(Payload(userScope: scope, key: key.encryptedStorePayload()))
    }
    public static func decode(_ data: Data, scope: CompanionCloudKitUserScope) -> ProviderAccountIdentityKey? {
        guard data.count <= 8192, let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.userScope == scope else { return nil }
        return ProviderAccountIdentityKey(encryptedStorePayload: payload.key)
    }
}

/// Profile material is cached in the app-owned Keychain, bound to the exact access credential.
/// Neither raw provider IDs nor the credential digest enter a usage snapshot.
public struct ProviderAccountIdentityMaterialStore: Sendable {
    private let store: any ProviderCredentialStoring
    public init(store: any ProviderCredentialStoring) { self.store = store }
    private func digest(_ credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func load(provider: Provider, configurationID: String, credential: String) -> ProviderAccountIdentityMaterial? {
        guard let data = try? store.load(accountID: provider.rawValue + ":" + configurationID) else { return nil }
        let material = ProviderAccountIdentityMaterial.cached(data, credentialDigest: digest(credential))
        return material?.provider == provider ? material : nil
    }
    public func save(_ material: ProviderAccountIdentityMaterial, configurationID: String, credential: String) {
        guard let data = try? material.cachePayload(credentialDigest: digest(credential)) else { return }
        try? store.save(data, accountID: material.provider.rawValue + ":" + configurationID)
    }
}
