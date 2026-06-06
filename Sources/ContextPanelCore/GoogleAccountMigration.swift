import Foundation

enum GoogleAccountMigration {
    static let oldAccountID = "gemini-code-assist-default"
    static let newAccountID = "google-antigravity-default"

    static func migratedDisplayName(from displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Gemini" ? "Antigravity" : trimmed
    }

    static func migrateCredentials(_ store: any ProviderCredentialStoring) {
        guard let credentials = try? store.load(accountID: oldAccountID) else { return }
        do {
            guard try store.load(accountID: newAccountID) == nil else { return }
        } catch {
            return
        }
        try? store.save(credentials, accountID: newAccountID)
    }
}
