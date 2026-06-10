import Foundation

enum ClaudeAccountMigration {
    static let oldAccountID = "claude-local-default"
    static let newAccountID = "claude-oauth-default"

    static func migrateAccountConfiguration(_ document: AccountConfigurationDocument, now: Date) -> AccountConfigurationDocument {
        var document = document
        var changed = false
        var seenAccountIDs: Set<String> = []
        var migratedAccounts: [LocalProviderAccountConfiguration] = []

        for account in document.accounts {
            let migrated = account.id == oldAccountID && account.connectorKind == .claudeOAuthUsage
                ? LocalProviderAccountConfiguration(
                    id: newAccountID,
                    provider: .anthropic,
                    connectorKind: .claudeOAuthUsage,
                    displayName: account.displayName.isEmpty ? "Claude" : account.displayName,
                    isEnabled: account.isEnabled
                )
                : account

            guard seenAccountIDs.insert(migrated.id).inserted else {
                changed = true
                continue
            }
            migratedAccounts.append(migrated)
        }

        if document.accounts != migratedAccounts {
            changed = true
            document.accounts = migratedAccounts
        }

        if changed {
            document.updatedAt = now
        }
        return document
    }

    static func migrateClaudeCredentials(_ store: any ProviderCredentialStoring) {
        guard let credentials = try? store.load(accountID: oldAccountID) ?? nil else { return }
        guard (try? store.load(accountID: newAccountID) ?? nil) == nil else { return }
        try? store.save(credentials, accountID: newAccountID)
    }
}
