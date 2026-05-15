import Foundation

enum ClaudeAccountMigration {
    static let oldAccountID = "claude-local-default"
    static let newAccountID = "claude-oauth-default"

    static func migrateAccountConfiguration(_ document: AccountConfigurationDocument, now: Date) -> AccountConfigurationDocument {
        var document = document
        var changed = false
        document.accounts = document.accounts.map { account in
            guard account.id == oldAccountID, account.connectorKind == .claudeLocalStatus else {
                return account
            }
            changed = true
            return LocalProviderAccountConfiguration(
                id: newAccountID,
                provider: .anthropic,
                connectorKind: .claudeOAuthUsage,
                displayName: account.displayName.isEmpty ? "Claude" : account.displayName,
                isEnabled: account.isEnabled
            )
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
