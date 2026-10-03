import Foundation

public enum CodexHomeBindingError: LocalizedError {
    case missingAuthFile, sharedHome

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile: "Select a Codex home containing a regular auth.json file. For a symbolic login file, use Select File to authorize its target."
        case .sharedHome: "This Codex home is already assigned to another enabled account. Change that account’s home or remove its panel entry before reusing it."
        }
    }
}

/// Only filesystem metadata is inspected. Credential contents remain in the existing adapter.
public enum CodexHomeSourceState: Equatable, Sendable {
    case sessionHistory, unconfigured, available, unavailable, unavailableUsingSavedLogin
}

public enum CodexHomeBinding {
    /// The main Codex history can mix logins, so it cannot override a different home.
    public static func isSharedSessionMismatch(
        account: LocalProviderAccountConfiguration, sessions: URL,
        siblings: [LocalProviderAccountConfiguration] = [],
        mainHome: URL = ContextPanelLocations.realUserHomeDirectory().appending(path: ".codex")
    ) -> Bool {
        let selected = sessions.resolvingSymlinksInPath().standardizedFileURL.path
        let shared = mainHome.appending(path: "sessions").resolvingSymlinksInPath().standardizedFileURL.path
        let boundHome = account.authPath.map { path in
            URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                .deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        }
        if (selected == shared || selected.hasPrefix(shared + "/")) && boundHome != mainHome.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        return siblings.contains { sibling in
            guard sibling.id != account.id, sibling.isEnabled, sibling.provider == .openAI,
                  let path = sibling.authPath else { return false }
            let home = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).deletingLastPathComponent()
            guard home.resolvingSymlinksInPath().standardizedFileURL.path != boundHome else { return false }
            let siblingSessions = home.appending(path: "sessions").resolvingSymlinksInPath().standardizedFileURL.path
            return selected == siblingSessions || selected.hasPrefix(siblingSessions + "/")
        }
    }

    public static func sourceState(
        account: LocalProviderAccountConfiguration, authFileAvailable: Bool, hasSavedLogin: Bool
    ) -> CodexHomeSourceState {
        if account.codexQuotaPath != nil { return .sessionHistory }
        guard account.effectiveAuthPath != nil else { return .unconfigured }
        if authFileAvailable { return .available }
        return hasSavedLogin ? .unavailableUsingSavedLogin : .unavailable
    }

    public static func commit(
        accountID: String, home: URL, accountStore: AccountConfigurationStore,
        bookmarkStore: SecureFileBookmarkStore, deleteImportedCredential: @Sendable (String) throws -> Void,
        lock: SnapshotRefreshLock = .appDefault(), now: Date = Date()
    ) async throws -> AccountConfigurationDocument? {
        try await lock.withLock {
            let loaded = accountStore.load(now: now)
            guard loaded.status != .failure else { throw AccountConfigurationMutationError.unreadableConfiguration }
            var document = loaded.document
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

    /// Create the named source and its bookmark together; a busy refresh saves nothing.
    public static func add(account: LocalProviderAccountConfiguration, home: URL,
                           accountStore: AccountConfigurationStore, bookmarkStore: SecureFileBookmarkStore,
                           lock: SnapshotRefreshLock = .appDefault(), now: Date = Date()) async throws -> AccountConfigurationDocument? {
        try await lock.withLock {
            let loaded = accountStore.load(now: now)
            guard loaded.status != .failure else { throw AccountConfigurationMutationError.unreadableConfiguration }
            var document = loaded.document
            let updated = try bind(account: account, home: home, siblings: document.accounts)
            guard let path = updated.authPath else { throw CodexHomeBindingError.missingAuthFile }
            try bookmarkStore.createAndStoreBookmark(for: URL(fileURLWithPath: path), path: path)
            guard bookmarkStore.canReadBookmark(for: path) else { throw CocoaError(.fileReadNoPermission) }
            document.accounts.append(updated)
            document.updatedAt = now
            try accountStore.save(document)
            return document
        }
    }

    public static func usingAuthFile(account: LocalProviderAccountConfiguration,
                                     siblings: [LocalProviderAccountConfiguration]) throws -> LocalProviderAccountConfiguration {
        guard let path = account.authPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexHomeBindingError.missingAuthFile
        }
        let canonical = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        for sibling in siblings where sibling.id != account.id && sibling.isEnabled && sibling.provider == .openAI {
            if let other = sibling.authPath,
               URL(fileURLWithPath: NSString(string: other).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL == canonical {
                throw CodexHomeBindingError.sharedHome
            }
        }
        var result = account
        result.codexQuotaPath = nil
        return result
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
            guard let path = sibling.authPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
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
