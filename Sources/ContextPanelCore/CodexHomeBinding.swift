import Foundation

public enum CodexHomeBindingError: LocalizedError {
    case missingAuthFile, sharedHome

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile: "Select a Codex home containing a regular auth.json file. For a symbolic login file, use Select File to authorize its target."
        case .sharedHome: "This Codex home is already assigned to another enabled account."
        }
    }
}

/// Only filesystem metadata is inspected. Credential contents remain in the existing adapter.
public enum CodexHomeBinding {
    public static func commit(
        accountID: String, home: URL, accountStore: AccountConfigurationStore,
        bookmarkStore: SecureFileBookmarkStore, deleteImportedCredential: @Sendable (String) throws -> Void,
        lock: SnapshotRefreshLock = .appDefault(), now: Date = Date()
    ) async throws -> AccountConfigurationDocument? {
        try await lock.withLock {
            var document = accountStore.load(now: now).document
            guard let index = document.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw CodexHomeBindingError.missingAuthFile
            }
            let updated = try bind(account: document.accounts[index], home: home, siblings: document.accounts)
            guard let path = updated.authPath else { throw CodexHomeBindingError.missingAuthFile }
            try bookmarkStore.createAndStoreBookmark(for: URL(fileURLWithPath: path), path: path)
            guard bookmarkStore.canReadBookmark(for: path) else { throw CocoaError(.fileReadNoPermission) }
            try deleteImportedCredential(accountID)
            document.accounts[index] = updated
            document.updatedAt = now
            try accountStore.save(document)
            return document
        }
    }

    public static func bind(
        account: LocalProviderAccountConfiguration,
        home: URL,
        siblings: [LocalProviderAccountConfiguration]
    ) throws -> LocalProviderAccountConfiguration {
        let auth = home.appending(path: "auth.json")
        let canonical = auth.resolvingSymlinksInPath().standardizedFileURL
        let values = try? auth.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw CodexHomeBindingError.missingAuthFile }
        for sibling in siblings where sibling.id != account.id && sibling.isEnabled && sibling.provider == .openAI {
            guard let path = sibling.effectiveAuthPath else { continue }
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            if source.resolvingSymlinksInPath().standardizedFileURL == canonical {
                throw CodexHomeBindingError.sharedHome
            }
        }
        var result = account
        result.authPath = auth.path
        result.codexQuotaPath = nil
        result.codexClient = .codex
        return result
    }
}
