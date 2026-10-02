import CloudKit
import ContextPanelCore
import Foundation

/// Uses the existing private container; the secret is never in a usage record.
actor SharedAccountIdentityCloudKitStore {
    private let container: CKContainer
    private let cache = ProviderCredentialStore(service: "Context Panel shared account identity")
    private var memoryKeys: [CompanionCloudKitUserScope: ProviderAccountIdentityKey] = [:]
    private let recordID = CKRecord.ID(recordName: "ContextPanelAccountIdentityKey.v1")
    private static let recordType = "ContextPanelAccountIdentityKey"
    private static let encryptedField = "keyMaterial"

    init(containerIdentifier: String) { container = CKContainer(identifier: containerIdentifier) }

    func resolve(_ material: ProviderAccountIdentityMaterial) async -> SharedProviderAccountIdentity? {
        guard let scope = await currentScope() else { return nil }
        let cacheID = "identity:" + scope.rawValue
        let cachedData = try? cache.load(accountID: cacheID)
        let establishedKey = memoryKeys[scope] ?? cachedData.flatMap { ScopedProviderAccountIdentityKey.decode($0, scope: scope) }
        let key = await ProviderIdentityKeyBootstrap.resolve(
            load: { await self.loadKey(scope: scope) }, establishedKey: establishedKey, insertIfAbsent: { await self.insertIfAbsent($0, scope: scope) })
        // Never carry a successful response into a different iCloud user's namespace.
        guard await currentScope() == scope else { return nil }
        if let key {
            guard let encoded = try? ScopedProviderAccountIdentityKey.encode(key, scope: scope) else { return nil }
            try? cache.save(encoded, accountID: cacheID)
            memoryKeys[scope] = key
            return key.identity(for: material)
        }
        // Offline reads may reuse an established key, but never create a local-only key.
        if let cached = establishedKey {
            memoryKeys[scope] = cached
            return cached.identity(for: material)
        }
        return nil
    }

    private func currentScope() async -> CompanionCloudKitUserScope? {
        do {
            guard try await container.accountStatus() == .available else { return nil }
            let user = try await container.userRecordID()
            return CompanionCloudKitUserScope.derive(containerIdentifier: container.containerIdentifier ?? "",
                userRecordName: user.recordName)
        } catch { return nil }
    }

    private func decode(_ record: CKRecord, scope: CompanionCloudKitUserScope) -> ProviderAccountIdentityKey? {
        guard record.recordType == Self.recordType,
              let data = record.encryptedValues[Self.encryptedField] as? Data else { return nil }
        return ScopedProviderAccountIdentityKey.decode(data, scope: scope)
    }

    private func loadKey(scope: CompanionCloudKitUserScope) async -> ProviderIdentityKeyLoad {
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let key = decode(record, scope: scope) else { return .unavailable }
            return .available(key)
        } catch let error as CKError where error.code == .unknownItem {
            return .absent
        } catch { return .unavailable }
    }

    private func insertIfAbsent(_ key: ProviderAccountIdentityKey, scope: CompanionCloudKitUserScope) async -> ProviderAccountIdentityKey? {
        guard await currentScope() == scope else { return nil }
        do {
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record.encryptedValues[Self.encryptedField] = try ScopedProviderAccountIdentityKey.encode(key, scope: scope) as NSData
            let result = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [],
                savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[recordID] else { return nil }
            return decode(try saved.get(), scope: scope)
        } catch {
            // Concurrent first installs converge on the server's winner, not the proposed key.
            if case let .available(winner) = await loadKey(scope: scope) { return winner }
            return nil
        }
    }
}
