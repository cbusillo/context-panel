import Foundation
import Security

public protocol ProviderCredentialStore: Sendable {
    func data(for key: ProviderCredentialKey) throws -> Data?
    func store(_ data: Data, for key: ProviderCredentialKey) throws
    func remove(_ key: ProviderCredentialKey) throws
}

public struct ProviderCredentialKey: Hashable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let kind: String

    public init(provider: Provider, accountID: String, kind: String) {
        self.provider = provider
        self.accountID = accountID
        self.kind = kind
    }

    var service: String {
        "com.shinycomputers.contextpanel.\(provider.rawValue).\(kind)"
    }

    var account: String {
        accountID
    }
}

public enum ProviderCredentialStoreError: LocalizedError, Equatable, Sendable {
    case keychainStatus(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychainStatus(operation, status):
            "Keychain \(operation) failed with status \(status)"
        }
    }
}

public struct KeychainProviderCredentialStore: ProviderCredentialStore {
    public static let defaultAccessGroup = "MM5YXC7T6E.com.shinycomputers.contextpanel.credentials"

    private let accessGroup: String?

    public init(accessGroup: String? = defaultAccessGroup) {
        self.accessGroup = accessGroup
    }

    public func data(for key: ProviderCredentialKey) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ProviderCredentialStoreError.keychainStatus(operation: "read", status: status)
        }
        return item as? Data
    }

    public func store(_ data: Data, for key: ProviderCredentialKey) throws {
        var query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychainStatus(operation: "update", status: updateStatus)
        }

        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.keychainStatus(operation: "store", status: addStatus)
        }
    }

    public func remove(_ key: ProviderCredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychainStatus(operation: "delete", status: status)
        }
    }

    private func baseQuery(for key: ProviderCredentialKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public final class InMemoryProviderCredentialStore: ProviderCredentialStore, @unchecked Sendable {
    private var values: [ProviderCredentialKey: Data]
    private let lock = NSLock()

    public init(values: [ProviderCredentialKey: Data] = [:]) {
        self.values = values
    }

    public func data(for key: ProviderCredentialKey) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func store(_ data: Data, for key: ProviderCredentialKey) throws {
        lock.withLock { values[key] = data }
    }

    public func remove(_ key: ProviderCredentialKey) throws {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
}
