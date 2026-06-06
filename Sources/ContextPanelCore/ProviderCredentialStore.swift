import Foundation
import Security

public protocol ProviderCredentialLoading: Sendable {
    func load(accountID: String) throws -> Data?
}

public protocol ProviderCredentialAvailabilityChecking: Sendable {
    func contains(accountID: String) throws -> Bool
}

public protocol ProviderCredentialStoring: ProviderCredentialLoading {
    func save(_ data: Data, accountID: String) throws
}

public struct ProviderCredentialStore: ProviderCredentialStoring, ProviderCredentialAvailabilityChecking {
    public enum StoreError: Error, Sendable {
        case unhandledStatus(OSStatus)
    }

    public static let defaultService = "com.shinycomputers.contextpanel.provider-credentials"
    public static let defaultAccessGroup = "MM5YXC7T6E.com.shinycomputers.contextpanel.provider-credentials"

    private let service: String
    private let accessGroup: String?

    public init(service: String = Self.defaultService, accessGroup: String? = Self.defaultAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load(accountID: String) throws -> Data? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.unhandledStatus(status) }
        return item as? Data
    }

    public func contains(accountID: String) throws -> Bool {
        var query = baseQuery(accountID: accountID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw StoreError.unhandledStatus(status) }
        return true
    }

    public func save(_ data: Data, accountID: String) throws {
        let query = baseQuery(accountID: accountID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw StoreError.unhandledStatus(updateStatus) }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.unhandledStatus(addStatus) }
    }

    public func delete(accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(accountID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public struct GenericPasswordCredentialLoader: ProviderCredentialLoading, ProviderCredentialAvailabilityChecking {
    public enum LoadError: Error, Sendable {
        case unhandledStatus(OSStatus)
    }

    private let service: String
    private let useDataProtectionKeychain: Bool

    public init(service: String, useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func load(accountID: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LoadError.unhandledStatus(status) }
        return item as? Data
    }

    public func contains(accountID: String) throws -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LoadError.unhandledStatus(status) }
        return true
    }
}

public final class InMemoryProviderCredentialStore: ProviderCredentialStoring, ProviderCredentialAvailabilityChecking, @unchecked Sendable {
    private var storage: [String: Data]

    public init(storage: [String: Data]) {
        self.storage = storage
    }

    public func load(accountID: String) throws -> Data? {
        storage[accountID]
    }

    public func contains(accountID: String) throws -> Bool {
        storage[accountID] != nil
    }

    public func save(_ data: Data, accountID: String) throws {
        storage[accountID] = data
    }
}

extension ProviderCredentialStore.StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

extension GenericPasswordCredentialLoader.LoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
