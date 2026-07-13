import Foundation

enum GoogleAccountMigration {
    static let oldAccountID = "gemini-code-assist-default"
    static let newAccountID = "google-antigravity-default"

    static func migratedDisplayName(from displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Gemini" ? "Antigravity" : trimmed
    }
}
